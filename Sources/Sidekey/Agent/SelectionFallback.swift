import AppKit
import CoreGraphics
import Foundation
import os.log

/// Async Cmd+C fallback for capturing the user's selection from
/// Electron / Chromium apps that don't expose `kAXSelectedTextAttribute`
/// reliably (Cursor, VS Code, Slack, Discord, Notion desktop).
///
/// **Architectural invariant (v3): the dance must run OUTSIDE the
/// `NSEvent.flagsChanged` monitor closure.** v1 (#103) and v2 (#106)
/// posted synthetic `CGEvent` Cmd+C synchronously inside the gesture's
/// flagsChanged handler. The synthesised events re-entered the same
/// global monitor, tripped the state machine's
/// `cancel-on-modifier-change` path (Left-Cmd-down delivered while
/// physical Right-Cmd was still held → modifiers = (Cmd + LeftCmd) →
/// `!isRightCommandOnly` → `cancelGesture()`), and the gesture committed
/// to neither tap nor hold. Right Cmd silently broke.
///
/// v3 splits the snapshot path:
///
/// 1. On Right Cmd press → `FocusSnapshot.capture()` does AX-only read
///    (fast, no synthetic events). Stays inside the NSEvent handler.
/// 2. After the gesture commits (`onTap` or `onHoldEnd` fired) →
///    `AgentController` calls `SelectionFallback.captureAsync` if the AX
///    selection was nil/empty. The dance executes via
///    `DispatchQueue.main.async`, on a fresh runloop tick, AFTER the
///    flagsChanged handler has returned. Synthesised events have no
///    monitor to re-enter.
///
/// The frontmost-PID guard inside the dispatched block protects against
/// the user switching focus between gesture press and the deferred
/// dance (Cmd+Tab during the ~200ms hold threshold). Without the guard
/// the dance would post Cmd+C into the wrong app and capture its
/// selection — a privacy and correctness bug.
///
/// All collaborators are injected via `Env` so the dispatcher, frontmost
/// PID source, pasteboard primitives, CGEvent post, sleep, suppression,
/// and the deferred unsuppress can each be stubbed independently.
enum SelectionFallback {
    /// Settle gap after posting Cmd+C, before reading the pasteboard.
    /// Mirrors `AutoPasteEngine.postWriteSettleMs` — short enough to
    /// feel instant, long enough for the target app's copy handler to
    /// land bytes on the pasteboard.
    static let postCmdCSettleSeconds: TimeInterval = 0.08

    /// How long `ClipboardSuppression` stays raised after reading the
    /// pasteboard. Must exceed one `ClipboardWatcher.pollIntervalSeconds`
    /// (500 ms) plus a safety margin so the watcher's next poll sees the
    /// flag still set and skips the transient pasteboard state. 700 ms
    /// = 500 (poll interval) + 200 (margin).
    static let unsuppressDelaySeconds: TimeInterval = 0.7

    /// Microsecond gap between adjacent synthesised key events. Matches
    /// `AutoPasteEngine.keyEventGapUs`: shorter than this and some apps
    /// coalesce / drop events.
    static let keyEventGapUs: UInt32 = 12_000

    /// Virtual keycode for `C` (kVK_ANSI_C).
    private static let cKeyCode: CGKeyCode = 0x08
    /// Virtual keycode for the Command key (kVK_Command).
    private static let commandKeyCode: CGKeyCode = 0x37

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "agent")

    /// Production entry. Dispatches the Cmd+C dance onto the main queue
    /// (out of any caller's NSEvent monitor closure), guards against
    /// frontmost-PID drift, and returns the captured selection through
    /// `completion`. Pass `nil`-yielding `completion` for fire-and-forget.
    ///
    /// `completion` is invoked on the main queue (same queue the dance
    /// runs on). Empty / nil pasteboard reads are normalised to `nil`.
    @MainActor
    static func captureAsync(
        targetPID: pid_t,
        completion: @escaping (String?) -> Void
    ) {
        captureAsync(
            targetPID: targetPID,
            env: .live,
            completion: completion
        )
    }

    /// Testable entry. `Env` lets tests inject a synchronous dispatcher,
    /// stub frontmost PID, stub pasteboard primitives, and assert side
    /// effects deterministically.
    @MainActor
    static func captureAsync(
        targetPID: pid_t,
        env: Env,
        completion: @escaping (String?) -> Void
    ) {
        env.dispatcher {
            performDance(targetPID: targetPID, env: env, completion: completion)
        }
    }

    private static func performDance(
        targetPID: pid_t,
        env: Env,
        completion: @escaping (String?) -> Void
    ) {
        // 1. Frontmost-PID guard. If the user pressed Right Cmd in
        //    Cursor, then Cmd+Tab'd into a different app before the tap
        //    released, the deferred dance would synthesise Cmd+C into
        //    that different app. Privacy + correctness bug. Skip the
        //    dance and report no selection.
        let liveFrontmostPID = env.frontmostPID()
        guard liveFrontmostPID == targetPID else {
            os_log(
                "selection.fallback.skipped_pid_mismatch target_pid=%{public}d live_pid=%{public}d",
                log: log,
                type: .info,
                Int(targetPID),
                Int(liveFrontmostPID)
            )
            completion(nil)
            return
        }

        os_log(
            "selection.fallback.started target_pid=%{public}d",
            log: log,
            type: .info,
            Int(targetPID)
        )

        // 2. Snapshot first so we can always restore. If anything
        //    between here and the restore call fails, the user's
        //    clipboard is still returned to its original state.
        let snap = env.pasteboardSnapshot()

        // 3. Raise the suppression flag BEFORE any pasteboard mutation
        //    so `ClipboardWatcher`'s next 500 ms poll skips the synth
        //    copy AND the restore. The flag is cleared via
        //    `scheduleUnsuppress` after a delay > one poll interval.
        env.setSuppressed(true)

        // 3a. Baseline the pasteboard changeCount BEFORE the synthetic
        //     Cmd+C — the only reliable signal that a copy actually
        //     happened. Cmd+C with no selection is a no-op that leaves
        //     the pasteboard (and changeCount) untouched, so the read
        //     below would otherwise return the user's STALE clipboard.
        let changeCountBeforeCopy = env.currentChangeCount()

        // 4. Post Cmd+C in the target app's context. The 4-event
        //    sequence mirrors `AutoPasteEngine.postCmdV` reversed —
        //    Command-down → C-down → C-up → Command-up — because a
        //    single-event post with `flags = .maskCommand` is not
        //    honoured by every app.
        env.postCmdC()

        // 5. Settle. Short enough to feel instant, long enough for the
        //    target app's copy handler to land bytes on the pasteboard.
        env.sleepAfterPost()

        // 6. Did the synthetic Cmd+C actually copy anything? A real copy
        //    clears + writes the pasteboard, bumping `changeCount` (even
        //    when the copied text equals the prior clipboard). If it did
        //    not move, there was no selection and `raw` below is stale.
        let didCopy = env.currentChangeCount() != changeCountBeforeCopy

        // 6b. Read the pasteboard. May be nil (password / secure field
        //     where Cmd+C is blocked) or empty (no selection) — the
        //     guard below handles both, plus the `didCopy` check.
        let raw = env.readPasteboardString()

        // 7. Restore the user's clipboard immediately. Restore even
        //    when `raw` is nil — we still wrote (or attempted to write)
        //    a synthetic copy via Cmd+C and must not leak it.
        env.pasteboardRestore(snap)

        // 8. Raise the watcher's skip-through threshold to the
        //    post-restore changeCount. The 700 ms unsuppress delay
        //    already covers most race windows (one poll interval is
        //    500 ms), but the threshold makes the contract independent
        //    of timing. If the deferred unsuppress somehow fires
        //    before the watcher's next poll, the threshold still
        //    catches the residual bumps from steps 4 and 7.
        env.suppressThrough(env.currentChangeCount())

        // 9. Schedule the suppression release. Must be deferred so the
        //    watcher's next poll cycle (~500 ms after the dance) sees
        //    the flag still set and skips the change-count bumps emitted
        //    by steps 4 and 7.
        env.scheduleUnsuppress(unsuppressDelaySeconds) {
            env.setSuppressed(false)
        }

        // 10. Reject a no-op Cmd+C (no selection) BEFORE trusting `raw`:
        //     an unchanged changeCount means the pasteboard was never
        //     written, so `raw` is the user's stale clipboard, not a
        //     selection. Fix for "no selection -> agent gets last clipboard".
        guard didCopy else {
            os_log(
                "selection.fallback.aborted_no_copy_stale_clipboard",
                log: log,
                type: .info
            )
            completion(nil)
            return
        }

        // 11. Normalise empty / nil -> nil. Secure / password field copies
        //     arrive as either nil or "" depending on the app.
        guard let raw, !raw.isEmpty else {
            os_log(
                "selection.fallback.aborted_secure_field_or_empty",
                log: log,
                type: .info
            )
            completion(nil)
            return
        }

        os_log(
            "selection.fallback.completed len=%{public}d",
            log: log,
            type: .info,
            raw.count
        )
        completion(raw)
    }

    /// Default 4-event Cmd+C sequence: Command-down → C-down → C-up →
    /// Command-up with `keyEventGapUs` between events. Mirrors
    /// `AutoPasteEngine.postCmdV` — single-event posts with
    /// `flags = .maskCommand` are not honoured by every app.
    static func defaultPostCmdC() {
        let source = CGEventSource(stateID: .hidSystemState)
        post(keyCode: commandKeyCode, down: true, flags: [], source: source)
        usleep(keyEventGapUs)
        post(keyCode: cKeyCode, down: true, flags: .maskCommand, source: source)
        usleep(keyEventGapUs)
        post(keyCode: cKeyCode, down: false, flags: .maskCommand, source: source)
        usleep(keyEventGapUs)
        post(keyCode: commandKeyCode, down: false, flags: [], source: source)
    }

    private static func post(
        keyCode: CGKeyCode,
        down: Bool,
        flags: CGEventFlags,
        source: CGEventSource?
    ) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            return
        }
        if !flags.isEmpty {
            event.flags = flags
        }
        event.post(tap: .cghidEventTap)
    }
}

extension SelectionFallback {
    /// Injectable collaborators. `dispatcher` is the critical seam —
    /// production hands work to `DispatchQueue.main.async`, tests record
    /// the block so they can run it deterministically and verify that
    /// the dance is NOT executed inline with the call site (the
    /// architectural invariant that v1 / v2 broke).
    struct Env {
        let frontmostPID: () -> pid_t
        let pasteboardSnapshot: () -> PasteboardSnapshot
        let pasteboardRestore: (PasteboardSnapshot) -> Void
        let setSuppressed: (Bool) -> Void
        let scheduleUnsuppress: (TimeInterval, @escaping () -> Void) -> Void
        let postCmdC: () -> Void
        let sleepAfterPost: () -> Void
        let readPasteboardString: () -> String?
        /// `NSPasteboard.general.changeCount` after the restore lands.
        /// Used to raise the watcher's skip-through threshold so the
        /// next poll skips the residual changeCount bumps even if the
        /// scheduled unsuppress fires before that poll.
        let currentChangeCount: () -> Int
        /// Forwards into `ClipboardSuppression.suppressThrough(changeCount:)`.
        /// Production binds to the shared instance; tests stub it to a
        /// recorder.
        let suppressThrough: (Int) -> Void
        /// **Architectural anti-re-entry seam.** Production binds to
        /// `DispatchQueue.main.async`. Tests can record the block and
        /// run it on demand to verify the dance never executes inline
        /// with the call site (which would re-enter the NSEvent monitor
        /// and break Right Cmd).
        let dispatcher: (@escaping () -> Void) -> Void

        static let live = Env(
            frontmostPID: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            },
            pasteboardSnapshot: Pasteboard.snapshot,
            pasteboardRestore: Pasteboard.restore,
            setSuppressed: { flag in
                // ClipboardSuppression is @MainActor. The dance always
                // runs from `DispatchQueue.main.async` (main thread) so
                // assumeIsolated is safe here. The v1 break was about
                // event re-entry, NOT about isolation (investigation
                // confirmed assumeIsolated would have trapped, not
                // silently no-op'd). See SelectionFallback header.
                MainActor.assumeIsolated {
                    ClipboardSuppression.shared.setSuppressed(flag)
                }
            },
            scheduleUnsuppress: { delay, block in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    block()
                }
            },
            postCmdC: SelectionFallback.defaultPostCmdC,
            sleepAfterPost: {
                Thread.sleep(forTimeInterval: postCmdCSettleSeconds)
            },
            readPasteboardString: {
                NSPasteboard.general.string(forType: .string)
            },
            currentChangeCount: {
                NSPasteboard.general.changeCount
            },
            suppressThrough: { count in
                MainActor.assumeIsolated {
                    ClipboardSuppression.shared.suppressThrough(changeCount: count)
                }
            },
            dispatcher: { block in
                DispatchQueue.main.async {
                    block()
                }
            }
        )
    }
}

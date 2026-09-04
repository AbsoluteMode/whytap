import AppKit
import CoreGraphics
import Foundation
import os.log

/// Snapshot of the user's system pasteboard captured before the drop
/// pipeline mutates it. Each item is a dictionary keyed by raw
/// `NSPasteboard.PasteboardType` string (`"public.utf8-plain-text"`, etc.)
/// with the corresponding `Data` payload. Empty `items` means the
/// pasteboard had no readable items at snapshot time (the restore step
/// will then just clear the pasteboard).
struct PasteboardSnapshot: Equatable {
    let items: [[String: Data]]
}

/// Orchestrates the drop-pipeline paste step. The drop hotkey may still be
/// physically held when the model returns, the floating panel may have
/// shifted focus, and posting CGEvents requires the Post Event TCC
/// permission. This engine sequences:
///
/// ```
/// hotkey press  -> rememberTargetBeforeRecording()  (capture pid + name)
/// model returns -> paste(text):
///   1. snapshot the current pasteboard so we can restore it after the
///      synth paste settles — drop must NOT pollute the user's clipboard
///      history (dictation lives in the drop history surface instead)
///   2. set the shared clipboard-suppression flag so `ClipboardWatcher`
///      does not record either the dictation OR the restored snapshot as
///      a clipboard history entry
///   3. write the dictation text to the pasteboard
///   4. preflight Post Event permission (advisory log only)
///   5. wait until Cmd/Opt/Ctrl/Shift modifiers are all released
///   6. restore frontmost focus to the remembered target (if it's still
///      alive)
///   7. settle 80 ms
///   8. post Cmd+V via explicit Command-down / V-down / V-up / Command-up
///      sequence with 12 ms between events
///   9. restore the pasteboard snapshot, returning the user's clipboard to
///      what it held before the drop
///  10. clear the clipboard-suppression flag
/// ```
///
/// Failure modes:
///  * Empty text -> return false BEFORE snapshotting (nothing happened).
///  * Pasteboard write fails -> return false; no restore (write never
///    landed). Suppression flag is cleared.
///  * Modifier-wait timeout -> return false; restore the snapshot so the
///    user's clipboard is not left holding the dictation. Suppression
///    flag is cleared.
///
/// All collaborators are injectable for unit tests via the designated
/// initialiser. The convenience init binds the production defaults.
@MainActor
final class AutoPasteEngine {
    struct RememberedTarget: Equatable {
        let pid: pid_t
        let name: String
    }

    typealias FlagsStateFn = () -> CGEventFlags
    typealias FrontmostAppInfoFn = () -> RememberedTarget?
    typealias ActivateFn = (pid_t) -> Bool
    typealias IsTerminatedFn = (pid_t) -> Bool
    typealias PermissionFn = (Bool) -> Bool
    typealias PasteboardWriteFn = (String) -> (before: Int, after: Int)?
    typealias PostEventFn = (CGKeyCode, Bool, CGEventFlags) -> Void
    typealias SleepUsFn = (UInt32) -> Void
    typealias NowMsFn = () -> UInt64
    typealias PasteboardSnapshotFn = () -> PasteboardSnapshot
    typealias PasteboardRestoreFn = (PasteboardSnapshot) -> Void
    typealias SetClipboardSuppressionFn = (Bool) -> Void
    typealias SuppressClipboardThroughFn = (Int) -> Void
    typealias CurrentChangeCountFn = () -> Int

    /// Logger seam. The string passed in is already formatted with the
    /// diagnostic-line key/value pairs (`autopaste_foo k=v`); the production
    /// default forwards it to `os_log` as a public message; tests can
    /// capture into an array.
    enum LogLevel { case info, error }
    typealias LogFn = (LogLevel, String) -> Void

    // MARK: - Public configuration

    /// Time budget for waiting until physical modifiers are released. 800 ms
    /// matches friend's recipe; longer than this and we'd rather drop into
    /// the fallback toast than block the pipeline indefinitely.
    static let modifierWaitBudgetMs: UInt64 = 800
    static let modifierPollIntervalMs: UInt64 = 20

    /// Time budget for the frontmost app to match the activated target.
    static let focusRestoreBudgetMs: UInt64 = 500
    static let focusRestorePollIntervalMs: UInt64 = 25

    /// Settle gap between focus restore and pasteboard write, and between
    /// pasteboard write and posting Cmd+V. 80 ms is friend's empirical
    /// number — long enough for the OS to settle, short enough to feel
    /// instant next to the multi-second transcribe/process step.
    static let postFocusSettleMs: UInt32 = 80
    static let postWriteSettleMs: UInt32 = 80

    /// Microsecond gap between adjacent synthesised key events. Friend's
    /// section 7: shorter than this and some apps coalesce / drop events.
    static let keyEventGapUs: UInt32 = 12_000

    private static let vKeyCode: CGKeyCode = 0x09     // kVK_ANSI_V
    private static let commandKeyCode: CGKeyCode = 0x37 // kVK_Command

    // MARK: - Injected collaborators

    private let flagsState: FlagsStateFn
    private let frontmostAppInfo: FrontmostAppInfoFn
    private let activate: ActivateFn
    private let isTerminated: IsTerminatedFn
    private let permissionGranted: PermissionFn
    private let pasteboardWrite: PasteboardWriteFn
    private let postEvent: PostEventFn
    private let sleepUs: SleepUsFn
    private let nowMs: NowMsFn
    private let logEmit: LogFn
    private let pasteboardSnapshot: PasteboardSnapshotFn
    private let pasteboardRestore: PasteboardRestoreFn
    private let setClipboardSuppression: SetClipboardSuppressionFn
    private let suppressClipboardThrough: SuppressClipboardThroughFn
    private let currentChangeCount: CurrentChangeCountFn

    // MARK: - State

    private var remembered: RememberedTarget?

    // MARK: - Initialisers

    convenience init(suppression: ClipboardSuppression = .shared) {
        let log = OSLog(subsystem: "com.rootwise.sidekey", category: "pipeline")
        self.init(
            flagsState: { CGEventSource.flagsState(.hidSystemState) },
            frontmostAppInfo: AutoPasteEngine.defaultFrontmostAppInfo,
            activate: AutoPasteEngine.defaultActivate,
            isTerminated: AutoPasteEngine.defaultIsTerminated,
            permissionGranted: PermissionsHelper.postEventAccessGranted,
            pasteboardWrite: AutoPasteEngine.defaultPasteboardWrite,
            postEvent: AutoPasteEngine.defaultPostEvent,
            sleepUs: { usleep($0) },
            nowMs: { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
            logEmit: { level, message in
                let type: OSLogType = (level == .error) ? .error : .info
                os_log("%{public}@", log: log, type: type, message)
            },
            pasteboardSnapshot: Pasteboard.snapshot,
            pasteboardRestore: Pasteboard.restore,
            setClipboardSuppression: { flag in suppression.setSuppressed(flag) },
            suppressClipboardThrough: { count in suppression.suppressThrough(changeCount: count) },
            currentChangeCount: { NSPasteboard.general.changeCount }
        )
    }

    init(
        flagsState: @escaping FlagsStateFn,
        frontmostAppInfo: @escaping FrontmostAppInfoFn,
        activate: @escaping ActivateFn,
        isTerminated: @escaping IsTerminatedFn,
        permissionGranted: @escaping PermissionFn,
        pasteboardWrite: @escaping PasteboardWriteFn,
        postEvent: @escaping PostEventFn,
        sleepUs: @escaping SleepUsFn,
        nowMs: @escaping NowMsFn,
        logEmit: @escaping LogFn,
        pasteboardSnapshot: @escaping PasteboardSnapshotFn = { PasteboardSnapshot(items: []) },
        pasteboardRestore: @escaping PasteboardRestoreFn = { _ in },
        setClipboardSuppression: @escaping SetClipboardSuppressionFn = { _ in },
        suppressClipboardThrough: @escaping SuppressClipboardThroughFn = { _ in },
        currentChangeCount: @escaping CurrentChangeCountFn = { 0 }
    ) {
        self.flagsState = flagsState
        self.frontmostAppInfo = frontmostAppInfo
        self.activate = activate
        self.isTerminated = isTerminated
        self.permissionGranted = permissionGranted
        self.pasteboardWrite = pasteboardWrite
        self.postEvent = postEvent
        self.sleepUs = sleepUs
        self.nowMs = nowMs
        self.logEmit = logEmit
        self.pasteboardSnapshot = pasteboardSnapshot
        self.pasteboardRestore = pasteboardRestore
        self.setClipboardSuppression = setClipboardSuppression
        self.suppressClipboardThrough = suppressClipboardThrough
        self.currentChangeCount = currentChangeCount
    }

    // MARK: - Public API

    /// Capture the frontmost app at hotkey-press time, before any UI shifts
    /// focus. The drop pipeline reuses this snapshot in `paste(_:)` to
    /// restore focus if it has drifted by the time the model returns.
    func rememberTargetBeforeRecording() {
        guard let target = frontmostAppInfo() else {
            remembered = nil
            logEmit(.info, "autopaste_target_remembered name=(none) pid=0")
            return
        }
        remembered = target
        logEmit(.info, "autopaste_target_remembered name=\(target.name) pid=\(target.pid)")
    }

    /// Returns the last value captured by `rememberTargetBeforeRecording()`.
    /// Internal because the production AppDelegate already has the name in
    /// hand from its own capture path; exposing this keeps the engine
    /// authoritative when callers want one consistent source.
    func currentTarget() -> RememberedTarget? {
        remembered
    }

    /// Convenience accessor for the remembered target's display name.
    /// Used by the history strip's "Paste to <App> ↵" hint as a fallback
    /// when `NSWorkspace.frontmostApplication` returns Sidekey itself.
    var currentTargetName: String? { remembered?.name }

    /// Settle window after the synth Cmd+V is posted but before the
    /// snapshot is restored. Gives the target app's editor enough time
    /// to consume the pasted content before the pasteboard flips back to
    /// the user's original clipboard. Empirically 120 ms is enough for
    /// every app tested (TextEdit, Notes, Slack, VS Code, Terminal).
    static let postPasteRestoreMs: UInt32 = 120

    /// Full paste pipeline. Returns `true` on success.
    ///
    /// Pasteboard semantics: the engine snapshots the user's current
    /// pasteboard contents before any mutation and restores them after
    /// the synth Cmd+V has settled. Drop dictation never lingers in the
    /// clipboard — the user re-pastes from the drop history surface if
    /// they want the dictation back. On any step failure between
    /// snapshot and the final restore, the engine still restores so the
    /// user's clipboard is consistent with "no drop happened".
    func paste(_ text: String) async -> Bool {
        guard !text.isEmpty else {
            return false
        }

        // Step 1: snapshot the current pasteboard so we can restore the
        // user's clipboard after the synth paste settles. Combined with
        // the suppression flag set below this is the core of the
        // "drop must not pollute clipboard history" invariant.
        let snapshot = pasteboardSnapshot()
        logEmit(.info, "autopaste_pasteboard_snapshotted items=\(snapshot.items.count)")

        // Step 2: enable the shared clipboard-suppression flag BEFORE
        // any pasteboard mutation. `ClipboardWatcher` polls
        // `NSPasteboard.changeCount` ~2× per second; without this flag
        // the watcher would capture both the dictation and the restore
        // as clipboard history entries.
        setClipboardSuppression(true)

        // Step 3: pasteboard write. If this fails the rest of the
        // pipeline is moot — no event was posted, no mutation landed,
        // so we don't need to restore. Suppression must still be
        // cleared on the failure path.
        guard let counts = pasteboardWrite(text) else {
            logEmit(.error, "autopaste_failed step=pasteboard reason=write_returned_nil")
            setClipboardSuppression(false)
            return false
        }
        logEmit(.info, "autopaste_clipboard_updated before=\(counts.before) after=\(counts.after) chars=\(text.count)")

        // Step 4: Post Event permission status, advisory only. On Tahoe
        // adhoc-signed builds `CGPreflightPostEventAccess` returns false
        // even when CGEvent.post works (Accessibility grant is sufficient
        // in practice; there is no separate "Post Event" pane in System
        // Settings on Tahoe consumer macOS). Log for diagnosis but
        // proceed — if the post is genuinely blocked, it no-ops silently
        // and the snapshot restore at the end still runs.
        if !permissionGranted(false) {
            logEmit(.info, "autopaste_post_event_preflight_false advisory=true")
        }

        // Step 5: wait for modifiers to release. Most common failure mode
        // for the user is Option still held from the hotkey when the model
        // returns; without this wait, Cmd+V becomes Cmd+Opt+V.
        guard let modifierWaitMs = await waitUntilModifiersReleased() else {
            logEmit(.error, "autopaste_failed step=modifiers reason=timeout")
            // Restore even on failure so the dictation does not leak
            // into the user's clipboard history.
            pasteboardRestore(snapshot)
            logEmit(.info, "autopaste_pasteboard_restored after=failure")
            // Raise the watcher's skip-through threshold BEFORE
            // lowering the flag — the watcher's next poll may run
            // after the flag is cleared but before it would otherwise
            // see the restore bump as a fresh user copy. The threshold
            // covers that race window.
            let postRestoreCount = currentChangeCount()
            suppressClipboardThrough(postRestoreCount)
            setClipboardSuppression(false)
            return false
        }
        logEmit(.info, "autopaste_modifiers_released wait_ms=\(Int(modifierWaitMs))")

        // Step 6: restore focus to the remembered target. If the remembered
        // app died or no target was remembered, skip; paste lands wherever
        // focus currently is (acceptable degradation).
        await restoreTargetFocusIfNeeded()

        // Step 7: settle.
        sleepUs(Self.postFocusSettleMs * 1000)

        // Step 8: settle again before posting (friend's recipe: 80 ms
        // between write and post lets the pasteboard daemon publish the
        // new generation).
        sleepUs(Self.postWriteSettleMs * 1000)

        // Step 9: post Cmd+V. Explicit Command-down → V-down → V-up →
        // Command-up sequence with usleep gaps — `CGEvent.flags = .maskCommand`
        // alone is not enough on every app (friend's empirical note).
        postCmdV()
        logEmit(.info, "autopaste_posted_cmdv")

        // Step 10: let the target app consume the pasted content
        // before the pasteboard flips back to the user's original
        // clipboard. Without this delay fast editors race the restore
        // and end up pasting the restored snapshot instead of the
        // dictation.
        sleepUs(Self.postPasteRestoreMs * 1000)

        // Step 11: restore the user's original clipboard. The
        // suppression flag below stops `ClipboardWatcher` from
        // recording the restore as a fresh history entry.
        pasteboardRestore(snapshot)
        logEmit(.info, "autopaste_pasteboard_restored after=success")

        // Step 12: raise the watcher's "skip up to" threshold to the
        // pasteboard's CURRENT changeCount (post-restore). This guards
        // the race window between clearing the suppression flag below
        // and the watcher's next 500 ms poll — a fast drop can finish
        // entirely between two poll ticks, in which case the next poll
        // observes the bumps caused by the drop's write + restore even
        // though the flag is already cleared. Without this threshold
        // those bumps would be recorded as a fresh "user copy" of the
        // user's pre-drop clipboard, leaking the restored snapshot back
        // into clipboard history as a Sidekey-authored artefact.
        let postRestoreCount = currentChangeCount()
        suppressClipboardThrough(postRestoreCount)
        logEmit(.info, "autopaste_clipboard_suppress_through=\(postRestoreCount)")

        // Step 13: clear the suppression flag. The watcher resumes
        // capturing user-initiated copies, but anything <= the
        // threshold above is still skipped.
        setClipboardSuppression(false)

        return true
    }

    /// Variant of `paste(_:)` that ASSUMES the caller has already
    /// written the desired payload to `NSPasteboard.general`. Used by
    /// the history strip's "Paste to <App> ↵" hover-Enter flow — the
    /// strip writes the card's payload (text / image / fileURLs) to the
    /// pasteboard via the existing copy helper, then asks the engine to
    /// post Cmd+V to the remembered target.
    ///
    /// Differences from `paste(_:)`:
    ///   * No pasteboard string-write (caller handles arbitrary payload
    ///     types — `pb.writeObjects([NSImage])`, fileURLs, etc).
    ///   * No snapshot / restore. When the user explicitly selects a
    ///     history card to paste, the expectation is that the card
    ///     remains on the system pasteboard afterward — matches the
    ///     mental model of "I picked this clipboard entry, it should
    ///     now BE the clipboard".
    ///   * No suppression flag / threshold. The caller-driven copy
    ///     helper already coordinates with `ClipboardSuppression` for
    ///     its own bounce-protect window; the engine doesn't need to
    ///     touch the flag because there's no engine-owned mutation to
    ///     hide.
    ///
    /// Returns `true` when the modifier-wait succeeded and Cmd+V was
    /// posted; `false` only on modifier-wait timeout. Focus-restore
    /// failure is non-fatal (Cmd+V still posts wherever focus
    /// currently sits — acceptable degradation, same contract as
    /// `paste(_:)`).
    func pasteAlreadyOnPasteboard() async -> Bool {
        // Step 1: Post Event permission status, advisory only. Same
        // rationale as `paste(_:)` — Tahoe adhoc builds report false
        // even when post works in practice.
        if !permissionGranted(false) {
            logEmit(.info, "autopaste_post_event_preflight_false advisory=true")
        }

        // Step 2: wait for modifiers to release. The user just pressed
        // Enter inside the strip, so modifiers should already be clear,
        // but we run the same wait for parity with the drop pipeline.
        guard let modifierWaitMs = await waitUntilModifiersReleased() else {
            logEmit(.error, "autopaste_failed step=modifiers reason=timeout context=paste_already_on_pb")
            return false
        }
        logEmit(.info, "autopaste_modifiers_released wait_ms=\(Int(modifierWaitMs)) context=paste_already_on_pb")

        // Step 3: restore focus to the remembered target (if any).
        await restoreTargetFocusIfNeeded()

        // Step 4: settle.
        sleepUs(Self.postFocusSettleMs * 1000)
        sleepUs(Self.postWriteSettleMs * 1000)

        // Step 5: post Cmd+V — same 4-event sequence as `paste(_:)`.
        postCmdV()
        logEmit(.info, "autopaste_posted_cmdv context=paste_already_on_pb")

        return true
    }

    // MARK: - Pipeline steps

    /// Polls modifier flags every `modifierPollIntervalMs` up to
    /// `modifierWaitBudgetMs`. Returns the elapsed wait in ms on success,
    /// or `nil` on timeout.
    private func waitUntilModifiersReleased() async -> UInt64? {
        let watched: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let start = nowMs()
        let deadline = start + Self.modifierWaitBudgetMs

        while true {
            let flags = flagsState()
            if flags.intersection(watched).isEmpty {
                return nowMs() - start
            }
            let nowValue = nowMs()
            if nowValue >= deadline {
                return nil
            }
            sleepUs(UInt32(Self.modifierPollIntervalMs) * 1000)
        }
    }

    /// Activates the remembered target and polls until the frontmost app
    /// matches. No-op if no remembered target or if it has terminated.
    private func restoreTargetFocusIfNeeded() async {
        let from = frontmostAppInfo()
        let fromName = from?.name ?? "(unknown)"

        guard let target = remembered else {
            logEmit(.info, "autopaste_focus_restored from=\(fromName) to=(no_target)")
            return
        }

        if isTerminated(target.pid) {
            logEmit(.info, "autopaste_focus_restored from=\(fromName) to=(terminated)")
            return
        }

        if from?.pid == target.pid {
            // Focus already on the target — nothing to do.
            logEmit(.info, "autopaste_focus_restored from=\(fromName) to=\(target.name)")
            return
        }

        _ = activate(target.pid)

        let start = nowMs()
        let deadline = start + Self.focusRestoreBudgetMs
        while true {
            if let now = frontmostAppInfo(), now.pid == target.pid {
                break
            }
            if nowMs() >= deadline {
                break
            }
            sleepUs(UInt32(Self.focusRestorePollIntervalMs) * 1000)
        }

        let to = frontmostAppInfo()
        logEmit(.info, "autopaste_focus_restored from=\(fromName) to=\(to?.name ?? "(unknown)")")
    }

    /// Friend's section 7: explicit Command-down / V-down / V-up / Command-up
    /// sequence with `keyEventGapUs` between events.
    private func postCmdV() {
        postEvent(Self.commandKeyCode, true, [])
        sleepUs(Self.keyEventGapUs)
        postEvent(Self.vKeyCode, true, .maskCommand)
        sleepUs(Self.keyEventGapUs)
        postEvent(Self.vKeyCode, false, .maskCommand)
        sleepUs(Self.keyEventGapUs)
        postEvent(Self.commandKeyCode, false, [])
    }

    // MARK: - Production defaults

    private static func defaultFrontmostAppInfo() -> RememberedTarget? {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            let name = app.localizedName
        else {
            return nil
        }
        return RememberedTarget(pid: app.processIdentifier, name: name)
    }

    private static func defaultActivate(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        return app.activate(options: [])
    }

    private static func defaultIsTerminated(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return true
        }
        return app.isTerminated
    }

    private static func defaultPasteboardWrite(_ text: String) -> (before: Int, after: Int)? {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        pb.clearContents()
        let ok = pb.setString(text, forType: .string)
        let after = pb.changeCount
        return ok ? (before: before, after: after) : nil
    }

    private static func defaultPostEvent(_ keyCode: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            return
        }
        if !flags.isEmpty {
            event.flags = flags
        }
        event.post(tap: .cghidEventTap)
    }

}

/// Shared coordinator between `AutoPasteEngine` (writer) and
/// `ClipboardWatcher` (reader) for "ignore the pasteboard while drop is
/// in flight". The coordinator has two signals:
///
/// 1. `isSuppressed` — a binary flag. While true, every `handleChange`
///    call on the watcher skips. The drop pipeline raises this before
///    any pasteboard mutation and lowers it after the restore.
///
/// 2. `skipThroughChangeCount` — a monotonic "skip up to" threshold.
///    The watcher polls `NSPasteboard.changeCount` every 500 ms. A
///    fast drop (write → restore) finishes in <100 ms and bumps
///    `changeCount` twice; if it completes between two polls, the
///    next poll observes the bumps but the flag is already cleared.
///    Without the threshold the watcher would record the restored
///    pasteboard as a fresh "user copy" — leaking the user's
///    pre-drop clipboard back as a Sidekey-authored history artefact.
///    The drop pipeline raises this threshold to
///    `NSPasteboard.general.changeCount` AFTER the restore and BEFORE
///    clearing the flag, so the watcher's subsequent poll skips on
///    the threshold check instead.
///
/// MainActor-isolated because both collaborators run on the main thread
/// (engine via `AutoPasteEngine`'s `@MainActor`, watcher via a
/// MainActor-bound polling timer). A singleton suffices — there is only
/// ever one drop pipeline + one watcher.
@MainActor
final class ClipboardSuppression {
    static let shared = ClipboardSuppression()

    private(set) var isSuppressed: Bool = false
    /// Monotonic upper bound on `changeCount` values the watcher should
    /// skip even after `isSuppressed` returns to false. `-1` means "no
    /// threshold yet"; `NSPasteboard.changeCount` is always >= 0 so the
    /// sentinel cannot collide with a real value.
    private(set) var skipThroughChangeCount: Int = -1

    init() {}

    /// Idempotent. Toggling the flag is the only write path; calls to
    /// `setSuppressed(true)` while already suppressed are no-ops.
    func setSuppressed(_ flag: Bool) {
        isSuppressed = flag
    }

    /// Advance the skip-through threshold. Calls are MONOTONIC: a
    /// smaller value than the current threshold is a no-op. This
    /// protects against a second drop landing while a previous drop's
    /// restored changeCount is still above the new drop's range —
    /// the previous threshold must not rewind.
    func suppressThrough(changeCount: Int) {
        if changeCount > skipThroughChangeCount {
            skipThroughChangeCount = changeCount
        }
    }
}

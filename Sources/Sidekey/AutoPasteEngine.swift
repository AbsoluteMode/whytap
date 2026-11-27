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
///   7. settle 80 ms, then 80 ms more without blocking the main thread
///   8. post Cmd+V via explicit Command-down / V-down / V-up / Command-up
///      sequence with 12 ms between events
///   9. return; restore the pasteboard snapshot asynchronously once the
///      target has read the dictation (or after a fallback timeout), unless
///      the clipboard was replaced in the meantime
/// ```
///
/// The dictation is published as promised data (`PromisedPasteboardPayload`)
/// so the engine learns when a reader takes it: Chromium/Electron targets
/// read only when the page handles the paste, which can be long after a
/// fixed delay. A take that arrives before the restore inherits the
/// pending snapshot instead of snapshotting the previous dictation.
/// WHY: .project-docs/decisions/2026-11-27-drop-paste-restore-on-read.md
///
/// Failure modes:
///  * Empty text -> return false BEFORE snapshotting (nothing happened).
///  * Pasteboard write fails -> return false; no restore (write never
///    landed). Suppression flag is cleared.
///  * Modifier-wait timeout -> return false; restore the snapshot so the
///    user's clipboard is not left holding the dictation. Suppression
///    flag is cleared.
///
/// A take that began in one of Whytap's own text editors skips all of the
/// above: `paste(_:)` inserts the text into that editor's selection, without
/// the clipboard or a key event (`rememberDropTarget()`).
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
    typealias RichPasteboardWriteFn = (SmartRichTextPaste) -> (before: Int, after: Int)?
    typealias PostEventFn = (CGKeyCode, Bool, CGEventFlags) -> Void
    /// Posts one key event to one process only (`CGEvent.postToPid`).
    typealias PostEventToPidFn = (CGKeyCode, Bool, CGEventFlags, pid_t) -> Void
    typealias SleepUsFn = (UInt32) -> Void
    /// Sleeps without blocking the main thread, so AppKit can deliver
    /// pasteboard read requests (promised data) meanwhile.
    typealias AsyncSleepMsFn = (UInt64) async -> Void
    typealias NowMsFn = () -> UInt64
    typealias PasteboardSnapshotFn = () -> PasteboardSnapshot
    typealias PasteboardRestoreFn = (PasteboardSnapshot) -> Void
    typealias SetClipboardSuppressionFn = (Bool) -> Void
    typealias SuppressClipboardThroughFn = (Int) -> Void
    typealias CurrentChangeCountFn = () -> Int

    /// A text editor of this app that had keyboard focus when a Drop take
    /// began. `insert` puts the text into its selection and returns false
    /// once that editor is gone.
    struct LocalEditorTarget {
        let name: String
        let insert: (String) -> Bool
    }
    typealias LocalEditorFn = () -> LocalEditorTarget?

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

    /// Why the last `paste(_:)` stopped without pasting, when the take can
    /// be retried as is (its text kept): the take's target was not in
    /// front, or newer content replaced the dictation on the clipboard.
    /// nil after a paste, or after a refusal that is not retryable (quit,
    /// held modifiers, a failed write).
    enum PasteRefusal: Equatable {
        case targetNotInFront
        case clipboardChanged
    }
    private(set) var lastPasteRefusal: PasteRefusal?
    /// The target the last `paste` was bound to. A refused take keeps it,
    /// so its Retry goes to the same app even if another capture (a new
    /// History open) changed the remembered target meanwhile.
    private(set) var lastPasteTarget: RememberedTarget?

    /// When the user's clipboard comes back after a Drop paste.
    struct RestoreTiming: Equatable {
        /// How often the pending restore checks for reads and replacements.
        var pollMs: UInt64 = 10
        /// Quiet time after the last read of the dictation before the
        /// restore: readers that take several types read them in a burst.
        var afterReadMs: UInt64 = 150
        /// Restore anyway when no reader took the dictation after Cmd+V
        /// (the target ignored the paste, or a reader took it before Cmd+V
        /// and the target was served from the pasteboard's cache).
        var fallbackMs: UInt64 = 2_000

        static let standard = RestoreTiming()
    }

    private static let vKeyCode: CGKeyCode = 0x09     // kVK_ANSI_V
    private static let commandKeyCode: CGKeyCode = 0x37 // kVK_Command

    // MARK: - Injected collaborators

    private let flagsState: FlagsStateFn
    private let frontmostAppInfo: FrontmostAppInfoFn
    private let activate: ActivateFn
    private let isTerminated: IsTerminatedFn
    private let permissionGranted: PermissionFn
    private let pasteboardWrite: PasteboardWriteFn
    private let richPasteboardWrite: RichPasteboardWriteFn?
    private let postEvent: PostEventFn
    private let postEventToPid: PostEventToPidFn
    private let sleepUs: SleepUsFn
    private let asyncSleepMs: AsyncSleepMsFn
    private let nowMs: NowMsFn
    private let logEmit: LogFn
    private let pasteboardSnapshot: PasteboardSnapshotFn
    private let pasteboardRestore: PasteboardRestoreFn
    private let setClipboardSuppression: SetClipboardSuppressionFn
    private let suppressClipboardThrough: SuppressClipboardThroughFn
    private let currentChangeCount: CurrentChangeCountFn
    private let localEditor: LocalEditorFn
    private let readMonitor: PasteboardReadMonitor
    private let restoreTiming: RestoreTiming
    private let writeLedger: PasteboardWriteLedger

    // MARK: - State

    /// The clipboard generation a Drop paste wrote and still owns, with the
    /// user's clipboard to give back. It exists from the dictation write
    /// until the restore, a handoff to the next take, or a replacement.
    private final class ClipboardClaim {
        let snapshot: PasteboardSnapshot
        /// The plain text written, to recognise the dictation after another
        /// Whytap feature snapshotted it and wrote it back (a round trip).
        let plainText: String
        /// The change count of Drop's own write, or of a round trip that
        /// put the dictation back. Any other content is not Drop's.
        var ownedChangeCount: Int
        /// The last change count found to hold foreign content.
        var foreignChangeCount: Int?
        /// The restore after Cmd+V; nil before Cmd+V.
        var task: Task<Void, Never>?
        /// A newer take waits to write: end at the restore point without
        /// restoring and hand the snapshot over.
        var successorWaiting = false
        private(set) var handedOver = false

        init(snapshot: PasteboardSnapshot, plainText: String, ownedChangeCount: Int) {
            self.snapshot = snapshot
            self.plainText = plainText
            self.ownedChangeCount = ownedChangeCount
        }

        func handOver() { handedOver = true }
    }
    private var claim: ClipboardClaim?
    /// Bumped by `flushPendingRestore` (quit): every Drop paste that began
    /// before it stops before its clipboard write or key events.
    private var flushGeneration = 0
    /// Drop pastes run one at a time; a newer take waits for its turn.
    private var pasteTurnBusy = false
    private var pasteTurnWaiters: [CheckedContinuation<Void, Never>] = []

    private var remembered: RememberedTarget?
    /// The current Drop take's own-app editor, if it began in one. Only
    /// `rememberDropTarget()` changes it: opening History re-captures the
    /// frontmost app, and a Retry afterwards must still not paste elsewhere.
    private var dropEditor: LocalEditorTarget?
    var hasLocalDropTarget: Bool { dropEditor != nil }

    // MARK: - Initialisers

    convenience init(suppression: ClipboardSuppression = .shared) {
        let log = OSLog(subsystem: "com.rootwise.sidekey", category: "pipeline")
        let reads = PasteboardReadMonitor()
        let ledger = PasteboardWriteLedger()
        self.init(
            flagsState: { CGEventSource.flagsState(.hidSystemState) },
            frontmostAppInfo: AutoPasteEngine.defaultFrontmostAppInfo,
            activate: AutoPasteEngine.defaultActivate,
            isTerminated: AutoPasteEngine.defaultIsTerminated,
            permissionGranted: PermissionsHelper.postEventAccessGranted,
            pasteboardWrite: { AutoPasteEngine.writePromisedText($0, to: .general, reads: reads, ledger: ledger) },
            richPasteboardWrite: { AutoPasteEngine.writeRichContent($0, to: .general, reads: reads, ledger: ledger) },
            postEvent: AutoPasteEngine.defaultPostEvent,
            postEventToPid: AutoPasteEngine.defaultPostEventToPid,
            sleepUs: { usleep($0) },
            asyncSleepMs: { try? await Task.sleep(nanoseconds: $0 * 1_000_000) },
            nowMs: { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
            logEmit: { level, message in
                let type: OSLogType = (level == .error) ? .error : .info
                os_log("%{public}@", log: log, type: type, message)
            },
            pasteboardSnapshot: Pasteboard.snapshot,
            pasteboardRestore: Pasteboard.restore,
            setClipboardSuppression: { flag in suppression.setSuppressed(flag) },
            suppressClipboardThrough: { count in suppression.suppressThrough(changeCount: count) },
            currentChangeCount: { NSPasteboard.general.changeCount },
            localEditor: {
                guard let editor = DropLocalEditor(focusedIn: DropLocalEditor.keyWindow) else { return nil }
                let name = NSRunningApplication.current.localizedName ?? "Whytap"
                return LocalEditorTarget(name: name, insert: { editor.insert($0) })
            },
            readMonitor: reads,
            writeLedger: ledger
        )
    }

    init(
        flagsState: @escaping FlagsStateFn,
        frontmostAppInfo: @escaping FrontmostAppInfoFn,
        activate: @escaping ActivateFn,
        isTerminated: @escaping IsTerminatedFn,
        permissionGranted: @escaping PermissionFn,
        pasteboardWrite: @escaping PasteboardWriteFn,
        richPasteboardWrite: RichPasteboardWriteFn? = nil,
        postEvent: @escaping PostEventFn,
        postEventToPid: @escaping PostEventToPidFn = { _, _, _, _ in },
        sleepUs: @escaping SleepUsFn,
        asyncSleepMs: @escaping AsyncSleepMsFn = { _ in await Task.yield() },
        nowMs: @escaping NowMsFn,
        logEmit: @escaping LogFn,
        pasteboardSnapshot: @escaping PasteboardSnapshotFn = { PasteboardSnapshot(items: []) },
        pasteboardRestore: @escaping PasteboardRestoreFn = { _ in },
        setClipboardSuppression: @escaping SetClipboardSuppressionFn = { _ in },
        suppressClipboardThrough: @escaping SuppressClipboardThroughFn = { _ in },
        currentChangeCount: @escaping CurrentChangeCountFn = { 0 },
        localEditor: @escaping LocalEditorFn = { nil },
        readMonitor: PasteboardReadMonitor = PasteboardReadMonitor(),
        restoreTiming: RestoreTiming = .standard,
        writeLedger: PasteboardWriteLedger = PasteboardWriteLedger()
    ) {
        self.flagsState = flagsState
        self.frontmostAppInfo = frontmostAppInfo
        self.activate = activate
        self.isTerminated = isTerminated
        self.permissionGranted = permissionGranted
        self.pasteboardWrite = pasteboardWrite
        self.richPasteboardWrite = richPasteboardWrite
        self.postEvent = postEvent
        self.postEventToPid = postEventToPid
        self.sleepUs = sleepUs
        self.asyncSleepMs = asyncSleepMs
        self.nowMs = nowMs
        self.logEmit = logEmit
        self.pasteboardSnapshot = pasteboardSnapshot
        self.pasteboardRestore = pasteboardRestore
        self.setClipboardSuppression = setClipboardSuppression
        self.suppressClipboardThrough = suppressClipboardThrough
        self.currentChangeCount = currentChangeCount
        self.localEditor = localEditor
        self.readMonitor = readMonitor
        self.restoreTiming = restoreTiming
        self.writeLedger = writeLedger
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

    /// Start of a Drop take. Besides the frontmost app this remembers a text
    /// editor of Whytap itself that has the keyboard (the floating Translate
    /// input is key while another app stays frontmost). Such a take is
    /// delivered into that editor and nowhere else.
    /// WHY: .project-docs/decisions/2026-11-18-drop-into-whytap-editors.md
    func rememberDropTarget() {
        dropEditor = localEditor()
        rememberTargetBeforeRecording()
        if dropEditor != nil {
            logEmit(.info, "autopaste_target_local_editor")
        }
    }

    /// What the take's processing may know about its destination. An editor
    /// of this app has no pid: the frontmost app is not where the text goes,
    /// so Smart reads no Accessibility context from it and keeps plain text.
    func currentDropTarget() -> (name: String?, pid: pid_t?) {
        if let dropEditor { return (dropEditor.name, nil) }
        return (remembered?.name, remembered?.pid)
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

    /// Full paste pipeline. Returns `true` once Cmd+V was posted.
    ///
    /// Pasteboard semantics: the engine snapshots the user's current
    /// pasteboard contents before any mutation and restores them after
    /// the target has read the dictation (`RestoreTiming`). The restore
    /// runs after this method returns. Drop dictation never lingers in the
    /// clipboard — the user re-pastes from the drop history surface if
    /// they want the dictation back. Drop owns only the clipboard
    /// generation it wrote: it never restores over, or pastes, newer
    /// content. If that content arrives before Cmd+V the paste stops and
    /// returns `false`. Other failures before Cmd+V give the clipboard
    /// back at once.
    func paste(_ text: String, formatting: SmartFormattingProfile = .plain) async -> Bool {
        await paste(text, formatting: formatting, to: remembered)
    }

    /// `paste(_:formatting:)` bound to an explicit target instead of the
    /// currently remembered one. Retry of a refused take uses the target
    /// that take was bound to (`lastPasteTarget`).
    func paste(_ text: String, formatting: SmartFormattingProfile = .plain, to boundTarget: RememberedTarget?) async -> Bool {
        guard !text.isEmpty else {
            return false
        }

        // A take that began in one of Whytap's own editors goes straight
        // into it. Cmd+V would be handled on this thread only after the
        // clipboard restore below, pasting the user's previous clipboard;
        // and once that editor is gone the keys would reach another app.
        // WHY: .project-docs/decisions/2026-11-18-drop-into-whytap-editors.md
        if let dropEditor {
            let inserted = dropEditor.insert(text)
            if inserted {
                logEmit(.info, "autopaste_local_editor_inserted chars=\(text.count)")
            } else {
                logEmit(.error, "autopaste_failed step=local_editor reason=target_gone")
            }
            return inserted
        }

        lastPasteRefusal = nil

        // The take's target is fixed for this paste: a newer take that
        // captures another app while this one waits must not redirect it.
        let target = boundTarget
        lastPasteTarget = target
        let generation = flushGeneration

        // One Drop paste at a time: the claim below must not be shared.
        await acquirePasteTurn()
        defer { releasePasteTurn() }
        guard flushGeneration == generation else {
            logEmit(.error, "autopaste_failed step=paste reason=retired_by_flush")
            return false
        }

        // Step 1: the user's clipboard to restore after the paste. A take
        // that arrives while the previous paste still waits for its read
        // waits for it (the previous target must read its own dictation)
        // and takes over its snapshot: the pasteboard then holds the
        // previous dictation, not the user's clipboard.
        let (snapshot, inherited) = await takeOverPreviousClaim()
        guard flushGeneration == generation else {
            // The flush already gave back whatever the previous take held.
            logEmit(.error, "autopaste_failed step=paste reason=retired_by_flush")
            return false
        }
        logEmit(.info, "autopaste_pasteboard_snapshotted items=\(snapshot.items.count) inherited=\(inherited)")

        // Step 2: enable the shared clipboard-suppression flag BEFORE
        // any pasteboard mutation. `ClipboardWatcher` polls
        // `NSPasteboard.changeCount` ~2× per second; without this flag
        // the watcher could capture the dictation as a clipboard history
        // entry.
        setClipboardSuppression(true)

        // Step 3: pasteboard write. If this fails the rest of the
        // pipeline is moot. Restore only on attributable evidence: the
        // writer's own clear is still the current generation (it may have
        // cleared before failing), or the earlier take's dictation is still
        // there. A count that merely moved may be another app's copy.
        // Suppression must still be cleared on the failure path.
        _ = writeLedger.takeFailedWrite()
        let written: (before: Int, after: Int)?
        let plainText: String
        if formatting.usesRichPaste, let richPasteboardWrite, let rich = SmartRichTextPaste.make(text) {
            plainText = rich.plainText
            written = richPasteboardWrite(rich)
        } else {
            plainText = text
            written = pasteboardWrite(text)
        }
        guard let counts = written else {
            let ownClear = writeLedger.takeFailedWrite()
            logEmit(.error, "autopaste_failed step=pasteboard reason=write_returned_nil")
            let previous = inherited ? claim : nil
            if claim != nil { claim = nil }
            // The generation that justifies a restore: this write's own
            // clear, or the previous take's dictation.
            var justified: Int?
            if let ownClear, currentChangeCount() == ownClear {
                justified = ownClear
            } else if let previous, clipboardIsOwned(by: previous) {
                justified = previous.ownedChangeCount
            }
            // The checks above read the pasteboard; anything that arrived
            // meanwhile is newer. Re-check right before restoring.
            if let justified, currentChangeCount() == justified {
                pasteboardRestore(snapshot)
                suppressClipboardThrough(currentChangeCount())
            } else if ownClear != nil || inherited {
                logEmit(.info, "autopaste_pasteboard_restore_skipped reason=replaced after=failure")
            }
            setClipboardSuppression(false)
            return false
        }
        logEmit(.info, "autopaste_clipboard_updated before=\(counts.before) after=\(counts.after) chars=\(text.count)")

        // Drop owns exactly the generation its own write produced. The
        // watcher's skip-through threshold covers only that write, and
        // the flag drops: a copy the user makes from here on is recorded
        // and is never pasted or overwritten by Drop.
        suppressClipboardThrough(counts.after)
        setClipboardSuppression(false)
        let claim = ClipboardClaim(snapshot: snapshot, plainText: plainText, ownedChangeCount: counts.after)
        self.claim = claim
        guard currentChangeCount() == counts.after else {
            self.claim = nil
            lastPasteRefusal = .clipboardChanged
            logEmit(.error, "autopaste_failed step=pasteboard reason=replaced_after_write")
            return false
        }

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
            // Give the clipboard back so the dictation does not linger,
            // unless something newer already replaced it.
            giveBack(claim, after: "failure")
            return false
        }
        logEmit(.info, "autopaste_modifiers_released wait_ms=\(Int(modifierWaitMs))")

        // Step 6: restore focus to the take's target. If that app died or
        // no target was remembered, skip; paste lands wherever focus
        // currently is (acceptable degradation).
        await restoreTargetFocusIfNeeded(target)
        let frontmostBeforeSettle = frontmostAppInfo()

        // Step 7: settle.
        sleepUs(Self.postFocusSettleMs * 1000)

        // Step 8: settle again before posting (friend's recipe: 80 ms
        // between write and post lets the pasteboard daemon publish the
        // new generation). This one does not block the main thread, so a
        // reader that asked for the dictation before Cmd+V (a clipboard
        // manager) is served now and is not mistaken for the target.
        await asyncSleepMs(UInt64(Self.postWriteSettleMs))

        // Step 9: the posting boundary. The settle above lets the world
        // move: the app may be quitting (the clipboard was given back),
        // the clipboard may hold something newer, or the target may have
        // lost focus to another app, which would receive the global Cmd+V.
        guard self.claim === claim else {
            logEmit(.error, "autopaste_failed step=paste reason=clipboard_given_back")
            return false
        }
        guard clipboardIsOwned(by: claim) else {
            self.claim = nil
            lastPasteRefusal = .clipboardChanged
            logEmit(.error, "autopaste_failed step=pasteboard reason=replaced_before_paste")
            return false
        }
        guard flushGeneration == generation else {
            logEmit(.error, "autopaste_failed step=paste reason=retired_by_flush")
            giveBack(claim, after: "flush")
            return false
        }
        // One foreground sample decides both the focus check and the
        // recipient. A live target must hold focus: if it lost focus in
        // the settle, or could not be brought to the front at all, nothing
        // is pasted into whichever app is in front instead; the take stops
        // with its text kept for Retry. Only without a target, or when the
        // target quit, does the paste go where focus is (fallback).
        // WHY: .project-docs/decisions/2026-11-27-drop-paste-restore-on-read.md
        let frontmostAtBoundary = frontmostAppInfo()
        let liveTarget = target.flatMap { isTerminated($0.pid) ? nil : $0 }
        if let liveTarget, frontmostAtBoundary?.pid != liveTarget.pid {
            let lostInSettle = frontmostBeforeSettle?.pid == liveTarget.pid
            logEmit(.error, "autopaste_failed step=focus reason=\(lostInSettle ? "target_lost_focus" : "target_not_frontmost")")
            lastPasteRefusal = .targetNotInFront
            giveBack(claim, after: "failure")
            return false
        }
        let recipient = frontmostAtBoundary

        // Step 10: post Cmd+V. Explicit Command-down → V-down → V-up →
        // Command-up sequence with usleep gaps — `CGEvent.flags = .maskCommand`
        // alone is not enough on every app (friend's empirical note). The
        // app frontmost now receives it; ownership and that recipient are
        // checked again right before V-down.
        guard postDropCmdV(recipient: recipient, claim: claim) else {
            return false
        }
        let readsAtPaste = readMonitor.readCount
        logEmit(.info, "autopaste_posted_cmdv")

        // Step 11: give the clipboard back once the target has read the
        // dictation. A fixed delay lost the race against busy Chromium
        // renderers, which read the pasteboard only when the page handles
        // the paste event.
        // WHY: .project-docs/decisions/2026-11-27-drop-paste-restore-on-read.md
        claim.task = Task { @MainActor [weak self] in
            await self?.runPendingRestore(claim, readsAtPaste: readsAtPaste)
        }
        return true
    }

    /// Gives the user's clipboard back now if a Drop paste still holds it,
    /// before or after its Cmd+V. A paste that has not posted Cmd+V yet
    /// then stops. Called when the app terminates.
    func flushPendingRestore() {
        flushGeneration += 1
        guard let claim else { return }
        claim.task?.cancel()
        giveBack(claim, after: "flush")
    }

    /// Drop's global Cmd+V. Before V-down — the event that pastes — the
    /// clipboard must still hold this take's dictation and `recipient`
    /// must still be frontmost; otherwise Command is released, nothing is
    /// pasted and the clipboard comes back if it is still Drop's. After
    /// V-down the paste is delivered and the sequence completes.
    /// WHY: .project-docs/decisions/2026-11-27-drop-paste-restore-on-read.md
    private func postDropCmdV(recipient: RememberedTarget?, claim: ClipboardClaim) -> Bool {
        postEvent(Self.commandKeyCode, true, [])
        sleepUs(Self.keyEventGapUs)
        // Each check can take time (the ownership check may read the
        // pasteboard), so both are sampled twice, interleaved: a clipboard
        // change during a foreground lookup, or a focus change during an
        // ownership check, is seen by the next check of the other kind.
        // The last check before V-down is the cheap change-count compare:
        // a copy during either foreground lookup is caught right at the
        // boundary.
        let ownedFirst = self.claim === claim && clipboardIsOwned(by: claim)
        let frontFirst = frontmostAppInfo()?.pid
        let frontLast = frontmostAppInfo()?.pid
        let recipientReady = recipient.map { frontFirst == $0.pid && frontLast == $0.pid } ?? true
        let owned = ownedFirst && self.claim === claim && currentChangeCount() == claim.ownedChangeCount
        guard recipientReady, owned else {
            postEvent(Self.commandKeyCode, false, [])
            if self.claim !== claim {
                logEmit(.error, "autopaste_failed step=paste reason=clipboard_given_back")
            } else if !owned {
                self.claim = nil
                lastPasteRefusal = .clipboardChanged
                logEmit(.error, "autopaste_failed step=pasteboard reason=replaced_before_paste")
            } else {
                lastPasteRefusal = .targetNotInFront
                logEmit(.error, "autopaste_failed step=focus reason=recipient_lost_focus")
                giveBack(claim, after: "failure")
            }
            return false
        }
        postEvent(Self.vKeyCode, true, .maskCommand)
        sleepUs(Self.keyEventGapUs)
        postEvent(Self.vKeyCode, false, .maskCommand)
        sleepUs(Self.keyEventGapUs)
        postEvent(Self.commandKeyCode, false, [])
        return true
    }

    /// Waits until the pending clipboard restore (if any) has finished.
    func waitForPendingRestore() async {
        await claim?.task?.value
    }

    var hasPendingRestore: Bool { claim != nil }

    private func acquirePasteTurn() async {
        guard pasteTurnBusy else {
            pasteTurnBusy = true
            return
        }
        await withCheckedContinuation { pasteTurnWaiters.append($0) }
    }

    private func releasePasteTurn() {
        if pasteTurnWaiters.isEmpty {
            pasteTurnBusy = false
        } else {
            pasteTurnWaiters.removeFirst().resume()
        }
    }

    private func takeOverPreviousClaim() async -> (PasteboardSnapshot, inherited: Bool) {
        if let previous = claim {
            if previous.task != nil {
                previous.successorWaiting = true
                logEmit(.info, "autopaste_waiting_for_previous_paste")
                await previous.task?.value
            }
            // A handed-over claim stays registered until this take's write
            // replaces it, so a flush in between still gives it back.
            if claim === previous, previous.handedOver, clipboardIsOwned(by: previous) {
                return (previous.snapshot, true)
            }
            if claim === previous { claim = nil }
        }
        return (pasteboardSnapshot(), false)
    }

    /// Whether the clipboard still holds this claim's dictation. Another
    /// Whytap feature that snapshots the clipboard, writes its own content
    /// and writes the snapshot back (selection capture, a failed Shot text
    /// copy) leaves the dictation with a new change count: it is recognised
    /// by content (transient marker and the same text) and adopted, so the
    /// user's clipboard still comes back. Anything else is foreign.
    private func clipboardIsOwned(by claim: ClipboardClaim) -> Bool {
        let count = currentChangeCount()
        if count == claim.ownedChangeCount { return true }
        if count == claim.foreignChangeCount { return false }
        let marker = PromisedPasteboardPayload.transientMarker.rawValue
        let text = Data(claim.plainText.utf8)
        let holdsDictation = pasteboardSnapshot().items.contains { item in
            item[marker] != nil && item[NSPasteboard.PasteboardType.string.rawValue] == text
        }
        // The snapshot itself must not have raced another write.
        guard currentChangeCount() == count else { return false }
        if holdsDictation {
            claim.ownedChangeCount = count
            claim.foreignChangeCount = nil
            suppressClipboardThrough(count)
            logEmit(.info, "autopaste_pasteboard_reclaimed change_count=\(count)")
            return true
        }
        claim.foreignChangeCount = count
        return false
    }

    /// Ends `claim` and restores its snapshot if the clipboard still holds
    /// its dictation; newer content is left alone.
    private func giveBack(_ claim: ClipboardClaim, after reason: String, detail: String = "") {
        guard self.claim === claim else { return }
        self.claim = nil
        guard clipboardIsOwned(by: claim) else {
            logEmit(.info, "autopaste_pasteboard_restore_skipped reason=replaced after=\(reason)")
            return
        }
        restoreClipboard(claim.snapshot, after: reason, detail: detail)
    }

    /// Waits for the target to read the dictation, then restores the
    /// snapshot, or hands it to a newer take waiting to write. Never
    /// restores over foreign content (a user copy must not be clobbered);
    /// it keeps watching for a round trip that puts the dictation back
    /// until the deadline.
    private func runPendingRestore(_ claim: ClipboardClaim, readsAtPaste: Int) async {
        let timing = restoreTiming
        let startMs = nowMs()
        var sleptMs: UInt64 = 0
        var seenReads = readsAtPaste
        var lastReadAtMs: UInt64?
        while true {
            await asyncSleepMs(timing.pollMs)
            sleptMs += timing.pollMs
            guard self.claim === claim, !Task.isCancelled else { return }
            let clockMs = nowMs()
            let elapsedMs = max(sleptMs, clockMs >= startMs ? clockMs - startMs : 0)
            let deadlineMs = timing.fallbackMs + timing.afterReadMs
            guard clipboardIsOwned(by: claim) else {
                if claim.successorWaiting || elapsedMs >= deadlineMs {
                    self.claim = nil
                    logEmit(.info, "autopaste_pasteboard_restore_skipped reason=replaced wait_ms=\(elapsedMs)")
                    return
                }
                continue
            }
            let reads = readMonitor.readCount
            if reads != seenReads {
                seenReads = reads
                lastReadAtMs = elapsedMs
            }
            let readSettled = lastReadAtMs.map { elapsedMs - $0 >= timing.afterReadMs } ?? false
            let timedOut = lastReadAtMs == nil && elapsedMs >= timing.fallbackMs
            guard readSettled || timedOut || elapsedMs >= deadlineMs else { continue }
            let detail = " wait_ms=\(elapsedMs) reads=\(seenReads - readsAtPaste)"
            if claim.successorWaiting {
                claim.handOver()
                logEmit(.info, "autopaste_pasteboard_handed_over after=\(readSettled ? "read" : "timeout")\(detail)")
                return
            }
            giveBack(claim, after: readSettled ? "read" : "timeout", detail: detail)
            return
        }
    }

    /// Restores `snapshot` while the clipboard watcher is suppressed, then
    /// raises its skip-through threshold to the post-restore change count
    /// BEFORE clearing the flag: the watcher's next 500 ms poll may come
    /// after the flag is cleared, and must not record the restored
    /// clipboard as a fresh "user copy".
    private func restoreClipboard(_ snapshot: PasteboardSnapshot, after reason: String, detail: String = "") {
        setClipboardSuppression(true)
        pasteboardRestore(snapshot)
        logEmit(.info, "autopaste_pasteboard_restored after=\(reason)\(detail)")
        let postRestoreCount = currentChangeCount()
        suppressClipboardThrough(postRestoreCount)
        logEmit(.info, "autopaste_clipboard_suppress_through=\(postRestoreCount)")
        setClipboardSuppression(false)
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

    // MARK: - Series bound to one target

    /// Whether a paste series that started for `target` may continue: the
    /// app is still running and no later capture (Drop, History reopened in
    /// another app) replaced it as the remembered target.
    /// WHY: .project-docs/decisions/2026-11-22-history-multi-paste.md
    /// With `requireFrontmost`, the target must also still have focus: a
    /// later paste of the series never takes focus back from where the user
    /// moved it.
    func isSeriesTargetCurrent(_ target: RememberedTarget, requireFrontmost: Bool = false) -> Bool {
        guard remembered?.pid == target.pid, !isTerminated(target.pid) else { return false }
        return !requireFrontmost || frontmostAppInfo()?.pid == target.pid
    }

    /// One paste of a series that must land only in `target`. Unlike
    /// `pasteAlreadyOnPasteboard()`, which degrades to "wherever focus is",
    /// this posts no Cmd+V unless the target is still current and frontmost
    /// after the focus restore. Returns `false` without any key event then,
    /// so the caller stops the rest of the series. Only the series' first
    /// paste restores focus to the target (`restoringFocus`); later ones need
    /// it to have kept focus.
    func pasteAlreadyOnPasteboard(into target: RememberedTarget, restoringFocus: Bool) async -> Bool {
        if !permissionGranted(false) {
            logEmit(.info, "autopaste_post_event_preflight_false advisory=true")
        }
        guard await waitUntilModifiersReleased() != nil else {
            logEmit(.error, "autopaste_failed step=modifiers reason=timeout context=series")
            return false
        }
        guard isSeriesTargetCurrent(target) else {
            logEmit(.info, "autopaste_series_stopped reason=target_changed")
            return false
        }
        if restoringFocus { await restoreTargetFocusIfNeeded() }
        guard frontmostAppInfo()?.pid == target.pid else {
            logEmit(.info, "autopaste_series_stopped reason=focus_not_restored")
            return false
        }
        sleepUs(Self.postFocusSettleMs * 1000)
        sleepUs(Self.postWriteSettleMs * 1000)
        guard postCmdV(to: target) else { return false }
        logEmit(.info, "autopaste_posted_cmdv context=series")
        return true
    }

    /// Whether the series' target can take the next key event right now.
    private func seriesRecipientReady(_ target: RememberedTarget) -> Bool {
        isSeriesTargetCurrent(target) && frontmostAppInfo()?.pid == target.pid
    }

    /// The same four-event Cmd+V as `postCmdV()`, but addressed to the
    /// target process instead of the global HID stream, with the recipient
    /// checked before every event. Focus moving to another app between two
    /// events (the 12 ms gaps) can then never route a V-down there. A check
    /// that fails before V-down releases Command in the target and stops; a
    /// target that quit by the end does not count as delivered.
    /// WHY: .project-docs/decisions/2026-11-22-history-multi-paste.md
    private func postCmdV(to target: RememberedTarget) -> Bool {
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [
            (Self.commandKeyCode, true, []),
            (Self.vKeyCode, true, .maskCommand),
            (Self.vKeyCode, false, .maskCommand),
            (Self.commandKeyCode, false, []),
        ]
        for (index, step) in steps.enumerated() {
            if index > 0 { sleepUs(Self.keyEventGapUs) }
            guard seriesRecipientReady(target) else {
                // Release what this sequence pressed, in the target only.
                if index == 2 { postEventToPid(Self.vKeyCode, false, .maskCommand, target.pid) }
                if index >= 1 && index <= 3 { postEventToPid(Self.commandKeyCode, false, [], target.pid) }
                let pasted = index >= 2
                logEmit(.info, "autopaste_series_stopped reason=recipient_lost_during_cmdv step=\(index)")
                // A V-down already went to the target; anything else is undelivered.
                return pasted && !isTerminated(target.pid)
            }
            postEventToPid(step.0, step.1, step.2, target.pid)
        }
        guard !isTerminated(target.pid) else {
            logEmit(.info, "autopaste_series_stopped reason=target_quit_after_cmdv")
            return false
        }
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
        await restoreTargetFocusIfNeeded(remembered)
    }

    private func restoreTargetFocusIfNeeded(_ target: RememberedTarget?) async {
        let from = frontmostAppInfo()
        let fromName = from?.name ?? "(unknown)"

        guard let target else {
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

    /// Publishes dictated plain text as promised data (see
    /// `PromisedPasteboardPayload`). A named pasteboard is injectable for
    /// validation without touching the user's clipboard.
    static func writePromisedText(
        _ text: String,
        to pasteboard: NSPasteboard,
        reads: PasteboardReadMonitor,
        ledger: PasteboardWriteLedger? = nil
    ) -> (before: Int, after: Int)? {
        PromisedPasteboardPayload.write([.string: Data(text.utf8)], to: pasteboard, reads: reads, ledger: ledger)
    }

    /// A named pasteboard is injectable for validation without touching the
    /// user's clipboard. All flavors share the existing snapshot/restore path.
    static func writeRichContent(
        _ content: SmartRichTextPaste,
        to pasteboard: NSPasteboard,
        reads: PasteboardReadMonitor = PasteboardReadMonitor(),
        ledger: PasteboardWriteLedger? = nil
    ) -> (before: Int, after: Int)? {
        var payload: [NSPasteboard.PasteboardType: Data] = [
            .string: Data(content.plainText.utf8),
            .rtf: content.rtf,
        ]
        if let html = content.html { payload[.html] = html }
        return PromisedPasteboardPayload.write(payload, to: pasteboard, reads: reads, ledger: ledger)
    }

    private static func defaultPostEventToPid(_ keyCode: CGKeyCode, _ down: Bool, _ flags: CGEventFlags, _ pid: pid_t) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            return
        }
        if !flags.isEmpty {
            event.flags = flags
        }
        event.postToPid(pid)
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

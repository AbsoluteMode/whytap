import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import os.log

/// Drop trigger built on a Space **hold** instead of a Carbon hot-key combo.
///
/// Unlike `CarbonHotkeyMonitor` (which `RegisterEventHotKey` lets the kernel
/// suppress for free), detecting a *hold* of an otherwise-ordinary key means
/// watching the live keystroke stream and deciding, per event, whether to let
/// it reach the focused app or swallow it. That requires an **active**
/// `CGEventTap` (`.defaultTap`), which on modern macOS is gated by the
/// **Input Monitoring** TCC bucket — a permission the rest of the app
/// deliberately avoids (see `CarbonHotkeyMonitor` and `CLAUDE.md`).
///
/// ## Responsibilities
/// `SpaceHoldMonitor` is the side-effecting shell around the pure
/// ``SpaceHoldDetector`` FSM. The FSM decides *what* should happen for each
/// event; this type performs it:
/// - maps a raw `CGEvent` to a ``SpaceHoldDetector/Event``,
/// - swallows or passes the keystroke based on the emitted actions,
/// - arms a real threshold timer on ``SpaceHoldDetector/Action/beginPending``,
/// - runs the Accessibility "is the focused field editable?" check **off** the
///   tap callback on ``SpaceHoldDetector/Action/requestEditableCheck``,
/// - synthesizes Backspace deletions and starts recording on
///   ``SpaceHoldDetector/Action/arm(deleteCount:)``,
/// - stops + transcribes on ``SpaceHoldDetector/Action/stopAndTranscribe`` and
///   discards on ``SpaceHoldDetector/Action/cancelDrop``.
///
/// ## Threading / race-freedom
/// All access to the detector — tap callbacks, the threshold timer firing, and
/// the AX result coming back — is funnelled through a single serial queue
/// (``runOnDetectorQueue``). In production the tap callback runs on a dedicated
/// thread's run loop and hops onto that serial queue synchronously to compute
/// the swallow/pass verdict (the C callback must return immediately), so the
/// hot path is one O(1) FSM transition. The threshold timer lives on the same
/// run loop, so it is naturally serialized with tap callbacks. The AX check
/// (`PasteTargetValidator`, `@MainActor`) is dispatched **off** the tap thread
/// onto a background queue (``runEditableCheckOffTapThread``) — it never stalls
/// the keystroke run loop — and its verdict is fed back onto the detector
/// queue. User callbacks fire on the main queue (``dispatchCallback``), like
/// the sibling monitors.
///
/// ## Privacy (CRITICAL)
/// The tap sees **every** keystroke globally. This type never logs, persists,
/// or inspects key *contents* — only the Space/Escape key codes it acts on and
/// state transitions. Secure-input fields are suppressed by the OS before the
/// tap sees them, so password keystrokes never reach here.
///
/// ## Testability
/// Every system boundary (tap creation, tap enable, threshold scheduling,
/// frontmost-app resolution, the AX check, Backspace synthesis, the
/// serializing queue, and logging) is an injected closure — the same
/// dependency-injection shape as `CarbonHotkeyMonitor`. Unit tests drive the
/// monitor synchronously through ``handleTapEvent(type:keyCode:isRepeat:)``,
/// ``fireThreshold()`` and the injected AX verdict, with no real tap, thread,
/// timer or Accessibility query.
final class SpaceHoldMonitor: HotkeyShortcutMonitoring {

    // MARK: - Callbacks

    typealias Callback = () -> Void

    // MARK: - Injected dependencies

    enum LogLevel { case info, error }

    /// Opaque token standing in for the installed tap. Production stores the
    /// `CFMachPort` here; the monitor only needs it as an "installed" flag and
    /// to drive the real run-loop wiring (which lives inside the default
    /// factory). Tests pass a dummy non-nil pointer.
    typealias TapHandle = OpaquePointer

    /// Creates (and, in production, installs on a dedicated run loop) the
    /// active `CGEventTap`. Returns `nil` when the tap could not be created —
    /// e.g. Input Monitoring not granted, or the tap was disabled at creation
    /// on a re-signed/adhoc build. The supplied callback is invoked by the OS
    /// for each `keyDown`/`keyUp` (and the `tapDisabled*` control events).
    typealias TapFactory = (@escaping CGEventTapCallBack) -> TapHandle?
    /// Re-enables the tap after the OS disabled it
    /// (`tapDisabledByTimeout`/`tapDisabledByUserInput`).
    typealias EnableTap = (_ enable: Bool) -> Void
    /// Arms the hold-threshold timer; the supplied block must be invoked (on
    /// the detector queue) once `holdThresholdMs` elapses.
    typealias ScheduleThreshold = (@escaping () -> Void) -> Void
    typealias CancelThreshold = () -> Void
    /// Resolves the frontmost application's pid + bundle id for the AX check.
    typealias FrontmostApp = () -> (pid: pid_t, bundleId: String?)?
    /// The Accessibility "focused element is an editable text field" check.
    typealias EditableCheck = (_ pid: pid_t, _ bundleId: String?) -> Bool
    /// Synthesizes one key event (used for Backspace deletion of leaked spaces).
    typealias PostEvent = (_ keyCode: CGKeyCode, _ down: Bool) -> Void
    /// Serializes all detector access. Synchronous on the tap thread, async
    /// for timer/AX completions.
    typealias RunOnDetectorQueue = (@escaping () -> Void) -> Void
    /// Runs the (potentially blocking, main-actor) AX editable check **off**
    /// the tap thread so the keystroke run loop never stalls. Production
    /// dispatches to a background queue; tests run inline.
    typealias RunEditableCheckOffTapThread = (@escaping () -> Void) -> Void
    /// Delivers a user callback (`onHotkey`/`onHotkeyReleased`/`onCancel`).
    /// Production hops to the main queue — matching `CarbonHotkeyMonitor` and
    /// `ModifierOnlyHotkeyMonitor`, whose callbacks always fire on main — since
    /// arming/stopping happens on the tap thread or a background queue. Tests
    /// run inline to assert synchronously.
    typealias DispatchCallback = (@escaping () -> Void) -> Void
    typealias LogFn = (LogLevel, String) -> Void

    /// Decision the tap callback returns to the OS for one event.
    enum TapDecision: Equatable {
        /// Let the event reach the focused app (return the event).
        case passThrough
        /// Consume the event (return `nil`) so it never reaches the app.
        case swallow
    }

    // MARK: - Stored state

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "hotkey")

    /// Marker stamped onto `eventSourceUserData` of every keystroke this monitor
    /// synthesizes (the Backspace deleting leaked spaces). Our active session tap
    /// observes events we post to `.cghidEventTap`; the tap callback reads this
    /// field and, when it matches, passes the event straight through instead of
    /// running it through the FSM — otherwise the monitor would swallow its own
    /// Backspace while `armed` and the leaked space would never be erased.
    /// Ordinary events carry `0` here, so a non-zero sentinel is unambiguous.
    static let syntheticEventTag: Int64 = 0x5744_524F_50  // arbitrary stable non-zero marker

    /// The functional hotkey modifiers (`⌘ ⇧ ⌃ ⌥`) the trigger gate compares.
    /// A raw `CGEventFlags` off a keyDown can also carry incidental, non-hotkey
    /// bits (Caps Lock `.maskAlphaShift`, numeric-keypad `.maskNumericPad`,
    /// secondary-Fn), so the gate masks the event flags down to these four before
    /// the exact-subset comparison — `⌥D` arms with Caps Lock on, `⌘⌥D` still
    /// fails to match an `⌥D` binding. Mirrors the `deviceIndependentFlagsMask`
    /// intersection pattern used elsewhere in the app for chord matching.
    static let functionalModifierMask: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate,
    ]

    /// The key whose hold arms the Drop gesture. Defaults to Space; a rebound
    /// combo Drop injects its own key code (e.g. `kVK_ANSI_D` for ⌥D).
    private let triggerKeyCode: CGKeyCode
    /// The exact set of functional modifiers required on the trigger keyDown.
    /// Empty for the default Space hold; a non-empty set marks a *modified combo*
    /// trigger, which changes the swallow policy (see ``triggerIsModifiedCombo``).
    private let requiredModifiers: CGEventFlags
    /// `true` when the trigger requires modifiers (a rebound combo). Combo
    /// triggers swallow the trigger keyDown from the **first** event (policy i):
    /// the character never prints, so no Backspace clean-up is needed. The
    /// default Space hold (`requiredModifiers == []`) keeps the legacy
    /// pass-through-then-delete behaviour. Keyed here, never in the FSM.
    private let triggerIsModifiedCombo: Bool

    private let onHotkey: Callback
    private let onHotkeyReleased: Callback
    private let onCancel: Callback

    private let makeTap: TapFactory
    private let enableTap: EnableTap
    private let scheduleThreshold: ScheduleThreshold
    private let cancelThreshold: CancelThreshold
    private let frontmostApp: FrontmostApp
    private let isEditable: EditableCheck
    private let postEvent: PostEvent
    private let runOnDetectorQueue: RunOnDetectorQueue
    private let runEditableCheckOffTapThread: RunEditableCheckOffTapThread
    private let dispatchCallback: DispatchCallback
    private let logEmit: LogFn
    /// Returns `true` when the Accessibility TCC grant is currently held. Used
    /// in the `tapDisabled*` branch to distinguish a transient OS throttle
    /// (re-enable is safe) from a revoked grant (re-enable would create a dead
    /// tap that lags all keyboard input system-wide → teardown instead).
    private let accessibilityTrusted: () -> Bool
    /// Called (on the main queue, via `dispatchCallback`) when a `tapDisabled*`
    /// event arrives while `accessibilityTrusted()` returns `false`. A later task
    /// (Task 7) wires this to a recovery screen; for now callers may no-op it.
    private let onAccessibilityLost: () -> Void

    /// Requests the Input Monitoring TCC grant and returns whether it was
    /// granted. Called at most once, lazily, when `makeTap` fails while
    /// Accessibility is already trusted — covering macOS versions where the
    /// active tap additionally needs IM. Production default surfaces the system
    /// prompt; tests inject a no-UI double.
    private let requestInputMonitoring: () -> Bool
    /// Ensures the IM fallback is attempted at most once across the lifetime of
    /// this monitor instance (a second `start()` after a successful retry must
    /// not re-prompt).
    private var didTryInputMonitoringFallback = false

    /// Ensures the Accessibility-lost teardown + repair signal fires at most once
    /// per monitor instance. The OS can deliver `tapDisabled*` repeatedly while
    /// the grant is gone; without this gate each would re-fire `onAccessibilityLost`
    /// (log-noise + redundant signal). Mirrors the trusted branch's one-shot
    /// backoff. Never reset on keystroke — the tap is dead in this state, so no
    /// real keystroke flows; recovery is a fresh monitor instance after re-register.
    private var didSignalAccessibilityLost = false

    private var detector = SpaceHoldDetector()
    private var tapHandle: TapHandle?

    /// Counts how many consecutive `tapDisabled*` events we have re-enabled
    /// without a real keystroke flowing between them. A real keystroke (one that
    /// successfully maps through `mapEvent`) resets this to zero, so a transient
    /// OS throttle that recovers doesn't trip the limit. An uninterrupted run of
    /// re-enables with no real keystrokes between them indicates a pathological
    /// loop that would lag all keyboard input — teardown at the limit instead.
    private var consecutiveReenables = 0
    private static let maxConsecutiveReenables = 3

    /// Whether the active tap is currently installed. Read by tests to assert
    /// the disabled-at-creation retry path.
    var isTapInstalled: Bool { tapHandle != nil }

    // MARK: - Init

    /// Designated initializer. In production the trailing dependencies default
    /// to the real system implementations; tests inject doubles.
    ///
    /// - Parameters:
    ///   - onHotkey: start the Drop recording (the gesture armed).
    ///   - onHotkeyReleased: stop recording and transcribe (Space released
    ///     while armed).
    ///   - onCancel: discard the in-flight recording without transcribing
    ///     (Escape while armed). **Distinct** from `onHotkeyReleased` — Stage 4
    ///     wires this to the real recording-cancel path; until then it is a
    ///     no-op-friendly discard hook.
    init(
        triggerKeyCode: CGKeyCode = CGKeyCode(kVK_Space),
        requiredModifiers: CGEventFlags = [],
        onHotkey: @escaping Callback,
        onHotkeyReleased: @escaping Callback,
        onCancel: @escaping Callback,
        makeTap: TapFactory? = nil,
        enableTap: EnableTap? = nil,
        scheduleThreshold: ScheduleThreshold? = nil,
        cancelThreshold: CancelThreshold? = nil,
        frontmostApp: @escaping FrontmostApp = SpaceHoldMonitor.defaultFrontmostApp,
        isEditable: @escaping EditableCheck = SpaceHoldMonitor.defaultIsEditable,
        postEvent: @escaping PostEvent = SpaceHoldMonitor.defaultPostEvent,
        runOnDetectorQueue: RunOnDetectorQueue? = nil,
        runEditableCheckOffTapThread: RunEditableCheckOffTapThread? = nil,
        dispatchCallback: DispatchCallback? = nil,
        log: LogFn? = nil,
        accessibilityTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
        onAccessibilityLost: @escaping () -> Void = {},
        requestInputMonitoring: @escaping () -> Bool = { PermissionsHelper.inputMonitoringGranted(prompt: true) }
    ) {
        self.triggerKeyCode = triggerKeyCode
        self.requiredModifiers = requiredModifiers.intersection(Self.functionalModifierMask)
        self.triggerIsModifiedCombo = !self.requiredModifiers.isEmpty
        self.onHotkey = onHotkey
        self.onHotkeyReleased = onHotkeyReleased
        self.onCancel = onCancel
        self.frontmostApp = frontmostApp
        self.isEditable = isEditable
        self.postEvent = postEvent
        self.logEmit = log ?? { level, message in
            os_log("%{public}@", log: Self.log, type: level == .error ? .error : .info, message)
        }

        // The serial queue that orders every detector mutation. Captured by the
        // default threshold scheduler so the timer callback lands on it too.
        let queue = DispatchQueue(label: "com.rootwise.sidekey.space-hold-detector")
        self.runOnDetectorQueue = runOnDetectorQueue ?? { work in queue.sync(execute: work) }

        // The AX check (frontmost resolve + `PasteTargetValidator`, which is
        // `@MainActor`) runs here, off the tap thread, so the keystroke run
        // loop is never blocked waiting on the main actor.
        self.runEditableCheckOffTapThread = runEditableCheckOffTapThread ?? { work in
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }

        self.dispatchCallback = dispatchCallback ?? { work in
            DispatchQueue.main.async(execute: work)
        }

        self.accessibilityTrusted = accessibilityTrusted
        self.onAccessibilityLost = onAccessibilityLost
        self.requestInputMonitoring = requestInputMonitoring

        // A dedicated run loop on its own thread hosts both the tap source and
        // the threshold timer, so timer fires are naturally serialized with tap
        // callbacks. Created lazily on first `start()`.
        let tapThread = SpaceHoldMonitor.TapThread(queueLabel: "com.rootwise.sidekey.space-hold-tap")

        self.makeTap = makeTap ?? { callback in
            tapThread.installTap(callback: callback)
        }
        self.enableTap = enableTap ?? { enable in
            tapThread.enableTap(enable)
        }
        self.scheduleThreshold = scheduleThreshold ?? { fire in
            // `fire` is `feed(.thresholdFired)`, which already serializes on the
            // detector queue via `runOnDetectorQueue`. Do NOT wrap it in another
            // `queue.sync` here — the timer fires on the tap thread and a nested
            // sync onto the same serial queue would deadlock.
            tapThread.scheduleThreshold(afterMs: SpaceHoldDetector.holdThresholdMs, fire: fire)
        }
        self.cancelThreshold = cancelThreshold ?? {
            tapThread.cancelThreshold()
        }
    }

    deinit {
        stop()
    }

    // MARK: - HotkeyShortcutMonitoring

    func start() throws {
        stop()
        guard let handle = makeTap(Self.tapCallback) else {
            // Tap creation failed. On macOS versions where the active
            // CGEventTap additionally requires Input Monitoring, try requesting
            // IM once (lazily) and retry — but only when Accessibility is
            // already granted (without Accessibility the retry would also fail).
            if accessibilityTrusted() && !didTryInputMonitoringFallback {
                didTryInputMonitoringFallback = true
                if requestInputMonitoring(), let retry = makeTap(Self.tapCallback) {
                    SpaceHoldMonitor.activeMonitor = self
                    tapHandle = retry
                    logEmit(.info, "space_hold_tap_installed_after_im_fallback")
                    return
                }
            }
            // Disabled-at-creation (no Input Monitoring grant, or tap disabled
            // immediately on a re-signed/adhoc build). Don't crash — record it
            // and leave the tap uninstalled; a later `start()` (after the user
            // grants the permission) retries.
            logEmit(.error, "space_hold_tap_create_failed (retry on next start)")
            return
        }
        // Smuggle `self` to the C callback via the per-process registry.
        SpaceHoldMonitor.activeMonitor = self
        tapHandle = handle
        logEmit(.info, "space_hold_tap_installed")
    }

    func stop() {
        cancelThreshold()
        if tapHandle != nil {
            enableTap(false)
            tapHandle = nil
        }
        if SpaceHoldMonitor.activeMonitor === self {
            SpaceHoldMonitor.activeMonitor = nil
        }
        // Reset the FSM so a subsequent start() begins idle.
        runOnDetectorQueue { [weak self] in
            self?.detector = SpaceHoldDetector()
        }
    }

    // MARK: - Tap event handling (entry point for both production + tests)

    /// Process one tap event and return whether it should reach the focused
    /// app. Called synchronously by the tap callback (production) and directly
    /// by unit tests. Runs the FSM on the serial detector queue.
    ///
    /// `isSynthetic` is `true` when the event carries our own tag
    /// (``syntheticEventTag`` on `eventSourceUserData`) — i.e. it is a keystroke
    /// **we** posted (the Backspace that erases leaked spaces). Such events must
    /// pass straight through and must NOT touch the FSM: our active session tap
    /// sees keystrokes we post to `.cghidEventTap`, and while `armed` a Backspace
    /// maps to `.otherKeyDown` → no `passThrough` → `.swallow`, which would make
    /// the monitor eat its own deletion (the leaked space then survives). The
    /// short-circuit closes that self-capture loop.
    @discardableResult
    func handleTapEvent(type: CGEventType, keyCode: CGKeyCode, isRepeat: Bool, flags: CGEventFlags = [], isSynthetic: Bool = false) -> TapDecision {
        // Our own synthesized keystroke looped back through the session tap.
        // Never swallow it and never feed the FSM — it is output, not input.
        if isSynthetic {
            return .passThrough
        }

        // Control events: the OS disabled the tap. Branch on Accessibility grant:
        // - trusted → transient throttle → re-enable safely.
        // - lost → re-enabling a dead tap lags ALL keyboard input system-wide →
        //   teardown instead and signal recovery via `onAccessibilityLost`.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if accessibilityTrusted() {
                consecutiveReenables += 1
                if consecutiveReenables == Self.maxConsecutiveReenables + 1 {
                    // First time we cross the limit: tear down and signal once.
                    logEmit(.error, "space_hold_tap_reenable_loop — tearing down")
                    enableTap(false)
                    dispatchCallback(onAccessibilityLost)
                } else if consecutiveReenables <= Self.maxConsecutiveReenables {
                    logEmit(.info, "space_hold_tap_reenabled")
                    enableTap(true)
                }
                // consecutiveReenables > max+1: already torn down, silently ignore.
            } else {
                if !didSignalAccessibilityLost {
                    didSignalAccessibilityLost = true
                    logEmit(.error, "space_hold_tap_disabled_accessibility_lost — tearing down")
                    enableTap(false)
                    dispatchCallback(onAccessibilityLost)
                }
                // else: already torn down + signaled, ignore repeat tapDisabled
            }
            return .passThrough
        }

        guard let event = Self.mapEvent(
            type: type,
            keyCode: keyCode,
            isRepeat: isRepeat,
            flags: flags,
            triggerKeyCode: triggerKeyCode,
            requiredModifiers: requiredModifiers
        ) else {
            // Not a keyDown/keyUp we model — pass through untouched.
            return .passThrough
        }

        // A real keystroke is flowing through the FSM: the tap is healthy and
        // the OS is not in a pathological re-enable loop. Reset the backoff
        // counter so a transient throttle that recovers doesn't accumulate
        // toward the limit across unrelated re-enable events.
        consecutiveReenables = 0

        var beforeState: SpaceHoldDetector.State = .idle
        var actions: [SpaceHoldDetector.Action] = []
        runOnDetectorQueue { [weak self] in
            guard let self else { return }
            beforeState = self.detector.state
            actions = self.detector.handle(event)
        }
        perform(actions)
        return Self.tapDecision(
            for: event,
            beforeState: beforeState,
            actions: actions,
            triggerIsModifiedCombo: triggerIsModifiedCombo
        )
    }

    /// Decides whether the tap should consume (`.swallow`) or forward
    /// (`.passThrough`) the event that produced `actions`.
    ///
    /// The FSM does not tag actions with a swallow flag; the rule is derived
    /// from its documented contract:
    /// - An explicit ``SpaceHoldDetector/Action/passThrough`` always forwards —
    ///   **except** under the modified-combo policy below.
    /// - While **armed**, the monitor owns the keystream: the release, the
    ///   Escape that cancels, held-trigger auto-repeats, and stray keys are all
    ///   consumed (the FSM emits no `passThrough` for them) so nothing leaks
    ///   into the field mid-recording.
    /// - While **awaitingDecision**, only trigger auto-repeats are swallowed (to
    ///   stop extra characters leaking during the AX check); a release / other
    ///   key / Escape there is ordinary input and must reach the app.
    /// - Every other state (`idle`, `pending`) forwards — those events are
    ///   tracked or ignored, never intercepted.
    ///
    /// ## Swallow policy is trigger-dependent (combo policy i)
    /// `triggerIsModifiedCombo` selects between two leaked-character policies:
    /// - **Space (`false`, default):** the trigger keyDown passes through; the
    ///   printed space is counted as leaked and erased with Backspace on arm.
    ///   This preserves the original Space behaviour bit-for-bit.
    /// - **Combo (`true`):** the trigger keyDown is swallowed from the **first**
    ///   event, so the bound character (e.g. ∂ for ⌥D) never prints at all and
    ///   no Backspace clean-up is needed even on a miss. Only the trigger key's
    ///   own keyDowns are affected — a non-trigger key (which the FSM forwards
    ///   with an explicit `passThrough`) still reaches the app.
    static func tapDecision(
        for event: SpaceHoldDetector.Event,
        beforeState: SpaceHoldDetector.State,
        actions: [SpaceHoldDetector.Action],
        triggerIsModifiedCombo: Bool = false
    ) -> TapDecision {
        // Combo policy i: consume the trigger key's own keyDowns from the first
        // event so the bound character never reaches the field. `.spaceKeyDown`
        // is emitted by `mapEvent` only for the *gated* trigger key; non-trigger
        // keys map to `.otherKeyDown` and are unaffected here.
        if triggerIsModifiedCombo, case .spaceKeyDown = event {
            return .swallow
        }
        if actions.contains(.passThrough) {
            return .passThrough
        }
        switch beforeState {
        case .armed:
            return .swallow
        case .awaitingDecision:
            if case .spaceKeyDown = event { return .swallow }
            return .passThrough
        case .idle, .pending:
            return .passThrough
        }
    }

    /// Maps a raw tap event to the FSM's input vocabulary, gated on the
    /// configured trigger key + modifiers. Pure; unit-tested directly.
    ///
    /// The FSM vocabulary keeps its Space-era names (`spaceKeyDown`/`spaceKeyUp`)
    /// but they are abstract "trigger key" events — `mapEvent` is the single
    /// place that resolves *which* physical key+modifier combination is the
    /// trigger:
    /// - Trigger key (`triggerKeyCode`) keyDown that passes the modifier gate →
    ///   `spaceKeyDown`; its keyUp → `spaceKeyUp`.
    /// - Escape (`kVK_Escape`) keyDown → `escapeKeyDown` (the FSM ignores it
    ///   unless armed, so an ordinary Escape passes through). Escape is fixed
    ///   (the universal cancel key), independent of the trigger binding.
    /// - Any other keyDown — including the trigger key **without** the required
    ///   modifiers, or with extra ones — → `otherKeyDown`, so it flows to the
    ///   app and (while pending) cancels the gesture as ordinary typing.
    /// - Any other event (e.g. a non-trigger keyUp) → `nil` (pass through; the
    ///   FSM has no transition that depends on it).
    ///
    /// ### Modifier gate
    /// `requiredModifiers` is the exact set of functional modifiers the trigger
    /// keyDown must carry:
    /// - **Empty (default Space):** no gate — the trigger key matches on key code
    ///   alone, bit-for-bit as the original hardcoded Space path did.
    /// - **Non-empty (combo, e.g. ⌥D):** the event's functional modifiers
    ///   (`flags` masked to `⌘⇧⌃⌥`) must **equal** `requiredModifiers`. So bare
    ///   `D` (no ⌥) and `⌘⌥D` (extra ⌘) both fail and map to `otherKeyDown`;
    ///   only `⌥D` arms. Incidental bits (Caps Lock, keypad) are masked out.
    static func mapEvent(
        type: CGEventType,
        keyCode: CGKeyCode,
        isRepeat: Bool,
        flags: CGEventFlags = [],
        triggerKeyCode: CGKeyCode = CGKeyCode(kVK_Space),
        requiredModifiers: CGEventFlags = []
    ) -> SpaceHoldDetector.Event? {
        switch type {
        case .keyDown:
            if keyCode == triggerKeyCode, modifiersSatisfy(flags, required: requiredModifiers) {
                return .spaceKeyDown(isRepeat: isRepeat)
            }
            if Int(keyCode) == kVK_Escape {
                return .escapeKeyDown
            }
            return .otherKeyDown
        case .keyUp:
            return keyCode == triggerKeyCode ? .spaceKeyUp : nil
        default:
            return nil
        }
    }

    /// The modifier gate: empty `required` (Space) is an unconditional match
    /// (key-code-only, preserving legacy behaviour); a non-empty `required`
    /// (combo) demands the held functional modifiers **exactly** equal it, after
    /// masking out incidental non-hotkey bits (Caps Lock, numeric keypad, Fn).
    private static func modifiersSatisfy(_ flags: CGEventFlags, required: CGEventFlags) -> Bool {
        let required = required.intersection(functionalModifierMask)
        guard !required.isEmpty else { return true }
        return flags.intersection(functionalModifierMask) == required
    }

    // MARK: - Action execution

    /// Executes the FSM's ordered side effects. The swallow/pass verdict for
    /// the tap is computed separately by ``tapDecision(for:beforeState:actions:)``
    /// — this method only performs effects, so it is shared by both the tap
    /// path and the internal timer/AX completions (which have no verdict).
    private func perform(_ actions: [SpaceHoldDetector.Action]) {
        for action in actions {
            switch action {
            case .passThrough:
                // Forwarding is handled by `tapDecision`; no side effect here.
                break
            case .beginPending:
                scheduleThreshold { [weak self] in
                    self?.feed(.thresholdFired)
                }
            case .incrementLeak:
                // Bookkeeping lives in the FSM (`leaked`); nothing to synthesize.
                break
            case .requestEditableCheck:
                requestEditableCheck()
            case .cancelPending:
                cancelThreshold()
            case let .arm(deleteCount):
                // The FSM counts every trigger keyDown as a leaked character
                // (it can't see the tap verdict). Under combo policy i those
                // keyDowns were *swallowed* and never printed, so there is
                // nothing to erase — deleting `deleteCount` here would Backspace
                // real characters left of the cursor. The swallow policy and the
                // delete policy are two faces of the same trigger-dependent rule
                // (both live in the monitor, not the FSM): combo ⇒ 0 leaked.
                let toDelete = triggerIsModifiedCombo ? 0 : deleteCount
                deleteLeakedTriggerKeys(count: toDelete)
                logEmit(.info, "space_hold_armed deleted=\(toDelete)")
                dispatchCallback(onHotkey)
            case .stopAndTranscribe:
                logEmit(.info, "space_hold_released")
                dispatchCallback(onHotkeyReleased)
            case .cancelDrop:
                logEmit(.info, "space_hold_cancelled")
                dispatchCallback(onCancel)
            }
        }
    }

    /// Feed an internal event (threshold fired, AX resolved) into the FSM on
    /// the serial queue and perform any resulting actions. Used by the timer
    /// and AX completion, which have no tap verdict to return.
    private func feed(_ event: SpaceHoldDetector.Event) {
        var actions: [SpaceHoldDetector.Action] = []
        runOnDetectorQueue { [weak self] in
            guard let self else { return }
            actions = self.detector.handle(event)
        }
        perform(actions)
    }

    /// Resolves the frontmost app and runs the AX editable check **off** the
    /// tap thread, then feeds the verdict back into the FSM on the detector
    /// queue. If the gesture already resolved (release/other-key arrived
    /// first), the FSM is back in `idle` and the late verdict is a harmless
    /// no-op — closing the "release during the AX query" race.
    private func requestEditableCheck() {
        runEditableCheckOffTapThread { [weak self] in
            guard let self else { return }
            let editable: Bool
            if let app = self.frontmostApp() {
                editable = self.isEditable(app.pid, app.bundleId)
            } else {
                editable = false
            }
            self.feed(.editableResolved(isEditable: editable))
        }
    }

    /// Synthesizes `count` Backspace presses (down+up each) to erase the trigger
    /// characters that leaked into the field before the hold was confirmed. For
    /// the default Space trigger this is the printed spaces; for a modified combo
    /// (swallowed from the first keyDown under policy i) `count` is normally 0,
    /// so this is a safety net that runs only if a character did slip through.
    private func deleteLeakedTriggerKeys(count: Int) {
        guard count > 0 else { return }
        let backspace = CGKeyCode(kVK_Delete)   // kVK_Delete == Backspace (erase-left)
        for _ in 0..<count {
            postEvent(backspace, true)
            postEvent(backspace, false)
        }
    }

    // MARK: - Test hooks

    /// Manually fire the hold threshold (production uses a real run-loop timer).
    /// Exposed for unit tests that drive the gesture without a system timer.
    func fireThreshold() {
        feed(.thresholdFired)
    }

    // MARK: - C callback bridge

    /// The single active monitor whose tap callback is live. `CGEventTap`'s C
    /// callback can't capture Swift state, and `userInfo` round-trips awkwardly
    /// across the run-loop hop, so we route through a per-process reference.
    /// Only one Space-hold tap is ever installed at a time (Drop is a single
    /// binding), so a single slot is sufficient.
    private static weak var activeMonitor: SpaceHoldMonitor?

    /// C-compatible tap callback. Translates the raw event into a
    /// ``TapDecision`` via the active monitor and returns the event (pass) or
    /// `nil` (swallow). Keeps the hot path minimal: a single synchronous queue
    /// hop computing an O(1) FSM transition; AX and Backspace happen off it.
    private static let tapCallback: CGEventTapCallBack = { _, type, event, _ in
        guard let monitor = SpaceHoldMonitor.activeMonitor else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        // Read the modifiers off THIS keyDown — the modifier gate compares them
        // against the configured combo (no flags-change tracking between events).
        let flags = event.flags
        // Recognise keystrokes this monitor synthesized (the leaked-space
        // Backspace) so they are passed through, not swallowed as foreign input.
        let isSynthetic = event.getIntegerValueField(.eventSourceUserData) == SpaceHoldMonitor.syntheticEventTag
        let decision = monitor.handleTapEvent(type: type, keyCode: keyCode, isRepeat: isRepeat, flags: flags, isSynthetic: isSynthetic)
        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        }
    }

    // MARK: - Production defaults

    private static func defaultFrontmostApp() -> (pid: pid_t, bundleId: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return (app.processIdentifier, app.bundleIdentifier)
    }

    /// The Accessibility check is `@MainActor`-isolated. The tap and detector
    /// never run on the main thread, so hop onto it synchronously here — this
    /// runs from `requestEditableCheck`, which is already off the tap callback.
    private static func defaultIsEditable(pid: pid_t, bundleId: String?) -> Bool {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                PasteTargetValidator.appHasFocusedTextInput(pid: pid, bundleIdentifier: bundleId)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                PasteTargetValidator.appHasFocusedTextInput(pid: pid, bundleIdentifier: bundleId)
            }
        }
    }

    /// Synthesizes one key event, mirroring `AutoPasteEngine.defaultPostEvent`
    /// (same `hidSystemState` source + `.cghidEventTap` posting). Used only for
    /// Backspace; no modifier flags.
    ///
    /// The event is tagged with ``syntheticEventTag`` on `eventSourceUserData`
    /// so that when it loops back through this monitor's own session tap the
    /// callback recognises it and passes it through instead of swallowing it.
    private static func defaultPostEvent(_ keyCode: CGKeyCode, _ down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Dedicated tap thread (production run-loop host)

extension SpaceHoldMonitor {
    /// Hosts the active `CGEventTap` source and the hold-threshold timer on a
    /// single dedicated thread's run loop. Keeping both on one run loop means
    /// the timer fires on the same thread as tap callbacks, so they never race
    /// on the detector beyond the serial-queue hop the monitor already does.
    ///
    /// This object only owns Core Foundation run-loop plumbing; all FSM logic
    /// stays in `SpaceHoldMonitor`. It is excluded from unit tests (which inject
    /// closures in its place), so it carries no test seams of its own.
    final class TapThread {
        private let queueLabel: String
        private var thread: Thread?
        private var runLoop: CFRunLoop?
        private var machPort: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private var thresholdTimer: CFRunLoopTimer?
        private let startGate = DispatchSemaphore(value: 0)

        init(queueLabel: String) {
            self.queueLabel = queueLabel
        }

        /// Creates the tap, attaches it to a freshly-spun dedicated run loop,
        /// and returns an opaque handle (the `CFMachPort` as a token). Returns
        /// `nil` if `CGEvent.tapCreate` fails (Input Monitoring not granted) or
        /// the tap is disabled the instant it is created.
        func installTap(callback: @escaping CGEventTapCallBack) -> TapHandle? {
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            guard let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: nil
            ) else {
                return nil
            }
            // A tap that is disabled the moment it is created (re-signed/adhoc
            // builds, or revoked permission) is unusable — report failure so
            // the monitor takes its retry path.
            guard CGEvent.tapIsEnabled(tap: port) else {
                return nil
            }
            self.machPort = port
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            self.runLoopSource = source

            let thread = Thread { [weak self] in
                guard let self else { return }
                self.runLoop = CFRunLoopGetCurrent()
                if let source {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
                }
                self.startGate.signal()
                CFRunLoopRun()
            }
            thread.name = queueLabel
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
            startGate.wait()   // ensure the run loop is live before returning
            return OpaquePointer(Unmanaged.passUnretained(port).toOpaque())
        }

        func enableTap(_ enable: Bool) {
            guard let port = machPort else { return }
            CGEvent.tapEnable(tap: port, enable: enable)
            if !enable {
                teardown()
            }
        }

        func scheduleThreshold(afterMs ms: Int, fire: @escaping () -> Void) {
            guard let runLoop else { return }
            cancelThreshold()
            let timer = CFRunLoopTimerCreateWithHandler(
                kCFAllocatorDefault,
                CFAbsoluteTimeGetCurrent() + Double(ms) / 1000.0,
                0, 0, 0
            ) { _ in fire() }
            thresholdTimer = timer
            CFRunLoopAddTimer(runLoop, timer, .commonModes)
        }

        func cancelThreshold() {
            if let timer = thresholdTimer {
                CFRunLoopTimerInvalidate(timer)
                thresholdTimer = nil
            }
        }

        private func teardown() {
            cancelThreshold()
            if let runLoop, let source = runLoopSource {
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
            if let runLoop {
                CFRunLoopStop(runLoop)
            }
            runLoopSource = nil
            machPort = nil
            runLoop = nil
            thread = nil
        }
    }
}

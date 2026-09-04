import Foundation

/// Pure, deterministic finite-state machine deciding whether a Space press is
/// an ordinary tap (let it through) or a hold gesture that should arm the Drop
/// flow (record while held, transcribe on release).
///
/// This type owns **no** system state: no `CGEventTap`, no Accessibility query,
/// no real timer, no callbacks. It is the testable core of Stage 3's
/// `SpaceHoldMonitor`, which feeds raw keyboard events in via ``handle(_:)``,
/// reads back the emitted ``Action`` list, and performs every side effect
/// (swallow/passthrough the event, synthesize Backspace, run the AX editable
/// check, start/stop the Drop recording). Same input sequence ⇒ same output.
///
/// ## Cross-stage contract (for `SpaceHoldMonitor`)
/// ``handle(_:)`` returns the actions for **one** event, in execution order:
/// - ``Action/passThrough``: let the triggering key reach the focused app.
/// - ``Action/beginPending``: a Space hold candidate started; arm the threshold
///   timer (which later sends ``Event/thresholdFired``). The first Space is
///   *already printed* in the field — it counts toward `leaked`, starting at 1.
/// - ``Action/incrementLeak``: another Space (auto-repeat) leaked into the field.
/// - ``Action/requestEditableCheck``: the hold threshold elapsed; run the AX
///   focused-text-field check **off** the tap callback and report the result
///   back via ``Event/editableResolved(isEditable:)``.
/// - ``Action/cancelPending``: abandon the in-progress gesture; cancel the timer
///   and stop swallowing. (Never emitted together with a Drop start.)
/// - ``Action/arm(deleteCount:)``: the gesture is a confirmed hold in an
///   editable field. Delete exactly `deleteCount` leaked spaces and start the
///   Drop recording. Emitted **at most once** per gesture.
/// - ``Action/stopAndTranscribe``: Space released while armed; stop recording
///   and transcribe.
/// - ``Action/cancelDrop``: Escape pressed while armed; discard the recording.
///
/// An **empty** action list means "no side effect" — used both for genuine
/// no-ops (stale timer/AX events that arrive after the gesture resolved) and
/// for the `armed` state's swallowed Space auto-repeats. In `armed`, returning
/// no `passThrough` is the signal for `SpaceHoldMonitor` to swallow the event
/// (return `nil` from the tap callback) so repeats never reach the field.
struct SpaceHoldDetector {

    /// Hold duration after which a Space press is treated as a hold gesture
    /// rather than a tap. The real timer lives in Stage 3; this is the single
    /// named source for that threshold.
    static let holdThresholdMs = 300

    /// The machine's current state.
    ///
    /// - `idle`: no Space gesture in progress.
    /// - `pending(leaked:)`: Space is down, threshold not yet elapsed; `leaked`
    ///   counts the spaces that have already reached the field (starts at 1 for
    ///   the initial keyDown, increments per auto-repeat).
    /// - `awaitingDecision(leaked:)`: threshold elapsed; waiting for the AX
    ///   editable result. A release or other key here cancels (closes the race
    ///   where the user lets go mid-AX-query).
    /// - `armed`: confirmed hold in an editable field; recording is running.
    enum State: Equatable {
        case idle
        case pending(leaked: Int)
        case awaitingDecision(leaked: Int)
        case armed
    }

    /// Raw inputs the monitor feeds in. `isRepeat` distinguishes the initial
    /// keyDown from OS auto-repeat keyDowns.
    enum Event: Equatable {
        case spaceKeyDown(isRepeat: Bool)
        case spaceKeyUp
        case otherKeyDown
        case escapeKeyDown
        case thresholdFired
        case editableResolved(isEditable: Bool)
    }

    /// Side effects for the monitor to perform, in order.
    enum Action: Equatable {
        case passThrough
        case beginPending
        case incrementLeak
        case requestEditableCheck
        case cancelPending
        case arm(deleteCount: Int)
        case stopAndTranscribe
        case cancelDrop
    }

    private(set) var state: State = .idle

    /// Advance the machine by one event, mutating ``state`` and returning the
    /// ordered actions the monitor must perform.
    mutating func handle(_ event: Event) -> [Action] {
        switch state {
        case .idle:
            return handleIdle(event)
        case .pending(let leaked):
            return handlePending(event, leaked: leaked)
        case .awaitingDecision(let leaked):
            return handleAwaitingDecision(event, leaked: leaked)
        case .armed:
            return handleArmed(event)
        }
    }

    // MARK: - Per-state transitions

    private mutating func handleIdle(_ event: Event) -> [Action] {
        switch event {
        case .spaceKeyDown(let isRepeat):
            // A repeat keyDown with no preceding non-repeat is an orphaned OS
            // event (e.g. the gesture already resolved): pass it through, stay
            // idle. The fresh keyDown starts a pending gesture with the first
            // space already printed (leaked = 1).
            guard !isRepeat else { return [.passThrough] }
            state = .pending(leaked: 1)
            return [.passThrough, .beginPending]
        case .spaceKeyUp, .otherKeyDown, .escapeKeyDown, .thresholdFired, .editableResolved:
            // Nothing in flight: the FSM neither swallows nor tracks these, so
            // it emits no action — the monitor lets the key flow by default,
            // and stale timer/AX results are ignored.
            return []
        }
    }

    private mutating func handlePending(_ event: Event, leaked: Int) -> [Action] {
        switch event {
        case .spaceKeyDown(let isRepeat):
            // Auto-repeat while holding: another space leaked into the field.
            guard isRepeat else {
                // A second non-repeat keyDown without an intervening keyUp is
                // anomalous; treat it as another leaked space, idempotently.
                return [.passThrough, .incrementLeak]
            }
            state = .pending(leaked: leaked + 1)
            return [.passThrough, .incrementLeak]
        case .spaceKeyUp:
            // Released before the threshold ⇒ it was a tap. The space is
            // already printed; let the keyUp through and reset.
            state = .idle
            return [.passThrough]
        case .otherKeyDown, .escapeKeyDown:
            // Another key (or Escape) during a Space hold ⇒ ordinary typing,
            // not a gesture. Abandon the candidate; the FSM does not swallow
            // the other key, so it flows to the app by default.
            state = .idle
            return [.cancelPending]
        case .thresholdFired:
            // Hold confirmed by time; ask whether the focused field is editable.
            state = .awaitingDecision(leaked: leaked)
            return [.requestEditableCheck]
        case .editableResolved:
            // No AX check was requested yet; ignore a stray result.
            return []
        }
    }

    private mutating func handleAwaitingDecision(_ event: Event, leaked: Int) -> [Action] {
        switch event {
        case .editableResolved(let isEditable):
            state = .idle
            guard isEditable else { return [.cancelPending] }
            state = .armed
            return [.arm(deleteCount: leaked)]
        case .spaceKeyUp:
            // Released while the AX query was in flight. Arming now would leave
            // a recording running on a key that is no longer held — the release
            // wins and a late `editableResolved` must not arm (we are back in
            // idle, where it is a no-op).
            state = .idle
            return [.cancelPending]
        case .otherKeyDown:
            state = .idle
            return [.cancelPending]
        case .escapeKeyDown:
            state = .idle
            return [.cancelPending]
        case .spaceKeyDown:
            // Auto-repeat is expected while we await the result; swallow it so
            // no extra space leaks, and keep waiting.
            return []
        case .thresholdFired:
            // Duplicate timer fire; already past the threshold.
            return []
        }
    }

    private mutating func handleArmed(_ event: Event) -> [Action] {
        switch event {
        case .spaceKeyUp:
            state = .idle
            return [.stopAndTranscribe]
        case .escapeKeyDown:
            state = .idle
            return [.cancelDrop]
        case .spaceKeyDown:
            // Held-key auto-repeat: swallow at the FSM level (empty ⇒ monitor
            // returns nil for the event). Never re-arm.
            return []
        case .otherKeyDown, .thresholdFired, .editableResolved:
            // Idempotent: stale/duplicate signals while recording are no-ops.
            return []
        }
    }
}

extension SpaceHoldDetector.Action {
    /// Convenience for tests/monitor to assert "an arm happened" without
    /// matching the associated `deleteCount`.
    var isArm: Bool {
        if case .arm = self { return true }
        return false
    }
}

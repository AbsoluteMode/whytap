import XCTest
@testable import Sidekey

/// `SpaceHoldDetector` is the pure, deterministic finite-state machine that
/// decides — from a stream of keyboard events — whether a Space press is an
/// ordinary tap (let it through) or a hold gesture that should arm the Drop
/// flow. It owns ZERO system state: no `CGEventTap`, no AX, no real timer,
/// no callbacks. Stage 3 (`SpaceHoldMonitor`) feeds events in, reads the
/// resulting `[SpaceHoldDetector.Action]`, and performs the side effects
/// (swallow/passthrough event, synth Backspace, AX check, start/stop Drop).
///
/// Mirrors the pure-function + parametrized-test style of
/// `AppDelegateDropFlowRouteTests` so the routing rules can be covered
/// without instantiating any system object.
final class SpaceHoldDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// Drive the detector through a sequence of events from a fresh `.idle`
    /// start, returning the final state plus the actions emitted at each step.
    private func run(
        _ events: [SpaceHoldDetector.Event]
    ) -> (state: SpaceHoldDetector.State, steps: [[SpaceHoldDetector.Action]]) {
        var detector = SpaceHoldDetector()
        var steps: [[SpaceHoldDetector.Action]] = []
        for event in events {
            steps.append(detector.handle(event))
        }
        return (detector.state, steps)
    }

    // MARK: - Threshold constant

    func test_hold_threshold_is_300ms() {
        XCTAssertEqual(SpaceHoldDetector.holdThresholdMs, 300)
    }

    // MARK: - Short tap (keyDown → keyUp before threshold)

    func test_short_tap_passes_through_without_arming() {
        // The single space was already printed into the field on keyDown
        // (passThrough). Releasing before the threshold fires resolves the
        // gesture as an ordinary tap: no arm, no Backspace, back to idle.
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .spaceKeyUp
        ])

        XCTAssertEqual(result.steps[0], [.passThrough, .beginPending])
        XCTAssertEqual(result.steps[1], [.passThrough])
        XCTAssertEqual(result.state, .idle)
        XCTAssertFalse(result.steps.flatMap { $0 }.contains { $0.isArm })
    }

    // MARK: - Hold → editable → arm with the real leaked count

    func test_threshold_then_editable_true_arms_with_leaked_count() {
        // 1 keyDown + 3 repeats = 4 leaked spaces that actually reached the
        // field. After the threshold fires we ask for the editable check;
        // a positive result arms Drop and tells Stage 3 to delete exactly 4.
        let result = run([
            .spaceKeyDown(isRepeat: false),   // leaked = 1
            .spaceKeyDown(isRepeat: true),    // leaked = 2
            .spaceKeyDown(isRepeat: true),    // leaked = 3
            .spaceKeyDown(isRepeat: true),    // leaked = 4
            .thresholdFired,
            .editableResolved(isEditable: true)
        ])

        XCTAssertEqual(result.steps[0], [.passThrough, .beginPending])
        XCTAssertEqual(result.steps[1], [.passThrough, .incrementLeak])
        XCTAssertEqual(result.steps[2], [.passThrough, .incrementLeak])
        XCTAssertEqual(result.steps[3], [.passThrough, .incrementLeak])
        XCTAssertEqual(result.steps[4], [.requestEditableCheck])
        XCTAssertEqual(result.steps[5], [.arm(deleteCount: 4)])
        XCTAssertEqual(result.state, .armed)
    }

    // MARK: - Hold → not editable → cancel, no arm

    func test_threshold_then_editable_false_cancels_without_arming() {
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired,
            .editableResolved(isEditable: false)
        ])

        XCTAssertEqual(result.steps[1], [.requestEditableCheck])
        XCTAssertEqual(result.steps[2], [.cancelPending])
        XCTAssertEqual(result.state, .idle)
        XCTAssertFalse(result.steps.flatMap { $0 }.contains { $0.isArm })
    }

    // MARK: - Key Repeat OFF → single leaked space

    func test_key_repeat_off_arms_with_delete_count_one() {
        // No repeats arrive at all (System Settings → Key Repeat off). The
        // threshold timer still fires, and we must delete exactly the one
        // space that leaked on the initial keyDown.
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired,
            .editableResolved(isEditable: true)
        ])

        XCTAssertEqual(result.steps[2], [.arm(deleteCount: 1)])
        XCTAssertEqual(result.state, .armed)
    }

    // MARK: - Release DURING the AX request (race close)

    func test_key_up_during_awaiting_decision_cancels_without_arming() {
        // The user let go after the threshold fired but BEFORE the editable
        // result came back. Arming now would leave a recording stuck on a
        // key that is no longer held — so the release wins and cancels.
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired,
            .spaceKeyUp,
            .editableResolved(isEditable: true)   // late result must NOT arm
        ])

        XCTAssertEqual(result.steps[2], [.cancelPending])
        XCTAssertEqual(result.state, .idle)
        XCTAssertFalse(result.steps.flatMap { $0 }.contains { $0.isArm })
    }

    // MARK: - Other key DURING the AX request

    func test_other_key_during_awaiting_decision_cancels() {
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired,
            .otherKeyDown
        ])

        XCTAssertEqual(result.steps[2], [.cancelPending])
        XCTAssertEqual(result.state, .idle)
    }

    // MARK: - Other key during pending (ordinary typing)

    func test_other_key_during_pending_cancels() {
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .otherKeyDown
        ])

        XCTAssertEqual(result.steps[1], [.cancelPending])
        XCTAssertEqual(result.state, .idle)
    }

    // MARK: - Escape during armed → cancel Drop

    func test_escape_during_armed_cancels_drop() {
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired,
            .editableResolved(isEditable: true),
            .escapeKeyDown
        ])

        XCTAssertEqual(result.steps[3], [.cancelDrop])
        XCTAssertEqual(result.state, .idle)
    }

    // MARK: - Release during armed → stop + transcribe

    func test_key_up_during_armed_stops_and_transcribes() {
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired,
            .editableResolved(isEditable: true),
            .spaceKeyUp
        ])

        XCTAssertEqual(result.steps[3], [.stopAndTranscribe])
        XCTAssertEqual(result.state, .idle)
    }

    // MARK: - Duplicate event in armed is idempotent (no re-arm)

    func test_duplicate_space_down_in_armed_is_idempotent() {
        // While armed, the OS keeps delivering key-repeat keyDowns. They must
        // be swallowed at the FSM level (empty action list) and MUST NOT
        // re-arm or re-issue a delete.
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired,
            .editableResolved(isEditable: true),
            .spaceKeyDown(isRepeat: true),
            .spaceKeyDown(isRepeat: true)
        ])

        XCTAssertEqual(result.steps[3], [])
        XCTAssertEqual(result.steps[4], [])
        XCTAssertEqual(result.state, .armed)
        // Exactly one arm across the whole sequence.
        XCTAssertEqual(result.steps.flatMap { $0 }.filter { $0.isArm }.count, 1)
    }

    // MARK: - Idempotence of unexpected / duplicate events

    func test_duplicate_editable_resolved_does_not_rearm() {
        // A second editableResolved after we are already armed is a stale /
        // duplicate signal and must be a no-op (no second arm).
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired,
            .editableResolved(isEditable: true),
            .editableResolved(isEditable: true)
        ])

        XCTAssertEqual(result.steps[3], [])
        XCTAssertEqual(result.state, .armed)
        XCTAssertEqual(result.steps.flatMap { $0 }.filter { $0.isArm }.count, 1)
    }

    func test_threshold_fired_in_idle_is_noop() {
        // A timer that fires after the gesture already resolved (back in
        // idle) must not resurrect anything.
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .spaceKeyUp,
            .thresholdFired
        ])

        XCTAssertEqual(result.steps[2], [])
        XCTAssertEqual(result.state, .idle)
    }

    func test_editable_resolved_in_idle_is_noop() {
        let result = run([.editableResolved(isEditable: true)])

        XCTAssertEqual(result.steps[0], [])
        XCTAssertEqual(result.state, .idle)
    }

    func test_threshold_moves_pending_to_awaiting_decision() {
        let result = run([
            .spaceKeyDown(isRepeat: false),
            .thresholdFired
        ])

        XCTAssertEqual(result.steps[1], [.requestEditableCheck])
        XCTAssertEqual(result.state, .awaitingDecision(leaked: 1))
    }
}

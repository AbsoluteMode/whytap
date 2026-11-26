import AppKit
import XCTest
@testable import Sidekey

/// Costs → "<Feature> · Models used": which row's detail is open as the
/// pointer, keyboard and clicks move. Scenarios follow the owner's report
/// (2026-11-26): the pointer on Agent showed Translation's detail, and the
/// detail blinked when it appeared under the pointer.
final class AIUsageModelsHoverTests: XCTestCase {
    private typealias S = AIUsageModelsHoverState
    private var t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private var state = S()
    private var now: Date!

    override func setUp() { now = t0; state = S() }

    private func send(_ event: S.Event) { state.send(event, now: now) }
    private func wait(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds); send(.tick) }

    private func openFromRest(_ id: String) {
        send(.pointerEnteredRow(id)); wait(S.openDelay)
        XCTAssertEqual(state.open, id)
    }

    func test_resting_on_a_row_opens_that_row_after_the_short_delay() {
        send(.pointerEnteredRow("Agent"))
        XCTAssertNil(state.open, "nothing opens while the pointer is only passing")
        wait(S.openDelay / 2); XCTAssertNil(state.open)
        wait(S.openDelay / 2); XCTAssertEqual(state.open, "Agent")
        XCTAssertTrue(state.highlighted("Agent"))
    }

    func test_sweeping_across_rows_opens_only_the_row_where_the_pointer_stops() {
        for id in ["Agent", "Translation"] {
            send(.pointerEnteredRow(id)); wait(0.05); send(.pointerExitedRow(id))
        }
        send(.pointerEnteredRow("Subtitles"))
        wait(S.openDelay)
        XCTAssertEqual(state.open, "Subtitles")
    }

    /// The reported break: Translation's detail stayed while the pointer was on Agent.
    func test_moving_to_another_row_shows_that_row_never_the_previous_one() {
        openFromRest("Translation")
        // Enter of the new row may arrive before exit of the old one, and vice versa.
        send(.pointerEnteredRow("Agent")); send(.pointerExitedRow("Translation"))
        XCTAssertEqual(state.open, "Agent")
        XCTAssertTrue(state.highlighted("Agent")); XCTAssertFalse(state.highlighted("Translation"))

        send(.pointerExitedRow("Agent")); send(.pointerEnteredRow("Subtitles"))
        XCTAssertEqual(state.open, "Subtitles")
        wait(S.closeGrace * 2)
        XCTAssertEqual(state.open, "Subtitles", "a stale close from the previous row must not fire")
        XCTAssertFalse(state.highlighted("Agent"))
    }

    func test_moving_onto_the_detail_keeps_it_open() {
        openFromRest("Agent")
        send(.pointerExitedRow("Agent"))
        wait(S.closeGrace / 2)
        send(.pointerEnteredDetail)
        wait(S.closeGrace * 3)
        XCTAssertEqual(state.open, "Agent")
        XCTAssertTrue(state.highlighted("Agent"), "the open row keeps its fill while the pointer is on its detail")
    }

    /// The detail may cover neighbouring rows; the pointer there is on the
    /// detail, so the detail does not switch underneath it.
    func test_pointer_on_the_detail_over_another_row_keeps_the_detail() {
        openFromRest("Agent")
        send(.pointerEnteredDetail); send(.pointerExitedRow("Agent"))
        wait(S.closeGrace * 2)
        XCTAssertEqual(state.open, "Agent")
        XCTAssertFalse(state.highlighted("Translation"))
    }

    func test_leaving_the_detail_onto_another_row_shows_that_row() {
        openFromRest("Agent")
        send(.pointerEnteredDetail)
        send(.pointerExitedDetail); send(.pointerEnteredRow("Translation"))
        XCTAssertEqual(state.open, "Translation")
        // Reverse order of the same two events.
        send(.pointerEnteredDetail)
        send(.pointerEnteredRow("Subtitles")); send(.pointerExitedDetail)
        XCTAssertEqual(state.open, "Subtitles")
    }

    func test_leaving_both_row_and_detail_closes_after_the_grace_period() {
        openFromRest("Agent")
        send(.pointerEnteredDetail); send(.pointerExitedRow("Agent"))
        send(.pointerExitedDetail)
        wait(S.closeGrace - 0.05); XCTAssertEqual(state.open, "Agent", "crossing a gap does not close it")
        wait(0.05); XCTAssertNil(state.open)
        XCTAssertFalse(state.highlighted("Agent"))
    }

    func test_returning_within_the_grace_period_keeps_the_same_detail() {
        openFromRest("Agent")
        send(.pointerExitedRow("Agent")); wait(S.closeGrace / 2)
        send(.pointerEnteredRow("Agent")); wait(S.closeGrace * 2)
        XCTAssertEqual(state.open, "Agent")
    }

    func test_click_pins_and_hovering_other_rows_does_not_replace_it() {
        send(.pointerEnteredRow("Agent")); send(.clicked("Agent"))
        XCTAssertEqual(state.open, "Agent"); XCTAssertTrue(state.pinned)
        send(.pointerExitedRow("Agent")); send(.pointerEnteredRow("Translation")); wait(1)
        XCTAssertEqual(state.open, "Agent")
        send(.clicked("Translation"))
        XCTAssertEqual(state.open, "Translation")
    }

    /// The transient popover closes on the mouse-down of the click that
    /// meant to close it; the click must not open it again.
    func test_clicking_the_pinned_row_closes_it_even_after_the_system_dismissed_it() {
        send(.pointerEnteredRow("Agent")); send(.clicked("Agent"))
        send(.dismissedBySystem("Agent")); now = now.addingTimeInterval(0.05); send(.clicked("Agent"))
        XCTAssertNil(state.open)
        // A later click opens it again.
        now = now.addingTimeInterval(1); send(.clicked("Agent"))
        XCTAssertEqual(state.open, "Agent")
        // Keyboard activation without a system dismissal toggles too.
        send(.clicked("Agent")); XCTAssertNil(state.open)
    }

    func test_system_dismissal_of_another_row_does_not_close_the_open_one() {
        openFromRest("Agent")
        send(.pointerEnteredRow("Translation"))
        send(.dismissedBySystem("Agent"))
        XCTAssertEqual(state.open, "Translation")
    }

    func test_keyboard_focus_opens_and_escape_closes() {
        send(.focused("Agent")); XCTAssertEqual(state.open, "Agent")
        send(.unfocused("Agent")); send(.focused("Translation"))
        XCTAssertEqual(state.open, "Translation")
        wait(1); XCTAssertEqual(state.open, "Translation", "focus holds the detail without the pointer")
        send(.escape); XCTAssertNil(state.open)
        send(.unfocused("Translation")); wait(1); XCTAssertNil(state.open)
    }

    func test_disabling_closes_everything() {
        send(.pointerEnteredRow("Agent")); send(.clicked("Agent"))
        send(.disabled)
        XCTAssertEqual(state, S())
    }

    // MARK: - Controller with the real-pointer probe

    /// The flicker: the detail opens beside the name and lands under the
    /// resting pointer. The row then reports exit, while the detail never
    /// reports enter because the pointer did not move into it.
    @MainActor
    func test_detail_appearing_under_the_resting_pointer_stays_open() {
        var clock = t0
        var probe = AIUsageModelsHoverController.PointerProbe(row: "Agent", onDetail: false)
        let controller = AIUsageModelsHoverController(now: { clock }, probe: { probe })
        defer { controller.stop() }
        controller.send(.pointerEnteredRow("Agent"))
        clock = clock.addingTimeInterval(S.openDelay); controller.send(.tick)
        XCTAssertTrue(controller.isPresented("Agent"))

        probe = .init(row: nil, onDetail: true)
        controller.send(.pointerExitedRow("Agent"))
        clock = clock.addingTimeInterval(S.closeGrace)
        controller.checkPointer()
        controller.send(.tick)
        XCTAssertTrue(controller.isPresented("Agent"), "no close → reopen loop")
        XCTAssertFalse(controller.isPresented("Translation"))

        probe = .init(row: "Translation", onDetail: false)
        controller.checkPointer()
        XCTAssertTrue(controller.isPresented("Translation"))
        XCTAssertFalse(controller.isPresented("Agent"))

        probe = .init(row: nil, onDetail: false)
        controller.checkPointer()
        clock = clock.addingTimeInterval(S.closeGrace); controller.send(.tick)
        XCTAssertFalse(controller.isPresented("Translation"))
    }

    @MainActor
    func test_a_period_change_that_removes_the_open_row_closes_it() {
        let controller = AIUsageModelsHoverController(now: { self.t0 }, probe: { .init(row: nil, onDetail: false) })
        defer { controller.stop() }
        controller.send(.clicked("Subtitles"))
        controller.retain(rows: ["Agent", "Translation", "Subtitles"])
        XCTAssertTrue(controller.isPresented("Subtitles"))
        controller.retain(rows: ["Agent"])
        XCTAssertNil(controller.state.open)
    }
}

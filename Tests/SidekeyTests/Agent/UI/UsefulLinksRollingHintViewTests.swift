import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class UsefulLinksRollingHintViewTests: XCTestCase {
    // MARK: - Hint list shape

    func testHintsForSingleLinkCycleInsertAndOpen() {
        // count == 1 — only Insert and Open are registered, so the
        // chip cycles between the two hints. Up/Down hints would
        // confuse the user since there's nothing to move between.
        let hints = UsefulLinksRollingHintView.hints(forItemCount: 1)

        XCTAssertEqual(hints.count, 2)
        XCTAssertEqual(hints[0].label, "Insert")
        // Insert / Open are now bare arrows (no ⌥), so the keycap is the
        // chevron alone.
        XCTAssertEqual(hints[0].contents, [HotkeyGlyph.chevronLeft])
        XCTAssertEqual(hints[1].label, "Open")
        XCTAssertEqual(hints[1].contents, [HotkeyGlyph.chevronRight])
    }

    func testHintsForMultiLinkCycleAllFourActions() {
        // count >= 2 — all four hotkeys register, so the chip cycles
        // Insert → Open → Down → Up. Order matches the hotkey family's
        // natural reading order (left, right, down, up) so the user's
        // mental model stays consistent across surfaces.
        let hints = UsefulLinksRollingHintView.hints(forItemCount: 2)

        XCTAssertEqual(hints.count, 4)
        XCTAssertEqual(hints[0].label, "Insert")
        XCTAssertEqual(hints[1].label, "Open")
        XCTAssertEqual(hints[2].label, "Down")
        // Switch bindings are now bare arrows (no ⌥), so the keycap is the
        // chevron alone.
        XCTAssertEqual(hints[2].contents, [HotkeyGlyph.chevronDown])
        XCTAssertEqual(hints[3].label, "Up")
        XCTAssertEqual(hints[3].contents, [HotkeyGlyph.chevronUp])
    }

    func testHintsReflectConfiguredUsefulLinksNavigationHotkeys() {
        var configuration = HotkeyConfiguration.defaults
        configuration.usefulLinksNextCombo = .optionD
        configuration.usefulLinksPreviousCombo = .optionQ

        let hints = UsefulLinksRollingHintView.hints(forItemCount: 2, configuration: configuration)

        XCTAssertEqual(hints[2].label, "Down")
        XCTAssertEqual(hints[2].contents, [.text(HotkeyGlyph.option), .text("D")])
        XCTAssertEqual(hints[3].label, "Up")
        XCTAssertEqual(hints[3].contents, [.text(HotkeyGlyph.option), .text("Q")])
    }

    func testHintsReflectConfiguredUsefulLinksInsertAndOpenHotkeys() {
        var configuration = HotkeyConfiguration.defaults
        configuration.usefulLinksInsertCombo = .optionD
        configuration.usefulLinksOpenCombo = .optionQ

        let hints = UsefulLinksRollingHintView.hints(forItemCount: 1, configuration: configuration)

        XCTAssertEqual(hints[0].label, "Insert")
        XCTAssertEqual(hints[0].contents, [.text(HotkeyGlyph.option), .text("D")])
        XCTAssertEqual(hints[1].label, "Open")
        XCTAssertEqual(hints[1].contents, [.text(HotkeyGlyph.option), .text("Q")])
    }

    func testHintsOmitOpenWhenSelectedItemHasNoOpen() {
        // A copy item is insert-only — the rolling hint must NOT cycle "Open".
        // Single-item copy: Insert only.
        let single = UsefulLinksRollingHintView.hints(forItemCount: 1, openAvailable: false)
        XCTAssertEqual(single.map(\.label), ["Insert"])

        // Multi-item with a copy selected: Insert + Down + Up, no Open.
        let multi = UsefulLinksRollingHintView.hints(forItemCount: 3, openAvailable: false)
        XCTAssertEqual(multi.map(\.label), ["Insert", "Down", "Up"])
        XCTAssertFalse(multi.contains { $0.label == "Open" })
    }

    func testHintsIncludeOpenWhenSelectedItemSupportsOpen() {
        // Link / path items support open — the Open hint cycles as before.
        let multi = UsefulLinksRollingHintView.hints(forItemCount: 3, openAvailable: true)
        XCTAssertEqual(multi.map(\.label), ["Insert", "Open", "Down", "Up"])
    }

    func testHintsForThreeLinksMatchesTwoLinkSet() {
        // Sanity: the SSE contract caps at 3 links. The hint set is the
        // same as for 2 because the registration policy is binary on
        // `count >= 2`.
        let twoLink = UsefulLinksRollingHintView.hints(forItemCount: 2)
        let threeLink = UsefulLinksRollingHintView.hints(forItemCount: 3)

        XCTAssertEqual(twoLink, threeLink)
    }

    func testHintsForZeroLinksReturnsEmpty() {
        // Empty block — no chip, no hints. Defensive: the rolling
        // view is gated on `selectedLink != nil` in the parent view
        // but the helper still degenerates cleanly so future
        // refactors don't crash on empty input.
        XCTAssertEqual(UsefulLinksRollingHintView.hints(forItemCount: 0), [])
    }

    // MARK: - Cycle interval

    func testCycleIntervalIsThreeSecondsPerHint() {
        // Each hint dwells for 3s. Tested as a separate assertion (not
        // implicit in the phase-math test below) so a future tweak to
        // the constant trips this anchor explicitly.
        XCTAssertEqual(UsefulLinksRollingHintView.cycleIntervalSeconds, 3.0)
    }

    // MARK: - Cycle phase mapping

    func testCyclePhaseMapsTimestampToActiveHintIndex() {
        // The rolling chip uses a TimelineView. Pure phase math —
        // wallclock seconds % (cycleSeconds * count) / cycleSeconds —
        // drives which hint shows on a given frame. Pin the math so
        // a future refactor doesn't accidentally drop a hint or
        // double-show one.
        let count = 4
        let interval = 1.0
        // t=0 → first hint (index 0).
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 0.0, count: count, interval: interval),
            0
        )
        // t=1.0 → second hint (index 1).
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 1.0, count: count, interval: interval),
            1
        )
        // t=3.5 → fourth hint (index 3 — t/interval = 3.5, floor = 3).
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 3.5, count: count, interval: interval),
            3
        )
        // t=4.5 — full cycle elapsed + 0.5, wraps back to index 0.
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 4.5, count: count, interval: interval),
            0
        )
    }

    func testCyclePhaseAtProductionIntervalAdvancesEveryThreeSeconds() {
        // Pin the production interval against the phase math so a
        // future tweak that breaks the contract (e.g. dropping
        // back to 1s) trips here.
        let count = 4
        let interval = UsefulLinksRollingHintView.cycleIntervalSeconds
        // t = 2.99s → still on the first hint.
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 2.99, count: count, interval: interval),
            0
        )
        // t = 3.0s → crosses into the second hint.
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 3.0, count: count, interval: interval),
            1
        )
        // t = 11.99s → still on the fourth hint (last before wrap).
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 11.99, count: count, interval: interval),
            3
        )
        // t = 12.0s → full cycle (3s × 4 hints) elapsed, wraps to 0.
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 12.0, count: count, interval: interval),
            0
        )
    }

    func testCyclePhaseDegeneratesGracefullyForZeroCount() {
        // Empty hint list — degeneracy guard. Returns 0 so the parent
        // view can short-circuit before reading hints[index].
        XCTAssertEqual(
            UsefulLinksRollingHintView.activeHintIndex(at: 1.5, count: 0, interval: 1.0),
            0
        )
    }

    // MARK: - Smoke render

    func testRendersInsideHostingControllerWithoutCrashing() {
        let view = UsefulLinksRollingHintView(itemCount: 3)
        let hosting = NSHostingController(rootView: view)

        XCTAssertNotNil(hosting.view)
    }
}

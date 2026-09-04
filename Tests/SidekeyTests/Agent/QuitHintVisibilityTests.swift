import XCTest
@testable import Sidekey

/// Pins the pure decision function that picks whether the Quit ⌥Q chip
/// in the agent response panel close-button row should render. Pulled
/// out of `AgentResponsePanelContent` as a free-standing resolver so the
/// decision matrix lives behind a unit-testable contract while the View
/// layer reads exactly one branch.
///
/// The chip has three visibility regimes:
///
///   1. Hide Helpers OFF -> visible immediately (matches PR #164 UX).
///   2. Hide Helpers ON, before the 10 s grace window elapses -> hidden
///      so the panel chrome stays minimal on first open.
///   3. Hide Helpers ON, after the grace window elapses -> visible until
///      the panel closes so the user still discovers Option+Q without
///      permanently giving up screen real estate.
final class QuitHintVisibilityTests: XCTestCase {
    func test_helpers_visible_renders_regardless_of_delay() {
        // Hide Helpers OFF: the chip surfaces straight away with no
        // delay involvement - the delay flag is irrelevant in this
        // branch. Both flag values must collapse to the same .visible
        // result so a stale `delayElapsed` from a prior ON->OFF flip
        // never gates rendering.
        XCTAssertEqual(
            QuitHintVisibility.resolve(hideHelpers: false, delayElapsed: false),
            .visible
        )
        XCTAssertEqual(
            QuitHintVisibility.resolve(hideHelpers: false, delayElapsed: true),
            .visible
        )
    }

    func test_helpers_hidden_before_delay_is_hidden() {
        // Hide Helpers ON and the 10 s timer has NOT elapsed yet: the
        // chip stays hidden so the close-button row reads as just the
        // dismiss control during the initial grace window.
        XCTAssertEqual(
            QuitHintVisibility.resolve(hideHelpers: true, delayElapsed: false),
            .hiddenForDelay
        )
    }

    func test_helpers_hidden_after_delay_is_visible() {
        // Hide Helpers ON and the 10 s timer HAS elapsed: the chip
        // fades back in so the user still learns the Option+Q hotkey
        // even though they opted out of inline helpers. Distinct case
        // from .visible so callers can tell which path triggered it
        // (e.g. for transition tagging).
        XCTAssertEqual(
            QuitHintVisibility.resolve(hideHelpers: true, delayElapsed: true),
            .visibleAfterDelay
        )
    }

    func test_should_render_matches_visibility_branches() {
        // The View-facing accessor must collapse the three cases into
        // a single bool: visible / visibleAfterDelay -> render the
        // chip, hiddenForDelay -> drop it from the close-button row.
        XCTAssertTrue(QuitHintVisibility.visible.shouldRender)
        XCTAssertTrue(QuitHintVisibility.visibleAfterDelay.shouldRender)
        XCTAssertFalse(QuitHintVisibility.hiddenForDelay.shouldRender)
    }
}

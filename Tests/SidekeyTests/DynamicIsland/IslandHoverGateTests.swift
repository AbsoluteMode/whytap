import XCTest
@testable import Sidekey

/// Pure-function tests for `IslandHoverGate.mouseExpanded(...)` — the gate
/// that decides whether the Dynamic Island hover drawer is open from the two
/// raw `.onHover` signals (`pillHovering` over the visible compact pill,
/// `panelHovering` over the rendered hover drawer) plus the prior open state.
///
/// ROO-259 (bug B): the drawer used to open on `pillHovering || panelHovering`.
/// While the drawer faded out after a close, its (still-mounted) panel hover
/// tracking area lingered far below the visible pill; moving the cursor back
/// toward the island re-entered that stale band and re-opened the drawer
/// BEFORE the cursor reached the pill — a false trigger. The gate fixes this by
/// requiring the visible pill for the OPEN edge while still honouring either
/// signal to STAY open (so the cursor can travel pill → gap → drawer).
final class IslandHoverGateTests: XCTestCase {

    // MARK: - Open edge requires the visible pill

    /// Closed → the panel-only signal must NOT open the drawer. This is the
    /// stale fade-out band: the cursor is over where the drawer used to be, not
    /// over the pill, so it must stay closed.
    func test_closed_panelHoverAlone_doesNotOpen() {
        XCTAssertFalse(
            IslandHoverGate.mouseExpanded(
                pillHovering: false,
                panelHovering: true,
                wasExpanded: false
            ),
            "A panel-only hover must not re-open a closed drawer (ROO-259 false trigger)."
        )
    }

    /// Closed → the pill signal opens the drawer (the genuine path: the cursor
    /// is over the visible island).
    func test_closed_pillHover_opens() {
        XCTAssertTrue(
            IslandHoverGate.mouseExpanded(
                pillHovering: true,
                panelHovering: false,
                wasExpanded: false
            )
        )
    }

    /// Closed + neither signal → stays closed.
    func test_closed_noHover_staysClosed() {
        XCTAssertFalse(
            IslandHoverGate.mouseExpanded(
                pillHovering: false,
                panelHovering: false,
                wasExpanded: false
            )
        )
    }

    // MARK: - Stay-open edge honours either signal

    /// Open + only the panel is hovered → stays open. This is the cursor having
    /// travelled down into the drawer/tiles; it must not collapse just because
    /// it left the pill.
    func test_open_panelHoverAlone_staysOpen() {
        XCTAssertTrue(
            IslandHoverGate.mouseExpanded(
                pillHovering: false,
                panelHovering: true,
                wasExpanded: true
            ),
            "An open drawer must stay open while the cursor is over the drawer."
        )
    }

    /// Open + cursor still on the pill → stays open.
    func test_open_pillHover_staysOpen() {
        XCTAssertTrue(
            IslandHoverGate.mouseExpanded(
                pillHovering: true,
                panelHovering: false,
                wasExpanded: true
            )
        )
    }

    /// Open + neither signal (cursor left both the pill and the drawer) →
    /// collapses.
    func test_open_noHover_collapses() {
        XCTAssertFalse(
            IslandHoverGate.mouseExpanded(
                pillHovering: false,
                panelHovering: false,
                wasExpanded: true
            )
        )
    }
}

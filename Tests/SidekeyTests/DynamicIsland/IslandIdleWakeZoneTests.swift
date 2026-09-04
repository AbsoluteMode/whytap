import XCTest
@testable import Sidekey

/// Locks the idle WAKE zone (founder feedback 2026-07-06, two rounds): the
/// island window is permanently agent-wide, so waking from anywhere in
/// `window.frame` revealed the island on any top-of-screen mouse sweep; and
/// the pill is NOT window-edge-aligned, so deriving its rect from the window
/// frame put the zone off the pill entirely (hover stopped waking at all).
/// The zone is the pill's authoritative SCREEN rect + padding, nothing else.
final class IslandIdleWakeZoneTests: XCTestCase {
    private let pill = NSRect(x: 700, y: 760, width: 200, height: 40)

    private var zone: NSRect {
        IslandPanelMouseEventPolicy.idleWakeZone(compactFrame: pill, padding: 12)
    }

    func test_zone_is_pill_rect_inflated_by_padding() {
        XCTAssertEqual(zone, NSRect(x: 688, y: 748, width: 224, height: 64))
    }

    func test_cursor_on_or_near_pill_is_inside() {
        XCTAssertTrue(zone.contains(NSPoint(x: 800, y: 780)))   // over the pill
        XCTAssertTrue(zone.contains(NSPoint(x: 695, y: 755)))   // padded edge
    }

    func test_cursor_away_from_pill_is_outside() {
        XCTAssertFalse(zone.contains(NSPoint(x: 300, y: 780)))  // top strip, far left
        XCTAssertFalse(zone.contains(NSPoint(x: 800, y: 600)))  // below, answer zone
    }

    /// Two-display fixture (tester feedback 2026-07-07): the wake zone must
    /// live on the island's SELECTED screen and never overlap the other
    /// display, so mousing on monitor 2 can neither wake nor keep the island
    /// awake. Vertically the zone pokes `padding` above the physical top of
    /// the screen — unreachable by the cursor, so only the horizontal band
    /// and the foreign screen matter.
    func test_zone_stays_on_selected_screen_and_off_the_other_display() {
        let primary = IslandScreenDescriptor(
            uuid: "primary",
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1055),
            safeAreaTopInset: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        let notchedHeight: CGFloat = 982
        let menuBar: CGFloat = 38
        let notched = IslandScreenDescriptor(
            uuid: "notched",
            frame: NSRect(x: 1920, y: 0, width: 1512, height: notchedHeight),
            visibleFrame: NSRect(x: 1920, y: 76, width: 1512, height: notchedHeight - 114),
            safeAreaTopInset: menuBar,
            auxiliaryTopLeftArea: NSRect(
                x: 1920, y: notchedHeight - menuBar, width: 670, height: menuBar
            ),
            auxiliaryTopRightArea: NSRect(
                x: 1920 + 842, y: notchedHeight - menuBar, width: 1512 - 842, height: menuBar
            )
        )

        let selected = IslandScreenResolver.selectDescriptor(
            preferredUUID: nil,
            descriptors: [primary, notched]
        )
        XCTAssertEqual(selected.uuid, "notched")

        let zone = IslandPanelMouseEventPolicy.idleWakeZone(
            compactFrame: IslandFrameLayout.islandFrame(on: selected),
            padding: IslandIdleConfig.wakeZonePadding
        )

        XCTAssertGreaterThanOrEqual(zone.minX, selected.frame.minX)
        XCTAssertLessThanOrEqual(zone.maxX, selected.frame.maxX)
        XCTAssertTrue(zone.intersects(selected.frame))
        XCTAssertFalse(zone.intersects(primary.frame))
    }
}

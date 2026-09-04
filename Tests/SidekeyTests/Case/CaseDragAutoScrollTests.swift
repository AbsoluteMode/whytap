import XCTest
@testable import Sidekey

final class CaseDragAutoScrollTests: XCTestCase {
    func test_top_edge_starts_upward_auto_scroll() {
        let velocity = CaseDragAutoScrollPolicy.velocity(pointerY: 5, viewportHeight: 200)
        XCTAssertLessThan(velocity, 0)
    }

    func test_bottom_edge_starts_downward_auto_scroll() {
        let velocity = CaseDragAutoScrollPolicy.velocity(pointerY: 195, viewportHeight: 200)
        XCTAssertGreaterThan(velocity, 0)
    }

    func test_velocity_increases_closer_to_edge() {
        let nearBottom = CaseDragAutoScrollPolicy.velocity(pointerY: 190, viewportHeight: 200)
        let atBottom = CaseDragAutoScrollPolicy.velocity(pointerY: 199, viewportHeight: 200)
        XCTAssertGreaterThan(abs(atBottom), abs(nearBottom))
    }

    func test_middle_has_zero_velocity() {
        XCTAssertEqual(CaseDragAutoScrollPolicy.velocity(pointerY: 100, viewportHeight: 200), 0)
    }
}

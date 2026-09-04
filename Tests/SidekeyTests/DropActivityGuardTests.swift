import XCTest
@testable import Sidekey

@MainActor
final class DropActivityGuardTests: XCTestCase {
    func testActivityTokenHeldWhileTurnActive() {
        let g = DropActivityGuard()
        XCTAssertFalse(g.isActive)
        g.begin(reason: "drop turn")
        XCTAssertTrue(g.isActive)
        g.end()
        XCTAssertFalse(g.isActive)
    }

    func testBeginIsIdempotent() {
        let g = DropActivityGuard()
        g.begin(reason: "a")
        g.begin(reason: "b")   // no-op, still one token
        XCTAssertTrue(g.isActive)
        g.end()
        XCTAssertFalse(g.isActive)
    }
}

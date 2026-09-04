import XCTest
@testable import Sidekey

final class CLIProviderTypesTests: XCTestCase {
    func testConnectOutcomeEquatable() {
        XCTAssertEqual(ConnectOutcome.notInstalled, .notInstalled)
        XCTAssertNotEqual(ConnectOutcome.notLoggedIn, .billing)
        XCTAssertEqual(CLIProviderID.claude.rawValue, "claude")
    }
}

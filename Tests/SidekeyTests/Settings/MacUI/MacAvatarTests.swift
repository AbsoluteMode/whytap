import XCTest
@testable import Sidekey

final class MacAvatarTests: XCTestCase {
    func test_initials_from_email_local_part() {
        XCTAssertEqual(MacAvatar.initials(from: "maria@example.com"), "MA")
    }

    func test_initials_from_dotted_name() {
        XCTAssertEqual(MacAvatar.initials(from: "alex.karenin@x.io"), "AK")
    }

    func test_initials_fallback_when_empty() {
        XCTAssertEqual(MacAvatar.initials(from: ""), "?")
        XCTAssertEqual(MacAvatar.initials(from: nil), "?")
    }
}

import XCTest
@testable import Sidekey

final class AppCompatibilityTests: XCTestCase {
    func testSupportsReplaceSelectionForVerifiedAppsOnly() {
        let cases: [(bundleID: String?, expected: Bool)] = [
            ("com.tinyspeck.slackmacgap", true),
            ("notion.id", true),
            ("com.linear", true),
            ("com.todesktop.230313mzl4w4u92", true),
            ("com.microsoft.VSCode", true),
            ("com.apple.mail", false),
            ("com.apple.MobileSMS", false),
            ("com.apple.Terminal", false),
            ("com.example.UnknownEditor", false),
            (nil, false)
        ]

        for testCase in cases {
            XCTAssertEqual(
                AppCompatibility.supportsReplaceSelection(bundleID: testCase.bundleID),
                testCase.expected,
                testCase.bundleID ?? "nil"
            )
        }
    }
}

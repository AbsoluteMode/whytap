import XCTest
@testable import Sidekey

final class HotkeyConfigurationGoogleTests: XCTestCase {
    func testDefaultsBindGoogleToRightOption() {
        let d = HotkeyConfiguration.defaults
        XCTAssertEqual(d.googleSearchTextShortcut, .modifier(.rightOption))
        XCTAssertEqual(d.googleSearchVoiceShortcut, .modifier(.rightOption))
        XCTAssertEqual(d.googleSearchVoiceGesture, .hold)
    }

    func testAssignmentsIncludeGoogle() {
        let titles = HotkeyConfiguration.defaults.assignments.map(\.actionTitle)
        XCTAssertTrue(titles.contains("Google text"))
        XCTAssertTrue(titles.contains("Google voice"))
    }

    func testDefaultsHaveNoConflict() {
        // Agent on R-Cmd, Google on R-Option -> distinct physical keys, no conflict.
        let assignments = HotkeyConfiguration.defaults.assignments
        let keys = assignments.map(\.binding.conflictKey)
        XCTAssertEqual(keys.count, Set(keys).count)
    }
}

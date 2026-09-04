import XCTest
@testable import Sidekey

@MainActor
final class NotesNavigationTests: XCTestCase {
    private func source(_ rel: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { break }
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8)
    }

    func test_topbar_exists_with_back_title_tabs() throws {
        let s = try source("Sources/Sidekey/Meetings/NotesTopBar.swift")
        XCTAssertTrue(s.contains("final class NotesTopBar"))
        XCTAssertTrue(s.contains("var onBack"))
        XCTAssertTrue(s.contains("var onSelectTab"))
        XCTAssertTrue(s.contains("func configure"))
    }

    func test_controller_uses_navigation_not_split() throws {
        let s = try source("Sources/Sidekey/Meetings/MeetingsContentController.swift")
        XCTAssertTrue(s.contains("NotesTopBar"))
        XCTAssertTrue(s.contains("func showEditor"))
        XCTAssertTrue(s.contains("func showList"))
        XCTAssertFalse(s.contains("NSSplitViewController"))
    }
}

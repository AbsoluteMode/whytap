import XCTest
@testable import Sidekey

@MainActor
final class MeetingsChromeContractTests: XCTestCase {
    private func source(_ rel: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { break }
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8)
    }

    func test_meeting_list_uses_theme_token_for_selection() throws {
        // The list selection fill comes from the shared Settings theme, not a
        // bespoke colour, so the Notes list stays consistent with every other
        // Settings surface. Styling now lives in the native SwiftUI list.
        let s = try source("Sources/Sidekey/Meetings/MeetingListView.swift")
        XCTAssertTrue(s.contains("MacSettingsTheme.selection"))
    }
}

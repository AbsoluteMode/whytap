import XCTest
@testable import Sidekey

/// Source-grep contract for the macOS-style Settings chrome: wider sidebar and
/// accent-filled selection, matching the mockup. Static copy helpers stay in
/// SettingsWindowViewTests.
@MainActor
final class SettingsWindowChromeTests: XCTestCase {
    func test_sidebar_is_widened_and_accent_selected() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/SettingsWindowView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("width: CGFloat = 220"))
        XCTAssertTrue(s.contains("MacSettingsTheme.accent"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "SettingsWindowChromeTests", code: 1)
    }
}

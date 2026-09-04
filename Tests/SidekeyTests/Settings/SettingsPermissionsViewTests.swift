import XCTest
@testable import Sidekey

@MainActor
final class SettingsPermissionsViewTests: XCTestCase {
    func test_permissions_uses_mac_reskin_components() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/SettingsPermissionsView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("MacCard"))
        XCTAssertTrue(s.contains("MacPill"))
        XCTAssertTrue(s.contains("MacButton"))
        XCTAssertFalse(s.contains("SettingsRowShell"))
        // Screen Recording must never be requested here (guarded elsewhere too).
        XCTAssertFalse(s.contains("title: \"Screen Recording\""))
        XCTAssertFalse(s.contains("requestScreenRecording"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "SettingsPermissionsViewTests", code: 1)
    }
}

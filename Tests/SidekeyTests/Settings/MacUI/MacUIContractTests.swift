import XCTest
@testable import Sidekey

@MainActor
final class MacUIContractTests: XCTestCase {
    private func source(_ rel: String) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { break }
            url.deleteLastPathComponent()
        }
        return try String(contentsOf: url.appendingPathComponent(rel), encoding: .utf8)
    }

    func test_macCard_uses_card_radius_and_card_bg() throws {
        let s = try source("Sources/Sidekey/Settings/MacUI/MacCard.swift")
        XCTAssertTrue(s.contains("MacSettingsTheme.radiusCard"))
        XCTAssertTrue(s.contains("MacSettingsTheme.bgCard"))
        XCTAssertTrue(s.contains("struct MacRow"))
        XCTAssertTrue(s.contains("struct MacGroupTitle"))
    }

    func test_macSwitch_is_ios_style_not_textual() throws {
        let s = try source("Sources/Sidekey/Settings/MacUI/MacSwitch.swift")
        XCTAssertTrue(s.contains("MacSettingsTheme.accent"))      // on-fill = accent
        XCTAssertFalse(s.contains("Text(\"ON\")"))                // no textual ON/OFF
        XCTAssertFalse(s.contains("Toggle("))                      // not the system toggle
    }

    func test_macButton_has_primary_and_danger_styles() throws {
        let s = try source("Sources/Sidekey/Settings/MacUI/MacButton.swift")
        XCTAssertTrue(s.contains("case primary"))
        XCTAssertTrue(s.contains("case danger"))
    }

    func test_macBanner_has_privacy_tone() throws {
        let s = try source("Sources/Sidekey/Settings/MacUI/MacBanner.swift")
        XCTAssertTrue(s.contains("case privacy"))
    }

    func test_macSegmented_uses_seg_tokens() throws {
        let s = try source("Sources/Sidekey/Settings/MacUI/MacSegmented.swift")
        XCTAssertTrue(s.contains("struct MacSegmented"))
        XCTAssertTrue(s.contains("MacSettingsTheme.segBg"))
        XCTAssertTrue(s.contains("MacSettingsTheme.segSel"))
        XCTAssertTrue(s.contains(".contentShape(Rectangle())"))
    }

    func test_macPopup_has_accent_chevron() throws {
        let s = try source("Sources/Sidekey/Settings/MacUI/MacPopup.swift")
        XCTAssertTrue(s.contains("struct MacPopup"))
        XCTAssertTrue(s.contains("MacSettingsTheme.accent"))
        XCTAssertTrue(s.contains("chevron"))
    }

    func test_macField_uses_field_bg_and_supports_secure() throws {
        let s = try source("Sources/Sidekey/Settings/MacUI/MacField.swift")
        XCTAssertTrue(s.contains("struct MacField"))
        XCTAssertTrue(s.contains("MacSettingsTheme.fieldBg"))
        XCTAssertTrue(s.contains("SecureField"))
    }
}

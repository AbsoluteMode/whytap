import XCTest
@testable import Sidekey

@MainActor
final class SettingsWindowTabTests: XCTestCase {
    func test_models_is_the_first_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.first, .models)
    }

    func test_hotkeys_is_the_second_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst().first, .hotkeys)
    }

    func test_permissions_is_the_third_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(2).first, .permissions)
    }

    func test_notes_is_the_fourth_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(3).first, .notes)
    }

    func test_agent_mode_is_the_fifth_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(4).first, .agentMode)
    }

    func test_toolbox_is_the_sixth_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(5).first, .toolbox)
    }

    func test_default_tab_is_models() {
        XCTAssertEqual(SettingsWindowTab.defaultAvailable, .models)
        XCTAssertEqual(SettingsWindowSelection().selectedTab, .models)
    }

    func test_every_tab_is_available() {
        XCTAssertEqual(SettingsWindowTab.availableCases, SettingsWindowTab.allCases)
        for tab in SettingsWindowTab.allCases {
            XCTAssertTrue(tab.isAvailable, "\(tab) must be available")
        }
    }

    func test_no_account_usage_or_integrations_tab() {
        let titles = SettingsWindowTab.allCases.map { $0.title }
        for gone in ["Account", "Usage", "Integrations"] {
            XCTAssertFalse(titles.contains(gone), "\(gone) tab must be gone")
        }
    }

    func test_models_tab_metadata() {
        XCTAssertEqual(SettingsWindowTab.models.title, "Models")
        XCTAssertNil(SettingsWindowTab.models.pdfResourceName)
        XCTAssertEqual(SettingsWindowTab.models.fallbackSystemImageName, "cpu")
    }

    func test_hotkeys_tab_metadata_uses_hover_icon() {
        XCTAssertEqual(SettingsWindowTab.hotkeys.title, "Hotkeys")
        XCTAssertNil(SettingsWindowTab.hotkeys.pdfResourceName)
        XCTAssertEqual(SettingsWindowTab.hotkeys.fallbackSystemImageName, "keyboard")
    }

    func test_notes_tab_metadata_uses_notes_icon() {
        XCTAssertEqual(SettingsWindowTab.notes.title, "Meetings")
        XCTAssertNil(SettingsWindowTab.notes.pdfResourceName)
        XCTAssertEqual(SettingsWindowTab.notes.fallbackSystemImageName, "note.text")
    }

    func test_permissions_tab_metadata_uses_permissions_icon() {
        XCTAssertEqual(SettingsWindowTab.permissions.title, "Permissions")
        XCTAssertNil(SettingsWindowTab.permissions.pdfResourceName)
        XCTAssertEqual(SettingsWindowTab.permissions.fallbackSystemImageName, "checkmark.shield.fill")
    }

    func test_agent_mode_tab_metadata() {
        XCTAssertEqual(SettingsWindowTab.agentMode.title, "Agents")
        XCTAssertNil(SettingsWindowTab.agentMode.pdfResourceName)
        XCTAssertEqual(SettingsWindowTab.agentMode.fallbackSystemImageName, "bolt.horizontal.circle.fill")
    }

    func test_settings_sidebar_icons_are_smaller_than_hover_tiles() {
        XCTAssertLessThan(
            SettingsSidebarIconStyle.tileSize,
            IslandGraphiteHoverControlStyle.tileSize
        )
        XCTAssertLessThan(
            SettingsSidebarIconStyle.cornerRadius,
            IslandGraphiteHoverControlStyle.cornerRadius
        )
    }

    func test_settings_sidebar_leaves_room_for_tab_titles() {
        XCTAssertGreaterThanOrEqual(SettingsSidebarStyle.labelAvailableWidth, 100)
        XCTAssertGreaterThanOrEqual(SettingsSidebarStyle.labelMinimumScaleFactor, 0.85)
    }

    // MARK: - Other tab (Part B)

    func test_other_tab_is_present() {
        XCTAssertTrue(SettingsWindowTab.allCases.contains(.other))
    }

    func test_other_tab_is_last() {
        XCTAssertEqual(SettingsWindowTab.allCases.last, .other)
    }

    func test_other_tab_title_is_Other() {
        XCTAssertEqual(SettingsWindowTab.other.title, "Other")
    }

    func test_other_tab_fallback_image_name() {
        XCTAssertFalse(SettingsWindowTab.other.fallbackSystemImageName.isEmpty)
    }

    func test_other_tab_has_no_pdf_resource() {
        XCTAssertNil(SettingsWindowTab.other.pdfResourceName)
    }

    func test_no_tab_titled_now_playing() {
        let titles = SettingsWindowTab.allCases.map { $0.title }
        XCTAssertFalse(titles.contains("Now Playing"), "music tab must be gone")
    }
}

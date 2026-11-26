import XCTest
@testable import Sidekey

@MainActor
final class SettingsWindowTabTests: XCTestCase {
    func test_features_is_the_first_and_default_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.first, .features)
        XCTAssertEqual(SettingsWindowTab.defaultAvailable, .features)
        XCTAssertEqual(SettingsWindowSelection().selectedTab, .features)
    }

    func test_api_and_models_follows_features() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst().first, .apiAndModels)
    }

    func test_hotkeys_is_the_third_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(2).first, .hotkeys)
    }

    func test_permissions_is_the_fourth_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(3).first, .permissions)
    }

    func test_notes_is_the_fifth_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(4).first, .notes)
    }

    func test_agent_mode_is_the_sixth_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(5).first, .agentMode)
    }

    func test_toolbox_is_the_seventh_settings_tab() {
        XCTAssertEqual(SettingsWindowTab.allCases.dropFirst(6).first, .toolbox)
    }

    func test_every_tab_but_agents_and_notifications_is_selectable() {
        XCTAssertEqual(SettingsWindowTab.availableCases,
                       SettingsWindowTab.allCases.filter { $0 != .agentMode && $0 != .notifications })
        XCTAssertFalse(SettingsWindowTab.agentMode.isAvailable)
        XCTAssertFalse(SettingsWindowTab.notifications.isAvailable)
    }

    /// The Notifications tab repeated Notify's list; it became Notify's screen
    /// in Features. Its link or a What's new button still land there.
    @MainActor
    func test_notifications_tab_opens_the_notify_screen() throws {
        XCTAssertEqual(SettingsWindowTab.notifications.resolved, .features)
        XCTAssertEqual(SettingsWindowTab.notifications.featureScreen, .notify)
        XCTAssertEqual(SettingsWindowTab.notifications.sidebarHome, .features)
        let selection = SettingsWindowSelection(selectedTab: .notifications)
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .notify)
        XCTAssertNil(selection.backLink, "Notify's screen has its own way back to the list")

        let url = try XCTUnwrap(URL(string: "whytap://settings/notifications"))
        guard case .show(.settings(let target)) = WhytapLink.request(for: url) else {
            return XCTFail("An old Notifications link still opens Settings")
        }
        selection.select(.other)
        selection.setHighlight(target)
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .notify)

        // Features in the sidebar is the list again, not Notify.
        selection.select(.features)
        XCTAssertNil(selection.shownFeature)
    }

    /// The Agents tab became the Agent's screen in Features; its link and
    /// setup prompt open that screen.
    @MainActor
    func test_agents_tab_opens_the_agent_screen() {
        XCTAssertEqual(SettingsWindowTab.agentMode.resolved, .features)
        for tab in SettingsWindowTab.availableCases {
            XCTAssertEqual(tab.resolved, tab)
            XCTAssertNil(tab.featureScreen)
        }
        let selection = SettingsWindowSelection(selectedTab: .agentMode)
        XCTAssertEqual(selection.selectedTab, .features)
        selection.select(.hotkeys)
        selection.select(.agentMode)
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .agent)
        selection.select(.hotkeys)
        selection.setHighlight(.tab(.agentMode))
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .agent)
    }

    func test_no_removed_settings_tabs() {
        let titles = SettingsWindowTab.allCases.map { $0.title }
        for gone in ["Account", "Usage", "Projects"] {
            XCTAssertFalse(titles.contains(gone), "\(gone) tab must be gone")
        }
    }

    func test_api_and_models_tab_metadata() {
        XCTAssertEqual(SettingsWindowTab.apiAndModels.title, "Keys & models")
        XCTAssertEqual(SettingsWindowTab.apiAndModels.id, "apiAndModels")
        XCTAssertNil(SettingsWindowTab.apiAndModels.pdfResourceName)
        XCTAssertEqual(SettingsWindowTab.apiAndModels.fallbackSystemImageName, "cpu")
    }

    func test_no_models_tab_left() {
        let titles = SettingsWindowTab.allCases.map { $0.title }
        XCTAssertFalse(titles.contains("Models"), "the Models tab is replaced by Keys & models")
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

    /// Other is gone as a name: what is left is General. The raw id stays
    /// `other` so `whytap://settings/other` keeps working.
    func test_other_tab_is_now_general_with_the_same_id() {
        XCTAssertEqual(SettingsWindowTab.other.title, "General")
        XCTAssertEqual(SettingsWindowTab.other.rawValue, "other")
        XCTAssertFalse(SettingsWindowTab.availableCases.map(\.title).contains("Other"))
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

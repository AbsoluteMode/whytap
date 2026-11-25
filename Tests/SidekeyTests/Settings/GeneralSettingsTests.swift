import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Settings once Other is taken apart: the sidebar says General, the old
/// links still land, and the start list holds every feature.
@MainActor
final class GeneralSettingsTests: XCTestCase {
    func testOldOtherLinkOpensGeneral() throws {
        let url = try XCTUnwrap(URL(string: "whytap://settings/other"))
        XCTAssertEqual(WhytapLink.request(for: url), .show(.settings(.tab(.other))))
        let selection = SettingsWindowSelection(selectedTab: .other)
        XCTAssertEqual(selection.selectedTab, .other)
        XCTAssertEqual(selection.selectedTab.title, "General")
    }

    /// The sidebar of the approved mockup; every other tab keeps its link and
    /// opens from where it belongs, with that row selected.
    func testSidebarIsTheMockupsAndEveryOtherTabHasAHome() {
        XCTAssertEqual(SettingsWindowTab.sidebarCases.map(\.title),
                       ["Features", "Keys & models", "Permissions", "Hotkeys", "General"])
        XCTAssertEqual(SettingsWindowTab.sidebarCases.map(\.rawValue),
                       ["features", "apiAndModels", "permissions", "hotkeys", "other"])
        for tab in SettingsWindowTab.allCases {
            XCTAssertTrue(tab.sidebarHome.isInSidebar, "\(tab) has a sidebar row to stay on")
            XCTAssertEqual(tab.isInSidebar, tab.sidebarHome == tab)
        }
        XCTAssertEqual(SettingsWindowTab.notes.sidebarHome, .features)
        XCTAssertEqual(SettingsWindowTab.toolbox.sidebarHome, .features)
        for tab in [SettingsWindowTab.notifications, .integrations, .backup] {
            XCTAssertEqual(tab.sidebarHome, .other)
        }
    }

    func testTabsThatLeftTheSidebarStillOpenFromLinks() throws {
        for tab in ["notes", "toolbox", "notifications", "integrations", "backup"] {
            let url = try XCTUnwrap(URL(string: "whytap://settings/\(tab)"))
            XCTAssertEqual(WhytapLink.request(for: url), .show(.settings(.tab(try XCTUnwrap(SettingsWindowTab(rawValue: tab))))))
            let selection = SettingsWindowSelection()
            selection.select(try XCTUnwrap(SettingsWindowTab(rawValue: tab)))
            XCTAssertEqual(selection.selectedTab.rawValue, tab, "\(tab) is shown, not swapped for Features")
        }
    }

    func testGeneralLeadsToNotificationsBackupAndIntegrationsAndBack() {
        XCTAssertEqual(SettingsOtherView.moreRows.map(\.tab), [.notifications, .backup, .integrations])
        let selection = SettingsWindowSelection(selectedTab: .other)
        for row in SettingsOtherView.moreRows {
            selection.select(row.tab)
            XCTAssertEqual(selection.selectedTab, row.tab)
            XCTAssertEqual(selection.backLink?.title, "General")
            selection.goBack()
            XCTAssertEqual(selection.selectedTab, .other)
            XCTAssertNil(selection.backLink)
        }
    }

    func testNotesAndToolboxLeadBackToTheirFeatureScreens() {
        let selection = SettingsWindowSelection()
        selection.open(.meetings)
        selection.select(.notes)
        XCTAssertEqual(selection.backLink?.title, "Meeting Notes")
        selection.goBack()
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .meetings)

        selection.select(.toolbox)
        XCTAssertEqual(selection.backLink?.title, "Hover")
        selection.goBack()
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .hover)
        for tab in SettingsWindowTab.sidebarCases {
            selection.select(tab)
            XCTAssertNil(selection.backLink, "\(tab) is in the sidebar: no back line")
        }
    }

    func testRenderTabsOutsideTheSidebarWithTheirBackLine() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let directory = FeaturesFixture.renderDirectory
        for tab in [SettingsWindowTab.notifications, .backup, .integrations] {
            let selection = SettingsWindowSelection(selectedTab: tab)
            try FeaturesFixture.render(fixture.shell(selection: selection),
                                       size: NSSize(width: 960, height: 560), dark: false,
                                       to: directory?.appendingPathComponent("\(tab.rawValue)-from-general.png"))
        }
    }

    func testRenderGeneralAndTheFeaturesList() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let directory = FeaturesFixture.renderDirectory
        for dark in [false, true] {
            for tab in [SettingsWindowTab.other, .features] {
                let selection = SettingsWindowSelection(selectedTab: tab)
                try FeaturesFixture.render(fixture.shell(selection: selection),
                                           size: NSSize(width: 960, height: 560), dark: dark,
                                           to: directory?.appendingPathComponent(
                                               "\(tab == .other ? "general" : "features-list")-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

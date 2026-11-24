import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Translate & Subtitles, Screenshots, To-do and Case: screens of island
/// tools, built from the same template, with the buttons that open them.
@MainActor
final class IslandToolScreensTests: XCTestCase {
    func testIslandToolsSayHowToShowThemAndNeedNoSwitch() {
        for feature in [AppFeature.translateSubtitles, .screenshots, .todo, .caseVault] {
            let info = FeatureCatalog.info(for: feature)
            XCTAssertFalse(info.hasSwitch)
            XCTAssertFalse(info.about.isEmpty)
            XCTAssertEqual(info.hotkeys.count, feature == .translateSubtitles ? 2 : 1)
        }
        XCTAssertEqual(FeatureSwitchCard.subtitle(FeatureCatalog.info(for: .caseVault), isOn: true),
                       "Show or hide it in Toolbox; its shortcut works either way.")
        XCTAssertTrue(FeatureSwitchCard.subtitle(FeatureCatalog.info(for: .translateSubtitles), isOn: true)
            .hasPrefix("Show or hide them"))
        XCTAssertEqual(FeatureHotkey.tool(.tasks).label, "Open To-do")
        XCTAssertEqual(FeatureHotkey.tool(.caseVault).label, "Open Case")
    }

    func testScreensOpenTheirToolsWithoutAWindowOnScreen() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        var opened: [String] = []
        var environment = fixture.environment
        environment.openScreenshot = { opened.append("shot") }
        environment.openHoverPanel = { opened.append("\($0)") }
        let selection = SettingsWindowSelection(selectedTab: .features)
        let context = FeatureScreenContext(snapshot: fixture.snapshot, selection: selection, models: fixture.models,
                                           permissions: fixture.permissions, environment: environment)
        context.environment.openScreenshot()
        context.environment.openHoverPanel(.tasks)
        context.environment.openHoverPanel(.caseVault)
        XCTAssertEqual(opened, ["shot", "tasks", "caseVault"])
    }

    func testRenderIslandToolScreens() async throws {
        let directory = FeaturesFixture.renderDirectory
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        for feature in [AppFeature.translateSubtitles, .screenshots, .todo, .caseVault] {
            for dark in [false, true] {
                let selection = SettingsWindowSelection(selectedTab: .features)
                selection.open(feature)
                try FeaturesFixture.render(fixture.shell(selection: selection),
                                           size: NSSize(width: 960, height: dark ? 560 : 820), dark: dark,
                                           to: directory?.appendingPathComponent(
                                               "\(feature.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

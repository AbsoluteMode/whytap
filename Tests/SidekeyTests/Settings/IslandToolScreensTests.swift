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

    /// Translate & Subtitles shows one clip per tool. The Subtitles clip has
    /// its place before the clip exists: the strip says what it will show.
    func testTranslateAndSubtitlesHaveAPlaceForEachClip() {
        let clips = FeatureCatalog.info(for: .translateSubtitles).clips
        XCTAssertEqual(clips.map(\.name), ["Translate", "Subtitles"])
        XCTAssertTrue(clips.allSatisfy { !$0.caption.isEmpty })
        for feature in AppFeature.allCases where feature != .translateSubtitles {
            XCTAssertEqual(FeatureCatalog.info(for: feature).clips.count, 1, "\(feature)")
            XCTAssertEqual(FeatureCatalog.info(for: feature).clips[0].name, FeatureCatalog.info(for: feature).name)
        }
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

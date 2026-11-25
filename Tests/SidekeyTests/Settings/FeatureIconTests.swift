import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Every feature in Settings → Features has one monochrome icon, the same one
/// its island tool shows, in the list and in its own header.
// WHY: .project-docs/decisions/2026-11-25-feature-icons.md
@MainActor
final class FeatureIconTests: XCTestCase {
    func testAFeatureWithAnIslandToolShowsThatToolsIcon() {
        let expected: [AppFeature: HoverTool] = [
            .translateSubtitles: .translate, .screenshots: .screenshot, .todo: .tasks,
            .caseVault: .caseVault, .notify: .notifs, .monitor: .monitor,
        ]
        for (feature, tool) in expected {
            XCTAssertEqual(feature.islandTool, tool)
            XCTAssertEqual(feature.symbol, HoverToolRegistry.info(for: tool).sfSymbol, "\(feature)")
        }
        XCTAssertEqual(AppFeature.screenshots.symbol, "viewfinder", "Screenshots = Shot's icon")
    }

    func testTheOthersCarryTheirHotkeysIcon() {
        XCTAssertEqual(AppFeature.drop.symbol, "mic")
        XCTAssertEqual(AppFeature.agent.symbol, "sparkles")
        XCTAssertEqual(AppFeature.meetings.symbol, "record.circle")
        XCTAssertEqual(AppFeature.googleSearch.symbol, "magnifyingglass")
        XCTAssertEqual(AppFeature.hover.symbol, "square.grid.2x2")
    }

    func testEveryIconIsARealSymbolAndNoTwoFeaturesShareOne() {
        for feature in AppFeature.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: feature.symbol, accessibilityDescription: nil),
                            "\(feature): \(feature.symbol) exists on macOS 14")
            XCTAssertNotEqual(feature.symbol, "questionmark")
        }
        XCTAssertEqual(Set(AppFeature.allCases.map(\.symbol)).count, AppFeature.allCases.count)
    }

    func testRenderTheListAndAHeaderWithIcons() async throws {
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        let directory = FeaturesFixture.renderDirectory
        for dark in [false, true] {
            let list = SettingsWindowSelection(selectedTab: .features)
            try FeaturesFixture.render(fixture.shell(selection: list), size: NSSize(width: 960, height: 900), dark: dark,
                                       to: directory?.appendingPathComponent("icons-list-\(dark ? "dark" : "light").png"))
            let screen = SettingsWindowSelection(selectedTab: .features)
            screen.open(.screenshots)
            try FeaturesFixture.render(fixture.shell(selection: screen), size: NSSize(width: 960, height: 560), dark: dark,
                                       to: directory?.appendingPathComponent("icons-header-\(dark ? "dark" : "light").png"))
        }
    }
}

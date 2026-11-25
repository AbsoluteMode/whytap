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

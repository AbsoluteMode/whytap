import XCTest

/// Source-string tests for `SettingsOtherView`.
///
/// The codebase norm for SwiftUI views is to assert on the source text rather
/// than instantiating the view (which requires a full AppKit harness). See
/// `OnboardingSkillsScreenTests` for the established pattern.
final class SettingsOtherViewTests: XCTestCase {

    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // Settings/
            .deletingLastPathComponent()     // SidekeyTests/
            .deletingLastPathComponent()     // Tests/
            .deletingLastPathComponent()     // worktree root
            .appendingPathComponent("Sources/Sidekey/Settings/SettingsOtherView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - What is left: the island and privacy

    /// Every feature's switches moved to its screen in Features; General keeps
    /// only what belongs to no feature.
    func test_generalHoldsOnlyTheIslandAndPrivacy() throws {
        let s = try source()
        for title in ["\"Island\"", "\"Privacy\"", "Auto-hide island", "Show island on", "Screenshot protection"] {
            XCTAssertTrue(s.contains(title), title)
        }
        for moved in ["Lower other audio while speaking", "Stop Drop automatically", "MacSwitch(isOn: meetings",
                      "MacSwitch(isOn: google", "agentSection", "MacGroupTitle(title: \"Drop\")",
                      "MacGroupTitle(title: \"Features\")"] {
            XCTAssertFalse(s.contains(moved), "\(moved) belongs to a feature screen now")
        }
    }

    func test_viewStaysPure() throws {
        let s = try source()
        XCTAssertFalse(s.contains("UserPreferencesCache"), "view must not touch the cache directly")
        XCTAssertFalse(s.contains("URLSession"), "view must not touch the network directly")
    }

    func test_islandAutoHideBindsToInjectedPreferences() throws {
        let s = try source()
        XCTAssertTrue(s.contains("islandIdlePreferences"), "binds to the injected IslandIdlePreferences")
        XCTAssertTrue(s.contains("islandAutoHideEnabled"), "uses local mirror state for the binding")
    }

    /// A tab revisit recreates the view: the switches re-read their live values.
    func test_onAppearReReadsLiveState() throws {
        let s = try source()
        let appear = try XCTUnwrap(s.range(of: ".onAppear {"))
        let body = s[appear.lowerBound...]
        XCTAssertTrue(body.contains("islandAutoHideEnabled = islandIdlePreferences.isEnabled"))
        XCTAssertTrue(body.contains("screenshotProtectionEnabled = privacyPreferences.screenshotProtectionEnabled"))
    }
}

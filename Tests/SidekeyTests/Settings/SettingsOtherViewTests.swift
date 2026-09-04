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

    // MARK: - Volume-duck row

    func test_containsVolumeDuckRow() throws {
        let s = try source()
        XCTAssertTrue(
            s.contains("Lower other audio while speaking"),
            "volume-duck row title must be present"
        )
    }

    func test_volumeDuckRowBindsToVolumeDuckConfig() throws {
        let s = try source()
        XCTAssertTrue(s.contains("volumeDuckConfig"), "binds to the injected VolumeDuckConfig")
        XCTAssertTrue(s.contains("volumeDuckEnabled"), "uses local mirror state for the binding")
    }

    // MARK: - Meeting Notes row

    func test_containsMeetingNotesRow() throws {
        let s = try source()
        XCTAssertTrue(
            s.contains("Meeting Notes"),
            "Meeting Notes row title must be present"
        )
    }

    // MARK: - Google search row

    func test_containsGoogleSearchRow() throws {
        let s = try source()
        XCTAssertTrue(
            s.contains("Google search"),
            "Google search row title must be present"
        )
    }

    // MARK: - Island auto-hide row

    func test_containsIslandAutoHideRow() throws {
        let s = try source()
        XCTAssertTrue(
            s.contains("Auto-hide island"),
            "island auto-hide row title must be present"
        )
    }

    /// Like volume-duck: binds to an injected `IslandIdlePreferences` via a local
    /// mirror, not the cache/network.
    func test_islandAutoHideBindsToInjectedPreferences() throws {
        let s = try source()
        XCTAssertTrue(s.contains("islandIdlePreferences"), "binds to the injected IslandIdlePreferences")
        XCTAssertTrue(s.contains("islandAutoHideEnabled"), "uses local mirror state for the binding")
    }

    /// The toggle re-reads its live value on appear so a tab revisit never shows
    /// a stale switch (same regression guard as the other rows).
    func test_onAppearReReadsIslandAutoHide() throws {
        let s = try source()
        guard let appearRange = s.range(of: ".onAppear {") else {
            XCTFail("SettingsOtherView must re-read live state in .onAppear")
            return
        }
        let appearBody = s[appearRange.lowerBound...]
        XCTAssertTrue(
            appearBody.contains("islandAutoHideEnabled = islandIdlePreferences.isEnabled"),
            "onAppear re-reads the island auto-hide flag"
        )
    }

    // MARK: - Capability toggles go through injected closures

    func test_togglesUseInjectedClosuresNotCacheDirectly() throws {
        let s = try source()
        XCTAssertTrue(s.contains("onMeetingsToggle"), "meetings toggle routes through the injected closure")
        XCTAssertTrue(s.contains("onGoogleToggle"), "google toggle routes through the injected closure")
        XCTAssertFalse(
            s.contains("UserPreferencesCache"),
            "view must not touch the cache directly — keep it pure"
        )
        XCTAssertFalse(
            s.contains("URLSession"),
            "view must not touch the network directly"
        )
    }

    // MARK: - Live getter seeds (not static Bools)

    func test_seedsAreLiveGettersNotStaticBools() throws {
        let s = try source()
        XCTAssertTrue(
            s.contains("meetingsEnabled: @escaping () -> Bool"),
            "meetings seed is a live getter closure"
        )
        XCTAssertTrue(
            s.contains("googleEnabled: @escaping () -> Bool"),
            "google seed is a live getter closure"
        )
        // The stale static-seed param names must be gone.
        XCTAssertFalse(s.contains("initialMeetingsEnabled"), "no static meetings seed")
        XCTAssertFalse(s.contains("initialGoogleEnabled"), "no static google seed")
    }

    // MARK: - State mirrors

    func test_localStateForMeetingsAndGoogle() throws {
        let s = try source()
        XCTAssertTrue(s.contains("meetingsEnabled"), "local meetings state mirror")
        XCTAssertTrue(s.contains("googleEnabled"), "local google state mirror")
    }

    // MARK: - Re-read on appear (regression guard)

    /// The original bug: `@State` seeded once from a static Bool went stale on a
    /// tab revisit (SwiftUI recreates the view). The fix re-reads the live
    /// getters in `.onAppear`, exactly as volume-duck already does. Guard that
    /// `.onAppear` refreshes all three mirrors from their live sources.
    func test_onAppearReReadsLiveCapabilityState() throws {
        let s = try source()
        guard let appearRange = s.range(of: ".onAppear {") else {
            XCTFail("SettingsOtherView must re-read live state in .onAppear")
            return
        }
        let appearBody = s[appearRange.lowerBound...]
        XCTAssertTrue(
            appearBody.contains("volumeDuckEnabled = volumeDuckConfig.isEnabled"),
            "onAppear re-reads the volume-duck flag"
        )
        XCTAssertTrue(
            appearBody.contains("meetingsEnabled = meetingsEnabledProvider()"),
            "onAppear re-reads the meetings capability via its live getter"
        )
        XCTAssertTrue(
            appearBody.contains("googleEnabled = googleEnabledProvider()"),
            "onAppear re-reads the google capability via its live getter"
        )
    }
}

import XCTest
@testable import Sidekey

@MainActor
final class DisplayPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.sidekey.display.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - hideHelpers persistence

    func test_hide_helpers_default_false() {
        // Default = false because the helper chips are a discovery
        // affordance — they must be visible to a fresh user.
        let prefs = DisplayPreferences(defaults: defaults)
        XCTAssertFalse(prefs.hideHelpers)
    }

    func test_hide_helpers_persists_true() {
        let prefs = DisplayPreferences(defaults: defaults)
        prefs.hideHelpers = true

        // Recreate the wrapper so the value can't come from in-memory
        // state — it has to round-trip through UserDefaults.
        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.hideHelpers)
    }

    func test_hide_helpers_persists_false_after_toggle() {
        let prefs = DisplayPreferences(defaults: defaults)
        prefs.hideHelpers = true
        prefs.hideHelpers = false

        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.hideHelpers)
    }

    // MARK: - hideIslandHoverWidgets persistence

    func test_hide_island_hover_widgets_default_false() {
        let prefs = DisplayPreferences(defaults: defaults)
        XCTAssertFalse(prefs.hideIslandHoverWidgets)
    }

    func test_hide_island_hover_widgets_persists_true() {
        let prefs = DisplayPreferences(defaults: defaults)
        prefs.hideIslandHoverWidgets = true

        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.hideIslandHoverWidgets)
    }

    func test_hide_island_hover_widgets_persists_false_after_toggle() {
        let prefs = DisplayPreferences(defaults: defaults)
        prefs.hideIslandHoverWidgets = true
        prefs.hideIslandHoverWidgets = false

        let reloaded = DisplayPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.hideIslandHoverWidgets)
    }

    // MARK: - Test isolation

    func test_isolated_suite_does_not_touch_standard_defaults() {
        // Guards the test infrastructure itself: writing through an
        // isolated suite must not leak into `UserDefaults.standard`,
        // otherwise the test would poison the live app preference on
        // any developer machine that runs `swift test`.
        let prefs = DisplayPreferences(defaults: defaults)
        prefs.hideHelpers = true

        let standard = UserDefaults.standard
        // We never wrote to `.standard` — the value should be absent
        // (object(forKey:) returns nil) or false. Use object(forKey:)
        // so a literal `false` write would still flag.
        let raw = standard.object(forKey: "sidekey.preferences.hideHelpers")
        XCTAssertNil(raw, "Isolated suite must not write through to UserDefaults.standard")
        let islandRaw = standard.object(forKey: "sidekey.preferences.hideIslandHoverWidgets")
        XCTAssertNil(islandRaw, "Isolated suite must not write through to UserDefaults.standard")
    }
}

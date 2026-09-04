import XCTest
@testable import Sidekey

@MainActor
final class IslandIdlePreferencesTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "island-idle-prefs-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// Missing key = enabled: the feature shipped always-on, so a fresh install
    /// keeps auto-hide on.
    func test_defaultsToEnabledWhenUnset() {
        let prefs = IslandIdlePreferences(defaults: makeDefaults())
        XCTAssertTrue(prefs.isEnabled)
    }

    /// Explicit `false` persists and reads back.
    func test_persistsDisabled() {
        let defaults = makeDefaults()
        IslandIdlePreferences(defaults: defaults).isEnabled = false
        XCTAssertFalse(IslandIdlePreferences(defaults: defaults).isEnabled)
    }

    /// A real change posts `didChangeNotification` (the host uses it to poke the
    /// live controller).
    func test_changePostsNotification() {
        let center = NotificationCenter()
        let prefs = IslandIdlePreferences(defaults: makeDefaults(), center: center)

        var posts = 0
        let token = center.addObserver(
            forName: IslandIdlePreferences.didChangeNotification,
            object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { center.removeObserver(token) }

        prefs.isEnabled = false
        XCTAssertEqual(posts, 1)
    }

    /// Setting the SAME value is a no-op and posts nothing — no spurious
    /// controller pokes.
    func test_settingSameValuePostsNothing() {
        let center = NotificationCenter()
        // Default is enabled; set it to `true` again.
        let prefs = IslandIdlePreferences(defaults: makeDefaults(), center: center)

        var posts = 0
        let token = center.addObserver(
            forName: IslandIdlePreferences.didChangeNotification,
            object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { center.removeObserver(token) }

        prefs.isEnabled = true
        XCTAssertEqual(posts, 0)
    }
}

import XCTest
@testable import Sidekey

/// Tests for `UserPreferencesCache` — the synchronous local cache of the
/// user's `transcription_mode` preference. The hotkey handler reads this
/// in `onHotkey()` to decide between the streaming WS pipeline and the
/// async HTTP multipart pipeline without doing a network round-trip on
/// every Option+/ press.
///
/// Mirrors the `PrivacyPreferences` test setup: each test uses an
/// isolated `UserDefaults` suite (UUID-namespaced) so concurrent tests
/// don't see each other's writes and so nothing leaks into the user's
/// real `.standard` defaults.
@MainActor
final class UserPreferencesCacheTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.sidekey.preferences.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Default state

    func test_currentMode_defaults_to_fast_when_unset() {
        let cache = UserPreferencesCache(defaults: defaults)

        // Brand-new install: nothing persisted yet. The hotkey handler
        // should route through the low-latency streaming path until the
        // Settings fetch populates the cache with an explicit server value.
        XCTAssertEqual(cache.currentMode, .fast)
    }

    // MARK: - Persistence + round-trip

    func test_setMode_persists_to_userDefaults() {
        let cache = UserPreferencesCache(defaults: defaults)
        cache.setMode(.fast)

        // Recreate the wrapper so we read from disk, not in-memory state.
        let reloaded = UserPreferencesCache(defaults: defaults)
        XCTAssertEqual(reloaded.currentMode, .fast)
    }

    func test_setMode_smart_persists_explicitly() {
        // Storing `.smart` explicitly is a valid "no, really, smart"
        // signal — not just "unset". The cache must round-trip both
        // values so a user who toggles fast→smart sees their choice
        // honoured on next launch.
        let cache = UserPreferencesCache(defaults: defaults)
        cache.setMode(.smart)

        let reloaded = UserPreferencesCache(defaults: defaults)
        XCTAssertEqual(reloaded.currentMode, .smart)
    }

    func test_setMode_overwrites_previous_value() {
        let cache = UserPreferencesCache(defaults: defaults)
        cache.setMode(.fast)
        cache.setMode(.smart)

        let reloaded = UserPreferencesCache(defaults: defaults)
        XCTAssertEqual(reloaded.currentMode, .smart)
    }

    func test_round_trip_fast_smart_fast() {
        let cache = UserPreferencesCache(defaults: defaults)

        cache.setMode(.fast)
        XCTAssertEqual(cache.currentMode, .fast)

        cache.setMode(.smart)
        XCTAssertEqual(cache.currentMode, .smart)

        cache.setMode(.fast)
        XCTAssertEqual(cache.currentMode, .fast)

        // Final state survives across instances.
        let reloaded = UserPreferencesCache(defaults: defaults)
        XCTAssertEqual(reloaded.currentMode, .fast)
    }

    // MARK: - Corrupted state tolerance

    func test_unrecognised_persisted_value_falls_back_to_fast() {
        // A stale value (older client wrote something unexpected, or a
        // user poked defaults manually) must not crash the hotkey
        // handler. Falling back to `.fast` matches the brand-new install
        // default.
        defaults.set("brokenMode", forKey: "sidekey.preferences.transcriptionMode")

        let cache = UserPreferencesCache(defaults: defaults)
        XCTAssertEqual(cache.currentMode, .fast)
    }

    // MARK: - Sync semantics

    func test_setMode_is_visible_synchronously_on_same_instance() {
        // The hotkey handler reads via `currentMode` on the same actor
        // immediately after the Settings window saved — there is no
        // refresh step. A second tap after Settings save must see the
        // new mode without a process restart.
        let cache = UserPreferencesCache(defaults: defaults)
        XCTAssertEqual(cache.currentMode, .fast)

        cache.setMode(.fast)

        XCTAssertEqual(cache.currentMode, .fast)
    }

    // MARK: - Capability flags (default-OFF)

    private func makeCache() -> UserPreferencesCache {
        let suite = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        return UserPreferencesCache(defaults: suite)
    }

    func testFlagsDefaultFalse() {
        let cache = makeCache()
        XCTAssertFalse(cache.currentAgentEnabled)
        XCTAssertFalse(cache.currentMeetingsEnabled)
        XCTAssertFalse(cache.currentGoogleEnabled)
    }

    func testSetThenGet() {
        let cache = makeCache()
        cache.setAgentEnabled(true)
        cache.setGoogleEnabled(true)
        XCTAssertTrue(cache.currentAgentEnabled)
        XCTAssertFalse(cache.currentMeetingsEnabled)
        XCTAssertTrue(cache.currentGoogleEnabled)
    }

    // MARK: - Change notification (E1)

    func testSetAgentEnabledPostsChangeNotificationOnChange() {
        let cache = makeCache()
        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sidekeyCapabilityFlagsChanged, object: nil, queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        cache.setAgentEnabled(true)   // false -> true: posts
        cache.setAgentEnabled(true)   // no change: no post
        XCTAssertEqual(fired, 1)
    }

    func testSetAgentEnabledNoPostOnNoOp() {
        let cache = makeCache()
        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sidekeyCapabilityFlagsChanged, object: nil, queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        cache.setAgentEnabled(false)  // false -> false: no post
        XCTAssertEqual(fired, 0)
    }

    func testSetMeetingsEnabledNoPostOnNoOp() {
        let cache = makeCache()
        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sidekeyCapabilityFlagsChanged, object: nil, queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        cache.setMeetingsEnabled(false)  // false -> false: no post
        XCTAssertEqual(fired, 0)
    }

    func testSetGoogleEnabledNoPostOnNoOp() {
        let cache = makeCache()
        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sidekeyCapabilityFlagsChanged, object: nil, queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        cache.setGoogleEnabled(false)  // false -> false: no post
        XCTAssertEqual(fired, 0)
    }

    func testSetMeetingsEnabledPostsChangeNotificationOnChange() {
        let cache = makeCache()
        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sidekeyCapabilityFlagsChanged, object: nil, queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        cache.setMeetingsEnabled(true)   // false -> true: posts
        cache.setMeetingsEnabled(true)   // no change: no post
        XCTAssertEqual(fired, 1)
    }

    func testSetGoogleEnabledPostsChangeNotificationOnChange() {
        let cache = makeCache()
        var fired = 0
        let token = NotificationCenter.default.addObserver(
            forName: .sidekeyCapabilityFlagsChanged, object: nil, queue: nil
        ) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        cache.setGoogleEnabled(true)   // false -> true: posts
        cache.setGoogleEnabled(true)   // no change: no post
        XCTAssertEqual(fired, 1)
    }
}

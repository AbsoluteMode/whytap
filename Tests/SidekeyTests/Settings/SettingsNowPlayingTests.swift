import AppKit
import XCTest
@testable import Sidekey

/// Tests for `NowPlayingConfig`, `VolumeDuckConfig` persistence, and the
/// always-on coordinator contract.
///
/// The Settings "Now Playing" tab no longer exists (replaced by the always-on
/// model), so tests that referenced `SettingsNowPlayingView` or the `.music`
/// tab have been removed. The `NowPlayingCoordinator` is now always-on:
/// `start()` begins polling regardless of `NowPlayingConfig.isEnabled`.
@MainActor
final class SettingsNowPlayingTests: XCTestCase {

    override func tearDown() {
        AppState.shared.clearNowPlaying()
        super.tearDown()
    }

    // MARK: - Fakes

    /// Controllable source mirroring `NowPlayingControllerTests.FakeSource`:
    /// returns whatever snapshot the test sets, no AppleScript.
    private final class FakeSource: NowPlayingSource {
        var nextSnapshot: NowPlayingSnapshot?
        func currentSnapshot() -> NowPlayingSnapshot? { nextSnapshot }
        func previous() {}
        func playPause(isPlaying: Bool) {}
        func next() {}
    }

    private func makeSnapshot(title: String = "Song") -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            app: .music,
            title: title,
            artist: "Artist",
            album: "Album",
            artwork: nil,
            elapsed: 10,
            duration: 200,
            isPlaying: true,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Toggle persistence

    func test_toggle_persistsToUserDefaults() {
        let suiteName = "test.nowplaying.toggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default (unset) reads true.
        let config = NowPlayingConfig(defaults: defaults)
        XCTAssertTrue(config.isEnabled, "unset flag should default to on")

        // Writing false persists and reads back false from a fresh instance
        // reading the same suite.
        config.isEnabled = false
        XCTAssertFalse(config.isEnabled)
        let reread = NowPlayingConfig(defaults: defaults)
        XCTAssertFalse(reread.isEnabled, "stored false must survive a re-read")

        // Toggling back on persists too.
        config.isEnabled = true
        XCTAssertTrue(NowPlayingConfig(defaults: defaults).isEnabled)
    }

    // MARK: - Always-on coordinator

    /// `start()` must begin polling EVEN WHEN `NowPlayingConfig.isEnabled == false`.
    /// Now Playing is always-on — the `isEnabled` flag is vestigial.
    func test_start_pollsEvenWhenConfigIsDisabled() async {
        let suiteName = "test.nowplaying.alwayson.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = NowPlayingConfig(defaults: defaults)
        config.isEnabled = false   // disable the flag …
        XCTAssertFalse(config.isEnabled)

        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(title: "AlwaysOn")
        let controller = NowPlayingController(source: source, clearDebounceTicks: 2)
        let coordinator = NowPlayingCoordinator(config: config, controller: controller)

        // … yet start() must still poll.
        coordinator.start()
        await controller.pollOnceForTesting()
        XCTAssertEqual(
            AppState.shared.nowPlaying?.title,
            "AlwaysOn",
            "coordinator must poll regardless of NowPlayingConfig.isEnabled (always-on)"
        )
    }

    // MARK: - setEnabled live-toggle still works

    func test_setEnabled_false_clearsSnapshotAndStopsPolling() async {
        let suiteName = "test.nowplaying.gating.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = NowPlayingConfig(defaults: defaults)
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(title: "Live")
        let controller = NowPlayingController(source: source, clearDebounceTicks: 2)
        let coordinator = NowPlayingCoordinator(config: config, controller: controller)

        coordinator.start()
        await controller.pollOnceForTesting()
        XCTAssertEqual(AppState.shared.nowPlaying?.title, "Live")

        // `setEnabled(false)` is still wired — it persists the flag, clears the
        // snapshot, and stops polling (used by the coordinator's own stop/start API).
        coordinator.setEnabled(false)
        XCTAssertFalse(config.isEnabled, "setEnabled(false) must persist the flag")
        XCTAssertNil(
            AppState.shared.nowPlaying,
            "disabling must clear the published snapshot immediately"
        )

        source.nextSnapshot = makeSnapshot(title: "Should not publish")
        await controller.pollOnceForTesting()
        XCTAssertNil(
            AppState.shared.nowPlaying,
            "polling must be stopped after setEnabled(false)"
        )

        // Re-enable: polling resumes.
        coordinator.setEnabled(true)
        XCTAssertTrue(config.isEnabled, "setEnabled(true) must persist the flag")
        source.nextSnapshot = makeSnapshot(title: "Back")
        await controller.pollOnceForTesting()
        XCTAssertEqual(
            AppState.shared.nowPlaying?.title,
            "Back",
            "re-enabling must resume polling and publishing"
        )
    }

    // MARK: - Volume-duck toggle persistence

    func test_volumeDuckToggle_persistsToUserDefaults() {
        let suiteName = "test.volumeduck.toggle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default (unset) reads true.
        let config = VolumeDuckConfig(defaults: defaults)
        XCTAssertTrue(config.isEnabled, "unset volume-duck flag should default to on")

        // Writing false persists and reads back false from a fresh instance
        // reading the same suite.
        config.isEnabled = false
        XCTAssertFalse(config.isEnabled)
        let reread = VolumeDuckConfig(defaults: defaults)
        XCTAssertFalse(reread.isEnabled, "stored false must survive a re-read")

        // Toggling back on persists too.
        config.isEnabled = true
        XCTAssertTrue(VolumeDuckConfig(defaults: defaults).isEnabled)
    }
}

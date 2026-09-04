import Foundation
import os.log

/// Wiring shell for the Now Playing feature. Owned strongly by
/// `AppDelegate` and mirrored weakly on `AppState.nowPlayingCoordinator`
/// so UI surfaces (Stage 3 transport buttons) can reach the controller
/// without going back through the app delegate.
///
/// Mirrors `MeetingsCoordinator`: `start()` reads `NowPlayingConfig
/// .isEnabled`; when off it is a logged no-op (no polling, nothing
/// published); when on it starts the controller's polling loop.
@MainActor
final class NowPlayingCoordinator {
    private static let log = OSLog(subsystem: "com.sidekey.nowplaying", category: "coordinator")

    private let config: NowPlayingConfig
    private let controller: NowPlayingController
    private var started = false

    init(config: NowPlayingConfig, controller: NowPlayingController) {
        self.config = config
        self.controller = controller
    }

    /// Forward transport so the Stage 3 strip can drive the active player
    /// through the coordinator handle on `AppState`.
    func previous() { controller.previous() }
    func playPause() { controller.playPause() }
    func next() { controller.next() }

    /// Begin polling. Idempotent — re-entrancy is guarded by `started`.
    /// Now Playing is always-on; `NowPlayingConfig.isEnabled` is vestigial
    /// and no longer gates this path.
    /// WHY: docs/decisions/2026-06-29-settings-other-tab-nowplaying-always-on.md
    func start() {
        guard !started else { return }
        started = true
        os_log("nowplaying coordinator start", log: Self.log, type: .info)
        controller.start()
    }

    /// Stop polling and clear any published snapshot. Stage 4 calls this
    /// when the user toggles the feature off.
    func stop() {
        started = false
        controller.stop()
    }

    /// Apply a live feature-flag change from the Settings toggle. Persists the
    /// new value to `NowPlayingConfig` (so it survives relaunch) AND reacts
    /// immediately: disabling stops polling and clears the snapshot so every
    /// music surface vanishes at once; enabling resumes polling. Without this,
    /// the toggle would only take effect on the next launch (where `start()`
    /// re-reads the flag).
    func setEnabled(_ enabled: Bool) {
        config.isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }
}

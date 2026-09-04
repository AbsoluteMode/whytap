import AppKit
import XCTest
@testable import Sidekey

/// Stage 1 tests for `NowPlayingController` (and the flag-gated
/// `NowPlayingCoordinator`) — the polling host that maps a
/// `NowPlayingSource` into `AppState.nowPlaying` with a debounced clear.
///
/// AppleScript is kept out of this path: tests inject a fake
/// `NowPlayingSource` and a manual tick driver so polling is
/// deterministic (no wall-clock waits).
///
/// Pinned by the plan's Stage 1 validation gate:
/// - `test_controller_publishesSnapshot_fromFakeSource`
/// - `test_controller_clearsAfterDebounce_whenSourceEmpty`
/// - `test_flagOff_coordinatorDoesNotPoll`
@MainActor
final class NowPlayingControllerTests: XCTestCase {

    override func tearDown() {
        AppState.shared.clearNowPlaying()
        super.tearDown()
    }

    // MARK: - Fakes

    /// Controllable source: returns whatever snapshot the test sets, and
    /// records transport calls so transport-forwarding can be asserted.
    final class FakeSource: NowPlayingSource {
        var nextSnapshot: NowPlayingSnapshot?
        private(set) var previousCalls = 0
        private(set) var playPauseCalls = 0
        /// `isPlaying` argument captured on the most recent `playPause` call.
        private(set) var lastPlayPauseIsPlaying: Bool?
        private(set) var nextCalls = 0

        func currentSnapshot() -> NowPlayingSnapshot? { nextSnapshot }
        func previous() { previousCalls += 1 }
        func playPause(isPlaying: Bool) {
            playPauseCalls += 1
            lastPlayPauseIsPlaying = isPlaying
        }
        func next() { nextCalls += 1 }
    }

    /// Deterministic stand-in for the controller's catch-up scheduler. Records
    /// every scheduled (delay, block) so tests can fire them on demand instead
    /// of waiting on a RunLoop. Tracks live (uncancelled, unfired) work so a
    /// test can assert the controller never stacks catch-up timers.
    @MainActor
    final class FakeScheduler: NowPlayingCatchUpScheduling {
        struct Pending {
            let delay: TimeInterval
            let block: () -> Void
            let token: Int
        }

        private(set) var scheduled: [Pending] = []
        private var cancelledTokens: Set<Int> = []
        private var firedTokens: Set<Int> = []
        private var nextToken = 0

        /// Count of work items that are still scheduled (not cancelled, not
        /// fired) — i.e. timers currently "alive".
        var liveCount: Int {
            scheduled.filter {
                !cancelledTokens.contains($0.token) && !firedTokens.contains($0.token)
            }.count
        }

        func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> NowPlayingCancellable {
            let token = nextToken
            nextToken += 1
            scheduled.append(Pending(delay: delay, block: block, token: token))
            return NowPlayingCancellable { [weak self] in
                self?.cancelledTokens.insert(token)
            }
        }

        /// Fire every still-live scheduled block, in scheduling order.
        func fireAllLive() {
            for pending in scheduled
            where !cancelledTokens.contains(pending.token) && !firedTokens.contains(pending.token) {
                firedTokens.insert(pending.token)
                pending.block()
            }
        }
    }

    private func makeSnapshot(
        app: NowPlayingApp = .music,
        title: String = "Song",
        isPlaying: Bool = true
    ) -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            app: app,
            title: title,
            artist: "Artist",
            album: "Album",
            artwork: nil,
            elapsed: 10,
            duration: 200,
            isPlaying: isPlaying,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - Tests

    func test_controller_publishesSnapshot_fromFakeSource() async {
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(title: "Karma Police")
        let controller = NowPlayingController(source: source, clearDebounceTicks: 2)

        XCTAssertNil(AppState.shared.nowPlaying)

        await controller.pollOnceForTesting(forceRunning: true)

        XCTAssertEqual(AppState.shared.nowPlaying?.title, "Karma Police")
        XCTAssertEqual(AppState.shared.nowPlaying?.app, .music)
        XCTAssertEqual(AppState.shared.nowPlaying?.isPlaying, true)
    }

    func test_controller_clearsAfterDebounce_whenSourceEmpty() async {
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot()
        // Clear only after the source has been empty for 2 consecutive polls.
        let controller = NowPlayingController(source: source, clearDebounceTicks: 2)

        await controller.pollOnceForTesting(forceRunning: true)
        XCTAssertNotNil(AppState.shared.nowPlaying)

        // Source goes empty. First empty poll must NOT clear (debounce) —
        // this avoids flicker when a player briefly returns nothing.
        source.nextSnapshot = nil
        await controller.pollOnceForTesting()
        XCTAssertNotNil(
            AppState.shared.nowPlaying,
            "snapshot should survive the first empty poll (debounce)"
        )

        // Second consecutive empty poll crosses the debounce → clear.
        await controller.pollOnceForTesting()
        XCTAssertNil(
            AppState.shared.nowPlaying,
            "snapshot should clear after the debounce window of empty polls"
        )
    }

    func test_controller_emptyStreakResets_onSnapshotReturn() async {
        // A single empty poll must not "bank" toward a later clear: if the
        // source returns a snapshot again, the empty streak resets.
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot()
        let controller = NowPlayingController(source: source, clearDebounceTicks: 2)

        await controller.pollOnceForTesting(forceRunning: true)
        source.nextSnapshot = nil
        await controller.pollOnceForTesting() // empty #1 (no clear yet)
        source.nextSnapshot = makeSnapshot(title: "Back") // recovers
        await controller.pollOnceForTesting()
        XCTAssertEqual(AppState.shared.nowPlaying?.title, "Back")

        source.nextSnapshot = nil
        await controller.pollOnceForTesting() // empty #1 again (streak reset)
        XCTAssertNotNil(AppState.shared.nowPlaying)
    }

    func test_controller_transportForwardsToSource() {
        let source = FakeSource()
        let controller = NowPlayingController(source: source, clearDebounceTicks: 2)

        controller.previous()
        controller.playPause()
        controller.next()

        XCTAssertEqual(source.previousCalls, 1)
        XCTAssertEqual(source.playPauseCalls, 1)
        XCTAssertEqual(source.nextCalls, 1)
    }

    // MARK: - Optimistic transport (latency fix)

    func test_playPause_optimisticallyFlipsIsPlaying_beforeNextPoll() async {
        // Publish a "playing" snapshot, then call playPause. The UI state on
        // AppState must flip to paused IMMEDIATELY — before any poll reads the
        // source again — so the wing/strip icon + waveform switch on click.
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(title: "Idioteque", isPlaying: true)
        let scheduler = FakeScheduler()
        let controller = NowPlayingController(
            source: source, clearDebounceTicks: 2, scheduler: scheduler
        )

        await controller.pollOnceForTesting(forceRunning: true)
        XCTAssertEqual(AppState.shared.nowPlaying?.isPlaying, true)

        // The source's cache still says "playing" (the real player hasn't
        // been re-read). Optimism must not depend on the source updating.
        controller.playPause()

        XCTAssertEqual(
            AppState.shared.nowPlaying?.isPlaying, false,
            "playPause must optimistically flip isPlaying on AppState before the next poll"
        )
        // Same track, only the play-state changed.
        XCTAssertEqual(AppState.shared.nowPlaying?.title, "Idioteque")
        // The source still gets the command, with the PRE-flip state so it
        // picks discrete pause (was playing).
        XCTAssertEqual(source.playPauseCalls, 1)
        XCTAssertEqual(source.lastPlayPauseIsPlaying, true)
    }

    func test_playPause_optimisticFlip_drivesNextDiscretePlayCommand() async {
        // After an optimistic pause, a second playPause must send the discrete
        // PLAY command — proving lastIsPlaying was updated by the optimistic
        // flip, not left stale at the polled value.
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(isPlaying: true)
        let scheduler = FakeScheduler()
        let controller = NowPlayingController(
            source: source, clearDebounceTicks: 2, scheduler: scheduler
        )

        await controller.pollOnceForTesting(forceRunning: true)
        controller.playPause() // playing → optimistic pause; sends pause
        XCTAssertEqual(source.lastPlayPauseIsPlaying, true)

        controller.playPause() // optimistic state is now paused → sends play
        XCTAssertEqual(
            source.lastPlayPauseIsPlaying, false,
            "second playPause must send PLAY: optimistic flip updates lastIsPlaying"
        )
        XCTAssertEqual(AppState.shared.nowPlaying?.isPlaying, true)
    }

    func test_playPause_withoutCurrentSnapshot_justSends() async {
        // No track on screen → nothing to flip optimistically; the command
        // still forwards and nothing is published.
        let source = FakeSource()
        let scheduler = FakeScheduler()
        let controller = NowPlayingController(
            source: source, clearDebounceTicks: 2, scheduler: scheduler
        )

        controller.playPause()

        XCTAssertNil(AppState.shared.nowPlaying)
        XCTAssertEqual(source.playPauseCalls, 1)
    }

    func test_transportCommands_scheduleQuickCatchUpPolls() async {
        // Each transport command schedules a couple of fast confirm-polls so
        // the REAL state (new track for prev/next, confirmed play-state) lands
        // within a few hundred ms instead of up to a full active interval.
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(title: "First", isPlaying: true)
        let scheduler = FakeScheduler()
        let controller = NowPlayingController(
            source: source, clearDebounceTicks: 2, scheduler: scheduler
        )
        await controller.pollOnceForTesting(forceRunning: true)

        controller.next()
        XCTAssertGreaterThanOrEqual(
            scheduler.scheduled.count, 2,
            "a transport command must schedule at least two quick catch-up polls"
        )
        // The catch-up delays are short (sub-second), not a full active poll.
        for pending in scheduler.scheduled {
            XCTAssertLessThan(pending.delay, NowPlayingController.activeIntervalSeconds)
            XCTAssertGreaterThan(pending.delay, 0)
        }

        // When the catch-up fires, the now-current track from the source is
        // published — no waiting on the normal cadence.
        source.nextSnapshot = makeSnapshot(title: "Second", isPlaying: true)
        scheduler.fireAllLive()
        XCTAssertEqual(AppState.shared.nowPlaying?.title, "Second")
    }

    func test_catchUpPolls_doNotStackAcrossRapidCommands() async {
        // Rapid clicks must cancel the previous catch-up batch before
        // scheduling the next, so timers never accumulate / leak.
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(isPlaying: true)
        let scheduler = FakeScheduler()
        let controller = NowPlayingController(
            source: source, clearDebounceTicks: 2, scheduler: scheduler
        )
        await controller.pollOnceForTesting(forceRunning: true)

        controller.next()
        let liveAfterFirst = scheduler.liveCount
        XCTAssertGreaterThanOrEqual(liveAfterFirst, 2)

        controller.next()
        controller.next()

        XCTAssertEqual(
            scheduler.liveCount, liveAfterFirst,
            "rapid commands must cancel the prior catch-up batch — live timers must not stack"
        )
    }

    func test_stop_cancelsPendingCatchUpPolls() async {
        // Tearing the controller down must cancel any in-flight catch-up so a
        // late poll can't publish after stop() cleared the snapshot.
        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(isPlaying: true)
        let scheduler = FakeScheduler()
        let controller = NowPlayingController(
            source: source, clearDebounceTicks: 2, scheduler: scheduler
        )
        await controller.pollOnceForTesting(forceRunning: true)

        controller.next()
        XCTAssertGreaterThan(scheduler.liveCount, 0)

        controller.stop()
        XCTAssertEqual(
            scheduler.liveCount, 0,
            "stop() must cancel pending catch-up polls"
        )

        // A late fire (already-cancelled) publishes nothing.
        source.nextSnapshot = makeSnapshot(title: "Late", isPlaying: true)
        scheduler.fireAllLive()
        XCTAssertNil(AppState.shared.nowPlaying)
    }

    /// Now Playing is always-on: `start()` polls regardless of
    /// `NowPlayingConfig.isEnabled`. This replaces the old "flag off → no poll"
    /// test which applied when the coordinator was gated by the flag.
    func test_flagOff_coordinatorStillPolls() async {
        let suiteName = "test.nowplaying.flagoff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = NowPlayingConfig(defaults: defaults)
        config.isEnabled = false
        XCTAssertFalse(config.isEnabled)

        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(title: "AlwaysOn")
        let controller = NowPlayingController(source: source, clearDebounceTicks: 2)
        let coordinator = NowPlayingCoordinator(config: config, controller: controller)

        coordinator.start()
        await controller.pollOnceForTesting()

        XCTAssertEqual(
            AppState.shared.nowPlaying?.title,
            "AlwaysOn",
            "coordinator must poll even when NowPlayingConfig.isEnabled == false (always-on)"
        )
    }

    func test_flagOn_coordinatorPolls() async {
        let suiteName = "test.nowplaying.flagon.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = NowPlayingConfig(defaults: defaults)
        // default-on: a fresh suite with no stored value should be enabled.
        XCTAssertTrue(config.isEnabled)

        let source = FakeSource()
        source.nextSnapshot = makeSnapshot(title: "Live")
        let controller = NowPlayingController(source: source, clearDebounceTicks: 2)
        let coordinator = NowPlayingCoordinator(config: config, controller: controller)

        coordinator.start()
        await controller.pollOnceForTesting()

        XCTAssertEqual(AppState.shared.nowPlaying?.title, "Live")
    }
}

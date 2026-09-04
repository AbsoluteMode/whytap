import AppKit
import Combine
import Foundation
import os.log

/// Cancellable handle for a scheduled catch-up poll. Wraps a single
/// cancel closure so the controller can drop an in-flight poll without
/// caring whether the backing primitive is a `DispatchWorkItem` or a test
/// double.
struct NowPlayingCancellable {
    private let onCancel: () -> Void
    init(_ onCancel: @escaping () -> Void) { self.onCancel = onCancel }
    func cancel() { onCancel() }
}

/// Seam for the short confirm-polls fired after a transport command. The
/// production scheduler hops to the main queue after a delay; tests inject
/// a deterministic double so catch-up behaviour is exercised without
/// RunLoop waits. `block` is invoked on the main queue/actor by every
/// conformer — the controller relies on that to touch its main-actor state.
protocol NowPlayingCatchUpScheduling {
    /// Run `block` after `delay`. The returned handle cancels the pending
    /// run if it hasn't fired yet.
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> NowPlayingCancellable
}

/// Default scheduler: `DispatchQueue.main.asyncAfter`, cancel-safe via a
/// `DispatchWorkItem`.
struct MainQueueCatchUpScheduler: NowPlayingCatchUpScheduling {
    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) -> NowPlayingCancellable {
        let item = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return NowPlayingCancellable { item.cancel() }
    }
}

/// MainActor host for the Now Playing polling loop. Mirrors
/// `MeetingPillController`'s shape: an `ObservableObject` that owns the
/// timing, maps a `NowPlayingSource` into `AppState.nowPlaying`, and
/// exposes the transport methods the Stage 3 strip buttons call.
///
/// Polling is pause-aware: it ticks ~`activeIntervalSeconds` while a
/// player is active and idles to `idleIntervalSeconds` when nothing is.
/// The actual `NowPlayingSource.currentSnapshot()` does its scripting off
/// the main thread (see `AppleScriptNowPlayingSource`), so the timer body
/// here never blocks the main thread on AppleScript.
///
/// A debounced clear (`clearDebounceTicks` consecutive empty polls) avoids
/// flicker when a player briefly returns nothing between tracks.
@MainActor
final class NowPlayingController: ObservableObject {

    #if DEBUG
    /// DEBUG-only log surface. Track metadata is NEVER written to prod
    /// `os_log` (invariant #3 extension) — this whole logging path is
    /// compiled out of release builds.
    private static let log = OSLog(subsystem: "com.sidekey.nowplaying", category: "controller")
    #endif

    /// Poll cadence while a track is active. Spec: ~1 s.
    static let activeIntervalSeconds: TimeInterval = 1.0
    /// Slower cadence while nothing is active, to avoid pointless scripting.
    static let idleIntervalSeconds: TimeInterval = 3.0
    /// Consecutive empty polls before the snapshot is cleared (debounce).
    static let defaultClearDebounceTicks = 2

    /// Short delays at which a transport command fires confirm-polls so the
    /// REAL state (new track for prev/next, the player's actual play-state)
    /// is reflected within a few hundred ms instead of up to a full
    /// `activeIntervalSeconds`. The optimistic flip handles the instant
    /// play/pause feel; these reconcile with the player's truth.
    static let catchUpDelaysSeconds: [TimeInterval] = [0.25, 0.6]

    private let source: NowPlayingSource
    private let clearDebounceTicks: Int
    private let scheduler: NowPlayingCatchUpScheduling

    /// Live catch-up handles, kept so a fresh transport command can cancel
    /// the prior batch (no stacking) and `stop()` can drop them all.
    private var catchUpHandles: [NowPlayingCancellable] = []

    /// Count of consecutive polls that returned `nil`. Reset whenever a
    /// snapshot is published. Clears once it reaches `clearDebounceTicks`.
    private var emptyStreak = 0

    /// Last snapshot known to the player's transport-state, used so
    /// `playPause()` can choose discrete play vs pause.
    private var lastIsPlaying = false

    private var pollTimer: Timer?
    private var running = false

    init(
        source: NowPlayingSource,
        clearDebounceTicks: Int = NowPlayingController.defaultClearDebounceTicks,
        scheduler: NowPlayingCatchUpScheduling = MainQueueCatchUpScheduler()
    ) {
        self.source = source
        self.clearDebounceTicks = max(1, clearDebounceTicks)
        self.scheduler = scheduler
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Begin polling. Idempotent. The coordinator gates this behind the
    /// feature flag, so the controller itself does not read config.
    func start() {
        guard !running else { return }
        running = true
        scheduleTimer(interval: Self.idleIntervalSeconds)
    }

    /// Stop polling and clear any published snapshot. Used when the flag is
    /// turned off (Stage 4) or on teardown.
    func stop() {
        running = false
        pollTimer?.invalidate()
        pollTimer = nil
        emptyStreak = 0
        cancelCatchUp()
        AppState.shared.clearNowPlaying()
    }

    // MARK: - Transport (forwarded to the active player)

    func previous() {
        source.previous()
        scheduleCatchUp()
    }

    func playPause() {
        // Optimistic flip: switch the published play-state BEFORE the source
        // confirms, so the wing/strip icon + sleep/active waveform respond on
        // click instead of after the next ~1 s poll. Built from the current
        // snapshot with `isPlaying` inverted; `lastIsPlaying` is updated in
        // lockstep so a rapid second tap sends the correct discrete command.
        let wasPlaying = lastIsPlaying
        if let current = AppState.shared.nowPlaying {
            let flipped = current.withIsPlaying(!current.isPlaying)
            lastIsPlaying = flipped.isPlaying
            AppState.shared.updateNowPlaying(flipped)
        }
        source.playPause(isPlaying: wasPlaying)
        scheduleCatchUp()
    }

    func next() {
        source.next()
        scheduleCatchUp()
    }

    /// Fire a short burst of confirm-polls after a transport command so the
    /// player's real state lands within a few hundred ms. Cancels any prior
    /// batch first so rapid clicks never stack timers.
    private func scheduleCatchUp() {
        cancelCatchUp()
        catchUpHandles = Self.catchUpDelaysSeconds.map { delay in
            scheduler.schedule(after: delay) { [weak self] in
                // Conformers fire this on the main queue/actor (production:
                // DispatchQueue.main; tests: a @MainActor double), so the
                // main-actor `poll()` is safe to reach here.
                MainActor.assumeIsolated {
                    self?.poll()
                }
            }
        }
    }

    private func cancelCatchUp() {
        for handle in catchUpHandles { handle.cancel() }
        catchUpHandles = []
    }

    // MARK: - Polling

    /// One poll: read the source, publish or debounce-clear, and re-arm the
    /// timer at the cadence matching the new state. Factored out so the
    /// test seam runs the identical logic without a RunLoop.
    private func poll() {
        let snapshot = source.currentSnapshot()
        apply(snapshot)
        // Re-arm at the cadence matching whether a track is active so the
        // loop speeds up on play and idles when nothing is on.
        if running {
            let interval = (snapshot != nil) ? Self.activeIntervalSeconds : Self.idleIntervalSeconds
            scheduleTimer(interval: interval)
        }
    }

    /// Apply one source read to `AppState`, honouring the debounce on clear.
    private func apply(_ snapshot: NowPlayingSnapshot?) {
        if let snapshot {
            emptyStreak = 0
            lastIsPlaying = snapshot.isPlaying
            AppState.shared.updateNowPlaying(snapshot)
            #if DEBUG
            os_log(
                "nowplaying %{public}@ — %{public}@ (%{public}@)",
                log: Self.log, type: .debug,
                snapshot.app == .music ? "music" : "spotify",
                snapshot.title,
                snapshot.isPlaying ? "playing" : "paused"
            )
            #endif
        } else {
            emptyStreak += 1
            if emptyStreak >= clearDebounceTicks {
                emptyStreak = clearDebounceTicks // saturate; avoid overflow
                lastIsPlaying = false
                AppState.shared.clearNowPlaying()
            }
        }
    }

    private func scheduleTimer(interval: TimeInterval) {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            // Hop to the main actor via a Task, NOT `assumeIsolated`: the
            // latter's synchronous executor check (swift_task_isCurrentExecutor)
            // intermittently crashed from this CFRunLoop timer callback on the
            // macOS 27 beta runtime (EXC_BAD_ACCESS). A Task enqueues on the main
            // executor without that bare-thread check.
            // WHY: docs/decisions/2026-06-23-nowplaying-assumeisolated-hardening.md
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - Test seam

    /// Run exactly one poll synchronously, bypassing the timer. Exercises
    /// the same publish/debounce logic the timer fires so tests pin real
    /// behaviour. Honours `running`: a stopped controller (e.g. one whose
    /// coordinator gated `start()` off behind the feature flag) never
    /// publishes, matching production where the timer would not be armed.
    /// Not used in production.
    func pollOnceForTesting(forceRunning: Bool = false) async {
        if forceRunning { running = true }
        guard running else { return }
        let snapshot = source.currentSnapshot()
        apply(snapshot)
    }
}

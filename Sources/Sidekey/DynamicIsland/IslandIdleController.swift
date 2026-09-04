import Combine
import Foundation

/// Schedules (and cancels) the single pending "re-evaluate idle" tick. Injected
/// into `IslandIdleController` so tests drive time by hand — a fake captures the
/// pending closure and fires it on demand, with no real `Timer` / `Task.sleep`.
///
/// Contract: `schedule` replaces any previously-armed tick (only one is ever
/// pending); `cancel` disarms it.
@MainActor
protocol IslandIdleTickScheduling: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
    func cancel()
}

/// Production tick scheduler — a lightweight one-shot `Timer` wrapper. Fires the
/// re-evaluation on the main run loop after `delay`. Rescheduling invalidates
/// the prior timer so at most one is ever armed.
@MainActor
final class IslandIdleTimerScheduler: IslandIdleTickScheduling {
    private var timer: Timer?

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        cancel()
        // A zero/negative delay means the deadline is already in the past;
        // fire on the next main-loop hop so the caller finishes its update
        // first (keeps behaviour identical to a real short timer).
        let interval = max(delay, 0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { work() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }
}

/// Owns the Dynamic Island idle-hide engine (spec §2.2): tracks the last
/// activity moment, recomputes `visibility` on activity / blocker changes /
/// scheduled ticks, and forces `.active` the instant a blocker rises.
///
/// Pure of AppKit and (directly) of `AppState`: the blocker disjunction reaches
/// it through `updateBusy(_:)` (wired to `AppState` by a Combine bridge in
/// Stage 4), and time flows through the injected `now` / scheduler. That keeps
/// the whole engine unit-testable with a virtual clock.
///
/// **Privacy (invariant #3):** `registerActivity()` takes no arguments and
/// reads only the clock — it is structurally impossible to pass keystroke
/// content, a keyCode, or any event payload through it. Nothing here is logged.
@MainActor
final class IslandIdleController: ObservableObject {

    /// Published visibility the UI bridge subscribes to (Stage 4). Starts
    /// `.active` — the pill is visible on launch.
    @Published private(set) var visibility: IdleVisibility = .active

    private let now: () -> Date
    private let scheduler: IslandIdleTickScheduling
    private let isEnabled: () -> Bool
    private let timeout: () -> TimeInterval

    /// Moment of the last activity signal (hover / hotkey / deep-link) or of the
    /// most recent blocker-fall — the anchor the timeout counts from.
    private var lastActivity: Date

    /// Whether any of the AppState blockers (spec §3, wired via Combine) is
    /// currently up. While `true` the island is pinned `.active`.
    private var isBusy = false

    /// Whether the cursor is currently over the island's rendered content
    /// (spec §3 B10). Tracked separately from `isBusy` because it flows from a
    /// different source (the panel's mouse routing) and is an independent
    /// OR-input into the effective hold.
    private var isHovered = false

    init(
        now: @escaping () -> Date = Date.init,
        scheduler: IslandIdleTickScheduling? = nil,
        isEnabled: @escaping () -> Bool = { true },
        timeout: @escaping () -> TimeInterval = { IslandIdleConfig.idleTimeout }
    ) {
        self.now = now
        // Default constructed inside the @MainActor init body — the production
        // `IslandIdleTimerScheduler.init` is main-actor-isolated and cannot be a
        // (nonisolated) default-argument expression.
        self.scheduler = scheduler ?? IslandIdleTimerScheduler()
        self.isEnabled = isEnabled
        self.timeout = timeout
        self.lastActivity = now()
        // Evaluate + arm the first tick so a launch with no interaction still
        // collapses after the timeout.
        reschedule()
    }

    /// Record an activity signal. Resets the idle window to `now` and — if the
    /// island was hidden — wakes it immediately (no tick wait). Takes no payload
    /// by design (invariant #3).
    func registerActivity() {
        lastActivity = now()
        reschedule()
    }

    /// Update the AppState-blocker disjunction (spec §3, wired via Combine in
    /// Stage 4). A rise forces `.active` immediately; a fall starts a FRESH idle
    /// window (see `applyBusyInput`).
    func updateBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        applyBusyInput()
    }

    /// React to the user flipping the Settings auto-hide toggle. Starts a FRESH
    /// idle window (like a blocker fall) and recomputes: enabling gives a full
    /// timeout before the first collapse instead of firing off a stale anchor,
    /// and disabling forces `.active` immediately (the `isEnabled()` veto), so a
    /// hidden island reappears the moment the user opts out — no hover/hotkey
    /// needed. Reads the flag through the same live `isEnabled` closure, so the
    /// host only has to persist the value and call this.
    func settingsDidChange() {
        lastActivity = now()
        reschedule()
    }

    /// Update the mouse-over-island blocker (spec §3 B10). Independent OR-input
    /// alongside `updateBusy`: a stationary cursor over the island emits no
    /// mouse events, so hover must hold `.active` on its own rather than relying
    /// on activity ticks.
    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        applyBusyInput()
    }

    /// Effective hold: the island stays `.active` while ANY blocker or a hover
    /// is up.
    private var effectiveBusy: Bool { isBusy || isHovered }

    /// Shared handling for a busy/hover input change. When the *effective* hold
    /// falls to `false`, reset the idle window to `now` so post-recording /
    /// post-hover idle is a full timeout, not the leftover of a stale pre-busy
    /// anchor (spec §2.4).
    private func applyBusyInput() {
        if !effectiveBusy {
            lastActivity = now()
        }
        reschedule()
    }

    /// Recompute `visibility` now and (re)arm the pending tick for the next
    /// collapse deadline. Called on every state-mutating input.
    private func reschedule() {
        evaluate()

        scheduler.cancel()
        // Only a running, not-held, enabled island has a future collapse to
        // wait for. When held/disabled the next input will re-arm; nothing to
        // schedule now.
        guard isEnabled(), !effectiveBusy, visibility == .active else { return }
        let deadline = lastActivity.addingTimeInterval(timeout())
        let remaining = deadline.timeIntervalSince(now())
        scheduler.schedule(after: remaining) { [weak self] in
            // Re-evaluate AND re-arm: if activity moved the deadline forward
            // between scheduling and firing, the island is still `.active` and
            // `reschedule()` arms a fresh tick for the new deadline. Once it
            // collapses, the `visibility == .active` guard stops re-arming.
            self?.reschedule()
        }
    }

    /// Pure recompute + publish. Idempotent: an unchanged value emits no
    /// duplicate (the `@Published` setter is guarded).
    private func evaluate() {
        let next = IdleVisibility.compute(
            now: now(),
            lastActivity: lastActivity,
            timeout: timeout(),
            isBusy: effectiveBusy,
            isEnabled: isEnabled()
        )
        if visibility != next {
            visibility = next
        }
    }
}

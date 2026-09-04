import Combine
import XCTest
@testable import Sidekey

/// Engine tests for `IslandIdleController` with an injected virtual clock and a
/// manually-driven tick scheduler — no real `Timer`, no `Task.sleep`. Each test
/// advances the clock explicitly and fires the pending tick, then asserts the
/// published `visibility`.
///
/// The controller owns `lastActivity`, recomputes `visibility` on activity /
/// busy changes / scheduled ticks via `IdleVisibility.compute`, and forces
/// `.active` the instant a blocker rises (spec §2.4).
@MainActor
final class IslandIdleControllerTests: XCTestCase {

    /// Virtual clock — mirrors the `MeetingDetector` test pattern. Holds a
    /// mutable `Date` the test advances directly.
    private final class VirtualClock {
        private(set) var current: Date
        init(_ start: Date) { current = start }
        func advance(_ seconds: TimeInterval) {
            current = current.addingTimeInterval(seconds)
        }
    }

    /// Fake scheduler that captures the most recent pending tick instead of
    /// arming a real timer. `fire()` runs it; `hasPending` reflects whether a
    /// tick is armed. The controller cancels the prior tick before scheduling a
    /// new one, so only the latest closure is retained.
    private final class FakeScheduler: IslandIdleTickScheduling {
        private var pending: (() -> Void)?
        private(set) var scheduleCount = 0
        private(set) var lastDelay: TimeInterval?

        var hasPending: Bool { pending != nil }

        func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
            scheduleCount += 1
            lastDelay = delay
            pending = work
        }

        func cancel() {
            pending = nil
        }

        /// Fire the armed tick (as if the delay elapsed). No-op if none armed.
        func fire() {
            let work = pending
            pending = nil
            work?()
        }
    }

    private let epoch = Date(timeIntervalSinceReferenceDate: 5_000_000)
    private let timeout: TimeInterval = 20

    private func makeController(
        clock: VirtualClock,
        scheduler: FakeScheduler,
        isEnabled: @escaping () -> Bool = { true }
    ) -> IslandIdleController {
        IslandIdleController(
            now: { clock.current },
            scheduler: scheduler,
            isEnabled: isEnabled,
            timeout: { self.timeout }
        )
    }

    // MARK: - Startup

    /// Fresh controller starts `.active` (the pill is visible on launch).
    func test_startsActive() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)
        XCTAssertEqual(controller.visibility, .active)
    }

    // MARK: - Idle collapse

    /// With no activity, advancing past the timeout and firing the tick
    /// collapses to `.hiddenIdle`.
    func test_idleTimeoutElapsed_collapsesToHiddenIdle() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        clock.advance(timeout)
        scheduler.fire()

        XCTAssertEqual(controller.visibility, .hiddenIdle)
    }

    /// Activity before the timeout resets `lastActivity`, so the pending tick
    /// keeps it `.active`; a full fresh timeout after the activity is required
    /// to collapse.
    func test_activityBeforeTimeout_resetsAndStaysActive() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        // 15s in (< 20s) the user does something.
        clock.advance(15)
        controller.registerActivity()
        XCTAssertEqual(controller.visibility, .active)

        // The original tick would fire at +20s from epoch — only 5s after the
        // activity. Firing it must NOT collapse (only 5s idle).
        clock.advance(5) // now epoch+20
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)

        // A full fresh timeout after the activity (activity was at epoch+15,
        // so collapse at epoch+35) collapses.
        clock.advance(15) // now epoch+35
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .hiddenIdle)
    }

    // MARK: - Busy forces .active

    /// A blocker rising while the timeout has already elapsed forces `.active`
    /// immediately — without waiting for a tick.
    func test_busyRises_forcesActiveImmediately_noTickNeeded() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        // Collapse first.
        clock.advance(timeout)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .hiddenIdle)

        // Blocker rises — instant wake, no scheduler.fire() in between.
        controller.updateBusy(true)
        XCTAssertEqual(controller.visibility, .active)
    }

    /// While busy, the tick cannot collapse the island even long past timeout.
    func test_whileBusy_tickCannotCollapse() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        controller.updateBusy(true)
        clock.advance(timeout * 10)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)
    }

    /// When the blocker falls, the idle window starts fresh from `now` — the
    /// old `lastActivity` is NOT inherited, so a full timeout is available
    /// before collapse (spec §2.4).
    func test_busyFalls_startsFreshIdleWindow() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        // Busy for a long time.
        controller.updateBusy(true)
        clock.advance(timeout * 5)
        XCTAssertEqual(controller.visibility, .active)

        // Busy falls at epoch + 100.
        controller.updateBusy(false)
        XCTAssertEqual(controller.visibility, .active)

        // Only 10s later (< timeout from the fall) — must NOT have collapsed.
        clock.advance(10)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)

        // A full timeout after the fall (fall was epoch+100, collapse at
        // epoch+120) collapses.
        clock.advance(10) // now epoch+120
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .hiddenIdle)
    }

    // MARK: - Wake from hidden

    /// `registerActivity()` while `.hiddenIdle` wakes to `.active` immediately
    /// (mouse-enter / hotkey), without waiting for a tick.
    func test_registerActivityWhileHidden_wakesImmediately() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        clock.advance(timeout)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .hiddenIdle)

        controller.registerActivity()
        XCTAssertEqual(controller.visibility, .active)
    }

    // MARK: - Hover blocker (B10)

    /// A stationary cursor over the island (`setHovered(true)`) holds `.active`
    /// past the timeout even with no activity ticks — a hover produces no mouse
    /// events once the cursor stops moving, so hover must be a proper blocker
    /// (spec §3 B10), not merely an activity tick.
    func test_hovered_holdsActive_pastTimeout() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        controller.setHovered(true)
        clock.advance(timeout * 3)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)
    }

    /// When the cursor leaves (`setHovered(false)`) the idle window starts fresh
    /// from `now` — like any blocker fall — so a full timeout is available.
    func test_hoverEnds_startsFreshIdleWindow() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        controller.setHovered(true)
        clock.advance(100)
        controller.setHovered(false) // window resets at epoch+100

        clock.advance(10) // epoch+110, only 10s idle
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)

        clock.advance(10) // epoch+120, full timeout since hover ended
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .hiddenIdle)
    }

    /// Hover and an AppState blocker are independent OR-inputs: dropping the
    /// AppState blocker while still hovered keeps `.active`.
    func test_hoverAndBusy_areIndependentOrInputs() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        controller.updateBusy(true)
        controller.setHovered(true)
        controller.updateBusy(false) // still hovered
        clock.advance(timeout * 2)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)
    }

    // MARK: - Disabled

    /// With the feature disabled, the controller never leaves `.active`, even
    /// past the timeout with a fired tick.
    func test_disabled_neverCollapses() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(
            clock: clock,
            scheduler: scheduler,
            isEnabled: { false }
        )

        clock.advance(timeout * 3)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)

        controller.registerActivity()
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)
    }

    // MARK: - Settings toggle (settingsDidChange)

    /// Disabling the feature while the island is hidden must wake it immediately:
    /// the user turned auto-hide OFF and expects the island back at once, without
    /// any hover/hotkey.
    func test_settingsDidChange_disableWhileHidden_wakesImmediately() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        var enabled = true
        let controller = makeController(
            clock: clock, scheduler: scheduler, isEnabled: { enabled }
        )

        clock.advance(timeout)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .hiddenIdle)

        // User flips auto-hide OFF in Settings.
        enabled = false
        controller.settingsDidChange()
        XCTAssertEqual(controller.visibility, .active)
    }

    /// Re-enabling starts a FRESH idle window from now — it must NOT collapse
    /// instantly off a stale pre-disable anchor. A full timeout after the toggle
    /// is required to collapse.
    func test_settingsDidChange_reEnable_startsFreshIdleWindow() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        var enabled = false
        let controller = makeController(
            clock: clock, scheduler: scheduler, isEnabled: { enabled }
        )

        // Long idle while disabled — the island is held `.active` (feature off).
        clock.advance(timeout * 5)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)

        // User enables auto-hide at epoch + 100.
        enabled = true
        controller.settingsDidChange()
        XCTAssertEqual(controller.visibility, .active)

        // 10s later (< timeout since the enable) — still `.active` (fresh window,
        // NOT collapsed off the stale epoch anchor).
        clock.advance(10)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .active)

        // A full timeout after the enable (epoch + 120) collapses.
        clock.advance(10)
        scheduler.fire()
        XCTAssertEqual(controller.visibility, .hiddenIdle)
    }

    // MARK: - Published output

    /// The `visibility` transition is observable via the `@Published` projection
    /// so the UI bridge (Stage 4) can subscribe.
    func test_publishesVisibilityTransition() {
        let clock = VirtualClock(epoch)
        let scheduler = FakeScheduler()
        let controller = makeController(clock: clock, scheduler: scheduler)

        var observed: [IdleVisibility] = []
        let cancellable = controller.$visibility.sink { observed.append($0) }
        defer { cancellable.cancel() }

        clock.advance(timeout)
        scheduler.fire()

        // Initial .active + the collapse to .hiddenIdle.
        XCTAssertEqual(observed, [.active, .hiddenIdle])
    }
}

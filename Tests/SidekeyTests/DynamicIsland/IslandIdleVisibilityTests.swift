import XCTest
@testable import Sidekey

/// Pure-function tests for `IdleVisibility.compute(...)` — the heart of the
/// Dynamic Island idle auto-hide feature. No timers, no `AppState`, no UI:
/// the function takes `now`, `lastActivity`, `timeout`, `isBusy`, `isEnabled`
/// and returns whether the compact pill should stay `.active` or collapse to
/// `.hiddenIdle`.
///
/// Contract (spec §2.4):
/// ```
/// isEnabled == false                       → .active            (feature off)
/// isBusy    == true                        → .active            (a blocker holds it)
/// now - lastActivity >= timeout            → .hiddenIdle        (idle long enough)
/// now - lastActivity <  timeout            → .active            (recent activity)
/// ```
final class IslandIdleVisibilityTests: XCTestCase {

    private let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let timeout: TimeInterval = 20

    // MARK: - isBusy forces .active (every blocker collapses to one bool)

    /// A blocker holds the island in `.active` regardless of how long ago the
    /// last activity was — even far past the timeout. `isBusy` is the OR of
    /// every blocker (spec §3), so this single case covers each one of them.
    func test_isBusy_true_forcesActive_evenWhenTimedOut() {
        let result = IdleVisibility.compute(
            now: epoch.addingTimeInterval(10_000),
            lastActivity: epoch,
            timeout: timeout,
            isBusy: true,
            isEnabled: true
        )
        XCTAssertEqual(result, .active)
    }

    // MARK: - Timeout boundary (isBusy == false)

    /// Just before the timeout the island stays visible.
    func test_notBusy_beforeTimeout_isActive() {
        let result = IdleVisibility.compute(
            now: epoch.addingTimeInterval(timeout - 0.001),
            lastActivity: epoch,
            timeout: timeout,
            isBusy: false,
            isEnabled: true
        )
        XCTAssertEqual(result, .active)
    }

    /// Exactly at the timeout the island collapses (inclusive boundary).
    func test_notBusy_atTimeout_isHiddenIdle() {
        let result = IdleVisibility.compute(
            now: epoch.addingTimeInterval(timeout),
            lastActivity: epoch,
            timeout: timeout,
            isBusy: false,
            isEnabled: true
        )
        XCTAssertEqual(result, .hiddenIdle)
    }

    /// Past the timeout the island stays collapsed.
    func test_notBusy_afterTimeout_isHiddenIdle() {
        let result = IdleVisibility.compute(
            now: epoch.addingTimeInterval(timeout + 5),
            lastActivity: epoch,
            timeout: timeout,
            isBusy: false,
            isEnabled: true
        )
        XCTAssertEqual(result, .hiddenIdle)
    }

    // MARK: - isEnabled == false is an absolute veto

    /// With the feature disabled the island is always `.active`, even when the
    /// timeout has elapsed and nothing is busy. This is the wiring point for a
    /// future Settings toggle (spec §6): a `false` here == "feature off".
    func test_disabled_staysActive_pastTimeout() {
        let result = IdleVisibility.compute(
            now: epoch.addingTimeInterval(timeout + 100),
            lastActivity: epoch,
            timeout: timeout,
            isBusy: false,
            isEnabled: false
        )
        XCTAssertEqual(result, .active)
    }

    /// `isEnabled == false` outranks `isBusy` too — both point at `.active`, so
    /// the result is unambiguous, but this pins that disabling never flips to
    /// `.hiddenIdle` under any input combination.
    func test_disabled_withBusy_staysActive() {
        let result = IdleVisibility.compute(
            now: epoch.addingTimeInterval(timeout + 100),
            lastActivity: epoch,
            timeout: timeout,
            isBusy: true,
            isEnabled: false
        )
        XCTAssertEqual(result, .active)
    }

    // MARK: - Config

    /// The single source of truth for the idle threshold is 20s (spec §2.1).
    func test_config_idleTimeout_is20Seconds() {
        XCTAssertEqual(IslandIdleConfig.idleTimeout, 20)
    }

    // MARK: - Blocker disjunction (spec §3)

    /// All blockers clear → not busy (the only state from which the island can
    /// collapse). This is the `allClear` fixture the per-blocker cases toggle
    /// one field from.
    private var allClear: IslandIdleBlockers {
        IslandIdleBlockers(
            dropFlowActive: false,
            agentPhaseActive: false,
            agentPanelVisible: false,
            meetingSuggestionActive: false,
            meetingRecordingActive: false,
            updateAvailable: false,
            justUpdatedVisible: false,
            nowPlayingActive: false,
            rightModifierHeld: false,
            programmaticHoverExpansion: false
        )
    }

    func test_blockers_allClear_isNotBusy() {
        XCTAssertFalse(allClear.isBusy)
    }

    /// Each AppState-sourced blocker (B10 hover is fed separately via the
    /// panel) independently forces busy. Toggling exactly one field true must
    /// flip `isBusy`, so no blocker can be silently dropped — in particular
    /// B7 (update pill, invariant #5) and B4/B5 (meeting pills).
    func test_blockers_eachOneForcesBusy() {
        var b = allClear; b.dropFlowActive = true
        XCTAssertTrue(b.isBusy, "B1 drop flow")

        b = allClear; b.agentPhaseActive = true
        XCTAssertTrue(b.isBusy, "B2 agent phase")

        b = allClear; b.agentPanelVisible = true
        XCTAssertTrue(b.isBusy, "B3 agent panel")

        b = allClear; b.meetingSuggestionActive = true
        XCTAssertTrue(b.isBusy, "B4 meeting nudge")

        b = allClear; b.meetingRecordingActive = true
        XCTAssertTrue(b.isBusy, "B5 meeting recording")

        b = allClear; b.updateAvailable = true
        XCTAssertTrue(b.isBusy, "B7 update pill (invariant #5)")

        b = allClear; b.justUpdatedVisible = true
        XCTAssertTrue(b.isBusy, "B13 post-relaunch Updated indicator (invariant #5)")

        b = allClear; b.nowPlayingActive = true
        XCTAssertTrue(b.isBusy, "B9 now playing")

        b = allClear; b.rightModifierHeld = true
        XCTAssertTrue(b.isBusy, "B11 right modifier held")

        b = allClear; b.programmaticHoverExpansion = true
        XCTAssertTrue(b.isBusy, "B12 programmatic hover expansion")
    }
}

import Foundation

/// Decides whether the `Quit ⌥Q` chip in the agent response panel close-
/// button row should render. Pulled out of `AgentResponsePanelContent`
/// so the decision matrix lives behind a pure, unit-testable contract
/// while the View layer just reads `shouldRender` (or branches on the
/// case for transition tagging).
///
/// The chip has three visibility regimes:
///
///   1. Hide Helpers OFF -> `.visible` (matches the PR #164 baseline).
///   2. Hide Helpers ON, before the 10 s grace window elapses ->
///      `.hiddenForDelay` so the panel chrome stays minimal on first
///      open.
///   3. Hide Helpers ON, after the grace window elapses ->
///      `.visibleAfterDelay` so power users still rediscover Option+Q
///      without giving up screen real estate permanently.
///
/// `.visible` and `.visibleAfterDelay` are intentionally distinct so a
/// caller can tag the appearance transition differently if it ever
/// matters (e.g. fade-in only for the delayed reveal). Today both
/// collapse to the same `shouldRender == true` and the View applies a
/// single `.transition(.opacity)`.
enum QuitHintVisibility: Equatable {
    /// Hide Helpers OFF: the chip surfaces immediately, no timer
    /// involved. The default UX shipped in PR #164.
    case visible
    /// Hide Helpers ON and the 10 s grace timer has not elapsed yet:
    /// the chip is suppressed so the close-button row reads as just
    /// the dismiss control during the initial window.
    case hiddenForDelay
    /// Hide Helpers ON and the 10 s timer has elapsed: the chip is
    /// back on screen until the panel closes.
    case visibleAfterDelay

    /// Pure resolver: the decision matrix lives here so the View can
    /// stay declarative and the tests can pin every case.
    ///
    /// - Parameters:
    ///   - hideHelpers: Mirror of `DisplayPreferences.shared.hideHelpers`.
    ///   - delayElapsed: `true` once the 10 s grace timer fired for the
    ///     current Hide Helpers ON window. The View owns the timer via
    ///     a `.task(id: hideHelpers)` modifier and resets the flag on
    ///     every ON cycle.
    static func resolve(
        hideHelpers: Bool,
        delayElapsed: Bool
    ) -> QuitHintVisibility {
        if !hideHelpers { return .visible }
        return delayElapsed ? .visibleAfterDelay : .hiddenForDelay
    }

    /// View-facing accessor: collapses the three cases into a single
    /// bool the close-button row consumes inside its `if` guard.
    var shouldRender: Bool {
        switch self {
        case .visible, .visibleAfterDelay:
            return true
        case .hiddenForDelay:
            return false
        }
    }
}

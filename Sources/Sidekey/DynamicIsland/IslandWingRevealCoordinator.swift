import SwiftUI

/// Two-step entrance for the agent/drop wing: the island form grows EMPTY
/// first, then the face content (provider mark + "listening…" / field /
/// activity slot) fades in once the width spring has landed.
///
/// The reveal is explicit `@Published` state driven by a timer, NOT a SwiftUI
/// `.transition`: a transition's insertion animation rides whatever
/// transaction performs the insert, and the body's width springs kept
/// overriding the intended delay — the face painted half-clipped over the
/// still-growing form ("listenin|"). Explicit state cannot be re-timed by a
/// transaction: while `revealed == false` the content is at opacity 0, full
/// stop; the flip animates via its own `withAnimation`.
@MainActor
final class IslandWingRevealCoordinator: ObservableObject {
    @Published private(set) var revealed = false

    /// How long the form gets to grow before the content fades in. Slightly
    /// past the body's `hoverMotion`/`widthGrowth` spring response so the
    /// capsule has visually landed when the fade starts.
    let growDelay: Duration
    /// The content fade itself.
    static let revealFade = Animation.easeOut(duration: 0.14)

    /// Claim counter: any visibility change invalidates the pending reveal,
    /// so a wing that collapsed (or re-opened) mid-delay never gets a stale
    /// flip. Same pattern as `AppDelegate.streamingSetupGeneration`.
    private var generation = 0

    init(growDelay: Duration = .milliseconds(260)) {
        self.growDelay = growDelay
    }

    /// Wire from the view: call with `wing != .hidden` whenever the coarse
    /// wing visibility changes (NOT on transcript partials). Face→face swaps
    /// while visible keep the content revealed — only hidden↔visible edges
    /// move the state.
    func wingVisibilityChanged(_ visible: Bool) {
        generation &+= 1
        let claimed = generation

        guard visible else {
            // Collapse hides the content in the same frame — the form is
            // about to shrink and nothing may linger over the wallpaper.
            revealed = false
            return
        }
        guard !revealed else { return }

        Task { [weak self] in
            guard let delay = self?.growDelay else { return }
            try? await Task.sleep(for: delay)
            guard let self, self.generation == claimed, !self.revealed else { return }
            withAnimation(Self.revealFade) {
                self.revealed = true
            }
        }
    }
}

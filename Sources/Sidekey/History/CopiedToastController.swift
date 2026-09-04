import Foundation

/// Tiny @Published-driven controller for the "Copied" toast that
/// appears centered on screen when the user clicks a strip card's
/// body. The toast fades in, holds, fades out — visible only.
///
/// Lifespan model: a single `totalLifespan` window from `show()`. A
/// second `show()` before that window closes resets the timer (so a
/// rapid copy of two cards leaves the toast visible for the second's
/// full lifespan). Implementation uses a generation counter so the
/// stale auto-hide closure no-ops when a newer `show()` superseded it.
@MainActor
final class CopiedToastController: ObservableObject {
    /// Total wall-clock time the toast stays on screen, from
    /// `show()` call to `hide()` call. The SwiftUI host inside
    /// `CopiedToastPanel` runs its own fade-in / fade-out animation
    /// within this window.
    static let totalLifespan: TimeInterval = 1.5

    @Published private(set) var isVisible: Bool = false

    /// Injection seam for the auto-hide scheduler. Production binds it
    /// to `DispatchQueue.main.asyncAfter(deadline:)`; tests pass a
    /// stub that captures the work without sleeping.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    private let schedule: Scheduler
    private var generation: UInt64 = 0

    init(schedule: @escaping Scheduler = CopiedToastController.defaultSchedule) {
        self.schedule = schedule
    }

    func show() {
        isVisible = true
        generation &+= 1
        let token = generation
        schedule(Self.totalLifespan) { [weak self] in
            guard let self else { return }
            // A newer `show()` has bumped the generation — the older
            // auto-hide is stale.
            guard self.generation == token else { return }
            self.isVisible = false
        }
    }

    func hide() {
        isVisible = false
        generation &+= 1
    }

    /// Pure dispatch helper — no actor state touched, so the default
    /// parameter value of `init(schedule:)` can reference it from a
    /// nonisolated context (Swift 6 strict concurrency would otherwise
    /// reject the cross-isolation reference). The trailing closure
    /// itself runs on the main queue via `DispatchQueue.main`, so any
    /// MainActor-isolated work the caller schedules still runs on the
    /// right actor.
    nonisolated private static func defaultSchedule(
        _ delay: TimeInterval,
        _ work: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            work()
        }
    }
}

import AppKit
import Foundation

/// The pause between a success and the next step, which the person can hold.
///
/// - `counting`: the current progress segment fills over the step's dwell,
///   then the onboarding moves on.
/// - `latched`: the pointer entered the step or Hold was clicked; time stops
///   until the pointer leaves (resume) or Return / the pill (go on now).
/// - `reviewing`: Back reached a step that is already done. It never moves on
///   by itself; "Saved · Next" or Return goes on.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingDwellController: ObservableObject {
    enum State: Equatable {
        case idle
        case counting(next: String, progress: Double)
        case latched(next: String, progress: Double)
        case reviewing(next: String)
    }

    @Published private(set) var state: State = .idle

    /// Tests wait the whole dwell at once instead of ticking.
    private let wait: ((TimeInterval) async -> Void)?
    private let reduceMotion: () -> Bool
    private var task: Task<Void, Never>?
    private var generation = 0
    private var duration: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var onAdvance: (() -> Void)?

    init(wait: ((TimeInterval) async -> Void)? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.wait = wait
        self.reduceMotion = reduceMotion
    }

    var isCounting: Bool { if case .counting = state { return true } else { return false } }
    var isLatched: Bool { if case .latched = state { return true } else { return false } }

    /// How far the current segment is filled.
    var fraction: Double {
        switch state {
        case .counting(_, let progress), .latched(_, let progress): return progress
        case .idle, .reviewing: return 0
        }
    }

    func schedule(_ seconds: TimeInterval, next: String, onAdvance: @escaping () -> Void) {
        cancel()
        // Reduce Motion adds a little reading time: nothing slides to say it moved.
        duration = reduceMotion() ? seconds + 0.22 : seconds
        elapsed = 0
        self.onAdvance = onAdvance
        state = .counting(next: next, progress: 0)
        run()
    }

    func review(next: String, onAdvance: @escaping () -> Void) {
        cancel()
        self.onAdvance = onAdvance
        state = .reviewing(next: next)
    }

    /// The pointer entered the step, or Hold was clicked.
    func latch() {
        guard case .counting(let next, let progress) = state else { return }
        generation += 1
        task?.cancel()
        state = .latched(next: next, progress: progress)
    }

    /// The pointer left the step.
    func resume() {
        guard case .latched(let next, let progress) = state else { return }
        state = .counting(next: next, progress: progress)
        run()
    }

    /// Return, the pill, or Next: go on now.
    func commitNow() {
        guard state != .idle else { return }
        let advance = onAdvance
        cancel()
        advance?()
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        onAdvance = nil
        elapsed = 0
        state = .idle
    }

    private func run() {
        generation += 1
        let run = generation
        task?.cancel()
        if let wait {
            let remaining = max(0, duration - elapsed)
            task = Task { @MainActor [weak self] in
                await wait(remaining)
                guard let self, self.generation == run, self.isCounting else { return }
                self.fire()
            }
            return
        }
        task = Task { @MainActor [weak self] in
            let tick: TimeInterval = 1.0 / 60
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard let self, self.generation == run, case .counting(let next, _) = self.state else { return }
                self.elapsed += tick
                let progress = min(1, self.elapsed / max(self.duration, 0.05))
                self.state = .counting(next: next, progress: progress)
                if progress >= 1 { return self.fire() }
            }
        }
    }

    private func fire() {
        let advance = onAdvance
        cancel()
        advance?()
    }
}

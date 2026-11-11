import Foundation

/// A short, memory-only pause of wake word listening that releases the
/// microphone without touching the user's setting.
///
/// The builder's meeting gate treats any microphone use as a possible call,
/// and Whytap's own idle listener would hold it "busy" forever. The builder
/// pauses listening through app control, runs the unchanged gate against the
/// real microphone state, and the pause ends by itself.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
@MainActor
final class WakeWordPause {
    static let shared = WakeWordPause()

    /// Long enough for the gate and a normal quit; short enough that a
    /// builder that never resumes cannot leave the wake word off.
    static let duration: TimeInterval = 180

    private let now: () -> Date
    private let notify: () -> Void
    private var until: Date?
    private var expiry: Task<Void, Never>?

    init(
        now: @escaping () -> Date = Date.init,
        notify: @escaping () -> Void = {
            NotificationCenter.default.post(name: WakeWordPreferences.didChangeNotification, object: nil)
        }
    ) {
        self.now = now
        self.notify = notify
    }

    var isPaused: Bool {
        guard let until else { return false }
        return now() < until
    }

    func setPaused(_ paused: Bool) {
        expiry?.cancel()
        expiry = nil
        until = paused ? now().addingTimeInterval(Self.duration) : nil
        if paused {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.duration))
                guard !Task.isCancelled, let self else { return }
                self.until = nil
                self.notify()
            }
        }
        notify()
    }
}

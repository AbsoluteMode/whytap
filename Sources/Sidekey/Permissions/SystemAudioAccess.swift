import Accelerate
import Foundation

/// What Whytap knows about System Audio Recording (TCC `AudioCapture`).
///
/// macOS offers no public status check for it: a refused or not yet given
/// grant starts the process tap without error and delivers only zero samples.
/// The one proof of a grant is a sample that is not zero, so the first one any
/// capture hears (Subtitles, Meeting Notes, the meeting detector, the
/// onboarding question) is remembered, and from then on Settings shows the
/// permission as allowed and Subtitles stop suggesting the privacy pane.
///
/// A grant withdrawn later in System Settings is not noticed: silence alone
/// cannot tell a refusal from a quiet Mac.
// WHY: .project-docs/decisions/2026-11-25-system-audio-heard-means-allowed.md
enum SystemAudioAccess {
    static let heardKey = "sidekey.systemAudio.heard.v1"
    /// Posted on the main queue once, when the first signal is remembered.
    static let didChange = Notification.Name("SidekeySystemAudioAccessDidChange")

    /// A capture has heard the Mac's sound at least once: the grant exists.
    static func heard(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: heardKey)
    }

    /// Remembers that a capture heard sound. Safe from any thread; only the
    /// first call writes and notifies.
    static func recordHeard(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: heardKey) else { return }
        defaults.set(true, forKey: heardKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// Whether a buffer carries any sound at all. Without the grant every
    /// sample is exactly zero.
    static func containsSignal(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak > 0
    }
}

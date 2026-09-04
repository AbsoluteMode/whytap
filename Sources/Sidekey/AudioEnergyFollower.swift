import Foundation

/// Asymmetric envelope follower for the orb's voice-driven energy.
///
/// Why this exists:
///   `audioEnergy(levels:)` used to average the last 10 raw samples,
///   which gave the orb a symmetric "smoothed peak meter" look. The
///   problem with symmetric averaging is that pauses in speech take
///   ~10 frames to register — when the user stops talking, the orb
///   keeps wobbling for a beat because the average still carries the
///   previous voice peaks.
///
///   Siri-style orbs feel snappy precisely because they DROP to silence
///   the moment the user pauses. This class implements an exponential
///   moving average with two different time constants:
///     - When the new sample is HIGHER than the current smoothed value
///       (audio is rising — the user just started speaking), apply a
///       moderate attack so peaks don't blow up frame-to-frame.
///     - When the new sample is LOWER (audio is falling — pause),
///       apply a fast decay so the orb shrinks before the user finishes
///       drawing breath for the next word.
///
///   Both coefficients are tuned by ear; the difference is what gives
///   the orb its responsiveness to pauses.
@MainActor
final class AudioEnergyFollower {
    static let shared = AudioEnergyFollower()

    /// EMA coefficient when audio is rising. Lower = smoother peaks.
    private static let attackCoef: Float = 0.35
    /// EMA coefficient when audio is falling. Higher = the orb snaps
    /// back to silence faster (Maxim explicitly asked for fast pause
    /// reaction: «реакция на паузу должна быть быстрой»).
    private static let decayCoef: Float = 0.85

    private var smoothed: Float = 0

    private init() {}

    /// Observe a new raw audio sample (0...1) and return the smoothed
    /// envelope value. Side effect: updates the internal state for the
    /// next call.
    @discardableResult
    func observe(_ rawLevel: Float) -> Float {
        let clamped = max(0, min(1, rawLevel))
        let coef = clamped > smoothed ? Self.attackCoef : Self.decayCoef
        smoothed += (clamped - smoothed) * coef
        return smoothed
    }

    /// Current smoothed value without observing a new sample.
    var value: Float { smoothed }

    /// Test hook — resets the follower so each test starts at zero.
    func reset() {
        smoothed = 0
    }
}

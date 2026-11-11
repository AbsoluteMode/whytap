import Foundation

/// End-of-speech timings for a wake-word take, adjustable without a rebuild
/// while they are being calibrated on real speech:
///
///     defaults write com.rootwise.sidekey com.sidekey.wakeword.quietSeconds -float 1.5
///     defaults write com.rootwise.sidekey com.sidekey.wakeword.providerSilenceSeconds -float 1.0
///
/// Read when a take starts. Out-of-range or missing values use the defaults.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
enum WakeWordTuning {
    static let quietSecondsKey = "com.sidekey.wakeword.quietSeconds"
    static let providerSilenceSecondsKey = "com.sidekey.wakeword.providerSilenceSeconds"

    static let defaultQuietSeconds: TimeInterval = 2
    static let quietSecondsRange: ClosedRange<TimeInterval> = 0.5...5
    static let defaultProviderSilenceSeconds: Double = 1.5
    /// ElevenLabs accepts 0.192...3.0 for `vad_silence_threshold_secs`.
    static let providerSilenceSecondsRange: ClosedRange<Double> = 0.3...3

    /// Quiet in the live transcript that ends the take (every provider).
    static func quietSeconds(_ defaults: UserDefaults = .standard) -> TimeInterval {
        value(defaults, quietSecondsKey, in: quietSecondsRange, fallback: defaultQuietSeconds)
    }

    /// Silence after which a turn-predicting provider commits on its own.
    static func providerSilenceSeconds(_ defaults: UserDefaults = .standard) -> Double {
        value(defaults, providerSilenceSecondsKey, in: providerSilenceSecondsRange,
              fallback: defaultProviderSilenceSeconds)
    }

    private static func value(
        _ defaults: UserDefaults, _ key: String, in range: ClosedRange<Double>, fallback: Double
    ) -> Double {
        guard let stored = defaults.object(forKey: key) as? NSNumber else { return fallback }
        let number = stored.doubleValue
        return number.isFinite && range.contains(number) ? number : fallback
    }
}

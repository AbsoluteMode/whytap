import Foundation

/// Estimates the ambient noise floor of the user's microphone setup by
/// tracking the bottom 5% of recent audio energy readings.
///
/// Why this exists:
///   A fixed noise gate (e.g. `voiceNoiseGate = 0.04`) cannot work
///   across rooms / microphones. In a quiet office a 0.04 gate is much
///   higher than the actual silence reading and clips most quiet
///   speech; in a noisy environment the same 0.04 falls below the
///   room tone and the orb wobbles even when nobody is speaking.
///
///   We therefore learn the floor from observation. The estimator keeps
///   a ring buffer of the most recent 1 000 energy samples (≈ 20 seconds
///   at typical AVAudioRecorder meter rates) and reports the 5th
///   percentile as "what silence looks like for this user right now."
///   Callers add a small epsilon and use the result as a dynamic gate.
///
///   Memory: 1 000 × 4 bytes = 4 KB. Nothing is persisted to disk; the
///   buffer lives only in memory and is rebuilt from scratch on every
///   app launch.
@MainActor
final class NoiseFloorEstimator {
    static let shared = NoiseFloorEstimator()

    /// Maximum number of samples kept in memory. ~20 seconds at typical
    /// meter rates, plenty for a robust percentile estimate without
    /// being heavyweight.
    private static let maxSamples = 1000
    /// Bottom 5% of the observed energy distribution is "silence."
    private static let floorPercentile = 0.05
    /// Top 5% of the observed energy distribution is "peak speech."
    /// `1 - peakPercentile` so we look at the upper tail.
    private static let peakPercentile = 0.95
    /// How many new samples to accept between recomputing the cached
    /// percentile. At ~30 fps that's about every 2 seconds — the floor
    /// drifts slowly enough that more frequent recomputes are wasted work.
    private static let recomputeEvery = 60

    private var samples: [Float] = []
    private var cachedFloor: Float = 0
    private var cachedPeak: Float = 1
    private var samplesSinceLastCompute = 0

    private init() {
        samples.reserveCapacity(Self.maxSamples)
    }

    /// Adds one audio energy reading (already normalized to 0...1) into
    /// the rolling buffer. Recomputes the percentile every
    /// `recomputeEvery` pushes (~2 seconds at typical meter rates) plus
    /// once immediately after the very first sample so the first frames
    /// after launch already see a non-zero floor.
    func record(_ level: Float) {
        let clamped = max(0, min(1, level))
        samples.append(clamped)
        if samples.count > Self.maxSamples {
            samples.removeFirst()
        }
        samplesSinceLastCompute += 1
        if samplesSinceLastCompute >= Self.recomputeEvery || samples.count == 1 {
            samplesSinceLastCompute = 0
            recomputeFloor()
        }
    }

    /// The current estimated noise floor in 0...1. Returns 0 when no
    /// samples have been recorded yet (the gate then degenerates to
    /// "any audio at all triggers" — acceptable for the very first
    /// frames before the user has had a chance to speak).
    var floor: Float {
        cachedFloor
    }

    /// The current estimated peak energy (95th percentile of recent
    /// samples). Used to normalize the user's individual dynamic range
    /// so the orb expands fully when the user reaches their typical
    /// peak speech level, regardless of microphone sensitivity.
    /// Defaults to 1 until a peak is observed.
    var peak: Float {
        cachedPeak
    }

    /// Maps a raw audio sample into the user's learned dynamic range:
    /// `(raw - floor) / (peak - floor)`, clamped to [0, 1]. Silence
    /// (`raw ≤ floor`) maps to 0; the user's typical loud speech
    /// (`raw ≥ peak`) maps to 1. The orb's expansion / contraction
    /// then reflects the user's personal range rather than the raw
    /// 0...1 mic energy.
    func normalize(_ raw: Float) -> Float {
        let denom = max(0.01, cachedPeak - cachedFloor)
        return max(0, min(1, (raw - cachedFloor) / denom))
    }

    /// Test / debug hook — exposes the live buffer size so callers can
    /// confirm the estimator is being fed.
    var sampleCount: Int {
        samples.count
    }

    /// Test hook — resets state so each test starts from a clean slate.
    func reset() {
        samples.removeAll(keepingCapacity: true)
        cachedFloor = 0
        cachedPeak = 1
        samplesSinceLastCompute = 0
    }

    private func recomputeFloor() {
        guard !samples.isEmpty else {
            cachedFloor = 0
            cachedPeak = 1
            return
        }
        let sorted = samples.sorted()
        let floorIdx = Int(Double(sorted.count) * Self.floorPercentile)
        let peakIdx = Int(Double(sorted.count) * Self.peakPercentile)
        cachedFloor = sorted[max(0, min(floorIdx, sorted.count - 1))]
        cachedPeak = sorted[max(0, min(peakIdx, sorted.count - 1))]
    }
}

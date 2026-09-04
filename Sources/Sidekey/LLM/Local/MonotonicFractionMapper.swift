import Foundation

/// Stitches a segmented, per-pass-resetting 0→1 fraction stream into one
/// forward-only curve.
///
/// WHY: FluidAudio's `AsrModels.download` runs its 0→1 progress reporter once
/// per Core ML model, so the raw fraction sawtooths (0→1, 0→1, …) and the bar
/// jumps backwards between models. The library fraction is byte-weighted *within*
/// each pass — it is the real signal — so rather than discard it we remap each
/// reset onto the next equal-width segment of `[0, 1]`. The diarizer reports a
/// single continuous pass (`segmentCount == 1`), for which this is the identity
/// mapping plus a monotonic guard against transient dips.
struct MonotonicFractionMapper {
    private let segmentWidth: Double
    private let segmentCount: Int
    private var segmentIndex = 0
    private var lastRaw: Double = 0
    private var peak: Double = 0

    /// - Parameter segmentCount: number of 0→1 passes the source will emit
    ///   (e.g. the number of Core ML models FluidAudio downloads). Values `< 1`
    ///   are treated as 1.
    init(segmentCount: Int) {
        let count = max(1, segmentCount)
        self.segmentCount = count
        self.segmentWidth = 1.0 / Double(count)
    }

    /// Map the next raw library fraction (expected 0…1) to a clamped, globally
    /// monotonic fraction in [0, 1].
    mutating func map(_ raw: Double) -> Double {
        let clampedRaw = min(1.0, max(0.0, raw))

        // A meaningful drop means the source moved on to the next pass and reset
        // its counter; advance to the next segment so the curve keeps climbing.
        if clampedRaw + 0.001 < lastRaw, segmentIndex < segmentCount - 1 {
            segmentIndex += 1
        }
        lastRaw = clampedRaw

        let base = Double(segmentIndex) * segmentWidth
        let mapped = min(1.0, base + segmentWidth * clampedRaw)
        peak = max(peak, mapped)
        return peak
    }
}

/// Thread-safe wrapper so a `MonotonicFractionMapper` can be driven from a
/// library progress callback that fires on an arbitrary queue (FluidAudio's
/// `ProgressHandler` is "called on an unspecified queue").
final class MonotonicFractionMapperBox: @unchecked Sendable {
    private let lock = NSLock()
    private var mapper: MonotonicFractionMapper

    init(segmentCount: Int) {
        self.mapper = MonotonicFractionMapper(segmentCount: segmentCount)
    }

    func map(_ raw: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return mapper.map(raw)
    }
}

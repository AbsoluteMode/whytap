import Foundation

/// Pure byte-level progress aggregator shared by the three on-device model
/// stores (LLM, STT, diarizer).
///
/// WHY this exists: the underlying HuggingFace download APIs report a coarse,
/// *file-count*-weighted fraction. A HF snapshot mixes a handful of tiny
/// config/tokenizer JSONs with one multi-GB weights shard, so a file-count
/// fraction leaps through the tiny files (e.g. straight to 57%) and then barely
/// moves for minutes while the big shard streams — "the percentages really
/// don't move". `swift-transformers`' `HubApi.snapshot` builds its parent
/// `Progress` with `totalUnitCount = filenames.count` (each file weight 1), and
/// FluidAudio's `AsrModels.download` re-runs its 0→1 reporter once per Core ML
/// model, sawtoothing the bar.
///
/// This type converts a running **downloaded-bytes** count against the known
/// **total bytes** into a fraction that advances proportionally to bytes
/// actually written — the real signal the user wants. It is monotonic (never
/// regresses on a transient dip) and clamped just below 1.0 so the bar never
/// reports a premature 100% before the model is actually loadable.
struct ModelDownloadByteProgress {
    /// Upper bound the reported fraction is clamped to. Staying below 1.0 means
    /// "all bytes on disk" never prematurely flips the UI to ready — readiness
    /// is decided separately by the store once load succeeds.
    static let ceiling: Double = 0.99

    private let totalBytes: Int64
    private let minimumStep: Double
    private var peakFraction: Double = 0
    private var lastEmitted: Double = 0

    /// - Parameters:
    ///   - totalBytes: sum of remote file sizes for the download. `<= 0` means
    ///     unknown — every update reports 0 so the caller can fall back to the
    ///     library-provided fraction.
    ///   - minimumStep: smallest fraction change that `updateIfChanged` will emit
    ///     (coalescing), e.g. 0.005 ≈ 0.5%. Does not affect `update`.
    init(totalBytes: Int64, minimumStep: Double = 0.005) {
        self.totalBytes = totalBytes
        self.minimumStep = minimumStep
    }

    /// Map a running downloaded-bytes count to a clamped, monotonic fraction.
    /// Always returns the current fraction (use `updateIfChanged` to throttle).
    mutating func update(downloadedBytes: Int64) -> Double {
        guard totalBytes > 0 else { return 0 }
        let raw = Double(max(0, downloadedBytes)) / Double(totalBytes)
        let clamped = min(Self.ceiling, max(0, raw))
        // Monotonic: a disk-size dip (temp file moved/replaced) or a library
        // re-report must never walk the bar backwards.
        peakFraction = max(peakFraction, clamped)
        lastEmitted = peakFraction
        return peakFraction
    }

    /// Like `update`, but returns `nil` when the change since the last *emitted*
    /// value is smaller than `minimumStep`, so the UI isn't spammed with
    /// sub-step churn while the bytes underneath stay real. Always emits once the
    /// ceiling is reached so the final step isn't swallowed.
    mutating func updateIfChanged(downloadedBytes: Int64) -> Double? {
        let previous = lastEmitted
        let fraction = update(downloadedBytes: downloadedBytes)
        let advanced = fraction - previous
        if advanced >= minimumStep || (fraction >= Self.ceiling && advanced > 0) {
            return fraction
        }
        // Roll back the emitted marker so accumulated sub-steps still count
        // toward the next threshold.
        lastEmitted = previous
        return nil
    }
}

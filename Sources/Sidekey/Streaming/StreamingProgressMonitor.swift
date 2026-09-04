import Foundation

/// Detects a half-open stream: audio is flowing out but no partial has come
/// back for `stallSeconds`. Pure (injected clock) so it's unit-testable;
/// a conservative threshold avoids false positives on merely-slow networks.
struct StreamingProgressMonitor {
    let stallSeconds: Double
    private let now: () -> Double
    private var firstAudioAt: Double?
    private var lastPartialAt: Double?

    init(stallSeconds: Double, now: @escaping () -> Double) {
        self.stallSeconds = stallSeconds
        self.now = now
    }

    mutating func noteAudioSent() { if firstAudioAt == nil { firstAudioAt = now() } }
    mutating func notePartial() { lastPartialAt = now() }

    func isStalled() -> Bool {
        guard let firstAudioAt else { return false }   // no audio yet → not stalled
        let lastProgress = lastPartialAt ?? firstAudioAt
        return now() - lastProgress >= stallSeconds
    }

    /// Seconds elapsed since the last partial (or since first audio, if no
    /// partial ever arrived). Returns `nil` if no audio has been sent yet
    /// (the session hasn't started flowing data so the clock hasn't started).
    /// Reads the same timestamp that `isStalled()` uses, so the two methods
    /// are always consistent.
    func secondsSinceLastProgress() -> Double? {
        guard let firstAudioAt else { return nil }
        let lastProgress = lastPartialAt ?? firstAudioAt
        return now() - lastProgress
    }
}

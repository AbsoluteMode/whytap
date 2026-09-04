import Foundation

/// Pure finishing-gate for the post-release audio tail.
///
/// Why this exists: the user releases the Drop hotkey while still
/// finishing the last word (motor anticipation, 100–400 ms), and
/// streaming ASR finalizes the tail poorly without right-context
/// silence. Cutting capture at keyUp therefore truncates/garbles the
/// last words. The engine keeps the tap alive after release and asks
/// this gate, per processed buffer, whether the tail is captured.
///
/// Decision rule after `beginFinish()`:
///   - fire `.silence` once the level stays below an adaptive threshold
///     for `silenceHoldMs` of CONSECUTIVE audio (the user finished the
///     word and the ASR gets its right context);
///   - fire `.maxTail` once `maxTailMs` of tail has accumulated
///     regardless of level (bounds the added latency; covers the user
///     who keeps talking and noisy rooms with a moving floor).
///
/// The threshold is `min(observed non-zero level so far) + floorDelta` —
/// a deliberately coarse per-session floor (`NoiseFloorEstimator` is
/// @MainActor and fed by the orb pipeline, so it cannot be used on the
/// audio thread; a rolling percentile is overkill for a <=450 ms
/// decision). Known limitations, both bounded by the max-tail guard:
/// exact-zero glitch frames are excluded from the floor (see observe());
/// a session whose quietest moment is still loud learns a high floor and
/// may read quiet trailing speech as silence.
///
/// Durations are sample-derived milliseconds supplied by the caller
/// (16 kHz → samples/16), NOT wall-clock — deterministic and testable.
///
/// Concurrency: not thread-safe; the owner serialises calls (the
/// engine uses its `chunkerQueue`, same contract as
/// `StreamingAudioChunker`).
struct StreamingFinishGate {
    enum FireReason: String {
        case silence
        case maxTail
    }

    /// Consecutive below-threshold audio required to fire `.silence`.
    /// ~140 ms: long enough to skip inter-word gaps (typically < 100 ms
    /// in fluent speech), short enough to be invisible under the
    /// `.transcribing` phase.
    let silenceHoldMs: Double
    /// Hard bound on the tail. 450 ms covers the longest plausible
    /// release-anticipation plus Bluetooth delivery latency; beyond it
    /// added latency hurts more than a clipped tail.
    let maxTailMs: Double
    /// Margin above the learned floor that still counts as silence.
    let floorDelta: Float

    private var floorEstimate: Float = 1.0
    private var finishing = false
    private var fired: FireReason?
    private var silenceRunMs: Double = 0
    private var tailMs: Double = 0

    init(
        silenceHoldMs: Double = 140,
        maxTailMs: Double = 450,
        floorDelta: Float = 0.06
    ) {
        self.silenceHoldMs = silenceHoldMs
        self.maxTailMs = maxTailMs
        self.floorDelta = floorDelta
    }

    /// Adaptive silence threshold: learned floor + delta. Internal so
    /// tests can pin the contract.
    var threshold: Float {
        floorEstimate + floorDelta
    }

    /// The hotkey was released: start accumulating the tail.
    ///
    /// Resets only the run counters — NOT `floorEstimate` (monotonic for
    /// the gate's lifetime; the factory builds a fresh engine+gate per
    /// session) and NOT `fired` (terminal by design — see observe()).
    /// An engine-reuse refactor would need a new gate instance, not a
    /// second beginFinish().
    mutating func beginFinish() {
        finishing = true
        silenceRunMs = 0
        tailMs = 0
    }

    /// Feed one processed buffer's level + duration. Returns a reason
    /// once the tail is complete; keeps returning it afterwards
    /// (terminal) so late tap callbacks racing the dispatched stop are
    /// harmless.
    mutating func observe(level: Float, durationMs: Double) -> FireReason? {
        // Exact-zero levels are glitch frames (AudioMeter.normalize collapses
        // silent/dropped buffers to 0.0): a single one would pin the running
        // min and freeze the threshold at floorDelta, turning the adaptive
        // gate into a fixed one. Learn the floor from real signal only.
        if level > 0 {
            floorEstimate = min(floorEstimate, level)
        }
        guard finishing else { return nil }
        if let fired { return fired }
        tailMs += durationMs
        if level < threshold {
            silenceRunMs += durationMs
        } else {
            silenceRunMs = 0
        }
        if silenceRunMs >= silenceHoldMs {
            fired = .silence
        } else if tailMs >= maxTailMs {
            fired = .maxTail
        }
        return fired
    }
}

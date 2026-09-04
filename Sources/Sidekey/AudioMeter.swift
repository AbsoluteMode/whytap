import Foundation

/// Pure-logic helpers for the audio level meter that drives the waveform UI.
enum AudioMeter {
    /// Number of recent normalized samples kept for waveform rendering.
    static let bufferSize = 32

    /// Convert `AVAudioRecorder.averagePower` (in dBFS, range ≈ -160..0) into
    /// a normalized [0..1] amplitude using a configurable noise floor.
    ///
    /// Non-finite inputs (`nan`, `±infinity`) collapse to 0 so a transient
    /// recorder hiccup never poisons the waveform buffer.
    static func normalize(dB: Float, floor: Float = -60) -> Float {
        guard dB.isFinite else { return 0 }
        let clamped = max(floor, min(0, dB))
        return (clamped - floor) / -floor
    }

    static func normalize(samples: [Float], floor: Float = -60) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for sample in samples {
            sumSquares += sample * sample
        }
        let meanSquare = sumSquares / Float(samples.count)
        let rms = sqrt(meanSquare)
        return normalize(dB: 20 * log10(rms), floor: floor)
    }
}

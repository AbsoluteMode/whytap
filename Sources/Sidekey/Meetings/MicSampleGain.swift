import Foundation

enum MicSampleGain {
    /// Matches the production microphone boost that fed the meeting recording
    /// indicator before the audio-only capture rewrite.
    static let defaultMultiplier: Float = 4.0

    static func applyDefault(to samples: [Float]) -> [Float] {
        apply(to: samples, gain: defaultMultiplier)
    }

    static func apply(to samples: [Float], gain: Float) -> [Float] {
        guard gain != 1 else { return samples }
        return samples.map { sample in
            max(-1.0, min(1.0, sample * gain))
        }
    }
}

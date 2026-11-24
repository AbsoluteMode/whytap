@testable import Sidekey
import XCTest

/// What the translation model hears: the system mix at 48 kHz, captured for
/// Subtitles at 24 kHz through the low-pass and the phase-keeping resampler,
/// in the 512-frame callbacks Core Audio delivers.
final class SubtitleCaptureAudioTests: XCTestCase {
    private let rate = 48_000.0

    private func tone(_ frequency: Double, seconds: Double = 2, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }

    /// The capture path Subtitles use, fed callback by callback.
    private func capture(_ samples: [Float], antiAlias: Bool = true, callback: Int = 512) -> [Float] {
        var filter = SystemAudioAntiAliasFilter(targetSampleRate: 24_000)
        var resampler = SystemAudioStreamingResampler(targetSampleRate: 24_000)
        var out: [Float] = []
        var start = 0
        while start < samples.count {
            let chunk = Array(samples[start..<min(start + callback, samples.count)])
            let filtered = antiAlias ? filter.process(chunk, sourceSampleRate: rate) : chunk
            out += resampler.process(filtered, sourceSampleRate: rate)
            start += callback
        }
        return out
    }

    /// Power of `frequency` in `samples` (24 kHz), by correlation over whole seconds.
    private func power(of frequency: Double, in samples: [Float]) -> Double {
        let window = samples[24_000..<48_000] // skip the filter's start
        var re = 0.0, im = 0.0
        for (index, sample) in window.enumerated() {
            let phase = 2 * .pi * frequency * Double(index) / 24_000
            re += Double(sample) * cos(phase); im += Double(sample) * sin(phase)
        }
        return (re * re + im * im) / Double(window.count * window.count)
    }

    /// A 14 kHz sound (above what 24 kHz can carry) must not come back as a
    /// 10 kHz one; without the low-pass it does, at full level.
    func testSoundAboveTheNewNyquistRateDoesNotFoldIntoTheBand() {
        let reference = power(of: 1_000, in: capture(tone(1_000)))
        let folded = power(of: 10_000, in: capture(tone(14_000)))
        let unfiltered = power(of: 10_000, in: capture(tone(14_000), antiAlias: false))
        XCTAssertLessThan(10 * log10(folded / reference), -40)
        XCTAssertGreaterThan(10 * log10(unfiltered / reference), -3, "the plain resampler folds it at full level")
    }

    /// Speech-band sound passes at unity gain, 16 samples (0.67 ms) late,
    /// without a seam at the callback boundaries.
    func testSpeechBandPassesCleanAcrossCallbacks() {
        let out = capture(tone(1_000))
        var error = 0.0, signal = 0.0
        for index in 2_400..<out.count {
            let expected = 0.5 * sin(2 * .pi * 1_000 * Double(index - 16) / 24_000)
            error += pow(Double(out[index]) - expected, 2); signal += expected * expected
        }
        XCTAssertLessThan(10 * log10(error / signal), -50)
    }

    /// Callbacks of any size give the same audio, and exactly half the
    /// samples: the model's clock never drifts from the video's.
    func testCallbackSizeChangesNothingAndNoSampleIsLost() {
        let input = tone(440, seconds: 1) + tone(3_000, seconds: 1)
        let small = capture(input, callback: 512)
        let odd = capture(input, callback: 333)
        XCTAssertEqual(Double(small.count), 48_000, accuracy: 1)
        XCTAssertEqual(odd.count, small.count)
        XCTAssertEqual(zip(small, odd).map { abs($0 - $1) }.max() ?? 1, 0, accuracy: 1e-5)
    }

    /// Capture already at or below the target rate (a headset in call mode)
    /// is passed on unchanged.
    func testCaptureAtOrBelowTheTargetRatePassesUnchanged() {
        var filter = SystemAudioAntiAliasFilter(targetSampleRate: 24_000)
        let samples: [Float] = [0.1, -0.2, 0.3, 0.05]
        XCTAssertEqual(filter.process(samples, sourceSampleRate: 16_000), samples)
        XCTAssertEqual(filter.process(samples, sourceSampleRate: 24_000), samples)
    }

    func testSubtitlesCaptureAtTheProvidersRate() {
        XCTAssertEqual(LiveSubtitleModel.captureSampleRate, 24_000)
    }
}

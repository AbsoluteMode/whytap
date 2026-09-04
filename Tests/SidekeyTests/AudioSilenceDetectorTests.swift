import XCTest
@testable import Sidekey

/// `AudioSilenceDetector` is the client-side guard that decides whether a
/// freshly-captured WAV recording is worth sending to the backend. The
/// intent is to absorb hot-key misfires — a fast tap-and-release of the
/// Agent (Right Cmd) or Drop (Option + /) gesture — without surfacing a
/// "Service temporarily unavailable" error to the user. The decision is
/// pure logic so it can be exercised without an actual recorder.
///
/// Two independent rules, OR-combined: a recording is dropped when EITHER
/// the gesture was too short to plausibly hold speech, OR the peak audio
/// energy across the buffer never crossed the voice noise gate (i.e. the
/// user held the gesture but never spoke into the mic). Either signal on
/// its own is enough — both signals firing is the typical misfire shape,
/// but a 5-second silent hold also has to be rejected.
final class AudioSilenceDetectorTests: XCTestCase {
    func testZeroDurationIsRejected() {
        let detector = AudioSilenceDetector()
        let result = detector.decide(durationSeconds: 0, peakEnergy: 0.5)
        XCTAssertEqual(result, .drop(.tooShort))
    }

    func testDurationBelowMinimumIsRejected() {
        let detector = AudioSilenceDetector()
        // 0.25s is well below the 0.4s minimum — typical quick-tap misfire.
        // Peak energy is intentionally above the noise gate to prove the
        // duration rule fires independently of the energy rule.
        let result = detector.decide(durationSeconds: 0.25, peakEnergy: 0.5)
        XCTAssertEqual(result, .drop(.tooShort))
    }

    func testDurationAtMinimumIsAccepted() {
        let detector = AudioSilenceDetector()
        // Boundary: exactly the configured minimum is accepted — the rule
        // is "strictly below" so the cutoff is unambiguous and a user
        // intentionally speaking a single short syllable around 0.4s does
        // not get dropped.
        let result = detector.decide(durationSeconds: 0.4, peakEnergy: 0.5)
        XCTAssertEqual(result, .proceed)
    }

    func testEnergyBelowGateIsRejected() {
        let detector = AudioSilenceDetector()
        // Long enough hold, but the user never spoke — peak across the
        // whole buffer stays below the noise gate. This is the
        // silence-only-recording branch.
        let result = detector.decide(durationSeconds: 5.0, peakEnergy: 0.01)
        XCTAssertEqual(result, .drop(.silenceOnly))
    }

    func testEnergyAtGateIsAccepted() {
        let detector = AudioSilenceDetector()
        // Boundary: a peak exactly at the gate is accepted. We want false
        // negatives (proceed-when-could-drop) instead of false positives
        // (drop-real-speech) — the gate is the floor of "noisy enough to
        // contain speech," so anything reaching it goes through.
        let result = detector.decide(durationSeconds: 1.0, peakEnergy: 0.04)
        XCTAssertEqual(result, .proceed)
    }

    func testLongHoldWithSpeechIsAccepted() {
        let detector = AudioSilenceDetector()
        let result = detector.decide(durationSeconds: 3.5, peakEnergy: 0.6)
        XCTAssertEqual(result, .proceed)
    }

    func testTooShortReasonWinsOverSilenceWhenBothFire() {
        let detector = AudioSilenceDetector()
        // Both rules fire on a tap-and-release on a mic that captured no
        // sound. The reported reason should be deterministic so the os_log
        // line is consistent for telemetry.
        let result = detector.decide(durationSeconds: 0.1, peakEnergy: 0.0)
        XCTAssertEqual(result, .drop(.tooShort))
    }

    func testNonFiniteEnergyTreatedAsSilence() {
        let detector = AudioSilenceDetector()
        // AVAudioRecorder.averagePower can return -inf / NaN on transient
        // hiccups; we feed normalized levels in but defend against the
        // pathological case so the guard never throws when the meter is
        // glitched.
        let result = detector.decide(durationSeconds: 2.0, peakEnergy: .nan)
        XCTAssertEqual(result, .drop(.silenceOnly))
    }
}

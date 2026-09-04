import XCTest
@testable import Sidekey

/// Unit tests for the pure finishing-gate logic. All durations are
/// sample-derived milliseconds fed explicitly — no clocks, no audio device.
final class StreamingFinishGateTests: XCTestCase {

    /// ~21 ms — the duration one 1024-frame tap buffer at 48 kHz yields
    /// after conversion to 16 kHz (340 samples ≈ 21.3 ms). Close enough
    /// for gate math; the gate only accumulates what it is told.
    private let tick: Double = 21.0

    /// Feed `count` observations of `level`, each `tick` ms long.
    /// Returns the first non-nil fire reason, if any.
    private func feed(
        _ gate: inout StreamingFinishGate,
        level: Float,
        count: Int
    ) -> StreamingFinishGate.FireReason? {
        for _ in 0..<count {
            if let reason = gate.observe(level: level, durationMs: tick) {
                return reason
            }
        }
        return nil
    }

    /// Before beginFinish() the gate never fires, no matter how much
    /// silence flows past — recording phase is open-ended by contract
    /// (hold-to-talk: the user controls the end).
    func testNeverFiresBeforeBeginFinish() {
        var gate = StreamingFinishGate()
        XCTAssertNil(feed(&gate, level: 0.01, count: 500))
    }

    /// Happy path: user genuinely finished speaking before release.
    /// Quiet-room floor learned during recording (0.02), speech at 0.5,
    /// then release → silence → fires .silence after >= silenceHoldMs.
    func testFiresOnSilenceAfterHold() {
        var gate = StreamingFinishGate()
        _ = feed(&gate, level: 0.02, count: 20) // pre-speech room tone
        _ = feed(&gate, level: 0.5, count: 50)  // speech
        gate.beginFinish()
        // 140 ms / 21 ms = 6.7 → fires on the 7th silent tick.
        var fired: StreamingFinishGate.FireReason?
        var ticks = 0
        while fired == nil && ticks < 20 {
            fired = gate.observe(level: 0.02, durationMs: tick)
            ticks += 1
        }
        XCTAssertEqual(fired, .silence)
        XCTAssertEqual(ticks, 7)
    }

    /// The motor-anticipation case this whole feature exists for: speech
    /// continues across the release. The gate must NOT fire while the
    /// level stays above threshold, then fire .silence once the word ends.
    func testSpeechAfterReleaseExtendsCapture() {
        var gate = StreamingFinishGate()
        _ = feed(&gate, level: 0.02, count: 20)
        _ = feed(&gate, level: 0.5, count: 50)
        gate.beginFinish()
        // 10 ticks (~210 ms) of continued speech: no fire.
        XCTAssertNil(feed(&gate, level: 0.5, count: 10))
        // Then silence: fires after the hold.
        XCTAssertEqual(feed(&gate, level: 0.02, count: 10), .silence)
    }

    /// A speech burst mid-tail resets the silence run: 3 silent ticks,
    /// then speech, then silence again — the hold restarts from zero.
    func testSpeechResetsSilenceRun() {
        var gate = StreamingFinishGate()
        _ = feed(&gate, level: 0.02, count: 20)
        _ = feed(&gate, level: 0.5, count: 50)
        gate.beginFinish()
        XCTAssertNil(feed(&gate, level: 0.02, count: 3))  // 63 ms silence
        XCTAssertNil(feed(&gate, level: 0.5, count: 2))   // speech burst
        XCTAssertNil(feed(&gate, level: 0.02, count: 6))  // 126 ms — still short
        XCTAssertEqual(feed(&gate, level: 0.02, count: 1), .silence)
    }

    /// Continuous loud input after release (user keeps talking, or loud
    /// environment above the learned floor): the max guard bounds the tail.
    /// 450 ms / 21 ms = 21.4 → fires .maxTail on the 22nd tick.
    func testMaxTailBoundsContinuedSpeech() {
        var gate = StreamingFinishGate()
        _ = feed(&gate, level: 0.02, count: 20) // low floor learned
        _ = feed(&gate, level: 0.5, count: 50)
        gate.beginFinish()
        let reason = feed(&gate, level: 0.5, count: 30)
        XCTAssertEqual(reason, .maxTail)
    }

    /// Constant ambient noise for the whole session: the floor estimate
    /// equals the noise level, so post-release the same level reads as
    /// "no speech" and the gate fires .silence (NOT .maxTail) — adaptive
    /// gating treats steady background as silence.
    func testSteadyNoiseFloorReadsAsSilence() {
        var gate = StreamingFinishGate()
        _ = feed(&gate, level: 0.3, count: 100) // noisy room, no quiet frames
        gate.beginFinish()
        XCTAssertEqual(feed(&gate, level: 0.3, count: 10), .silence)
    }

    /// A single zero-level glitch frame (mic mute, dropped buffer, BT route
    /// change — AudioMeter.normalize collapses those to exactly 0.0) must
    /// NOT pin the learned floor: steady room noise afterwards still reads
    /// as the floor and fires .silence, not .maxTail.
    func testZeroLevelGlitchDoesNotPinFloor() {
        var gate = StreamingFinishGate()
        _ = feed(&gate, level: 0.3, count: 50)        // noisy room
        _ = gate.observe(level: 0.0, durationMs: tick) // glitch frame
        _ = feed(&gate, level: 0.3, count: 50)
        gate.beginFinish()
        XCTAssertEqual(feed(&gate, level: 0.3, count: 10), .silence)
    }

    /// Threshold contract: floor ~0 → threshold == floorDelta; the
    /// threshold tracks the learned floor + delta. The near-zero case
    /// feeds a tiny non-zero level because exact 0.0 is a glitch frame
    /// and excluded from floor learning (see
    /// testZeroLevelGlitchDoesNotPinFloor).
    func testThresholdTracksLearnedFloor() {
        var gate = StreamingFinishGate()
        _ = gate.observe(level: 0.000001, durationMs: tick)
        XCTAssertEqual(gate.threshold, gate.floorDelta, accuracy: 0.0001)
        var gate2 = StreamingFinishGate()
        _ = gate2.observe(level: 0.2, durationMs: tick)
        XCTAssertEqual(gate2.threshold, 0.2 + gate2.floorDelta, accuracy: 0.0001)
    }

    /// After a fire the gate keeps returning a reason for subsequent
    /// observations (idempotent terminal state) — the engine may receive
    /// a few more tap callbacks before the dispatched stop() lands.
    func testStaysFiredAfterFire() {
        var gate = StreamingFinishGate()
        gate.beginFinish()
        _ = feed(&gate, level: 0.0, count: 10) // fires .silence inside
        XCTAssertNotNil(gate.observe(level: 0.0, durationMs: tick))
    }

    /// beginFinish() after a fire must not resurrect the gate: the fired
    /// state is terminal by design (the engine's failsafe timer and the
    /// gate fire race; a second begin must not restart the tail).
    func testBeginFinishAfterFireStaysTerminal() {
        var gate = StreamingFinishGate()
        gate.beginFinish()
        _ = feed(&gate, level: 0.0, count: 10) // fires .silence inside
        gate.beginFinish()
        XCTAssertEqual(gate.observe(level: 0.0, durationMs: tick), .silence)
    }
}

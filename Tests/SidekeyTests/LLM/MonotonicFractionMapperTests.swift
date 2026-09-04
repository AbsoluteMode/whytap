import XCTest
@testable import Sidekey

/// FluidAudio's `AsrModels.download` re-runs its 0→1 progress reporter once per
/// Core ML model (preprocessor, decoder, joint…), so the raw fraction sawtooths
/// 0→1, 0→1, 0→1 — the bar visibly jumps backwards between models. The diarizer
/// reports a single 0→1 but with a coarse 0.5→1.0 compile leap. The library
/// fraction itself is byte-weighted *within* each pass, so it is the real
/// signal; it just needs to be stitched into one forward-only curve.
///
/// `MonotonicFractionMapper` maps that stream into a single non-regressing
/// fraction across a known number of segments.
final class MonotonicFractionMapperTests: XCTestCase {

    /// Two segments (two model passes). Each pass runs the library fraction 0→1.
    /// The mapped fraction must occupy 0→0.5 for the first pass and 0.5→1.0 for
    /// the second, and must never jump back to ~0 when the second pass restarts.
    func testPerSegmentResetsBecomeOneForwardCurve() {
        var mapper = MonotonicFractionMapper(segmentCount: 2)

        // First model pass.
        XCTAssertEqual(mapper.map(0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(mapper.map(0.5), 0.25, accuracy: 0.0001)
        XCTAssertEqual(mapper.map(1.0), 0.5, accuracy: 0.0001)

        // Second pass restarts the library fraction at 0 — but the bar must not
        // regress; it continues from the segment boundary.
        let restart = mapper.map(0.0)
        XCTAssertGreaterThanOrEqual(restart, 0.5)
        XCTAssertEqual(mapper.map(0.5), 0.75, accuracy: 0.0001)
        XCTAssertEqual(mapper.map(1.0), 1.0, accuracy: 0.0001)
    }

    /// A dip inside a single segment (library re-reports a lower value) must not
    /// walk the bar backwards.
    func testMonotonicWithinSegment() {
        var mapper = MonotonicFractionMapper(segmentCount: 1)

        XCTAssertEqual(mapper.map(0.6), 0.6, accuracy: 0.0001)
        XCTAssertEqual(mapper.map(0.4), 0.6, accuracy: 0.0001, "dip must not regress")
        XCTAssertEqual(mapper.map(0.7), 0.7, accuracy: 0.0001)
    }

    /// A single segment is the identity mapping (used by the diarizer, which
    /// reports one continuous 0→1).
    func testSingleSegmentIsIdentityButMonotonic() {
        var mapper = MonotonicFractionMapper(segmentCount: 1)

        XCTAssertEqual(mapper.map(0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(mapper.map(0.33), 0.33, accuracy: 0.0001)
        XCTAssertEqual(mapper.map(1.0), 1.0, accuracy: 0.0001)
    }

    /// Out-of-range inputs are clamped so a misbehaving library can't drive the
    /// bar past its segment or below zero.
    func testInputsAreClamped() {
        var mapper = MonotonicFractionMapper(segmentCount: 2)

        XCTAssertEqual(mapper.map(-0.5), 0.0, accuracy: 0.0001)
        XCTAssertEqual(mapper.map(2.0), 0.5, accuracy: 0.0001, "first segment capped at boundary")
    }
}

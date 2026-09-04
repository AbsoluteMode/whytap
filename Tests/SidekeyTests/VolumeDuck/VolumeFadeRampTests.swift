import XCTest
@testable import Sidekey

final class VolumeFadeRampTests: XCTestCase {
    func test_endpointsAndMidpoint() {
        let ramp = VolumeFadeRamp(from: 0.8, to: 0.28, duration: 1.2)
        XCTAssertEqual(ramp.volume(at: 0), 0.8, accuracy: 0.0001)
        XCTAssertEqual(ramp.volume(at: 1.2), 0.28, accuracy: 0.0001)
        XCTAssertEqual(ramp.volume(at: 0.6), 0.54, accuracy: 0.001)   // halfway
    }

    func test_clampsBeyondRange_andZeroDuration() {
        let ramp = VolumeFadeRamp(from: 0.8, to: 0.28, duration: 1.2)
        XCTAssertEqual(ramp.volume(at: -1), 0.8, accuracy: 0.0001)    // before start
        XCTAssertEqual(ramp.volume(at: 9), 0.28, accuracy: 0.0001)    // past end
        XCTAssertEqual(VolumeFadeRamp(from: 0.8, to: 0.28, duration: 0).volume(at: 0),
                       0.28, accuracy: 0.0001)                        // zero duration snaps
    }
}

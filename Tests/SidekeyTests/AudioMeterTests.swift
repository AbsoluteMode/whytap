import XCTest
@testable import Sidekey

final class AudioMeterTests: XCTestCase {
    func testNormalizeAtFloorIsZero() {
        XCTAssertEqual(AudioMeter.normalize(dB: -60), 0, accuracy: 1e-6)
    }

    func testNormalizeAtCeilingIsOne() {
        XCTAssertEqual(AudioMeter.normalize(dB: 0), 1, accuracy: 1e-6)
    }

    func testNormalizeMidpointIsHalf() {
        XCTAssertEqual(AudioMeter.normalize(dB: -30), 0.5, accuracy: 1e-6)
    }

    func testNormalizeBelowFloorClampsToZero() {
        XCTAssertEqual(AudioMeter.normalize(dB: -200), 0, accuracy: 1e-6)
    }

    func testNormalizeAboveCeilingClampsToOne() {
        XCTAssertEqual(AudioMeter.normalize(dB: 10), 1, accuracy: 1e-6)
    }

    func testNormalizeNanReturnsZero() {
        XCTAssertEqual(AudioMeter.normalize(dB: .nan), 0, accuracy: 1e-6)
    }

    func testNormalizeNegativeInfinityReturnsZero() {
        XCTAssertEqual(AudioMeter.normalize(dB: -.infinity), 0, accuracy: 1e-6)
    }

    func testNormalizeCustomFloor() {
        // -40 dB floor: -20 dB should map to 0.5
        XCTAssertEqual(AudioMeter.normalize(dB: -20, floor: -40), 0.5, accuracy: 1e-6)
    }
}

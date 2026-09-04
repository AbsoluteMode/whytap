import XCTest
@testable import Sidekey

final class MicSampleGainTests: XCTestCase {
    func testDefaultGainRestoresProductionMicLevelAndClamps() {
        let boosted = MicSampleGain.applyDefault(to: [0.05, -0.2, 0.4, -0.5])

        XCTAssertEqual(boosted, [0.2, -0.8, 1.0, -1.0])
    }
}

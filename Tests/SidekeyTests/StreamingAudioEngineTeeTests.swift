import XCTest
@testable import Sidekey

final class StreamingAudioEngineTeeTests: XCTestCase {
    func testAccumulateMirrorsYieldedChunks() {
        let engine = StreamingAudioEngine()
        engine.accumulate(Data([1, 2, 3]))
        engine.accumulate(Data([4, 5]))
        XCTAssertEqual(engine.capturedPCM16(), Data([1, 2, 3, 4, 5]))
    }
}

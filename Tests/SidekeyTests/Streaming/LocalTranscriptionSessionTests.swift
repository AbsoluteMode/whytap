import XCTest
import FluidAudio
@testable import Sidekey

final class LocalTranscriptionSessionTests: XCTestCase {
    func testPCM16LittleEndianConversion() {
        let data = Data([
            0x00, 0x00,  // 0
            0xff, 0x7f,  // Int16.max
            0x01, 0x80,  // -Int16.max
        ])

        let samples = LocalTranscriptionSession.floatSamples(fromPCM16LittleEndian: data)

        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0], 0, accuracy: 0.0001)
        XCTAssertEqual(samples[1], 1, accuracy: 0.0001)
        XCTAssertEqual(samples[2], -1, accuracy: 0.0001)
    }

    func testFluidLanguageMapsRegionCode() {
        XCTAssertEqual(LocalTranscriptionSession.fluidLanguage(from: "en-US"), .english)
        XCTAssertEqual(LocalTranscriptionSession.fluidLanguage(from: "ru"), .russian)
    }

    func testFluidLanguageFallsBackToNilWhenUnsupportedByParakeetFilter() {
        XCTAssertNil(LocalTranscriptionSession.fluidLanguage(from: "zh"))
        XCTAssertNil(LocalTranscriptionSession.fluidLanguage(from: nil))
    }
}

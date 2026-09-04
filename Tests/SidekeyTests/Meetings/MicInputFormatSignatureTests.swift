import AVFoundation
import XCTest
@testable import Sidekey

final class MicInputFormatSignatureTests: XCTestCase {
    func test_signatureChangesWhenSampleRateChanges() throws {
        let fortyEight = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let sixteen = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))

        XCTAssertNotEqual(
            MicInputFormatSignature(format: fortyEight),
            MicInputFormatSignature(format: sixteen)
        )
    }

    func test_signatureIsStableForEquivalentFormats() throws {
        let first = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let second = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        XCTAssertEqual(
            MicInputFormatSignature(format: first),
            MicInputFormatSignature(format: second)
        )
    }

    func test_signatureChangesWhenChannelCountChanges() throws {
        let mono = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let stereo = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))

        XCTAssertNotEqual(
            MicInputFormatSignature(format: mono),
            MicInputFormatSignature(format: stereo)
        )
    }
}

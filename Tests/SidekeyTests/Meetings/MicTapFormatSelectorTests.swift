import AVFoundation
import XCTest
@testable import Sidekey

final class MicTapFormatSelectorTests: XCTestCase {
    func test_prefersHardwareInputFormatWhenOutputFormatIsStale() throws {
        let hardwareInput = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let staleOutput = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))

        let selected = MicTapFormatSelector.preferredTapFormat(
            inputFormat: hardwareInput,
            outputFormat: staleOutput
        )

        XCTAssertEqual(selected?.sampleRate, 44_100)
        XCTAssertEqual(selected?.channelCount, 1)
    }

    func test_returnsNilWhenNeitherFormatCanCarryAudio() {
        let emptyInput = AVAudioFormat()
        let emptyOutput = AVAudioFormat()

        XCTAssertNil(MicTapFormatSelector.preferredTapFormat(
            inputFormat: emptyInput,
            outputFormat: emptyOutput
        ))
    }
}

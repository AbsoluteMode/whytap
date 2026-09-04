import XCTest
@testable import Sidekey

final class TurnAudioBufferTests: XCTestCase {
    func testAppendAccumulatesAndSnapshots() {
        let buf = TurnAudioBuffer()
        XCTAssertTrue(buf.isEmpty)
        buf.append(Data([1, 2]))
        buf.append(Data([3, 4]))
        XCTAssertEqual(buf.snapshotPCM16(), Data([1, 2, 3, 4]))
        XCTAssertEqual(buf.byteCount, 4)
    }

    func testCapStopsAppendingPastLimit() {
        let buf = TurnAudioBuffer(maxBytes: 3)
        buf.append(Data([1, 2]))
        buf.append(Data([3, 4]))           // would exceed 3 → dropped whole chunk
        XCTAssertEqual(buf.snapshotPCM16(), Data([1, 2]))
        XCTAssertTrue(buf.didReachCap)
    }

    func testResetClearsPCMAndCapFlag() {
        let buf = TurnAudioBuffer(maxBytes: 3)
        buf.append(Data([1, 2]))
        buf.append(Data([3, 4]))   // hits cap
        XCTAssertTrue(buf.didReachCap)
        buf.reset()
        XCTAssertTrue(buf.isEmpty)
        XCTAssertFalse(buf.didReachCap)
        buf.append(Data([5, 6]))   // must work after reset
        XCTAssertEqual(buf.byteCount, 2)
    }

    func testWavHeaderIsWellFormed() {
        let pcm = Data(repeating: 0, count: 320)   // 10 ms @ 16 kHz mono PCM16
        let wav = TurnAudioBuffer.wav(fromPCM16: pcm, sampleRate: 16_000, channels: 1)
        XCTAssertEqual(wav.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(wav.subdata(in: 8..<12), Data("WAVE".utf8))
        let riffSize = wav.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(riffSize), 36 + pcm.count)
        let dataLen = wav.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        XCTAssertEqual(Int(dataLen), pcm.count)
        XCTAssertEqual(wav.count, 44 + pcm.count)   // 44-byte canonical header
    }
}

import XCTest
@testable import Sidekey

/// Pure-logic tests for the streaming audio chunker that converts incoming
/// 16 kHz Float32 mono samples into Soniox-shaped PCM16 chunks of a fixed
/// byte budget (~120 ms = 3840 bytes = 1920 Int16 samples).
///
/// The chunker is split out from `StreamingAudioEngine` so it can be unit
/// tested without an `AVAudioEngine` (the engine needs a mic and TCC grant
/// to run inside the test bundle — not viable on CI). The engine wires the
/// tap → converter → this chunker.
final class StreamingAudioChunkerTests: XCTestCase {

    /// Sanity: a feed smaller than the chunk size produces no output yet.
    func testSmallFeedBuffersUntilChunkSizeReached() {
        var chunker = StreamingAudioChunker(chunkSampleCount: 1920)
        let chunks = chunker.feed(samples: Array(repeating: Float(0.5), count: 100))
        XCTAssertTrue(chunks.isEmpty)
    }

    /// Exactly one chunk worth of samples produces exactly one PCM16
    /// chunk of the configured byte size.
    func testFeedingChunkSizeProducesOneChunkOfCorrectByteSize() {
        var chunker = StreamingAudioChunker(chunkSampleCount: 1920)
        let chunks = chunker.feed(samples: Array(repeating: Float(0.5), count: 1920))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 1920 * 2)
    }

    /// More samples than fit in one chunk produce multiple full chunks
    /// while the remainder stays buffered for the next feed.
    func testMultipleChunksProducedWhenSampleSurplus() {
        var chunker = StreamingAudioChunker(chunkSampleCount: 1920)
        let chunks = chunker.feed(samples: Array(repeating: Float(0.5), count: 1920 * 2 + 100))
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 1920 * 2)
        XCTAssertEqual(chunks[1].count, 1920 * 2)
    }

    /// PCM16 conversion: 0.0 → 0, 1.0 → Int16.max, -1.0 → -Int16.max.
    /// Verifies that the chunk bytes parse back to the expected Int16 values.
    func testFloatToInt16Conversion() {
        var chunker = StreamingAudioChunker(chunkSampleCount: 4)
        let mid = Array(repeating: Float(0.0), count: 1)
        let one = Array(repeating: Float(1.0), count: 1)
        let negOne = Array(repeating: Float(-1.0), count: 1)
        let half = Array(repeating: Float(0.5), count: 1)
        let chunks = chunker.feed(samples: mid + one + negOne + half)
        XCTAssertEqual(chunks.count, 1)
        let bytes = chunks[0]
        // Little-endian Int16 decode
        func i16(_ off: Int) -> Int16 {
            return Int16(bytes[off]) | (Int16(bytes[off + 1]) << 8)
        }
        XCTAssertEqual(i16(0), 0)
        XCTAssertEqual(i16(2), Int16.max)
        XCTAssertEqual(i16(4), -Int16.max)
        XCTAssertEqual(i16(6), Int16(0.5 * Float(Int16.max)))
    }

    /// Out-of-range floats (e.g. clipping from a boosted input) are
    /// clamped to ±1.0 before conversion to keep Int16 saturated.
    func testFloatClampsBeyondRange() {
        var chunker = StreamingAudioChunker(chunkSampleCount: 2)
        let chunks = chunker.feed(samples: [Float(2.0), Float(-2.0)])
        XCTAssertEqual(chunks.count, 1)
        let bytes = chunks[0]
        func i16(_ off: Int) -> Int16 {
            return Int16(bytes[off]) | (Int16(bytes[off + 1]) << 8)
        }
        XCTAssertEqual(i16(0), Int16.max)
        XCTAssertEqual(i16(2), -Int16.max)
    }

    /// `drain()` flushes any partial buffered samples as a final (possibly
    /// short) chunk — used at end-of-stream so no audio is lost.
    func testDrainEmitsResidualSamples() {
        var chunker = StreamingAudioChunker(chunkSampleCount: 1920)
        _ = chunker.feed(samples: Array(repeating: Float(0.5), count: 100))
        let residual = chunker.drain()
        XCTAssertEqual(residual?.count, 200) // 100 samples * 2 bytes
    }

    func testDrainAfterChunkBoundaryReturnsNilWhenEmpty() {
        var chunker = StreamingAudioChunker(chunkSampleCount: 1920)
        _ = chunker.feed(samples: Array(repeating: Float(0.5), count: 1920))
        XCTAssertNil(chunker.drain())
    }
}

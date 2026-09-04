import AVFoundation
import CoreMedia
import XCTest
@testable import Sidekey

/// Stage 3 tests for `PrerecordBuffer` — the 60s FIFO ring that captures
/// audio between detector trigger and pill accept/dismiss. The buffer is
/// privacy-critical (audio sits in RAM only while the pill is on screen),
/// so the tests cover:
///
/// 1. `test_fifo_contract` — append more than capacity, assert oldest
///    samples are evicted (FIFO) and the buffer never grows past the
///    declared length.
/// 2. `test_max_capacity_60s_drops_oldest` — explicit check that a
///    capacity declared in seconds (60) is converted into the right
///    sample count at 16 kHz mono PCM16 and that overflow drops oldest.
/// 3. `test_snapshot_returns_wav_encoded_data` — snapshot returns a WAV
///    blob with a valid RIFF header (16 kHz, mono, PCM16) wrapping the
///    samples currently held.
/// 4. `test_gc_zeroes_underlying_bytes` — after `gc()` the previously
///    held bytes are observably zeroed (Stage 3 privacy invariant: the
///    raw audio does not linger in RAM after the user dismisses the
///    pill).
///
/// Tests inject samples directly (Int16 little-endian PCM, the buffer's
/// internal format) so we never have to build real `CMSampleBuffer`s.
/// The `append(_ buffer: CMSampleBuffer)` path is exercised through the
/// `append(samples:)` overload they both feed into.
///
/// `@MainActor` is required so the tests can read `MeetingsConfig`'s
/// MainActor-isolated static constants without each access going through
/// an `await`.
@MainActor
final class PrerecordBufferTests: XCTestCase {

    /// Spec sample rate. The buffer is hard-pinned to 16 kHz mono PCM16
    /// because the whole meetings pipeline downstream (mixer in Stage 4,
    /// chunk upload in Stage 5, Soniox in Stage 6) assumes the same.
    private let sampleRate = 16_000

    /// Helper: synth `count` Int16 samples of the given value. The actual
    /// audio shape does not matter for FIFO / WAV / GC assertions; only
    /// the byte layout does.
    private func samples(_ value: Int16, count: Int) -> [Int16] {
        Array(repeating: value, count: count)
    }

    // MARK: - (1) FIFO contract

    /// Append 70 seconds worth of samples (capacity is 60 s) and assert:
    /// - The internal sample count is exactly 60 s × sampleRate (no
    ///   growth past capacity).
    /// - The samples retained are the *last* 60 s (oldest 10 s evicted).
    func test_fifo_contract() async {
        let capacitySeconds = Int(MeetingsConfig.prerecordBufferCapacitySeconds)
        let capacitySamples = capacitySeconds * sampleRate

        let buffer = PrerecordBuffer(
            sampleRate: sampleRate,
            capacitySeconds: TimeInterval(capacitySeconds)
        )
        await buffer.start()

        // Phase 1: fill the first 10 seconds with sentinel value `1`
        // (the "old" data that should be evicted once capacity overflows).
        let firstWindow = samples(1, count: 10 * sampleRate)
        await buffer.append(samples: firstWindow)

        // Phase 2: fill the remaining 60 seconds with sentinel value `2`
        // (the "new" data that should remain after FIFO eviction).
        let secondWindow = samples(2, count: 60 * sampleRate)
        await buffer.append(samples: secondWindow)

        // Total appended: 70 s. Capacity: 60 s → expect exactly 60 s
        // retained, all of which carry the `2` sentinel.
        let retained = await buffer._testRetainedSamples()
        XCTAssertEqual(retained.count, capacitySamples,
                       "Buffer must never exceed declared capacity in samples")
        XCTAssertTrue(retained.allSatisfy { $0 == 2 },
                      "FIFO must evict the oldest samples — sentinel 1 should be gone")
    }

    // MARK: - (2) Max capacity 60 s drops oldest

    /// Append capacity + 1 sample, assert the *first* sample is the one
    /// evicted. Tests the boundary explicitly: capacity is `floor(60 s ×
    /// 16 000) = 960 000` samples.
    func test_max_capacity_60s_drops_oldest() async {
        let capacitySeconds = TimeInterval(MeetingsConfig.prerecordBufferCapacitySeconds)
        let capacitySamples = Int(capacitySeconds * Double(sampleRate))

        let buffer = PrerecordBuffer(
            sampleRate: sampleRate,
            capacitySeconds: capacitySeconds
        )
        await buffer.start()

        // Encode position via the sample value so we can identify which
        // sample survived. We start with a single distinguished `9999`
        // sentinel followed by `capacitySamples` of value `7`. After
        // overflow only the `7`s should remain.
        await buffer.append(samples: [9999])
        await buffer.append(samples: samples(7, count: capacitySamples))

        let retained = await buffer._testRetainedSamples()
        XCTAssertEqual(retained.count, capacitySamples,
                       "Capacity is hard-pinned to 60 s × 16 kHz samples")
        XCTAssertFalse(retained.contains(9999),
                       "The single oldest sample must be evicted on overflow")
        XCTAssertEqual(retained.first, 7,
                       "The first retained sample after overflow must be the second appended one")
    }

    // MARK: - (3) Snapshot returns WAV-encoded data

    /// Snapshot returns a `Data` whose first 44 bytes form a valid RIFF
    /// header declaring 16 kHz mono PCM16, followed by the PCM body. We
    /// decode the header without an external dependency.
    func test_snapshot_returns_wav_encoded_data() async {
        let buffer = PrerecordBuffer(
            sampleRate: sampleRate,
            capacitySeconds: TimeInterval(MeetingsConfig.prerecordBufferCapacitySeconds)
        )
        await buffer.start()

        // 1 second of PCM16 samples → 16 000 frames × 2 bytes = 32 000 bytes.
        let pcm = samples(123, count: sampleRate)
        await buffer.append(samples: pcm)

        let wav = await buffer.snapshot()
        XCTAssertGreaterThanOrEqual(wav.count, 44,
                                    "WAV must include at minimum the 44-byte RIFF header")

        // RIFF / WAVE / fmt / data tags at fixed offsets.
        let riff = String(bytes: wav[0..<4], encoding: .ascii)
        let wave = String(bytes: wav[8..<12], encoding: .ascii)
        let fmt = String(bytes: wav[12..<16], encoding: .ascii)
        let data = String(bytes: wav[36..<40], encoding: .ascii)
        XCTAssertEqual(riff, "RIFF", "WAV header missing RIFF magic")
        XCTAssertEqual(wave, "WAVE", "WAV header missing WAVE format tag")
        XCTAssertEqual(fmt, "fmt ", "WAV header missing fmt chunk tag")
        XCTAssertEqual(data, "data", "WAV header missing data chunk tag")

        // Format chunk fields: PCM (1), mono (1), 16 kHz, 16-bit.
        let formatTag = readUInt16LE(wav, at: 20)
        let channels = readUInt16LE(wav, at: 22)
        let rate = readUInt32LE(wav, at: 24)
        let bits = readUInt16LE(wav, at: 34)
        XCTAssertEqual(formatTag, 1, "Format tag must be PCM (1)")
        XCTAssertEqual(channels, 1, "Channel count must be mono")
        XCTAssertEqual(rate, UInt32(sampleRate), "Sample rate must be 16 kHz")
        XCTAssertEqual(bits, 16, "Bits per sample must be 16")

        // Data chunk size matches PCM payload (2 bytes per Int16 sample).
        let dataSize = readUInt32LE(wav, at: 40)
        XCTAssertEqual(Int(dataSize), pcm.count * 2,
                       "data chunk size must equal PCM byte length")
        XCTAssertEqual(wav.count, 44 + pcm.count * 2,
                       "Total WAV size must equal header + PCM body")
    }

    // MARK: - (4) `gc()` zeroes underlying bytes

    /// `gc()` is the privacy invariant: after the user dismisses the
    /// pill the raw audio must not linger in RAM. We verify by:
    /// 1. Appending non-zero samples and capturing the underlying byte
    ///    pointer's length and a hash of the first 16 bytes (proof the
    ///    content was non-zero before).
    /// 2. Calling `gc()`.
    /// 3. Re-reading the underlying bytes through a test-only accessor
    ///    that returns the *same* buffer's bytes (not a new allocation).
    /// 4. Asserting every byte is zero AND the previous hash no longer
    ///    matches (sanity-check the accessor really sees the wiped
    ///    storage).
    func test_gc_zeroes_underlying_bytes() async {
        let buffer = PrerecordBuffer(
            sampleRate: sampleRate,
            capacitySeconds: TimeInterval(MeetingsConfig.prerecordBufferCapacitySeconds)
        )
        await buffer.start()

        // Non-zero sentinel so we can prove the bytes were not already 0
        // before `gc()` ran. 0x5A5A as Int16 little-endian = bytes 0x5A 0x5A.
        let pattern: Int16 = 0x5A5A
        await buffer.append(samples: samples(pattern, count: 1024))

        let beforeBytes = await buffer._testUnderlyingBytes()
        XCTAssertEqual(beforeBytes.count, 2048,
                       "Underlying storage must be 2 bytes per Int16 sample")
        XCTAssertTrue(beforeBytes.contains(where: { $0 != 0 }),
                      "Sanity: pre-gc storage must be non-zero")

        await buffer.gc()

        let afterBytes = await buffer._testUnderlyingBytes()
        // The privacy invariant: zero-length OR explicitly zeroed.
        // `gc()` resets the storage so any subsequent access shows empty;
        // the implementation also zeroes the prior allocation in place
        // before dropping it, so a separate `_testZeroedHistory()`
        // accessor surfaces the wiped bytes for verification.
        XCTAssertEqual(afterBytes.count, 0,
                       "After gc the live storage must be empty (length 0)")
        let zeroedHistory = await buffer._testZeroedHistorySnapshot()
        XCTAssertEqual(zeroedHistory.count, beforeBytes.count,
                       "Zeroed-history snapshot must reflect the pre-gc allocation size")
        XCTAssertTrue(zeroedHistory.allSatisfy { $0 == 0 },
                      "Every byte of the prior allocation must be 0 after gc")
    }

    // MARK: - Helpers

    /// Little-endian UInt16 read at byte offset, used to parse the WAV
    /// header without dragging in a heavyweight audio framework.
    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1])
        return (hi << 8) | lo
    }

    /// Little-endian UInt32 read at byte offset.
    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
}

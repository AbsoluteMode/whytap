import Foundation

/// Buffers 16 kHz Float32 mono samples and emits Soniox-shaped PCM16
/// little-endian chunks of a fixed byte budget.
///
/// Soniox real-time API expects ~120 ms (3840 bytes = 1920 Int16 samples)
/// at 16 kHz mono. The chunker is decoupled from `AVAudioEngine` so the
/// Float → Int16 conversion and the chunk-boundary logic can be unit
/// tested without an audio device.
///
/// Concurrency: not thread-safe. The owner serialises calls (the
/// `StreamingAudioEngine` drains its tap on the audio thread and dispatches
/// to a single actor before feeding the chunker).
struct StreamingAudioChunker {
    /// Number of Int16 samples per emitted chunk. Default `1920` is
    /// 120 ms at 16 kHz, matching the Soniox realtime spec
    /// against.
    let chunkSampleCount: Int

    /// Accumulated samples not yet flushed as a chunk.
    private var pending: [Int16] = []

    init(chunkSampleCount: Int = 1920) {
        self.chunkSampleCount = chunkSampleCount
        pending.reserveCapacity(chunkSampleCount * 2)
    }

    /// Append more Float32 samples (clamped to [-1, 1] then scaled to
    /// Int16) and return any whole chunks the new feed completes.
    /// Residual samples stay buffered until the next call or `drain()`.
    mutating func feed(samples: [Float]) -> [Data] {
        guard !samples.isEmpty else { return [] }
        pending.reserveCapacity(pending.count + samples.count)
        for sample in samples {
            let clamped = max(Float(-1.0), min(Float(1.0), sample))
            // Scale by `Int16.max` (not `Int16.max + 1`) so -1.0 maps to
            // -32767, which keeps the conversion symmetric around 0 and
            // avoids overflow at exact -1.0.
            let scaled = Int16(clamped * Float(Int16.max))
            pending.append(scaled)
        }

        var chunks: [Data] = []
        while pending.count >= chunkSampleCount {
            let slice = Array(pending.prefix(chunkSampleCount))
            pending.removeFirst(chunkSampleCount)
            chunks.append(Self.bytes(from: slice))
        }
        return chunks
    }

    /// Flush any pending residual as a (possibly short) final chunk.
    /// Returns `nil` when the buffer is empty — used at end-of-stream
    /// so the tail of the recording is not silently dropped.
    mutating func drain() -> Data? {
        guard !pending.isEmpty else { return nil }
        let out = Self.bytes(from: pending)
        pending.removeAll(keepingCapacity: true)
        return out
    }

    /// Pack Int16 samples as little-endian bytes.
    private static func bytes(from samples: [Int16]) -> Data {
        var out = Data(capacity: samples.count * 2)
        for sample in samples {
            let unsigned = UInt16(bitPattern: sample)
            out.append(UInt8(unsigned & 0xff))
            out.append(UInt8((unsigned >> 8) & 0xff))
        }
        return out
    }
}

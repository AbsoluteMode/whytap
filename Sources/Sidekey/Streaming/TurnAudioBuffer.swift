import Foundation
import os.lock

/// Per-turn accumulator of the exact PCM16 bytes the mic produced, so a
/// degraded live stream can be recovered by re-transcribing the full audio
/// with the on-device batch transcriber. Thread-safe: the audio tap appends from the
/// chunker queue; the main actor snapshots after the session resolves.
///
/// Holds raw PCM16 mono @ 16 kHz (the format `StreamingAudioEngine` emits).
/// `wav(fromPCM16:)` wraps it in a canonical 44-byte WAV header when a
/// consumer wants a self-describing file.
final class TurnAudioBuffer: @unchecked Sendable {
    private var pcm = Data()
    private var capped = false
    private let lock = OSAllocatedUnfairLock()
    private let maxBytes: Int

    /// Default cap ≈ 10 min @ 16 kHz mono PCM16 (32 KB/s) = ~19.2 MB.
    /// Beyond it we stop appending (memory + upload-size guard); the
    /// already-captured prefix is still recoverable.
    init(maxBytes: Int = 20 * 1024 * 1024) {
        self.maxBytes = maxBytes
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return pcm.isEmpty }
    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return pcm.count }
    var didReachCap: Bool { lock.lock(); defer { lock.unlock() }; return capped }

    /// Append one PCM16 chunk. A chunk that would cross the cap is dropped
    /// whole (keeps frame alignment) and sets `didReachCap`.
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard pcm.count + chunk.count <= maxBytes else {
            capped = true
            return
        }
        pcm.append(chunk)
    }

    func snapshotPCM16() -> Data { lock.lock(); defer { lock.unlock() }; return pcm }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        pcm.removeAll(keepingCapacity: false)
        capped = false
    }

    /// Canonical 44-byte PCM WAV header + samples. Pure for unit testing.
    static func wav(fromPCM16 pcm: Data, sampleRate: Int = 16_000, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var out = Data()
        out.append(Data("RIFF".utf8))
        // precondition: pcm.count <= UInt32.max - 36
        out.append(u32(UInt32(36 + pcm.count)))
        out.append(Data("WAVE".utf8))
        out.append(Data("fmt ".utf8))
        out.append(u32(16))
        out.append(u16(1))                       // PCM
        out.append(u16(UInt16(channels)))
        out.append(u32(UInt32(sampleRate)))
        out.append(u32(UInt32(byteRate)))
        out.append(u16(UInt16(blockAlign)))
        out.append(u16(UInt16(bitsPerSample)))
        out.append(Data("data".utf8))
        out.append(u32(UInt32(pcm.count)))
        out.append(pcm)
        return out
    }
}

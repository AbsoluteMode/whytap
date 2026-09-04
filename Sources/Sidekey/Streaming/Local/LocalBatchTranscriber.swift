import Foundation
import os.log

/// One-shot transcription of an already-captured audio buffer. The Drop
/// recorder fallback, the resilient-delivery batch rung, and the agent's
/// batch voice path all go through this seam so a test can inject a fake
/// instead of the 2.3 GB Parakeet model.
protocol BatchTranscribing: Sendable {
    /// Whether a batch transcription can run right now (for the on-device
    /// implementation: the Parakeet model is downloaded).
    func isAvailable() async -> Bool

    /// Transcribe a 16 kHz mono PCM16 buffer. Callers hand over either raw
    /// PCM or a canonical WAV file (`AudioRecorder` output); the WAV header is
    /// stripped transparently. Throws `LocalTranscriptionModelError` when the
    /// model is missing or the buffer carries no audio.
    func transcribe(audio: Data, language: String?) async throws -> String
}

/// On-device batch transcriber over FluidAudio Parakeet. Reuses the same
/// stateless full-buffer decode the live local session runs on stop, so a
/// batch-recovered Drop pastes exactly what a live local turn would have.
struct LocalBatchTranscriber: BatchTranscribing {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "local-batch")

    private let modelStore: any LocalTranscriptionModelManaging
    private let decoder: any LocalASRDecoding

    init(modelStore: any LocalTranscriptionModelManaging = LocalTranscriptionModelStore.shared) {
        self.init(modelStore: modelStore, decoder: ParakeetLocalASRDecoder(modelStore: modelStore))
    }

    init(modelStore: any LocalTranscriptionModelManaging, decoder: any LocalASRDecoding) {
        self.modelStore = modelStore
        self.decoder = decoder
    }

    func isAvailable() async -> Bool {
        await modelStore.isModelReady()
    }

    func transcribe(audio: Data, language: String?) async throws -> String {
        guard await modelStore.isModelReady() else {
            throw LocalTranscriptionModelError.modelNotDownloaded
        }
        let pcm = Self.pcm16(from: audio)
        let samples = LocalTranscriptionSession.floatSamples(fromPCM16LittleEndian: pcm)
        guard !samples.isEmpty else {
            throw LocalTranscriptionModelError.noAudio
        }
        let text = try await decoder.decode(
            samples: samples,
            language: LocalTranscriptionSession.fluidLanguage(from: language)
        )
        os_log(
            "local batch transcribe ok chars=%{public}d samples=%{public}d",
            log: Self.log, type: .info, text.count, samples.count
        )
        return text
    }

    /// Strip a RIFF/WAVE header when present; raw PCM passes through untouched.
    static func pcm16(from audio: Data) -> Data {
        guard audio.count >= 12,
              String(data: audio.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: audio.subdata(in: 8..<12), encoding: .ascii) == "WAVE"
        else {
            return audio
        }
        var offset = 12
        while offset + 8 <= audio.count {
            let chunkId = String(data: audio.subdata(in: offset..<(offset + 4)), encoding: .ascii)
            let chunkSize = Int(
                UInt32(audio[offset + 4])
                    | (UInt32(audio[offset + 5]) << 8)
                    | (UInt32(audio[offset + 6]) << 16)
                    | (UInt32(audio[offset + 7]) << 24)
            )
            let bodyStart = offset + 8
            if chunkId == "data" {
                let bodyEnd = min(audio.count, bodyStart + chunkSize)
                return audio.subdata(in: bodyStart..<bodyEnd)
            }
            offset = bodyStart + chunkSize + (chunkSize % 2)
        }
        return audio.count > 44 ? Data(audio.dropFirst(44)) : Data()
    }
}

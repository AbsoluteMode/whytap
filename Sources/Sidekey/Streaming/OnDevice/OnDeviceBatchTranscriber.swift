import Foundation
import os.log

/// Whole-take transcription on this Mac: the batch rung of resilient delivery,
/// Retry, the recorder fallback and agent batch voice when the take's route is
/// "On this Mac". The same stateless full-buffer decode the live session runs
/// on stop, so a recovered take pastes what the live one would have.
// WHY: .project-docs/decisions/2026-11-19-on-device-dictation.md
struct OnDeviceBatchTranscriber: BatchTranscribing {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "on-device-speech")

    private let readiness: OnDeviceSpeechReadiness
    private let decoder: any OnDeviceSpeechDecoding

    init(readiness: OnDeviceSpeechReadiness = .live, decoder: any OnDeviceSpeechDecoding = ParakeetSpeechDecoder()) {
        self.readiness = readiness
        self.decoder = decoder
    }

    func isAvailable() async -> Bool {
        readiness.isReady()
    }

    func transcribe(audio: Data, language: String?) async throws -> String {
        guard readiness.isReady() else { throw BatchTranscriptionUnavailable() }
        let samples = OnDeviceTranscriptionSession.floatSamples(fromPCM16LittleEndian: Self.pcm16(from: audio))
        // Parakeet rejects takes under 0.3 s; that little audio holds no word.
        guard samples.count >= 4_800 else { return "" }
        let started = ContinuousClock.now
        let text = try await decoder.decode(samples: samples, language: language)
        let elapsed = ContinuousClock.now - started
        os_log("on-device batch ok chars=%{public}d samples=%{public}d ms=%{public}d",
               log: Self.log, type: .info, text.count, samples.count,
               Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000))
        return text
    }

    /// Strip a RIFF/WAVE header when present; raw PCM passes through untouched.
    static func pcm16(from audio: Data) -> Data {
        guard audio.count >= 12,
              String(data: audio.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
              String(data: audio.subdata(in: 8..<12), encoding: .ascii) == "WAVE"
        else { return audio }
        var offset = 12
        while offset + 8 <= audio.count {
            let chunkID = String(data: audio.subdata(in: offset..<(offset + 4)), encoding: .ascii)
            let chunkSize = Int(
                UInt32(audio[offset + 4]) | (UInt32(audio[offset + 5]) << 8)
                    | (UInt32(audio[offset + 6]) << 16) | (UInt32(audio[offset + 7]) << 24)
            )
            let bodyStart = offset + 8
            if chunkID == "data" {
                return audio.subdata(in: bodyStart..<min(audio.count, bodyStart + chunkSize))
            }
            offset = bodyStart + chunkSize + (chunkSize % 2)
        }
        return audio.count > 44 ? Data(audio.dropFirst(44)) : Data()
    }
}

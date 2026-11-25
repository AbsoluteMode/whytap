import Foundation

/// One-shot transcription of an already-captured audio buffer. The Drop
/// recorder fallback, the resilient-delivery batch rung, and the agent's
/// batch voice path all go through this seam.
protocol BatchTranscribing: Sendable {
    /// Whether a batch transcription can run right now.
    func isAvailable() async -> Bool

    /// Transcribe a 16 kHz mono PCM16 buffer. Callers hand over either raw
    /// PCM or a canonical WAV file (`AudioRecorder` output).
    func transcribe(audio: Data, language: String?) async throws -> String
}

/// There is no batch recognizer: `UnavailableBatchTranscriber`, or
/// `ProviderBatchTranscriber` without a provider and its key chosen in
/// Keys & models.
struct BatchTranscriptionUnavailable: Error, Equatable {}

/// No batch recognizer: the default of `BatchAgentAudioTranscriber`, so a
/// controller built without one never sends audio anywhere. Production binds
/// `ProviderBatchTranscriber`.
/// WHY: .project-docs/decisions/2026-10-18-provider-batch-transcription.md
struct UnavailableBatchTranscriber: BatchTranscribing {
    func isAvailable() async -> Bool { false }

    func transcribe(audio: Data, language: String?) async throws -> String {
        throw BatchTranscriptionUnavailable()
    }
}

import Foundation

/// Common contract for any drop transcription session (direct-to-provider
/// or on-device). Lets `TranscriptionSessionFactory` route without the
/// caller knowing which path runs.
///
/// Inherits `AgentRealtimeVoiceSessioning` (`run`/`stop`/`cancel`) so the same
/// factory-built session can drive both the drop flow and the agent voice
/// factory. `stop()` finalizes (end-of-stream) on a user hotkey release;
/// `cancel()` tears down on app termination / sleep without waiting for the
/// provider.
@MainActor
protocol StreamingSessionRunning: AgentRealtimeVoiceSessioning {
    func run() async -> StreamingSessionResult
    func stop() async
    func cancel() async

    /// PCM16 retained locally for the current turn. The degraded-recovery path
    /// (AppDelegate) batch-transcribes this when a session resolves `.degraded`
    /// after a live-stream blip. Defaults to empty for sessions that do not
    /// retain audio (e.g. BYOK direct), whose degrade path is deferred.
    func capturedAudioPCM16() -> Data
}

extension StreamingSessionRunning {
    func capturedAudioPCM16() -> Data { Data() }
}

enum BYOKStreamEvent: Equatable {
    case partial(String)
    case final(String)
    case done(String)
    case error(String)
}

/// How `DirectProviderStreamingSession` composes the live transcript out of
/// an upstream's `.final`/`.partial` texts.
///
/// - `.wordBoundary`: finals are whole words/segments with no spacing of
///   their own (Deepgram/ElevenLabs/OpenAI) — insert a space between
///   adjacent segments unless one already touches whitespace.
/// - `.verbatim`: finals are per-token fragments that carry their own
///   leading spaces at word boundaries (Soniox tokens) — concatenate
///   untouched; inserting spaces splits words into syllables.
///
/// WHY: docs/decisions/2026-07-22-hub-token-join-and-batch-recovery-deadline.md
enum BYOKTranscriptJoin: Equatable {
    case wordBoundary
    case verbatim
}

enum BYOKStreamErrorCode {
    static let endOfStreamSendFailed = "end_of_stream_send_failed"
}

protocol BYOKUpstreamSession: AnyObject {
    var events: AsyncStream<BYOKStreamEvent> { get }

    /// Composition semantics for this upstream's `.final`/`.partial` texts.
    /// Session-level (not per-event) on purpose: every live upstream speaks
    /// ONE provider's token shape for its whole lifetime.
    var finalsJoin: BYOKTranscriptJoin { get }

    func sendAudio(_ pcm: Data) async
    func endInput() async
    func close() async
}

extension BYOKUpstreamSession {
    /// Default matches the historical behavior: BYOK providers emit whole
    /// words/segments, so segments are joined at word boundaries.
    var finalsJoin: BYOKTranscriptJoin { .wordBoundary }
}

protocol BYOKTranscriptionAdapter {
    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession
}

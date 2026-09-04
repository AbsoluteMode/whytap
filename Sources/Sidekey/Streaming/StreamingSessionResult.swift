import Foundation

/// Why a streaming transcription session failed. Shared by every session
/// kind (direct-to-provider BYOK and on-device) so the Drop / agent / Google
/// result handlers branch on one vocabulary.
enum StreamingSessionError: Error, Equatable {
    case transportFailed
    case transportCancelled
    case unauthorized
    case rateLimited
    case unsupported
    case unknown
    /// The post-stop watchdog expired: the user finalized the turn but the
    /// provider never delivered the terminal frame (half-open socket).
    /// Distinct from `transportFailed` so diagnostics
    /// (`reason: "streaming_watchdogTimeout"`) can aggregate hung-finalize
    /// incidents separately from connect/receive errors.
    case watchdogTimeout
    /// The local audio engine died mid-session (input format went invalid or
    /// a route-change restart exhausted its retries). The transport may be
    /// perfectly healthy — the mic is the problem — so the caller must NOT
    /// re-arm the recorder fallback (see
    /// `shouldFallbackToRecorderOnStreamingFailure`).
    case audioEngineFailed
    /// Sending the end-of-stream marker failed. The socket broke between the
    /// last audio frame and finalize; the receive side will never deliver the
    /// terminal frame, so the session resolves immediately with this case
    /// rather than waiting out the watchdog.
    case endOfStreamSendFailed
}

/// Outcome of one streaming session, surfaced to the AppDelegate so the
/// drop-flow code can branch into paste / error / cancellation without
/// reaching into session internals.
enum StreamingSessionResult: Equatable {
    /// The session finished cleanly; payload is the final transcript ready to
    /// paste.
    case transcript(String)
    /// The provider detected end-of-speech before the user released the
    /// hotkey. Treated the same as a normal stop: the caller uses the
    /// returned string as the committed text.
    case endpointDetected(String)
    /// Streaming failed before any usable transcript landed. Caller falls
    /// back to the recorder path or resolves via the delivery ladder.
    case failed(StreamingSessionError)
    /// User cancelled (e.g. tapped Esc while recording). No transcript
    /// available; caller should reset UI without surfacing an error.
    case cancelled
    /// Live stream broke/stalled mid-turn but local audio was captured.
    /// Caller MUST recover the transcript by batch-transcribing
    /// `capturedAudioPCM16()`. Distinct from `.failed` (nothing usable).
    case degraded
}

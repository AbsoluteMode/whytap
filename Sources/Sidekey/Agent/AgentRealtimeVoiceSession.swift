import Foundation

/// The realtime-voice surface `AgentController` depends on. Every
/// `StreamingSessionRunning` (direct-to-provider BYOK, on-device Parakeet)
/// satisfies it in production; tests inject a fake. Mirrors the session's own
/// lifecycle: `run()` blocks until the session resolves, `stop()` finalizes
/// (sends end-of-stream), `cancel()` tears down.
@MainActor
protocol AgentRealtimeVoiceSessioning: AnyObject {
    /// Partial-transcript sink. The session calls this with the live
    /// (cumulative) transcript snapshot as words land so the island wing
    /// can show the running text while the user is still speaking. Set by
    /// `AgentController` before `run()`; left nil when the consumer does
    /// not need partials.
    var onTranscriptUpdate: ((String) -> Void)? { get set }
    func run() async -> StreamingSessionResult
    func stop() async
    func cancel() async
}

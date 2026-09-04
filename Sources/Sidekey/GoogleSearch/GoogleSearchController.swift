import AppKit
import Foundation

/// Drives the Right-Option Google-search gesture: a typed query (tap) or a
/// spoken query (hold) is turned into a Google results URL and opened in the
/// default browser. No CLI, no answer panel — the result lives in the browser.
@MainActor
final class GoogleSearchController {
    /// Opens a URL in the default browser. Injected for tests.
    private let openURL: (URL) -> Void
    /// Builds a realtime voice session (same factory shape the agent uses).
    /// Returns nil in tests / when realtime voice is unavailable.
    private let voiceSessionFactory: @MainActor () async -> (any StreamingSessionRunning)?
    /// Bridges live partial transcripts into the island wing — mirrors the agent
    /// voice path's `session.onTranscriptUpdate -> islandAgentFlow.transcriptUpdated`.
    /// Default no-op for tests / when there is no island surface.
    private let onTranscript: (String) -> Void

    private var runTask: Task<Void, Never>?
    private var voiceSession: (any StreamingSessionRunning)?

    init(
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        voiceSessionFactory: @escaping @MainActor () async -> (any StreamingSessionRunning)?,
        onTranscript: @escaping (String) -> Void = { _ in }
    ) {
        self.openURL = openURL
        self.voiceSessionFactory = voiceSessionFactory
        self.onTranscript = onTranscript
    }

    // MARK: Text (tap)

    func submitText(_ text: String) {
        guard let url = GoogleSearchURL.make(query: text) else { return }
        openURL(url)
    }

    // MARK: Voice (hold)

    func handleHoldStart() {
        teardownVoiceSession()
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let session = await self.voiceSessionFactory() else { return }
            if Task.isCancelled { await session.cancel(); return }
            // Bridge live partials into the island wing, exactly as the agent
            // voice path does — without this the Google wing shows no words.
            session.onTranscriptUpdate = { [weak self] text in
                self?.onTranscript(text)
            }
            self.voiceSession = session
            let result = await session.run()
            await self.handleStreamResult(result)
        }
    }

    func handleHoldEnd() async {
        if let session = voiceSession {
            await session.stop()  // resolves run() -> handleStreamResult
        } else if runTask != nil {
            teardownVoiceSession()
        }
    }

    func handleCancel() {
        teardownVoiceSession()
    }

    private func teardownVoiceSession() {
        runTask?.cancel()
        runTask = nil
        if let session = voiceSession {
            voiceSession = nil
            Task { await session.cancel() }
        }
    }

    private func handleStreamResult(_ result: StreamingSessionResult) async {
        runTask = nil
        voiceSession = nil
        switch result {
        case .transcript(let text), .endpointDetected(let text):
            submitText(text)
        case .failed, .cancelled, .degraded:
            // `.degraded` (Drop resilient-delivery) has no batch-recovery path
            // here — Google search voice has no retained-audio fallback — so
            // treat a broken live stream as a no-op like `.failed`.
            break
        }
    }

    /// Test seam: drives `handleStreamResult` directly without a live session.
    func handleStreamResultForTesting(_ result: StreamingSessionResult) async {
        await handleStreamResult(result)
    }
}

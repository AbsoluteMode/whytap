import Foundation
import os

/// What a speech-translation session reports: the original as the model
/// heard it, its translation, and how the session ended. Both texts are
/// append-only deltas; `elapsedMs` is the model's own position in the input
/// audio (200 ms steps), the only link between the two.
enum SpeechTranslationEvent: Equatable {
    case source(String, elapsedMs: Int?)
    case translation(String, elapsedMs: Int?)
    /// The provider flushed the last audio and closed the session.
    case closed
    case failed(SpeechTranslationFailure)
}

/// Why a speech-translation session could not start or stopped. Read from the
/// handshake status and the error event's code only, never from its message.
enum SpeechTranslationFailure: Error, Equatable {
    case refusedKey
    case noCredit
    case busy
    case unsupportedLanguage
    case connectionLost
    case provider
}

/// One live audio-in, translation-out session (OpenAI `gpt-realtime-translate`).
protocol SpeechTranslationSession: AnyObject {
    var events: AsyncStream<SpeechTranslationEvent> { get }
    /// Mono PCM16 at 16 kHz, the system-audio capture's format.
    func sendAudio(_ pcm: Data) async
    /// Sends what is buffered and asks the provider to finish; `.closed`
    /// follows once the last translation has arrived.
    func endInput() async
    func close() async
    /// Seconds of audio the provider accepted, for Costs.
    func acceptedAudioSeconds() -> Double
}

/// OpenAI's live speech translation: audio goes in, the model returns the
/// translated transcript (and the transcript of what it heard, when input
/// transcription is on) on one WebSocket. No separate speech model and no
/// LLM translation request per phrase.
// WHY: .project-docs/decisions/2026-11-21-subtitle-speech-translation.md
struct OpenAIRealtimeTranslateAdapter {
    typealias TransportFactory = () -> StreamingTransporting
    /// The only snapshot OpenAI lists (`GET /v1/models`, checked 2026-11-21).
    static let model = "gpt-realtime-translate"
    /// Transcribes the input inside the same session, for the pair's original.
    static let inputTranscriptionModel = "gpt-realtime-whisper"
    /// $0.034 per audio minute for translation, plus $0.017 for the input
    /// transcript (OpenAI pricing, 2026-11-21).
    static let usdPerMinute = 0.034
    static let inputTranscriptionUSDPerMinute = 0.017

    private let makeTransport: TransportFactory
    private let model: String
    var startDeadline: Duration = .seconds(10)

    init(apiKey: String, model: String = Self.model) {
        self.model = model
        self.makeTransport = {
            var components = URLComponents(string: "wss://api.openai.com/v1/realtime/translations")!
            components.queryItems = [URLQueryItem(name: "model", value: model)]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return URLSessionWebSocketTransport(task: URLSession.shared.webSocketTask(with: request))
        }
    }

    init(model: String = Self.model, transport: @escaping TransportFactory) {
        self.model = model
        self.makeTransport = transport
    }

    /// Opens the session and waits until the provider accepted the target
    /// language, so a refused key or language fails here, before any audio.
    func open(target: String) async throws -> SpeechTranslationSession {
        let transport = makeTransport()
        transport.resume()
        let session = OpenAIRealtimeTranslateSession(transport: transport)
        try await session.start(target: target, deadline: startDeadline)
        return session
    }
}

final class OpenAIRealtimeTranslateSession: SpeechTranslationSession, @unchecked Sendable {
    private let transport: StreamingTransporting
    private let continuation: AsyncStream<SpeechTranslationEvent>.Continuation
    let events: AsyncStream<SpeechTranslationEvent>
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var started = false
    /// Why the session failed before `start` began waiting for it.
    private var startFailure: SpeechTranslationFailure?
    /// `endInput` sent session.close: only session.closed completes cleanly.
    private var closing = false
    /// `close()` was called: the app tore the session down itself.
    private var clientClosed = false
    private var finished = false
    private var pending = Data()
    private var acceptedBytes = 0
    /// Event types only; never transcript text, keys or audio.
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "openai-realtime-translate")
    /// OpenAI recommends 200 ms frames: 4,800 samples at 24 kHz.
    static let frameBytes = 9_600

    init(transport: StreamingTransporting) {
        self.transport = transport
        (events, continuation) = AsyncStream.makeStream(of: SpeechTranslationEvent.self)
    }

    func start(target: String, deadline: Duration) async throws {
        let update: [String: Any] = [
            "type": "session.update",
            "session": ["audio": [
                "output": ["language": target],
                "input": ["transcription": ["model": OpenAIRealtimeTranslateAdapter.inputTranscriptionModel]],
            ]],
        ]
        startReceiveLoop()
        do {
            try await send(update)
        } catch {
            close(with: failure(for: error))
            throw failure(for: error)
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: deadline)
            guard !Task.isCancelled else { return }
            self?.resolveStart(.failure(SpeechTranslationFailure.connectionLost))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resolved: Result<Void, Error>? = lock.withLock {
                if started { return .success(()) }
                if finished { return .failure(startFailure ?? SpeechTranslationFailure.connectionLost) }
                ready = continuation
                return nil
            }
            if let resolved { continuation.resume(with: resolved) }
        }
    }

    private func resolveStart(_ result: Result<Void, Error>) {
        let waiter: CheckedContinuation<Void, Error>? = lock.withLock {
            switch result {
            case .success: started = true
            case .failure(let error):
                if !started, startFailure == nil { startFailure = error as? SpeechTranslationFailure }
            }
            defer { ready = nil }
            return ready
        }
        waiter?.resume(with: result)
        if case .failure(let error) = result {
            close(with: error as? SpeechTranslationFailure ?? .provider)
        }
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                switch await self.transport.receive() {
                case .failure(let error):
                    // Only the app's own teardown ends quietly. A socket lost
                    // after session.close, before session.closed, may have
                    // dropped the last translation: that is a lost connection.
                    // https://developers.openai.com/api/docs/guides/realtime-translation#close-a-websocket-session
                    if self.lock.withLock({ self.clientClosed }) {
                        self.finish(.closed)
                    } else {
                        self.fail(self.failure(for: error))
                    }
                    return
                case .success(let frame):
                    guard case .text(let text) = frame,
                          let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          let type = object["type"] as? String else { continue }
                    if self.handle(type: type, object) { return }
                }
            }
        }
    }

    /// How far the model's position trails the audio sent so far, in audio
    /// ms, when a delta arrives (numbers only). If it grows during a session,
    /// the delay builds up at the provider; `LiveSubtitleModel` logs the same
    /// when the delta is shown.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    private func logTrail(_ stream: StaticString, _ elapsed: Int?) {
        let sent = lock.withLock { acceptedBytes } / 48 // 24 kHz PCM16: 48 bytes per ms
        os_log("delta stream=%{public}s elapsed_ms=%d sent_ms=%d trail_ms=%d", log: Self.log, type: .info,
               "\(stream)", elapsed ?? -1, sent, sent - (elapsed ?? 0))
    }

    /// Returns true when the session is over.
    private func handle(type: String, _ object: [String: Any]) -> Bool {
        os_log("translate event type=%{public}@", log: Self.log, type: .debug, type)
        let elapsed = (object["elapsed_ms"] as? NSNumber)?.intValue
        switch type {
        case "session.updated":
            resolveStart(.success(()))
        case "session.input_transcript.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                logTrail("source", elapsed)
                continuation.yield(.source(delta, elapsedMs: elapsed))
            }
        case "session.output_transcript.delta":
            if let delta = object["delta"] as? String, !delta.isEmpty {
                logTrail("translation", elapsed)
                continuation.yield(.translation(delta, elapsedMs: elapsed))
            }
        case "session.closed":
            finish(.closed)
            return true
        case "error":
            let error = object["error"] as? [String: Any]
            guard let failure = Self.failure(code: error?["code"] as? String, type: error?["type"] as? String,
                                             param: error?["param"] as? String) else { return false }
            fail(failure)
            return true
        default:
            break
        }
        return false
    }

    /// Fatal error codes end the session; others (a malformed event, say)
    /// are recoverable and only logged by type.
    static func failure(code: String?, type: String?, param: String?) -> SpeechTranslationFailure? {
        let code = code ?? ""
        switch code {
        case "invalid_api_key", "incorrect_api_key", "invalid_authentication", "authentication_error", "unauthorized":
            return .refusedKey
        case "insufficient_quota", "credit_balance_exhausted", "billing_hard_limit_reached", "billing_not_active":
            return .noCredit
        case "rate_limit_exceeded", "session_limit_reached", "concurrent_session_limit":
            return .busy
        case "unsupported_language", "invalid_language":
            return .unsupportedLanguage
        default:
            break
        }
        if type == "authentication_error" || type == "permission_error" { return .refusedKey }
        if type == "insufficient_quota" { return .noCredit }
        if let param, param.contains("language") { return .unsupportedLanguage }
        if type == "server_error" { return .provider }
        return nil
    }

    /// A refused handshake has no error event: only its HTTP status.
    private func failure(for error: Error) -> SpeechTranslationFailure {
        if let failure = error as? SpeechTranslationFailure { return failure }
        switch transport.responseStatusCode {
        case 401: return .refusedKey
        case 402: return .noCredit
        case 403: return .refusedKey
        case 429: return .busy
        default: return .connectionLost
        }
    }

    private func fail(_ failure: SpeechTranslationFailure) {
        let isStarted = lock.withLock { started }
        if !isStarted { resolveStart(.failure(failure)); return }
        close(with: failure)
    }

    private func close(with failure: SpeechTranslationFailure) {
        finish(.failed(failure))
        transport.cancel(reason: nil)
    }

    private func finish(_ event: SpeechTranslationEvent) {
        let first: Bool = lock.withLock {
            guard !finished else { return false }
            finished = true; return true
        }
        guard first else { return }
        continuation.yield(event)
        continuation.finish()
        resolveStart(.failure(SpeechTranslationFailure.connectionLost))
    }

    func sendAudio(_ pcm: Data) async {
        let frames: [Data] = lock.withLock {
            guard !finished, !closing else { return [] }
            pending.append(OpenAIRealtimeSession.upsample16kTo24k(pcm))
            var frames: [Data] = []
            while pending.count >= Self.frameBytes {
                frames.append(pending.prefix(Self.frameBytes))
                pending.removeFirst(Self.frameBytes)
            }
            return frames
        }
        for frame in frames { await append(frame) }
    }

    private func append(_ frame: Data) async {
        do {
            try await send(["type": "session.input_audio_buffer.append", "audio": frame.base64EncodedString()])
            lock.withLock { acceptedBytes += frame.count }
        } catch {
            fail(failure(for: error))
        }
    }

    func endInput() async {
        let rest: Data = lock.withLock {
            defer { pending = Data() }
            return pending
        }
        if !rest.isEmpty { await append(rest) }
        let alreadyOver = lock.withLock { () -> Bool in
            closing = true
            return finished
        }
        guard !alreadyOver else { return }
        do { try await send(["type": "session.close"]) } catch { fail(failure(for: error)) }
    }

    func close() async {
        lock.withLock { closing = true; clientClosed = true }
        receiveTask?.cancel()
        finish(.closed)
        transport.cancel(reason: "client closed")
    }

    func acceptedAudioSeconds() -> Double {
        Double(lock.withLock { acceptedBytes }) / 48_000
    }

    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await transport.send(.text(String(decoding: data, as: UTF8.self)))
    }
}

/// Records one Costs row per session from the audio the provider accepted,
/// captured with the route before audio leaves the Mac.
final class AIUsageMeteredSpeechTranslation: SpeechTranslationSession {
    let session: SpeechTranslationSession
    let context: AIUsageContext
    var record: (AIUsageEvent) -> Void = AIUsageRecorder.record
    private let started = Date()
    private let lock = NSLock()
    private var recorded = false

    init(session: SpeechTranslationSession, context: AIUsageContext) {
        self.session = session; self.context = context
    }

    var events: AsyncStream<SpeechTranslationEvent> { session.events }
    func sendAudio(_ pcm: Data) async { await session.sendAudio(pcm) }
    func endInput() async { await session.endInput() }
    func acceptedAudioSeconds() -> Double { session.acceptedAudioSeconds() }

    func close() async {
        await session.close()
        let first: Bool = lock.withLock {
            defer { recorded = true }
            return !recorded
        }
        let seconds = session.acceptedAudioSeconds()
        if first, seconds > 0 { record(AIUsageEvent.speech(context, seconds: seconds, at: started)) }
    }
}

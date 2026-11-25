import Foundation
import os

/// Soniox real-time translation: one WebSocket hears the system audio and
/// returns the original as tokens with audio timestamps and, in the same
/// stream, its translation (one-way, to the chosen language). Measured on
/// 2026-11-25 with the same lecture: a sentence's translation arrives about
/// 0.8 s after the sentence ends, against 3.6 to 4 s for OpenAI
/// `gpt-realtime-translate`, at about $0.12 per audio hour against $3.06.
///
/// Only final tokens are passed on, as the append-only deltas
/// `SpeechTranslationSession` promises. An original token's position is its
/// `end_ms`. Translated tokens carry no timestamps: theirs is the end of the
/// last final original token, the audio they were translated from, which is
/// what `SubtitleSpeechPairer` matches sentences by.
// WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-engine.md
struct SonioxRealtimeTranslateAdapter {
    typealias TransportFactory = () -> StreamingTransporting
    static let model = ModelRegistry.sonioxRealtimeModel
    static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    private let makeTransport: TransportFactory
    var startDeadline: Duration = .seconds(10)

    /// The key goes in the `Authorization` header: Soniox deprecates the
    /// config frame's `api_key` (refused from 2027-01-15).
    init(apiKey: String) {
        self.makeTransport = {
            var request = URLRequest(url: Self.endpoint)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            return URLSessionWebSocketTransport(task: URLSession.shared.webSocketTask(with: request))
        }
    }

    init(transport: @escaping TransportFactory) {
        self.makeTransport = transport
    }

    /// Opens the session and waits for Soniox's first answer to the config,
    /// so a refused key or an unsupported language fails here, before any
    /// system audio is captured. `source` nil detects the spoken language.
    func open(source: String?, target: String) async throws -> SpeechTranslationSession {
        let transport = makeTransport()
        transport.resume()
        let session = SonioxRealtimeTranslateSession(transport: transport)
        try await session.start(source: source, target: target, deadline: startDeadline)
        return session
    }
}

final class SonioxRealtimeTranslateSession: SpeechTranslationSession, @unchecked Sendable {
    private let transport: StreamingTransporting
    private let continuation: AsyncStream<SpeechTranslationEvent>.Continuation
    let events: AsyncStream<SpeechTranslationEvent>
    var providerName: String { "Soniox" }
    private let lock = NSLock()
    private var receiveTask: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var started = false
    private var startFailure: SpeechTranslationFailure?
    /// `endInput` sent the end of audio: only `finished` completes cleanly.
    private var closing = false
    private var clientClosed = false
    private var finished = false
    private var pending = Data()
    private var acceptedBytes = 0
    /// End of the last final original token: the translation's position.
    private var heardMs = 0
    private let clientReferenceID = UUID().uuidString
    /// Numbers and codes only; never transcript text, keys or audio.
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "soniox-realtime-translate")
    /// 100 ms of 24 kHz PCM16 per binary frame.
    static let frameBytes = 4_800

    init(transport: StreamingTransporting) {
        self.transport = transport
        (events, continuation) = AsyncStream.makeStream(of: SpeechTranslationEvent.self)
    }

    /// The config frame: 24 kHz PCM16 mono (the Subtitles capture), endpoint
    /// detection on (it finalizes a sentence as soon as the speaker pauses),
    /// one-way translation to `target`.
    static func config(source: String?, target: String, reference: String) -> [String: Any] {
        var config: [String: Any] = [
            "model": SonioxRealtimeTranslateAdapter.model,
            "audio_format": "pcm_s16le",
            "sample_rate": 24_000,
            "num_channels": 1,
            "enable_endpoint_detection": true,
            "client_reference_id": reference,
            "translation": ["type": "one_way", "target_language": target],
        ]
        if let source, !source.isEmpty { config["language_hints"] = [source] }
        return config
    }

    func start(source: String?, target: String, deadline: Duration) async throws {
        startReceiveLoop()
        do {
            try await send(.text(Self.json(Self.config(source: source, target: target, reference: clientReferenceID))))
        } catch {
            let failure = failure(for: error)
            close(with: failure)
            throw failure
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
                    // after the end of audio, before `finished`, may have
                    // dropped the last translation: a lost connection.
                    if self.lock.withLock({ self.clientClosed }) {
                        self.finish(.closed)
                    } else {
                        self.fail(self.failure(for: error))
                    }
                    return
                case .success(let frame):
                    let data: Data
                    switch frame {
                    case .text(let text): data = Data(text.utf8)
                    case .data(let value): data = value
                    }
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if self.handle(object) { return }
                }
            }
        }
    }

    /// Returns true when the session is over.
    private func handle(_ object: [String: Any]) -> Bool {
        let isStarted = lock.withLock { started }
        if let code = (object["error_code"] as? NSNumber)?.intValue {
            let failure = Self.failure(code: code, starting: !isStarted)
            os_log("soniox translate error session=%{public}@ code=%d", log: Self.log, type: .error,
                   clientReferenceID, code)
            fail(failure)
            return true
        }
        if !isStarted { resolveStart(.success(())) }
        for token in object["tokens"] as? [[String: Any]] ?? [] {
            guard (token["is_final"] as? Bool) == true, let text = token["text"] as? String, !text.isEmpty,
                  text != "<end>", text != "<fin>" else { continue }
            switch token["translation_status"] as? String {
            case "translation":
                let heard = lock.withLock { heardMs }
                continuation.yield(.translation(text, elapsedMs: heard))
            default:
                // "original", or "none" when the spoken language is already the target.
                let end = (token["end_ms"] as? NSNumber)?.intValue
                if let end { lock.withLock { heardMs = max(heardMs, end) } }
                continuation.yield(.source(text, elapsedMs: end))
                if (token["translation_status"] as? String) == "none" {
                    // Nothing to translate: the original is the subtitle.
                    continuation.yield(.translation(text, elapsedMs: end))
                }
            }
        }
        if (object["finished"] as? Bool) == true {
            let audio = lock.withLock { acceptedBytes } / 48
            os_log("soniox translate finished session=%{public}@ audio_ms=%d", log: Self.log, type: .info,
                   clientReferenceID, audio)
            finish(.closed)
            transport.cancel(reason: nil)
            return true
        }
        return false
    }

    /// Soniox error codes are HTTP statuses. During start a 400 is the
    /// configuration, whose only variable part is the languages.
    static func failure(code: Int, starting: Bool) -> SpeechTranslationFailure {
        switch code {
        case 401, 403: return .refusedKey
        case 402: return .noCredit
        case 429: return .busy
        case 400 where starting: return .unsupportedLanguage
        case 408: return .connectionLost
        default: return .provider
        }
    }

    /// A refused upgrade has no error message: only its HTTP status.
    private func failure(for error: Error) -> SpeechTranslationFailure {
        if let failure = error as? SpeechTranslationFailure { return failure }
        switch transport.responseStatusCode {
        case 401, 403: return .refusedKey
        case 402: return .noCredit
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
            pending.append(pcm)
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
            try await send(.data(frame))
            lock.withLock { acceptedBytes += frame.count }
        } catch {
            fail(failure(for: error))
        }
    }

    /// Sends what is buffered, then an empty text frame: Soniox's end of
    /// audio (an empty binary frame would be an empty chunk). It answers with
    /// the last tokens and `finished`.
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
        do { try await send(.text("")) } catch { fail(failure(for: error)) }
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

    private func send(_ frame: StreamingFrame) async throws {
        try await transport.send(frame)
    }

    private static func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }
}

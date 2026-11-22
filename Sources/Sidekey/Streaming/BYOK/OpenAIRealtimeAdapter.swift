import Foundation
import os

/// Which side of the OpenAI Realtime transcription protocol the adapter
/// talks to.
enum OpenAIRealtimeDialect: Equatable, Sendable {
    /// A user's own OpenAI-compatible server: the GA shape with `language`
    /// and `prompt`, push-to-talk (one commit when the take ends).
    case server
    /// OpenAI itself (`api.openai.com`): fields and turn handling follow the
    /// model, see `OpenAIRealtimeTurns`.
    // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
    case openAI
}

/// How a take is cut into transcription turns.
enum OpenAIRealtimeTurns: Equatable, Sendable {
    /// `turn_detection: null`, one commit when the take ends. Text streams
    /// within the turn only for models that do so (`gpt-live-transcribe`,
    /// `gpt-realtime-whisper`, a server that streams).
    case oneCommit
    /// OpenAI's server VAD commits a turn at every pause, so a model that
    /// starts after a commit (`gpt-transcribe`, `gpt-4o-*-transcribe`,
    /// `whisper-1`) shows text phrase by phrase instead of only after the
    /// take. The take's end commits what is left.
    case serverVAD

    static func forModel(_ model: String, dialect: OpenAIRealtimeDialect) -> Self {
        switch dialect {
        case .server: return .oneCommit
        case .openAI: return ModelRegistry.openAIStreamsWithinTurn(model) ? .oneCommit : .serverVAD
        }
    }
}

/// Adapter for the OpenAI Realtime transcription standard: OpenAI's own
/// speech models on the shared OpenAI key, or a self-hosted /
/// OpenAI-compatible server.
struct OpenAIRealtimeAdapter: BYOKTranscriptionAdapter {
    typealias TransportFactory = () -> StreamingTransporting
    private let model: String
    private let dialect: OpenAIRealtimeDialect
    private let pingInterval: Duration?
    private let makeTransport: TransportFactory

    /// How often a live session pings the socket. A pong is progress for the
    /// stall detector: OpenAI sends nothing during a pause (and a turn-based
    /// model nothing until the pause ends), which must not read as a
    /// half-open socket. A socket that stops answering still stalls.
    static let defaultPingInterval: Duration = .seconds(2)

    /// Production initializer: builds a `URLSessionWebSocketTask` to `url`,
    /// authenticated when `apiKey` is not empty (see `handshakeRequest`). A
    /// server's `url` comes from `BYOKRealtimeURL.openAIRealtime(baseURL:)`,
    /// OpenAI's from `BYOKRealtimeURL.openAIHosted`; neither falls back to
    /// the other.
    init(apiKey: String, url: URL, model: String, dialect: OpenAIRealtimeDialect = .server) {
        self.model = model
        self.dialect = dialect
        // A user's server keeps its earlier stall behavior: no pings.
        self.pingInterval = dialect == .openAI ? Self.defaultPingInterval : nil
        self.makeTransport = {
            let request = Self.handshakeRequest(url: url, apiKey: apiKey)
            let task = URLSession.shared.webSocketTask(with: request)
            return URLSessionWebSocketTransport(task: task)
        }
    }

    /// The WebSocket upgrade request. `Authorization: Bearer` is sent only for
    /// a non-empty key: a user's own server may run without one, and a bare
    /// "Bearer " header is something a gateway can reject.
    static func handshakeRequest(url: URL, apiKey: String) -> URLRequest {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // GA Realtime API: NO `OpenAI-Beta: realtime=v1` header — that header
        // selects the retired beta shape (server replies beta_api_shape_disabled).
        return request
    }

    /// Test initializer: inject a transport (e.g. StubWebSocketTransport).
    init(model: String, dialect: OpenAIRealtimeDialect = .server, pingInterval: Duration? = nil,
         transport: @escaping TransportFactory) {
        self.model = model
        self.dialect = dialect
        self.pingInterval = pingInterval
        self.makeTransport = transport
    }

    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        let transport = makeTransport()
        transport.resume()
        let session = OpenAIRealtimeSession(transport: transport, dialect: dialect,
                                            turns: OpenAIRealtimeTurns.forModel(model, dialect: dialect),
                                            pingInterval: pingInterval)
        try await session.start(config: Self.sessionUpdate(model: model, dialect: dialect,
                                                           language: language, terms: terms))
        return session
    }

    /// The `session.update` frame. OpenAI Realtime GA transcription shape:
    /// config nested under session.audio.input; PCM rate must be >= 24 kHz
    /// (the 16 kHz capture is upsampled in `sendAudio`).
    ///
    /// On OpenAI the fields follow the model (OpenAI's realtime transcription
    /// guide, 2026-11-22): `gpt-live-transcribe` and `gpt-transcribe` take
    /// `languages` and the vocabulary as `keywords` or `prompt`;
    /// `gpt-realtime-whisper` takes no prompt; the older models `language`
    /// and `prompt`. A server keeps `language` and `prompt`.
    static func sessionUpdate(model: String, dialect: OpenAIRealtimeDialect,
                              language: String?, terms: [String]) -> [String: Any] {
        var tx: [String: Any] = ["model": model]
        let turns = OpenAIRealtimeTurns.forModel(model, dialect: dialect)
        switch dialect {
        case .server:
            if let language { tx["language"] = language }
            if !terms.isEmpty { tx["prompt"] = terms.joined(separator: ", ") }
        case .openAI:
            let live = model.hasPrefix(ModelRegistry.openAILiveModel)
            let takesLanguages = live || model.hasPrefix(ModelRegistry.openAIRecordedModel)
            if let language { tx[takesLanguages ? "languages" : "language"] = takesLanguages ? [language] : language }
            if live {
                let keywords = keywords(from: terms)
                if !keywords.isEmpty { tx["keywords"] = keywords }
            } else if !model.hasPrefix(ModelRegistry.openAIRealtimeWhisperModel), !terms.isEmpty {
                tx["prompt"] = terms.joined(separator: ", ")
            }
        }
        let turnDetection: Any
        switch turns {
        // Push-to-talk: the take's end is the commit.
        case .oneCommit: turnDetection = NSNull()
        case .serverVAD:
            turnDetection = [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500,
            ] as [String: Any]
        }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": OpenAIRealtimeSession.outputSampleRate],
                    "transcription": tx,
                    "turn_detection": turnDetection,
                ]],
            ],
        ]
    }

    /// Vocabulary as OpenAI keywords: one term each, without `<`, `>` or line
    /// breaks, which the API refuses.
    static func keywords(from terms: [String]) -> [String] {
        terms.compactMap { term in
            let cleaned = term.filter { !"<>\r\n".contains($0) }.trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? nil : cleaned
        }
    }
}

/// One live transcription session. Transcripts are tracked per committed
/// item (`item_id`): deltas build the item's partial text, and completed
/// items become finals in commit order, since OpenAI does not order
/// completions of different turns.
///
/// The take's end on OpenAI: the app's final commit carries its own
/// `event_id`. With server VAD it is followed by `input_audio_buffer.clear`,
/// whose `cleared` answer comes after every commit the server made from the
/// take's audio, automatic or the app's own (the server handles client
/// events in order), so `cleared` is the tail boundary. Only OpenAI's
/// empty-buffer refusal of that commit means "nothing left"; any other error
/// fails the take.
// WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
final class OpenAIRealtimeSession: BYOKUpstreamSession, @unchecked Sendable {
    private let transport: StreamingTransporting
    private let dialect: OpenAIRealtimeDialect
    private let turns: OpenAIRealtimeTurns
    private let pingInterval: Duration?
    private var continuation: AsyncStream<BYOKStreamEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    /// Everything below is read and written under `lock`, and events are
    /// yielded under it too, so a ping's heartbeat can never land between a
    /// final and the partial that follows it.
    private let lock = NSLock()
    private var order: [String] = []
    private var deltas: [String: String] = [:]
    private var completed: [String: String] = [:]
    private var flushed = 0
    private var finalParts: [String] = []
    private var endRequested = false
    /// Every commit of the take is answered: the push-to-talk turn completed,
    /// the final commit was refused as empty, or (server VAD) `cleared` came.
    private var tailReached = false
    private var finished = false

    /// Diagnostic only — logs upstream event TYPES and allowlisted error
    /// labels (never transcript content, keys, audio or a server's own error
    /// text) so a protocol mismatch is visible
    /// (`log stream --predicate 'category == "byok-openai-realtime"'`).
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "byok-openai-realtime")
    /// OpenAI Realtime GA requires input PCM at >= 24 kHz; our capture is 16 kHz.
    static let outputSampleRate = 24_000
    /// An item event without `item_id` (a minimal server) belongs to the one turn.
    private static let unnamedItem = "_"
    /// Client `event_id`s of the take's end, echoed in an error's `event_id`.
    static let finalCommitEventID = "whytap_final_commit"
    static let tailBoundaryEventID = "whytap_tail_boundary"
    /// OpenAI's refusal of a commit with nothing in the buffer.
    static let emptyCommitCode = "input_audio_buffer_commit_empty"

    let events: AsyncStream<BYOKStreamEvent>

    init(transport: StreamingTransporting, dialect: OpenAIRealtimeDialect = .server,
         turns: OpenAIRealtimeTurns = .oneCommit, pingInterval: Duration? = nil) {
        self.transport = transport
        self.dialect = dialect
        self.turns = turns
        self.pingInterval = pingInterval
        var cont: AsyncStream<BYOKStreamEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// A server's refusal stays terminal (`"provider"`), as before OpenAI
    /// speech existed; OpenAI's goes to Drop's batch rung.
    private var refusalCode: String {
        dialect == .openAI ? BYOKStreamErrorCode.providerRefused : "provider"
    }

    func start(config: [String: Any]) async throws {
        try await send(config)
        startReceiveLoop()
        startPings()
    }

    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await transport.send(.text(String(decoding: data, as: UTF8.self)))
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.transport.receive()
                switch result {
                case .failure:
                    os_log("byok openai realtime transport failed status=%{public}d", log: Self.log, type: .error,
                           self.transport.responseStatusCode ?? 0)
                    self.fail("transport")
                    return
                case .success(let frame):
                    guard case .text(let s) = frame,
                          let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                          let type = obj["type"] as? String else { continue }
                    os_log("byok openai event type=%{public}@", log: Self.log, type: .debug, Self.eventLabel(type))
                    if self.handle(type: type, object: obj) { return }
                }
            }
        }
    }

    /// A pong proves the socket alive: the current partial is repeated, which
    /// the session reads as progress and the island ignores (same text).
    private func startPings() {
        guard let pingInterval else { return }
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pingInterval)
                guard !Task.isCancelled, let self else { return }
                do { try await self.transport.sendPing() } catch { return }
                self.heartbeat()
            }
        }
    }

    /// Returns true when the session is over.
    private func handle(type: String, object obj: [String: Any]) -> Bool {
        let item = (obj["item_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.unnamedItem
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return true }
        switch type {
        case "input_audio_buffer.committed":
            place(item, after: obj["previous_item_id"] as? String)
            emitPartialLocked()
        case "input_audio_buffer.cleared":
            // Server VAD's tail boundary: every commit of the take is in.
            if dialect == .openAI, turns == .serverVAD, endRequested { tailReached = true }
            emitPartialLocked()
            finishIfDoneLocked()
        case "conversation.item.input_audio_transcription.delta":
            place(item, after: nil)
            if let delta = obj["delta"] as? String { deltas[item, default: ""] += delta }
            emitPartialLocked()
        case "conversation.item.input_audio_transcription.completed":
            place(item, after: nil)
            completed[item] = (obj["transcript"] as? String) ?? ""
            // Push-to-talk has one turn: its completion is the take's end.
            if turns == .oneCommit { tailReached = true; endRequested = true }
            flushLocked()
        case "conversation.item.input_audio_transcription.failed":
            // A server's failed turn was never acted on; keep it that way.
            guard dialect == .openAI else { break }
            os_log("byok openai realtime turn failed code=%{public}@", log: Self.log, type: .error,
                   Self.errorLabel(Self.errorCode(obj)))
            failLocked(refusalCode)
        case "error":
            let code = Self.errorCode(obj)
            os_log("byok openai realtime error code=%{public}@", log: Self.log, type: .error, Self.errorLabel(code))
            if isEmptyFinalCommit(code: code, eventID: Self.errorEventID(obj)) {
                // Nothing was left after the last automatic commit (or the
                // take had no audio). With server VAD `cleared` still marks
                // the tail; push-to-talk has no turn left to wait for.
                if turns == .oneCommit { tailReached = true }
                finishIfDoneLocked()
            } else {
                failLocked(refusalCode)
            }
        default:
            // Any other server event (speech started or stopped, session
            // updates) still shows the stream is alive.
            emitPartialLocked()
        }
        return finished
    }

    /// OpenAI's empty-buffer refusal of the app's own final commit, and
    /// nothing else: a server's error, an error before the take's end, an
    /// error naming another client event or any other code fails the take.
    private func isEmptyFinalCommit(code: String?, eventID: String?) -> Bool {
        guard dialect == .openAI, endRequested, code == Self.emptyCommitCode else { return false }
        return eventID == nil || eventID == Self.finalCommitEventID
    }

    /// Records `item` in commit order: after `previous` when known, else last.
    private func place(_ item: String, after previous: String?) {
        guard !order.contains(item) else { return }
        if let previous, let index = order.firstIndex(of: previous), index >= flushed {
            order.insert(item, at: index + 1)
        } else {
            order.append(item)
        }
    }

    /// The text of turns not yet final, in order.
    private func pendingTextLocked() -> String {
        guard flushed < order.count else { return "" }
        return order[flushed...]
            .map { completed[$0] ?? deltas[$0] ?? "" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func emitPartialLocked() {
        continuation?.yield(.partial(pendingTextLocked()))
    }

    private func heartbeat() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        emitPartialLocked()
    }

    /// Completed turns at the front of the order become finals.
    private func flushLocked() {
        while flushed < order.count, let text = completed[order[flushed]] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                finalParts.append(trimmed)
                continuation?.yield(.final(trimmed))
            }
            flushed += 1
        }
        emitPartialLocked()
        finishIfDoneLocked()
    }

    private func finishIfDoneLocked() {
        guard !finished, endRequested, tailReached, flushed == order.count else { return }
        finished = true
        continuation?.yield(.done(finalParts.joined(separator: " ")))
        continuation?.finish()
    }

    private func fail(_ code: String) {
        lock.lock(); defer { lock.unlock() }
        failLocked(code)
    }

    private func failLocked(_ code: String) {
        guard !finished else { return }
        finished = true
        continuation?.yield(.error(code))
        continuation?.finish()
    }

    private static func errorCode(_ obj: [String: Any]) -> String? {
        (obj["error"] as? [String: Any])?["code"] as? String
    }

    private static func errorEventID(_ obj: [String: Any]) -> String? {
        (obj["error"] as? [String: Any])?["event_id"] as? String
    }

    /// Error codes the log may name; anything else (a server can put any
    /// text there) is logged as `unlisted`.
    private static let loggableErrorCodes: Set<String> = [
        emptyCommitCode, "invalid_value", "invalid_request_error", "invalid_api_key", "incorrect_api_key",
        "invalid_authentication", "insufficient_quota", "credit_balance_exhausted", "rate_limit_exceeded",
        "slow_down", "session_limit_reached", "model_not_found", "invalid_model", "server_error",
        "unsupported_language", "invalid_language",
    ]

    static func errorLabel(_ code: String?) -> String {
        guard let code else { return "none" }
        return loggableErrorCodes.contains(code) ? code : "unlisted"
    }

    /// Event types the log may name; anything else is `other`.
    static func eventLabel(_ type: String) -> String {
        let known = type.hasPrefix("input_audio_buffer.") || type.hasPrefix("conversation.item.")
            || type.hasPrefix("session.") || type.hasPrefix("transcription_session.") || type == "error"
        return known && type.count <= 64 && type.allSatisfy({ $0.isLetter || $0 == "." || $0 == "_" }) ? type : "other"
    }

    func sendAudio(_ pcm: Data) async {
        let upsampled = Self.upsample16kTo24k(pcm)
        try? await send([
            "type": "input_audio_buffer.append",
            "audio": upsampled.base64EncodedString(),
        ])
    }

    /// Linear-interpolate mono PCM16 LE from 16 kHz to 24 kHz (3:2 ratio).
    /// Per-chunk with clamped edges — adequate for speech recognition; OpenAI
    /// Realtime rejects sample rates below 24 kHz.
    static func upsample16kTo24k(_ data: Data) -> Data {
        let input: [Int16] = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let inCount = input.count
        guard inCount > 1 else { return data }
        let outCount = inCount * 3 / 2
        var output = [Int16](repeating: 0, count: outCount)
        for j in 0..<outCount {
            let pos = Double(j) * 2.0 / 3.0
            let i = Int(pos)
            let frac = pos - Double(i)
            let a = Double(input[min(i, inCount - 1)])
            let b = Double(input[min(i + 1, inCount - 1)])
            output[j] = Int16((a + (b - a) * frac).rounded())
        }
        return output.withUnsafeBytes { Data($0) }
    }

    func endInput() async {
        lock.lock()
        endRequested = true
        lock.unlock()
        // A server gets the plain commit it always got. OpenAI's carries an
        // event_id, and with server VAD a clear follows as the tail boundary.
        var commit: [String: Any] = ["type": "input_audio_buffer.commit"]
        if dialect == .openAI { commit["event_id"] = Self.finalCommitEventID }
        do {
            try await send(commit)
            if dialect == .openAI, turns == .serverVAD {
                try await send(["type": "input_audio_buffer.clear", "event_id": Self.tailBoundaryEventID])
            }
        } catch {
            // Log the event type only (no payload) on a failed commit so a
            // half-open socket is diagnosable; the session's stop watchdog
            // bounds the resulting receive-side wait.
            os_log("byok openai realtime endInput send failed", log: Self.log, type: .error)
            fail(BYOKStreamErrorCode.endOfStreamSendFailed)
        }
    }

    func close() async {
        receiveTask?.cancel()
        pingTask?.cancel()
        lock.lock()
        finished = true
        lock.unlock()
        continuation?.finish()
        transport.cancel(reason: "client closed")
    }
}

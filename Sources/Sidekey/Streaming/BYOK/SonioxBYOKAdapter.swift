import Foundation
import os

/// Soniox stt-rt-v5 BYOK adapter: client-direct with the user's key. Config
/// (incl. the user `api_key`) rides in the first JSON frame. Mirrors the
/// hold-to-talk config (endpoint-detection off for the
/// tap-tap drop; `en` appended to language_hints) plus the user key + terms
/// as documented by Soniox.
struct SonioxBYOKAdapter: BYOKTranscriptionAdapter {
    typealias TransportFactory = () -> StreamingTransporting
    private let apiKey: String
    private let model: String
    private let makeTransport: TransportFactory

    /// Production: open the Soniox realtime WS (no handshake auth header — the
    /// key travels in the config frame).
    init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
        self.makeTransport = {
            let url = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
            return URLSessionWebSocketTransport(task: URLSession.shared.webSocketTask(with: url))
        }
    }

    /// Test: inject a transport.
    init(apiKey: String, model: String, transport: @escaping TransportFactory) {
        self.apiKey = apiKey
        self.model = model
        self.makeTransport = transport
    }

    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        let transport = makeTransport()
        transport.resume()
        let session = SonioxBYOKSession(transport: transport)
        try await session.start(apiKey: apiKey, model: model, language: language, terms: terms)
        return session
    }
}

final class SonioxBYOKSession: BYOKUpstreamSession, @unchecked Sendable {
    private let transport: StreamingTransporting
    private var continuation: AsyncStream<BYOKStreamEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var finalParts: [String] = []
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "byok-soniox")

    /// Soniox emits one `.final` per token; tokens carry their own leading
    /// spaces, so live composition must concatenate verbatim (same semantics
    /// so words are never split into syllables).
    var finalsJoin: BYOKTranscriptJoin { .verbatim }

    let events: AsyncStream<BYOKStreamEvent>

    init(transport: StreamingTransporting) {
        self.transport = transport
        var cont: AsyncStream<BYOKStreamEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start(apiKey: String, model: String, language: String?, terms: [String]) async throws {
        var config: [String: Any] = [
            "api_key": apiKey,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": 16_000,
            "num_channels": 1,
            "enable_endpoint_detection": false,
        ]
        var hints: [String] = []
        if let language, !language.isEmpty { hints.append(language) }
        if !hints.contains("en") { hints.append("en") }
        config["language_hints"] = hints
        if !terms.isEmpty { config["context"] = ["terms": terms] }
        let data = try JSONSerialization.data(withJSONObject: config)
        try await transport.send(.text(String(decoding: data, as: UTF8.self)))
        startReceiveLoop()
    }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.transport.receive()
                switch result {
                case .failure:
                    self.emit(.error("transport"))
                    self.continuation?.finish()
                    return
                case .success(let frame):
                    guard case .text(let s) = frame,
                          let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
                    else { continue }
                    if let tokens = obj["tokens"] as? [[String: Any]] {
                        let interim = tokens
                            .filter { ($0["is_final"] as? Bool) != true }
                            .compactMap { $0["text"] as? String }
                            .joined()
                        for token in tokens where (token["is_final"] as? Bool) == true {
                            let text = token["text"] as? String ?? ""
                            self.finalParts.append(text)
                            self.emit(.final(text))
                        }
                        if !interim.isEmpty { self.emit(.partial(interim)) }
                    }
                    if (obj["finished"] as? Bool) == true {
                        os_log("byok soniox finished", log: Self.log, type: .debug)
                        self.emit(.done(self.finalParts.joined()))
                        self.continuation?.finish()
                        return
                    }
                }
            }
        }
    }

    private func emit(_ ev: BYOKStreamEvent) { continuation?.yield(ev) }

    func sendAudio(_ pcm: Data) async {
        try? await transport.send(.data(pcm))  // native PCM16 16 kHz — raw binary
    }

    func endInput() async {
        // Empty-string end-of-stream marker. Log the event type only on a
        // failed send (no payload) so a half-open socket is diagnosable; the
        // session's stop watchdog bounds the resulting receive-side wait.
        do {
            try await transport.send(.text(""))
        } catch {
            os_log("byok soniox endInput send failed", log: Self.log, type: .error)
            self.emit(.error(BYOKStreamErrorCode.endOfStreamSendFailed))
            self.continuation?.finish()
        }
    }

    func close() async {
        receiveTask?.cancel()
        continuation?.finish()
        transport.cancel(reason: "client closed")
    }
}

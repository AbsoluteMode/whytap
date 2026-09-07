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

actor SonioxBYOKSession: BYOKUpstreamSession {
    private let transport: StreamingTransporting
    private var continuation: AsyncStream<BYOKStreamEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var finalParts: [String] = []
    private var ending = false
    private var terminal = false
    private var endInputAt: Double?
    private var audioBytes = 0
    private let clientReferenceID = UUID().uuidString
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "byok-soniox")

    /// Soniox emits one `.final` per token; tokens carry their own leading
    /// spaces, so live composition must concatenate verbatim (same semantics
    /// so words are never split into syllables).
    nonisolated let finalsJoin: BYOKTranscriptJoin = .verbatim

    nonisolated let events: AsyncStream<BYOKStreamEvent>

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
            "client_reference_id": clientReferenceID,
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
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            let result = await self.transport.receive()
            guard !self.terminal, !Task.isCancelled else { return }
            switch result {
            case .failure:
                self.finish(.error("transport"))
                return
            case .success(let frame):
                let data: Data
                switch frame {
                case .text(let value): data = Data(value.utf8)
                case .data(let value): data = value
                }
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.finish(.error("provider"))
                    return
                }
                if let code = obj["error_code"] as? Int {
                    os_log("soniox provider_error session=%{public}@ code=%{public}d",
                           log: Self.log, type: .error, self.clientReferenceID, code)
                    self.finish(.error("provider"))
                    return
                }
                var finalized = false
                if let tokens = obj["tokens"] as? [[String: Any]] {
                    var interim = ""
                    for token in tokens {
                        guard let value = token["text"] as? String else { continue }
                        if value == "<fin>" {
                            finalized = (token["is_final"] as? Bool) == true
                            continue
                        }
                        if value == "<end>" { continue }
                        if (token["is_final"] as? Bool) == true {
                            self.finalParts.append(value)
                            self.emit(.final(value))
                        } else {
                            interim += value
                        }
                    }
                    // An empty tail flushes newly committed final tokens to
                    // the live UI and counts as receive-side progress.
                    self.emit(.partial(interim))
                }
                // After the audio drain, our only finalize request covers
                // ALL audio in this take. <fin> is the provider's explicit
                // acknowledgement; no need to wait for a socket-close frame.
                if (self.ending && finalized) || (obj["finished"] as? Bool) == true {
                    let elapsed = self.endInputAt.map { Int((ProcessInfo.processInfo.systemUptime - $0) * 1000) } ?? -1
                    os_log("soniox complete session=%{public}@ finalize_ms=%{public}d audio_bytes=%{public}d marker=%{public}@",
                           log: Self.log, type: .info, self.clientReferenceID, elapsed, self.audioBytes,
                           finalized ? "fin" : "finished")
                    self.finish(.done(self.finalParts.joined()))
                    return
                }
            }
        }
    }

    private func emit(_ ev: BYOKStreamEvent) { continuation?.yield(ev) }

    private func finish(_ event: BYOKStreamEvent) {
        guard !terminal else { return }
        terminal = true
        emit(event)
        continuation?.finish()
        transport.cancel(reason: "session complete")
    }

    func sendAudio(_ pcm: Data) async {
        guard !terminal, !ending else { return }
        do {
            try await transport.send(.data(pcm))
            audioBytes += pcm.count
        } catch {
            os_log("soniox audio_send_failed session=%{public}@", log: Self.log, type: .error, clientReferenceID)
            finish(.error("transport"))
        }
    }

    func endInput() async {
        guard !ending, !terminal else { return }
        ending = true
        endInputAt = ProcessInfo.processInfo.systemUptime
        // The caller drains every captured chunk before entering here. Soniox
        // recommends ~200ms silence before manual finalization; append PCM
        // silence (never truncate or replace the captured post-release tail).
        // WHY: docs/decisions/2026-09-07-smart-latency.md
        do {
            try await transport.send(.data(Data(repeating: 0, count: 6400)))
            guard !terminal else { return }
            try await transport.send(.text(#"{"type":"finalize"}"#))
            guard !terminal else { return }
            try await transport.send(.text(""))
            os_log("soniox end_input_sent session=%{public}@ audio_bytes=%{public}d",
                   log: Self.log, type: .info, clientReferenceID, audioBytes)
        } catch {
            guard !terminal else { return }
            os_log("soniox end_input_failed session=%{public}@", log: Self.log, type: .error, clientReferenceID)
            finish(.error(BYOKStreamErrorCode.endOfStreamSendFailed))
        }
    }

    func close() async {
        terminal = true
        receiveTask?.cancel()
        continuation?.finish()
        transport.cancel(reason: "client closed")
    }
}

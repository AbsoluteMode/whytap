import Foundation
import os

/// Builds the Deepgram realtime WS URL. Model/language/keyterms ride in the
/// query string (Deepgram has no client config message); repeated `keyterm`
/// params are how Deepgram expects multiple terms.
enum DeepgramRealtimeURL {
    static func make(model: String, language: String?, terms: [String]) -> URL {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]
        if let language, !language.isEmpty { items.append(URLQueryItem(name: "language", value: language)) }
        for term in terms { items.append(URLQueryItem(name: "keyterm", value: term)) }
        comps.queryItems = items
        return comps.url!
    }
}

/// Deepgram Nova-3 BYOK adapter: client-direct with the user's key.
struct DeepgramBYOKAdapter: BYOKTranscriptionAdapter {
    /// Language/terms reach the URL (query), so the factory is parameterized.
    typealias TransportFactory = (_ language: String?, _ terms: [String]) -> StreamingTransporting
    private let makeTransport: TransportFactory

    /// Production: authenticated `URLSessionWebSocketTask` with the URL query.
    init(apiKey: String, model: String) {
        self.makeTransport = { language, terms in
            let url = DeepgramRealtimeURL.make(model: model, language: language, terms: terms)
            var request = URLRequest(url: url)
            request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
            let task = URLSession.shared.webSocketTask(with: request)
            return URLSessionWebSocketTransport(task: task)
        }
    }

    /// Test: inject a transport.
    init(model: String, transport: @escaping TransportFactory) {
        self.makeTransport = transport
    }

    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        let transport = makeTransport(language, terms)
        transport.resume()
        let session = DeepgramBYOKSession(transport: transport)
        session.start()
        return session
    }
}

final class DeepgramBYOKSession: BYOKUpstreamSession, @unchecked Sendable {
    private let transport: StreamingTransporting
    private var continuation: AsyncStream<BYOKStreamEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var finalParts: [String] = []
    private var receivedAnyFrame = false
    /// Diagnostic only — logs event TYPES, never transcript content.
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "byok-deepgram")

    let events: AsyncStream<BYOKStreamEvent>

    init(transport: StreamingTransporting) {
        self.transport = transport
        var cont: AsyncStream<BYOKStreamEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start() { startReceiveLoop() }

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await self.transport.receive()
                switch result {
                case .failure:
                    // Deepgram closes the socket after flushing finals -> terminal.
                    // No frame ever received + no finals => handshake/auth failure.
                    if !self.receivedAnyFrame && self.finalParts.isEmpty {
                        self.emit(.error("transport"))
                    } else {
                        self.emit(.done(self.finalParts.joined(separator: " ")))
                    }
                    self.continuation?.finish()
                    return
                case .success(let frame):
                    self.receivedAnyFrame = true
                    guard case .text(let s) = frame,
                          let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
                    else { continue }
                    let alts = (obj["channel"] as? [String: Any])?["alternatives"] as? [[String: Any]]
                    let transcript = (alts?.first?["transcript"] as? String) ?? ""
                    if transcript.isEmpty { continue }
                    if (obj["is_final"] as? Bool) == true {
                        self.finalParts.append(transcript)
                        os_log("byok deepgram final", log: Self.log, type: .debug)
                        self.emit(.final(transcript))
                    } else {
                        self.emit(.partial(transcript))
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
        // Log the event type only (no payload) on a failed end-of-stream send
        // so a half-open socket is diagnosable; the session's stop watchdog
        // bounds the resulting receive-side wait.
        do {
            try await transport.send(.text(#"{"type":"CloseStream"}"#))
        } catch {
            os_log("byok deepgram endInput send failed", log: Self.log, type: .error)
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

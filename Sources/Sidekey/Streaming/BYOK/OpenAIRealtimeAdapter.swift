import Foundation
import os

/// Adapter for the OpenAI Realtime transcription standard. Used for both the
/// OpenAI preset and any self-hosted / OpenAI-compatible server.
struct OpenAIRealtimeAdapter: BYOKTranscriptionAdapter {
    typealias TransportFactory = () -> StreamingTransporting
    private let model: String
    private let makeTransport: TransportFactory

    /// Production initializer: builds an authenticated `URLSessionWebSocketTask`.
    init(apiKey: String, baseURL: String?, model: String) {
        self.model = model
        self.makeTransport = {
            var request = URLRequest(url: BYOKRealtimeURL.openAIRealtime(baseURL: baseURL))
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // GA Realtime API: NO `OpenAI-Beta: realtime=v1` header — that header
            // selects the retired beta shape (server replies beta_api_shape_disabled).
            let task = URLSession.shared.webSocketTask(with: request)
            return URLSessionWebSocketTransport(task: task)
        }
    }

    /// Test initializer: inject a transport (e.g. StubWebSocketTransport).
    init(model: String, transport: @escaping TransportFactory) {
        self.model = model
        self.makeTransport = transport
    }

    func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
        let transport = makeTransport()
        transport.resume()
        let session = OpenAIRealtimeSession(transport: transport)
        try await session.start(model: model, language: language, terms: terms)
        return session
    }
}

final class OpenAIRealtimeSession: BYOKUpstreamSession, @unchecked Sendable {
    private let transport: StreamingTransporting
    private var continuation: AsyncStream<BYOKStreamEvent>.Continuation?
    private var receiveTask: Task<Void, Never>?
    private var finalParts: [String] = []
    /// Diagnostic only — logs upstream event TYPES (never transcript content,
    /// keys, or audio) so a live OpenAI/self-hosted protocol mismatch is
    /// visible (`log stream --predicate 'category == "byok-openai-realtime"'`).
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "byok-openai-realtime")
    /// OpenAI Realtime GA requires input PCM at >= 24 kHz; our capture is 16 kHz.
    static let outputSampleRate = 24_000

    let events: AsyncStream<BYOKStreamEvent>

    init(transport: StreamingTransporting) {
        self.transport = transport
        var cont: AsyncStream<BYOKStreamEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func start(model: String, language: String?, terms: [String]) async throws {
        var tx: [String: Any] = ["model": model]
        if let language { tx["language"] = language }
        if !terms.isEmpty { tx["prompt"] = terms.joined(separator: ", ") }
        // OpenAI Realtime GA transcription shape: config nested under
        // session.audio.input; PCM rate must be >= 24 kHz (we upsample the
        // 16 kHz capture in sendAudio); turn_detection=null gives push-to-talk
        // (we commit on hotkey release, not on VAD-detected pauses).
        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": Self.outputSampleRate],
                    "transcription": tx,
                    "turn_detection": NSNull(),
                ]],
            ],
        ]
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
                    return
                case .success(let frame):
                    guard case .text(let s) = frame,
                          let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                          let type = obj["type"] as? String else { continue }
                    os_log("byok openai event type=%{public}@", log: Self.log, type: .debug, type)
                    switch type {
                    case "conversation.item.input_audio_transcription.delta":
                        if let d = obj["delta"] as? String { self.emit(.partial(d)) }
                    case "conversation.item.input_audio_transcription.completed":
                        let text = (obj["transcript"] as? String) ?? ""
                        self.finalParts.append(text)
                        self.emit(.final(text))
                        self.emit(.done(self.finalParts.joined(separator: " ")))
                        self.continuation?.finish()
                        return
                    case "error":
                        self.emit(.error("provider"))
                        self.continuation?.finish()
                        return
                    default:
                        continue
                    }
                }
            }
        }
    }

    private func emit(_ ev: BYOKStreamEvent) { continuation?.yield(ev) }

    func sendAudio(_ pcm: Data) async {
        let upsampled = Self.upsample16kTo24k(pcm)
        let msg: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": upsampled.base64EncodedString(),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: msg) {
            try? await transport.send(.text(String(decoding: data, as: UTF8.self)))
        }
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
        // Log the event type only (no payload) on a failed commit so a
        // half-open socket is diagnosable; the session's stop watchdog bounds
        // the resulting receive-side wait.
        let msg: [String: Any] = ["type": "input_audio_buffer.commit"]
        guard let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        do {
            try await transport.send(.text(String(decoding: data, as: UTF8.self)))
        } catch {
            os_log("byok openai realtime endInput send failed", log: Self.log, type: .error)
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

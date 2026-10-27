import Foundation
import os

protocol ModelProbing: Sendable {
    func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome
}

/// Tries a model with a synthetic request before the user relies on it: one
/// second of silence for speech models, a one-word prompt for text models. The
/// request goes only to the route's own provider. Logs the provider, the use,
/// the outcome and the milliseconds taken; never a model id, a key or an answer.
// WHY: .project-docs/decisions/2026-10-19-api-and-models.md
struct ModelProbe: ModelProbing {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "model-probe")

    /// One second of PCM16 mono at 16 kHz, all zeros.
    static let silence = Data(count: 16_000 * 2)
    private static let frameSize = 3_200

    private let session: URLSession
    private let makeRealtimeAdapter: @Sendable (ResolvedRoute) throws -> BYOKTranscriptionAdapter
    private let timeout: Duration

    init(
        session: URLSession = .shared,
        makeRealtimeAdapter: @escaping @Sendable (ResolvedRoute) throws -> BYOKTranscriptionAdapter = { try ModelProbe.headerAuthenticatedAdapter($0) },
        timeout: Duration = .seconds(15)
    ) {
        self.session = session
        self.makeRealtimeAdapter = makeRealtimeAdapter
        self.timeout = timeout
    }

    /// The real-time adapter of the route, with the key in the handshake
    /// header where the provider takes it there. Soniox's runtime adapter puts
    /// the key in its config frame; the probe sends it in the header the spec
    /// asks for. The other providers authenticate as they do at runtime (a
    /// server without a key sends no `Authorization`).
    static func headerAuthenticatedAdapter(_ route: ResolvedRoute) throws -> BYOKTranscriptionAdapter {
        switch route.account {
        case .soniox:
            guard let key = route.apiKey, !key.isEmpty else { throw FeatureRouteError.missingKey(route.feature) }
            return SonioxBYOKAdapter(apiKey: key, model: route.model, transport: {
                let task = URLSession.shared.webSocketTask(with: SonioxBYOKAdapter.handshakeRequest(apiKey: key))
                return URLSessionWebSocketTransport(task: task)
            })
        case .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic, .server:
            return try RealtimeAdapterFactory.make(route)
        }
    }

    func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
        let started = ContinuousClock.now
        let outcome: ProbeOutcome
        switch use {
        case .realtimeSTT: outcome = await probeRealtime(route)
        case .asyncSTT: outcome = await probeAsync(route)
        case .chat: outcome = await probeChat(route, withTools: false, catalog: catalog)
        case .chatWithTools: outcome = await probeChat(route, withTools: true, catalog: catalog)
        case .decision:
            // A synthetic one-word state, never meeting speech.
            do {
                _ = try await MeetingAssistantDetector(session: session, timeout: timeout, usageSink: { _ in })
                    .verdict(route: route, newSpeech: "Hello.", context: "", offered: [])
                outcome = .passed
            } catch is MeetingQuestionError {
                outcome = .inconclusive(reason: "No decision returned")
            } catch let error as OpenRouterLLMError where error.isModelRefusal {
                outcome = .failed(reason: "The provider refused this decision model")
            } catch {
                outcome = .inconclusive(reason: "Couldn't reach the decision API")
            }
        }
        os_log("model probe provider=%{public}@ use=%{public}@ outcome=%{public}@ ms=%{public}d",
               log: Self.log, type: .info,
               route.account.kind.rawValue, use.rawValue, Self.label(outcome), Self.milliseconds(since: started))
        return outcome
    }

    // MARK: - Real-time

    private func probeRealtime(_ route: ResolvedRoute) async -> ProbeOutcome {
        let maker = makeRealtimeAdapter
        let outcome = await withTimeout { await Self.runRealtime(route, makeAdapter: maker) }
        if let outcome { return outcome }
        // A timeout may be a slow network as much as an unknown dialect, so it
        // is never kept as a failure.
        if case .server = route.account {
            return .inconclusive(reason: "No answer from the server (its realtime dialect may differ)")
        }
        return .inconclusive(reason: "No answer from the provider")
    }

    /// Adapter codes for a broken connection (a dropped socket, a refused
    /// upgrade, a failed end-of-stream send): no verdict on the model.
    private static let transportErrorCodes: Set<String> = ["transport", BYOKStreamErrorCode.endOfStreamSendFailed]

    private static func runRealtime(
        _ route: ResolvedRoute,
        makeAdapter: @Sendable (ResolvedRoute) throws -> BYOKTranscriptionAdapter
    ) async -> ProbeOutcome {
        let upstream: BYOKUpstreamSession
        do {
            let adapter = try makeAdapter(route)
            // "en" passes Deepgram's language policy for every model.
            upstream = try await adapter.open(language: "en", terms: [])
        } catch let error as FeatureRouteError {
            return error.isKeyProblem
                ? .inconclusive(reason: "Key problem")
                : .inconclusive(reason: "Not set up")
        } catch is URLError {
            return .inconclusive(reason: "No connection")
        } catch {
            return .inconclusive(reason: "Could not open the connection")
        }

        var offset = 0
        while offset < silence.count {
            let end = min(offset + frameSize, silence.count)
            await upstream.sendAudio(silence.subdata(in: offset..<end))
            offset = end
        }
        await upstream.endInput()

        var outcome = ProbeOutcome.passed
        for await event in upstream.events {
            switch event {
            case .error(let message) where transportErrorCodes.contains(message):
                outcome = .inconclusive(reason: "No connection")
            case .error(let message):
                outcome = .failed(reason: "Provider refused: " + shortened(message))
            case .done:
                outcome = .passed
            case .partial, .final:
                continue
            }
            break
        }
        await upstream.close()
        return outcome
    }

    // MARK: - Recorded

    private func probeAsync(_ route: ResolvedRoute) async -> ProbeOutcome {
        guard case .soniox = route.account else { return .inconclusive(reason: "Not supported yet") }
        guard let key = route.apiKey, !key.isEmpty else { return .inconclusive(reason: "Key problem") }
        let model = route.model
        let session = session
        let outcome: ProbeOutcome? = await withTimeout {
            let transcriber = ProviderBatchTranscriber(route: { .soniox(apiKey: key, model: model) }, session: session)
            do {
                _ = try await transcriber.transcribe(audio: Self.silence, language: "en")
                return .passed
            } catch ProviderBatchTranscriptionError.httpStatus(let code) where [400, 404, 422].contains(code) {
                return .failed(reason: "Provider refused the model (HTTP \(code))")
            } catch is URLError {
                return .inconclusive(reason: "No connection")
            } catch {
                return .inconclusive(reason: "No answer from the provider")
            }
        }
        return outcome ?? .inconclusive(reason: "No answer from the provider")
    }

    // MARK: - Chat

    private struct ChatBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Preferences: Encodable {
            let requireParameters: Bool
            enum CodingKeys: String, CodingKey { case requireParameters = "require_parameters" }
        }
        struct Empty: Encodable {}
        struct Tool: Encodable {
            struct Function: Encodable {
                struct Parameters: Encodable {
                    let type: String
                    let properties: Empty
                }
                let name: String
                let description: String
                let parameters: Parameters
            }
            let type: String
            let function: Function
        }

        let model: String
        let messages: [Message]
        let maxTokens: Int?
        var maxCompletionTokens: Int? = nil
        let stream: Bool
        let provider: Preferences?
        let reasoning: OpenRouterReasoningSetting?
        let tools: [Tool]?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, provider, reasoning, tools
            case maxTokens = "max_tokens"
            case maxCompletionTokens = "max_completion_tokens"
        }
    }

    private func probeChat(_ route: ResolvedRoute, withTools: Bool, catalog: CatalogModel?) async -> ProbeOutcome {
        let key = route.apiKey.flatMap { $0.isEmpty ? nil : $0 }
        let url: URL
        let isOpenRouter: Bool
        switch route.account {
        case .openRouter:
            guard key != nil else { return .inconclusive(reason: "Key problem") }
            url = URL(string: "https://openrouter.ai/api/v1")!
            isOpenRouter = true
        case .server:
            guard let base = Self.serverBaseURL(route.server) else { return .inconclusive(reason: "Invalid server address") }
            url = base
            isOpenRouter = false
        case .anthropic:
            return await probeAnthropic(route, withTools: withTools)
        case .openAI:
            guard key != nil else { return .inconclusive(reason: "Key problem") }
            url = URL(string: "https://api.openai.com/v1")!
            isOpenRouter = false
        case .soniox, .deepgram, .elevenLabs:
            return .inconclusive(reason: "Not supported yet")
        }

        var maxTokens = 16
        var attempt = 0
        while true {
            attempt += 1
            let body = ChatBody(
                model: route.model,
                messages: [.init(role: "user", content: "Reply with OK.")],
                maxTokens: route.account == .openAI ? nil : maxTokens,
                maxCompletionTokens: route.account == .openAI ? 512 : nil,
                stream: false,
                provider: isOpenRouter ? .init(requireParameters: true) : nil,
                reasoning: isOpenRouter ? catalog?.reasoning?.dictationSetting : nil,
                tools: withTools ? [Self.probeTool] : nil
            )
            var request = URLRequest(url: url.appendingPathComponent("chat").appendingPathComponent("completions"))
            request.httpMethod = "POST"
            request.timeoutInterval = Self.seconds(timeout)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            guard let encoded = try? JSONEncoder().encode(body) else { return .inconclusive(reason: "Could not build the request") }
            request.httpBody = encoded

            let data: Data
            let status: Int
            do {
                let (received, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .inconclusive(reason: "No connection") }
                data = received
                status = http.statusCode
            } catch {
                return .inconclusive(reason: "No connection")
            }

            if status == 400, attempt == 1, String(decoding: data, as: UTF8.self).contains("max_tokens") {
                maxTokens = 512
                continue
            }
            return Self.interpretChat(status: status, data: data, key: key)
        }
    }

    private static let probeTool = ChatBody.Tool(
        type: "function",
        function: .init(
            name: "whytap_probe",
            description: "Probe tool. Do not call.",
            parameters: .init(type: "object", properties: .init())
        )
    )

    // MARK: - Anthropic

    private struct AnthropicBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Tool: Encodable {
            struct Schema: Encodable {
                let type: String
                let properties: ChatBody.Empty
            }
            let name: String
            let description: String
            let inputSchema: Schema
            enum CodingKeys: String, CodingKey {
                case name, description
                case inputSchema = "input_schema"
            }
        }

        let model: String
        let maxTokens: Int
        let messages: [Message]
        let tools: [Tool]?

        enum CodingKeys: String, CodingKey {
            case model, messages, tools
            case maxTokens = "max_tokens"
        }
    }

    /// Anthropic's Messages API with one fake tool and no `tool_choice`
    /// (forced tool use is a 400 on current models). Any 2xx passes, a reply
    /// cut off at `max_tokens` included.
    private func probeAnthropic(_ route: ResolvedRoute, withTools: Bool) async -> ProbeOutcome {
        guard let key = route.apiKey, !key.isEmpty else { return .inconclusive(reason: "Key problem") }
        let body = AnthropicBody(
            model: route.model,
            maxTokens: 16,
            messages: [.init(role: "user", content: "Reply with OK.")],
            tools: withTools ? [Self.anthropicProbeTool] : nil
        )
        guard let encoded = try? JSONEncoder().encode(body) else { return .inconclusive(reason: "Could not build the request") }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.seconds(timeout)
        for (name, value) in ModelCatalogFetcher.anthropicHeaders(apiKey: key) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = encoded

        let data: Data
        let status: Int
        do {
            let (received, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .inconclusive(reason: "No connection") }
            data = received
            status = http.statusCode
        } catch {
            return .inconclusive(reason: "No connection")
        }
        switch status {
        case 200..<300:
            return .passed
        case 400, 404:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = object.flatMap { Self.providerMessage($0, key: key) } ?? "HTTP \(status)"
            return .failed(reason: "Provider refused: " + message)
        case 401, 402, 403:
            return .inconclusive(reason: "Key problem")
        default:
            return .inconclusive(reason: "No answer from the provider")
        }
    }

    private static let anthropicProbeTool = AnthropicBody.Tool(
        name: "whytap_probe",
        description: "Probe tool. Do not call.",
        inputSchema: .init(type: "object", properties: .init())
    )

    private static func interpretChat(status: Int, data: Data, key: String?) -> ProbeOutcome {
        switch status {
        case 200..<300:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .inconclusive(reason: "Unexpected answer")
            }
            if let choices = object["choices"] as? [Any], !choices.isEmpty { return .passed }
            return .failed(reason: "Provider refused: " + (providerMessage(object, key: key) ?? "empty answer"))
        case 400, 404, 422:
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = object.flatMap { providerMessage($0, key: key) } ?? "HTTP \(status)"
            return .failed(reason: "Provider refused: " + message)
        case 401, 402, 403:
            return .inconclusive(reason: "Key problem")
        default:
            return .inconclusive(reason: "No answer from the provider")
        }
    }

    /// The provider's own error message (`error.message`, `error` or
    /// `message`), shortened. A message that repeats the key is cut off there.
    private static func providerMessage(_ object: [String: Any], key: String?) -> String? {
        var message: String?
        if let error = object["error"] as? [String: Any] {
            message = error["message"] as? String
        } else if let error = object["error"] as? String {
            message = error
        } else {
            message = object["message"] as? String
        }
        guard var message, !message.isEmpty else { return nil }
        if let key, !key.isEmpty { message = message.replacingOccurrences(of: key, with: "…") }
        return shortened(message)
    }

    private static func serverBaseURL(_ server: ServerEndpoint?) -> URL? {
        guard let raw = server?.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil
        else { return nil }
        return url
    }

    // MARK: - Helpers

    /// `nil` when `timeout` passes first. The work is cancelled then.
    private func withTimeout(_ work: @escaping @Sendable () async -> ProbeOutcome) async -> ProbeOutcome? {
        let limit = timeout
        return await withTaskGroup(of: ProbeOutcome?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func shortened(_ message: String) -> String {
        let flat = message.split(whereSeparator: \.isNewline).joined(separator: " ")
        return String(flat.prefix(120))
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    private static func label(_ outcome: ProbeOutcome) -> String {
        switch outcome {
        case .passed: return "passed"
        case .failed: return "failed"
        case .inconclusive: return "inconclusive"
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now).components
        return Int(elapsed.seconds) * 1000 + Int(elapsed.attoseconds / 1_000_000_000_000_000)
    }
}

private extension FeatureRouteError {
    var isKeyProblem: Bool {
        if case .missingKey = self { return true }
        return false
    }
}

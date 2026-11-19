import Foundation
import OSLog

struct OpenRouterModelOption: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    var reasoning: OpenRouterReasoningCapabilities? = nil

    var displayName: String {
        name == id ? id : "\(name) · \(id)"
    }

    static let fallback: [OpenRouterModelOption] = [
        .init(id: "openai/gpt-4o-mini", name: "GPT-4o mini"),
        .init(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4"),
        .init(id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash"),
        .init(id: "openai/gpt-4o", name: "GPT-4o"),
        .init(id: "meta-llama/llama-3.1-70b-instruct", name: "Llama 3.1 70B Instruct"),
        .init(id: "openrouter/auto", name: "Auto Router (OpenRouter chooses)"),
    ]
}

struct OpenRouterChatMessage: Codable, Equatable {
    let role: String
    let content: String
}

struct OpenAICompatibleLLMEndpoint: Equatable {
    enum TextAPI: Equatable { case chatCompletions, openAI, anthropic }
    let baseURL: URL
    let apiKey: String?
    let requiresAPIKey: Bool
    let sendsOpenRouterHeaders: Bool
    /// OpenRouter endpoint tag the request must use, with no fallback; `nil`
    /// lets OpenRouter pick.
    var pinnedProvider: String? = nil
    var textAPI: TextAPI = .chatCompletions

    static func openAI(apiKey: String?) -> OpenAICompatibleLLMEndpoint {
        .init(baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: apiKey,
              requiresAPIKey: true, sendsOpenRouterHeaders: false, textAPI: .openAI)
    }

    static func anthropic(apiKey: String?) -> OpenAICompatibleLLMEndpoint {
        .init(baseURL: URL(string: "https://api.anthropic.com/v1")!, apiKey: apiKey,
              requiresAPIKey: true, sendsOpenRouterHeaders: false, textAPI: .anthropic)
    }

    /// Groq speaks plain Chat Completions on its own host, with its own key.
    static let groqBaseURL = URL(string: "https://api.groq.com/openai/v1")!

    static func groq(apiKey: String?) -> OpenAICompatibleLLMEndpoint {
        .init(baseURL: groqBaseURL, apiKey: apiKey, requiresAPIKey: true, sendsOpenRouterHeaders: false)
    }

    static func openRouter(apiKey: String?, provider: String? = nil) -> OpenAICompatibleLLMEndpoint {
        OpenAICompatibleLLMEndpoint(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            apiKey: apiKey,
            requiresAPIKey: true,
            sendsOpenRouterHeaders: true,
            pinnedProvider: provider
        )
    }

    static func custom(baseURL: URL, apiKey: String?) -> OpenAICompatibleLLMEndpoint {
        OpenAICompatibleLLMEndpoint(
            baseURL: baseURL,
            apiKey: apiKey,
            requiresAPIKey: false,
            sendsOpenRouterHeaders: false
        )
    }
}

enum OpenRouterLLMError: Error, CustomStringConvertible, Equatable {
    /// No LLM route is chosen in Settings -> API & Models.
    case notConfigured
    case missingKey
    case missingBaseURL
    case invalidBaseURL(String)
    case missingModel
    case unexpectedStatus(Int, String?)
    case emptyContent
    case outputLimitReached
    case inputRejected
    case decoding(String)

    var description: String {
        switch self {
        case .notConfigured:
            return "No LLM is chosen in Settings > API & Models."
        case .missingKey:
            return "LLM API key is missing."
        case .missingBaseURL:
            return "LLM base URL is missing."
        case .invalidBaseURL(let value):
            return "LLM base URL is invalid: \(value)"
        case .missingModel:
            return "LLM model is missing."
        case .unexpectedStatus(let status, let message):
            if let message, !message.isEmpty {
                return "LLM API error \(status): \(message)"
            }
            return "LLM API error \(status)."
        case .emptyContent:
            return "LLM endpoint returned an empty response."
        case .outputLimitReached:
            return "The model reached its output limit. Try a shorter request."
        case .inputRejected:
            return "The provider rejected the input. Try a shorter request."
        case .decoding(let message):
            return "Could not parse LLM response: \(message)"
        }
    }
}

protocol OpenRouterLLMClienting {
    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption]
    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String
}

extension OpenRouterLLMClienting {
    func complete(route: DirectLLMRoute, messages: [OpenRouterChatMessage]) async throws -> String {
        try await AIUsageTaskScope.$context.withValue(route.usageContext) {
            try await complete(endpoint: route.endpoint, model: route.model, messages: messages)
        }
    }
    func listModels(apiKey: String?) async throws -> [OpenRouterModelOption] {
        try await listModels(endpoint: .openRouter(apiKey: apiKey))
    }

    func complete(apiKey: String, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        try await complete(endpoint: .openRouter(apiKey: apiKey), model: model, messages: messages)
    }
}

struct OpenRouterLLMClient: OpenRouterLLMClienting {
    enum Profile { case standard, dictation }
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "cleanup-llm")
    private let profile: Profile
    private let reasoningCatalog: OpenRouterReasoningCatalog
    let baseURL: URL
    let session: URLSession
    let usageSink: (AIUsageEvent) -> Void

    init(
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        session: URLSession = .shared,
        profile: Profile = .standard,
        reasoningCatalog: OpenRouterReasoningCatalog = OpenRouterReasoningCatalog(),
        usageSink: @escaping (AIUsageEvent) -> Void = AIUsageRecorder.record
    ) {
        self.baseURL = baseURL
        self.session = session
        self.profile = profile
        self.reasoningCatalog = reasoningCatalog
        self.usageSink = usageSink
    }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, endpoint: endpoint)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, body: data)

        struct ModelsResponse: Decodable {
            struct Model: Decodable {
                struct Architecture: Decodable {
                    let outputModalities: [String]?

                    enum CodingKeys: String, CodingKey {
                        case outputModalities = "output_modalities"
                    }
                }

                let id: String
                let name: String?
                let architecture: Architecture?
                let reasoning: OpenRouterReasoningCapabilities?
            }

            let data: [Model]
        }

        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            let models = decoded.data
                .filter { model in
                    let outputs = model.architecture?.outputModalities ?? ["text"]
                    return outputs.contains("text")
                }
                .map { OpenRouterModelOption(id: $0.id, name: $0.name ?? $0.id, reasoning: $0.reasoning) }
            if endpoint.sendsOpenRouterHeaders { await reasoningCatalog.update(models) }
            return models
        } catch {
            throw OpenRouterLLMError.decoding(error.localizedDescription)
        }
    }

    func listModels(apiKey: String?) async throws -> [OpenRouterModelOption] {
        try await listModels(endpoint: OpenAICompatibleLLMEndpoint(
            baseURL: baseURL,
            apiKey: apiKey,
            requiresAPIKey: true,
            sendsOpenRouterHeaders: true
        ))
    }

    /// Drops one leading `<think>…</think>` block. An unclosed block means the
    /// answer never started, so nothing of it is kept.
    static func withoutLeadingThinkBlock(_ content: String) -> String {
        let trimmed = content.drop(while: \.isWhitespace)
        guard trimmed.hasPrefix("<think>") else { return content }
        guard let end = trimmed.range(of: "</think>") else { return "" }
        return String(trimmed[end.upperBound...].drop(while: \.isWhitespace))
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        let trimmedKey = endpoint.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if endpoint.requiresAPIKey, trimmedKey.isEmpty { throw OpenRouterLLMError.missingKey }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { throw OpenRouterLLMError.missingModel }
        if endpoint.textAPI == .anthropic {
            return try await completeAnthropic(endpoint: endpoint, model: trimmedModel, messages: messages)
        }

        var request = URLRequest(
            url: endpoint.baseURL
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request, endpoint: endpoint)

        let discoveryStarted = ProcessInfo.processInfo.systemUptime
        let reasoning: OpenRouterReasoningSetting?
        if profile == .dictation, endpoint.sendsOpenRouterHeaders {
            reasoning = await reasoningCatalog.setting(model: trimmedModel, baseURL: endpoint.baseURL, session: session)
        } else {
            reasoning = nil
        }
        try Task.checkCancellation()
        let discoveryMs = Int((ProcessInfo.processInfo.systemUptime - discoveryStarted) * 1000)
        let provider = providerPreferences(for: endpoint)
        struct ChatRequest: Encodable {
            let model: String
            let messages: [OpenRouterChatMessage]
            let temperature: Double?
            let stream: Bool
            let reasoning: OpenRouterReasoningSetting?
            let provider: ProviderPreferences?
        }
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: trimmedModel, messages: messages,
                        temperature: endpoint.textAPI == .openAI ? nil : 0.1,
                        stream: false, reasoning: reasoning, provider: provider)
        )

        let requestStarted = ProcessInfo.processInfo.systemUptime
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let context = AIUsageTaskScope.context {
                usageSink(AIUsageEvent(context: context, currency: .usd, amount: nil, basis: .unavailable))
            }
            throw error
        }
        let requestMs = Int((ProcessInfo.processInfo.systemUptime - requestStarted) * 1000)
        try validate(response: response, body: data)
        if let context = AIUsageTaskScope.context {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let usage = object?["usage"] as? [String: Any]
            let cost = AIUsageNumber.nonnegative(usage?["cost"])
            let amount = endpoint.sendsOpenRouterHeaders ? cost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
            let actual = (object?["model"] as? String).flatMap { !$0.isEmpty && $0.count <= 512 ? $0 : nil } ?? context.model
            usageSink(AIUsageEvent(context: .init(feature: context.feature, account: context.account, model: actual),
                                   currency: .usd, amount: amount, basis: amount == nil ? .unavailable : .reported))
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            struct Usage: Decodable {
                struct Details: Decodable { let reasoning_tokens: Int? }
                let completion_tokens: Int?
                let completion_tokens_details: Details?
            }
            let id: String?
            let usage: Usage?
            let choices: [Choice]
        }

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            if profile == .dictation {
                // No prompt, reply, reasoning text, key, URL, or provider error body.
                // Only catalog identifiers (OpenRouter) and numeric diagnostics.
                let modelID = endpoint.sendsOpenRouterHeaders ? Self.safeDiagnosticID(trimmedModel) : "custom"
                let requestID = endpoint.sendsOpenRouterHeaders ? Self.safeDiagnosticID(decoded.id) : "unavailable"
                os_log("cleanup model=%{public}@ request_id=%{public}@ effort=%{public}@ catalog_ms=%{public}d llm_ms=%{public}d completion_tokens=%{public}d reasoning_tokens=%{public}d",
                       log: Self.log, type: .info,
                       modelID, requestID, reasoning?.diagnosticLabel ?? "default",
                       discoveryMs, requestMs, decoded.usage?.completion_tokens ?? -1,
                       decoded.usage?.completion_tokens_details?.reasoning_tokens ?? -1)
            }
            guard var content = decoded.choices.first?.message.content else {
                throw OpenRouterLLMError.emptyContent
            }
            // Without tools Groq's reasoning models may put their thinking in
            // the text itself; it must never be pasted as the user's words.
            if endpoint.baseURL == OpenAICompatibleLLMEndpoint.groqBaseURL {
                content = Self.withoutLeadingThinkBlock(content)
            }
            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenRouterLLMError.emptyContent
            }
            return content
        } catch let error as OpenRouterLLMError {
            throw error
        } catch {
            throw OpenRouterLLMError.decoding(error.localizedDescription)
        }
    }

    func complete(apiKey: String, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        try await complete(endpoint: OpenAICompatibleLLMEndpoint(
            baseURL: baseURL,
            apiKey: apiKey,
            requiresAPIKey: true,
            sendsOpenRouterHeaders: true
        ), model: model, messages: messages)
    }

    struct ProviderPreferences: Encodable, Equatable {
        var sort: String? = nil
        var order: [String]? = nil
        var allow_fallbacks: Bool? = nil
    }

    /// A pinned provider is used alone: a choice the user made is not quietly
    /// swapped for another provider. Auto keeps OpenRouter's routing, sorted by
    /// throughput for dictation.
    func providerPreferences(for endpoint: OpenAICompatibleLLMEndpoint) -> ProviderPreferences? {
        guard endpoint.sendsOpenRouterHeaders else { return nil }
        if let pinned = endpoint.pinnedProvider {
            return ProviderPreferences(order: [pinned], allow_fallbacks: false)
        }
        // WHY: docs/decisions/2026-09-07-smart-latency.md
        return profile == .dictation ? ProviderPreferences(sort: "throughput") : nil
    }

    private static func safeDiagnosticID(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 150,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/.:~").contains($0) })
        else { return "unavailable" }
        return value
    }

    private func applyCommonHeaders(to request: inout URLRequest, endpoint: OpenAICompatibleLLMEndpoint) {
        let trimmed = endpoint.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        }
        if endpoint.sendsOpenRouterHeaders {
            request.setValue(BuildConfig.landingURL.absoluteString, forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Whytap", forHTTPHeaderField: "X-Title")
        }
    }

    private func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterLLMError.unexpectedStatus(-1, nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenRouterLLMError.unexpectedStatus(http.statusCode, Self.errorMessage(from: body))
        }
    }

    private static func errorMessage(from body: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct Payload: Decodable {
                let message: String?
                let code: String?
            }
            let error: Payload?
        }
        if let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
            return decoded.error?.message ?? decoded.error?.code
        }
        return String(data: body, encoding: .utf8)
    }
}

protocol OpenRouterLLMKeyStoring {
    func save(key: String) throws
    func read() throws -> String?
    func delete() throws
}

struct OpenRouterLLMKeyStore: OpenRouterLLMKeyStoring {
    static let account = "byok.openrouter.llm_api_key"

    private var store: KeychainStore {
        KeychainStore(service: BuildConfig.keychainService, account: Self.account)
    }

    func save(key: String) throws {
        try store.save(key)
    }

    func read() throws -> String? {
        try store.read()
    }

    func delete() throws {
        try store.delete()
    }
}

struct CustomLLMKeyStore: OpenRouterLLMKeyStoring {
    static let account = "byok.custom_llm.api_key"

    private var store: KeychainStore {
        KeychainStore(service: BuildConfig.keychainService, account: Self.account)
    }

    func save(key: String) throws {
        try store.save(key)
    }

    func read() throws -> String? {
        try store.read()
    }

    func delete() throws {
        try store.delete()
    }
}

import Foundation

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
    /// No LLM route is chosen in Settings -> Keys & models.
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
            return "No LLM is chosen in Settings > Keys & models."
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
    /// `dictation` is the OpenRouter latency profile (Smart and translation);
    /// `smart` is Drop Smart cleanup, which also asks direct Anthropic and
    /// OpenAI models for the least reasoning (`SmartDirectReasoning`).
    enum Profile { case standard, dictation, smart }
    let profile: Profile
    private let reasoningCatalog: OpenRouterReasoningCatalog
    let reasoningRefusals: SmartReasoningRefusals
    private var isDictation: Bool { profile != .standard }
    let baseURL: URL
    let session: URLSession
    let usageSink: (AIUsageEvent) -> Void
    /// Receives each stored timing line; the default writes it to the log.
    let diagnostics: (CleanupDiagnostics) -> Void

    init(
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        session: URLSession = .shared,
        profile: Profile = .standard,
        reasoningCatalog: OpenRouterReasoningCatalog = OpenRouterReasoningCatalog(),
        reasoningRefusals: SmartReasoningRefusals = .shared,
        usageSink: @escaping (AIUsageEvent) -> Void = AIUsageRecorder.record,
        diagnostics: @escaping (CleanupDiagnostics) -> Void = CleanupDiagnostics.write
    ) {
        self.baseURL = baseURL
        self.session = session
        self.profile = profile
        self.reasoningCatalog = reasoningCatalog
        self.reasoningRefusals = reasoningRefusals
        self.usageSink = usageSink
        self.diagnostics = diagnostics
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
        if isDictation, endpoint.sendsOpenRouterHeaders {
            reasoning = await reasoningCatalog.setting(model: trimmedModel, baseURL: endpoint.baseURL, session: session)
        } else {
            reasoning = nil
        }
        try Task.checkCancellation()
        let discoveryMs = Int((ProcessInfo.processInfo.systemUptime - discoveryStarted) * 1000)
        let provider = providerPreferences(for: endpoint)
        // WHY: .project-docs/decisions/2026-11-24-smart-minimal-reasoning.md
        var directEffort: String? = nil
        if profile == .smart, endpoint.textAPI == .openAI, !reasoningRefusals.contains(.openAI, model: trimmedModel) {
            directEffort = SmartDirectReasoning.openAIEffort(model: trimmedModel)
        }
        struct ChatRequest: Encodable {
            let model: String
            let messages: [OpenRouterChatMessage]
            let temperature: Double?
            let stream: Bool
            let reasoning: OpenRouterReasoningSetting?
            let reasoning_effort: String?
            let provider: ProviderPreferences?
        }
        func body(effort: String?) throws -> Data {
            try JSONEncoder().encode(
                ChatRequest(model: trimmedModel, messages: messages,
                            temperature: endpoint.textAPI == .openAI ? nil : 0.1,
                            stream: false, reasoning: reasoning, reasoning_effort: effort, provider: provider)
            )
        }
        func send() async throws -> (Data, URLResponse) {
            do {
                return try await session.data(for: request)
            } catch {
                if let context = AIUsageTaskScope.context {
                    usageSink(AIUsageEvent(context: context, currency: .usd, amount: nil, basis: .unavailable))
                }
                throw error
            }
        }
        request.httpBody = try body(effort: directEffort)

        let requestStarted = ProcessInfo.processInfo.systemUptime
        var (data, response) = try await send()
        var refusedEffort = false
        if directEffort != nil, (response as? HTTPURLResponse)?.statusCode == 400 {
            // The request goes once more exactly as before this policy. The
            // model is marked below, only once that repeat returns an answer;
            // a request refused both ways (too long an input, a model that is
            // gone) says nothing about the field.
            refusedEffort = true
            try Task.checkCancellation()
            request.httpBody = try body(effort: nil)
            (data, response) = try await send()
        }
        let requestMs = Int((ProcessInfo.processInfo.systemUptime - requestStarted) * 1000)
        let effortLabel = reasoning?.diagnosticLabel ?? (refusedEffort ? nil : directEffort) ?? "default"
        if isDictation {
            // Fixed words, verified catalog names and numbers only; the saved
            // model name, the reply and an error body never get here.
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let usage = object?["usage"] as? [String: Any]
            var line = CleanupDiagnostics(provider: "custom", model: "custom", effort: effortLabel,
                                          status: (response as? HTTPURLResponse)?.statusCode ?? -1, llmMs: requestMs)
            if endpoint.sendsOpenRouterHeaders {
                line.provider = "openrouter"
                line.model = CleanupDiagnosticModel.openRouter(trimmedModel, listed: await reasoningCatalog.lists(trimmedModel))
                line.requestID = Self.openRouterRequestID(object?["id"] as? String)
            } else if endpoint.textAPI == .openAI {
                line.provider = "openai"
                line.model = CleanupDiagnosticModel.openAI(trimmedModel)
            }
            line.catalogMs = discoveryMs
            line.outputTokens = (usage?["completion_tokens"] as? Int) ?? -1
            line.reasoningTokens = ((usage?["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int) ?? -1
            line.effortRefused = refusedEffort
            diagnostics(line)
        }
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
            guard let content = decoded.choices.first?.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw OpenRouterLLMError.emptyContent
            }
            // The repeat without the field produced a real answer: the field
            // was the reason, and this model gets none again. A status alone
            // does not prove it (a proxy can answer 200 with its own page).
            if refusedEffort { reasoningRefusals.record(.openAI, model: trimmedModel) }
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
        return isDictation ? ProviderPreferences(sort: "throughput") : nil
    }

    /// OpenRouter's generation ID (`gen-…`), for looking a request up in its
    /// dashboard. Anything of another shape in the response is not logged.
    static func openRouterRequestID(_ value: String?) -> String {
        guard let value, value.hasPrefix("gen-"), value.count <= 80,
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) })
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

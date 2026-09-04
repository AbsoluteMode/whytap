import Foundation

struct OpenRouterModelOption: Identifiable, Equatable, Hashable {
    let id: String
    let name: String

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
    let baseURL: URL
    let apiKey: String?
    let requiresAPIKey: Bool
    let sendsOpenRouterHeaders: Bool

    static func openRouter(apiKey: String?) -> OpenAICompatibleLLMEndpoint {
        OpenAICompatibleLLMEndpoint(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            apiKey: apiKey,
            requiresAPIKey: true,
            sendsOpenRouterHeaders: true
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
    case missingKey
    case missingBaseURL
    case invalidBaseURL(String)
    case missingModel
    case unexpectedStatus(Int, String?)
    case emptyContent
    case decoding(String)

    var description: String {
        switch self {
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
    func listModels(apiKey: String?) async throws -> [OpenRouterModelOption] {
        try await listModels(endpoint: .openRouter(apiKey: apiKey))
    }

    func complete(apiKey: String, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        try await complete(endpoint: .openRouter(apiKey: apiKey), model: model, messages: messages)
    }
}

struct OpenRouterLLMClient: OpenRouterLLMClienting {
    let baseURL: URL
    let session: URLSession

    init(
        baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
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
            }

            let data: [Model]
        }

        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data
                .filter { model in
                    let outputs = model.architecture?.outputModalities ?? ["text"]
                    return outputs.contains("text")
                }
                .map { OpenRouterModelOption(id: $0.id, name: $0.name ?? $0.id) }
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

        var request = URLRequest(
            url: endpoint.baseURL
                .appendingPathComponent("chat")
                .appendingPathComponent("completions")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCommonHeaders(to: &request, endpoint: endpoint)

        struct ChatRequest: Encodable {
            let model: String
            let messages: [OpenRouterChatMessage]
            let temperature: Double
            let stream: Bool
        }
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(model: trimmedModel, messages: messages, temperature: 0.1, stream: false)
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response, body: data)

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }

        do {
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
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

import Foundation

/// A provider's list price for one model, in USD per million tokens. Present
/// only when the catalog states both sides as non-negative amounts; a zero is
/// the catalog's own zero, never a stand-in for "unknown".
// WHY: .project-docs/decisions/2026-11-17-openrouter-model-prices.md
struct CatalogTokenPrice: Codable, Equatable, Sendable {
    let inputPerMillion: Double
    let outputPerMillion: Double

    /// `nil` unless both per-token amounts are known and not negative
    /// (OpenRouter prices its routers at -1: the price depends on the route).
    init?(promptPerToken: Decimal?, completionPerToken: Decimal?) {
        guard let promptPerToken, let completionPerToken,
              promptPerToken >= 0, completionPerToken >= 0
        else { return nil }
        let input = NSDecimalNumber(decimal: promptPerToken * 1_000_000).doubleValue
        let output = NSDecimalNumber(decimal: completionPerToken * 1_000_000).doubleValue
        guard input.isFinite, output.isFinite else { return nil }
        inputPerMillion = input
        outputPerMillion = output
    }
}

/// One model as a provider's catalog describes it. Fields a provider does not
/// report stay `nil`.
struct CatalogModel: Codable, Equatable, Sendable {
    let id: String
    /// `nil`: the provider does not say (a user's server).
    var uses: Set<ModelUse>?
    /// Soniox `aliased_model_id`: the model this one is a deprecated alias of.
    var aliasOf: String?
    var contextLength: Int?
    /// OpenRouter `top_provider.max_completion_tokens`, Anthropic `max_tokens`.
    var maxOutputTokens: Int?
    var supportsTools: Bool?
    /// `"reasoning"` is among OpenRouter's `supported_parameters`; Anthropic's
    /// `capabilities.thinking.supported`.
    var supportsReasoning: Bool?
    var reasoning: OpenRouterReasoningCapabilities?
    var expiresAt: Date?
    /// Deepgram: the date of the model's newest version (`version` is
    /// `YYYY-MM-DD.N`). Pickers hide a model not updated for a year.
    var updatedAt: Date?
    /// Anthropic: released; OpenAI: created; OpenRouter: added to its catalog;
    /// a user's server: its `created`, when it is a real date.
    /// These meanings are deliberately kept distinct in the picker label.
    var catalogDate: Date?
    /// OpenRouter `pricing.prompt` / `pricing.completion`. Display only.
    var tokenPrice: CatalogTokenPrice?

    init(
        id: String,
        uses: Set<ModelUse>? = nil,
        aliasOf: String? = nil,
        contextLength: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool? = nil,
        supportsReasoning: Bool? = nil,
        reasoning: OpenRouterReasoningCapabilities? = nil,
        expiresAt: Date? = nil,
        updatedAt: Date? = nil,
        catalogDate: Date? = nil,
        tokenPrice: CatalogTokenPrice? = nil
    ) {
        self.id = id
        self.uses = uses
        self.aliasOf = aliasOf
        self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsReasoning = supportsReasoning
        self.reasoning = reasoning
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
        self.catalogDate = catalogDate
        self.tokenPrice = tokenPrice
    }
}

/// Why a catalog could not be read. Never carries a response body or a URL.
enum CatalogFetchError: Error, Equatable {
    /// Non-2xx. `code` is the provider's own error label when the body has one.
    case http(Int, code: String?)
    case offline
    case malformed
}

protocol ModelCatalogFetching: Sendable {
    /// `apiKey` is the caller's to read from the Keychain; `server` is required
    /// for a `.server` account. A server that answers 404 throws
    /// `.http(404, code: nil)`: the caller treats that as "no catalog".
    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel]
}

extension ServerEndpoint {
    /// Where this server lists its models: `ws`/`wss` become `http`/`https`; a
    /// base ending in `/v1` gets `/models`, anything else gets `/v1/models` on
    /// the same host and port. `nil` for a base that is not a web URL.
    var modelsURL: URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), components.host?.isEmpty == false
        else { return nil }
        switch scheme {
        case "http", "https": components.scheme = scheme
        case "ws": components.scheme = "http"
        case "wss": components.scheme = "https"
        default: return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path.hasSuffix("/v1") ? path + "/models" : "/v1/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct ModelCatalogFetcher: ModelCatalogFetching {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let sonioxURL = URL(string: "https://api.soniox.com/v1/models")!
    private static let deepgramURL = URL(string: "https://api.deepgram.com/v1/models")!
    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/models")!
    static let anthropicModelsURL = URL(string: "https://api.anthropic.com/v1/models")!
    static let openAIModelsURL = URL(string: "https://api.openai.com/v1/models")!
    static let anthropicVersion = "2023-06-01"
    /// A stop for a catalog that keeps saying `has_more`.
    private static let anthropicMaxPages = 20

    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        switch account {
        case .soniox:
            let data = try await get(Self.sonioxURL, bearer: apiKey)
            return try Self.parseSoniox(data)
        case .deepgram:
            // The Deepgram catalog is public; the key is not sent.
            let data = try await get(Self.deepgramURL, bearer: nil)
            return try Self.parseDeepgram(data)
        case .elevenLabs:
            // /v1/models lists voice models only; STT models come from the registry.
            return []
        case .openRouter:
            let data = try await get(Self.openRouterURL, bearer: nil)
            return try Self.parseOpenRouter(data)
        case .anthropic:
            guard let apiKey, !apiKey.isEmpty else { throw CatalogFetchError.http(401, code: nil) }
            return try await fetchAnthropic(apiKey: apiKey)
        case .openAI:
            guard let apiKey, !apiKey.isEmpty else { throw CatalogFetchError.http(401, code: nil) }
            return try Self.parseOpenAI(await get(Self.openAIModelsURL, bearer: apiKey))
        case .thisMac:
            // Its models are the app's own registry; nothing is fetched.
            return []
        case .server:
            guard let url = server?.modelsURL else { throw CatalogFetchError.malformed }
            let data = try await get(url, bearer: apiKey)
            return try Self.parseServer(data)
        }
    }

    /// Every page of Anthropic's models list: `has_more` asks for the next
    /// one after the page's `last_id`.
    private func fetchAnthropic(apiKey: String) async throws -> [CatalogModel] {
        var models: [CatalogModel] = []
        var after: String?
        for _ in 0..<Self.anthropicMaxPages {
            let url = Self.anthropicModelsPage(after: after)
            let data = try await get(url, headers: Self.anthropicHeaders(apiKey: apiKey))
            let page = try Self.parseAnthropicPage(data)
            models += page.models
            guard page.hasMore, let last = page.lastID, !last.isEmpty, last != after else { break }
            after = last
        }
        return models
    }

    /// `…/v1/models?limit=1000`, with `after_id` for every page but the first.
    static func anthropicModelsPage(after: String?) -> URL {
        var components = URLComponents(url: anthropicModelsURL, resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "limit", value: "1000")]
        if let after { items.append(URLQueryItem(name: "after_id", value: after)) }
        components.queryItems = items
        return components.url!
    }

    /// Anthropic authenticates with `x-api-key`, never a Bearer token.
    static func anthropicHeaders(apiKey: String) -> [String: String] {
        ["x-api-key": apiKey, "anthropic-version": anthropicVersion]
    }

    // MARK: - Transport

    private func get(_ url: URL, bearer: String?) async throws -> Data {
        var headers: [String: String] = [:]
        if let bearer, !bearer.isEmpty { headers["Authorization"] = "Bearer \(bearer)" }
        return try await get(url, headers: headers)
    }

    private func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is URLError {
            throw CatalogFetchError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw CatalogFetchError.malformed }
        guard (200..<300).contains(http.statusCode) else {
            throw CatalogFetchError.http(http.statusCode, code: Self.errorCode(in: data))
        }
        return data
    }

    /// The provider's own label for an error, when the body has one:
    /// `error_type` (Soniox), `err_code` / `category` (Deepgram),
    /// `detail.status` (ElevenLabs).
    private static func errorCode(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        func text(_ value: Any?) -> String? {
            if let string = value as? String, !string.isEmpty { return string }
            return nil
        }
        if let code = text(object["error_type"]) ?? text(object["err_code"]) ?? text(object["category"]) {
            return code
        }
        return text((object["detail"] as? [String: Any])?["status"])
    }

    // MARK: - Parsing

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CatalogFetchError.malformed
        }
    }

    private struct SonioxResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let transcriptionMode: String?
            let aliasedModelID: String?

            enum CodingKeys: String, CodingKey {
                case id
                case transcriptionMode = "transcription_mode"
                case aliasedModelID = "aliased_model_id"
            }
        }
        let models: [Model]
    }

    static func parseSoniox(_ data: Data) throws -> [CatalogModel] {
        try decode(SonioxResponse.self, from: data).models.map { model in
            let uses: Set<ModelUse>
            switch model.transcriptionMode {
            case "real_time": uses = [.realtimeSTT]
            case "async": uses = [.asyncSTT]
            default: uses = []
            }
            let alias = model.aliasedModelID.flatMap { $0.isEmpty ? nil : $0 }
            return CatalogModel(id: model.id, uses: uses, aliasOf: alias)
        }
    }

    private struct DeepgramResponse: Decodable {
        struct Row: Decodable {
            let canonicalName: String?
            let streaming: Bool?
            let batch: Bool?
            let version: String?

            enum CodingKeys: String, CodingKey {
                case canonicalName = "canonical_name"
                case streaming
                case batch
                case version
            }
        }
        let stt: [Row]
    }

    static func parseDeepgram(_ data: Data) throws -> [CatalogModel] {
        // Rows are split by language and version; one model is the union of its rows.
        var usesByID: [String: Set<ModelUse>] = [:]
        var updatedByID: [String: Date] = [:]
        func noteUpdate(_ date: Date?, for id: String) {
            guard let date else { return }
            updatedByID[id] = max(updatedByID[id] ?? date, date)
        }
        for row in try decode(DeepgramResponse.self, from: data).stt {
            guard let id = row.canonicalName, !id.isEmpty else { continue }
            var uses = usesByID[id] ?? []
            if row.streaming == true { uses.insert(.realtimeSTT) }
            if row.batch == true { uses.insert(.asyncSTT) }
            usesByID[id] = uses
            noteUpdate(row.version.flatMap(deepgramVersionDate), for: id)
        }
        // `nova-3-general` is what the API calls plain `nova-3`.
        let generalSuffix = "-general"
        for (id, uses) in usesByID where id.hasSuffix(generalSuffix) && id.count > generalSuffix.count {
            let architecture = String(id.dropLast(generalSuffix.count))
            usesByID[architecture] = (usesByID[architecture] ?? []).union(uses)
            noteUpdate(updatedByID[id], for: architecture)
        }
        return usesByID
            .filter { !$0.value.isEmpty }
            .map { CatalogModel(id: $0.key, uses: $0.value, updatedAt: updatedByID[$0.key]) }
            .sorted { $0.id < $1.id }
    }

    /// `"2026-10-15.0"` → that day (UTC); anything else → `nil`.
    static func deepgramVersionDate(_ version: String) -> Date? {
        let day = version.prefix(10)
        guard day.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(day))
    }

    private struct OpenRouterResponse: Decodable {
        struct Model: Decodable {
            struct Architecture: Decodable {
                let outputModalities: [String]?
                enum CodingKeys: String, CodingKey { case outputModalities = "output_modalities" }
            }
            /// USD per token, sent as decimal strings. Optional metadata: an
            /// amount of another shape is unknown, never a failed catalog.
            struct Pricing: Decodable {
                let prompt: Decimal?
                let completion: Decimal?

                enum CodingKeys: String, CodingKey { case prompt, completion }

                init(from decoder: Decoder) throws {
                    let container = try? decoder.container(keyedBy: CodingKeys.self)
                    prompt = container.flatMap { Self.amount(in: $0, .prompt) }
                    completion = container.flatMap { Self.amount(in: $0, .completion) }
                }

                private static func amount(
                    in container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
                ) -> Decimal? {
                    if let text = try? container.decode(String.self, forKey: key) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        // `Decimal(string:)` accepts a numeric prefix; `Double` does not.
                        guard let number = Double(trimmed), number.isFinite else { return nil }
                        return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
                    }
                    if let number = try? container.decode(Double.self, forKey: key), number.isFinite {
                        return Decimal(number)
                    }
                    return nil
                }
            }
            struct TopProvider: Decodable {
                let maxCompletionTokens: Int?
                enum CodingKeys: String, CodingKey { case maxCompletionTokens = "max_completion_tokens" }
            }

            let id: String
            let created: ModelDateTimestamp?
            let contextLength: Int?
            let expirationDate: String?
            let supportedParameters: [String]?
            let architecture: Architecture?
            let pricing: Pricing?
            let topProvider: TopProvider?
            let reasoning: OpenRouterReasoningCapabilities?

            enum CodingKeys: String, CodingKey {
                case id, created
                case contextLength = "context_length"
                case expirationDate = "expiration_date"
                case supportedParameters = "supported_parameters"
                case architecture
                case pricing
                case topProvider = "top_provider"
                case reasoning
            }
        }
        let data: [Model]
    }

    static func parseOpenRouter(_ data: Data) throws -> [CatalogModel] {
        try decode(OpenRouterResponse.self, from: data).data.compactMap { model in
            let id = model.id
            // `:batch` variants and `~…-latest` aliases are not models to pick.
            if id.contains(":batch") || id.contains("~") { return nil }
            let isDecision = model.architecture?.outputModalities?.contains("decision") == true
                || (id.hasPrefix("typesafe/jev-") && id != "typesafe/jev-router")
            // Text must be an output (a missing list is read as text, as the LLM client does).
            if let outputs = model.architecture?.outputModalities, !outputs.contains("text"), !isDecision { return nil }
            // Routers priced at -1 are not models, except the one the app has always offered.
            if model.pricing?.prompt == -1, id != "openrouter/auto" { return nil }
            let parameters = model.supportedParameters
            let tools = parameters?.contains("tools")
            var uses: Set<ModelUse> = isDecision ? [.decision] : [.chat]
            if tools == true && !isDecision { uses.insert(.chatWithTools) }
            return CatalogModel(
                id: id,
                uses: uses,
                contextLength: model.contextLength,
                maxOutputTokens: model.topProvider?.maxCompletionTokens,
                supportsTools: tools,
                supportsReasoning: parameters?.contains("reasoning"),
                reasoning: model.reasoning,
                expiresAt: model.expirationDate.flatMap(parseDate),
                catalogDate: model.created?.date,
                tokenPrice: CatalogTokenPrice(
                    promptPerToken: model.pricing?.prompt, completionPerToken: model.pricing?.completion)
            )
        }
    }

    private struct AnthropicResponse: Decodable {
        struct Model: Decodable {
            let id: String
            let maxInputTokens: Int?
            let maxTokens: Int?
            let thinking: Bool?
            let createdAt: String?

            enum CodingKeys: String, CodingKey {
                case id
                case maxInputTokens = "max_input_tokens"
                case maxTokens = "max_tokens"
                case capabilities
                case createdAt = "created_at"
            }

            private struct Capabilities: Decodable {
                struct Support: Decodable { let supported: Bool? }
                let thinking: Support?
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
                maxInputTokens = try? container.decodeIfPresent(Int.self, forKey: .maxInputTokens)
                maxTokens = try? container.decodeIfPresent(Int.self, forKey: .maxTokens)
                // A capabilities object of another shape costs only the flag.
                thinking = (try? container.decodeIfPresent(Capabilities.self, forKey: .capabilities))?.thinking?.supported
            }
        }
        let data: [Model]
        let hasMore: Bool?
        let lastID: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }

    /// One page of Anthropic's models list. Every Claude model takes tools.
    static func parseAnthropicPage(_ data: Data) throws -> (models: [CatalogModel], hasMore: Bool, lastID: String?) {
        let page = try decode(AnthropicResponse.self, from: data)
        let models = page.data.map { model in
            CatalogModel(
                id: model.id,
                uses: [.chat, .chatWithTools],
                contextLength: model.maxInputTokens,
                maxOutputTokens: model.maxTokens,
                supportsTools: true,
                supportsReasoning: model.thinking,
                catalogDate: knownModelDate(model.createdAt.flatMap(parseDate))
            )
        }
        return (models, page.hasMore ?? false, page.lastID)
    }

    private struct ServerResponse: Decodable {
        struct Model: Decodable {
            let id: String
            /// Optional: Ollama sends when the model was pulled or changed;
            /// others the request time (`ModelStatusResolver.serverModelDate`).
            let created: ModelDateTimestamp?
        }
        let data: [Model]
    }

    /// A server lists IDs only. They suggest names when the user adds a model
    /// to the server; what each model does is the user's entry
    /// (`ServerEndpoint.models`), never this list.
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    static func parseServer(_ data: Data) throws -> [CatalogModel] {
        try decode(ServerResponse.self, from: data).data.map { CatalogModel(id: $0.id, catalogDate: $0.created?.date) }
    }

    /// OpenAI's list has IDs, not endpoint capabilities. Offer text families;
    /// each unverified ID still passes the existing synthetic model check.
    static func parseOpenAI(_ data: Data) throws -> [CatalogModel] {
        struct Response: Decodable {
            struct Model: Decodable {
                let id: String
                let created: ModelDateTimestamp?
            }
            let data: [Model]
        }
        return try decode(Response.self, from: data).data.compactMap { model in
            let id = model.id
            let base = id.hasPrefix("ft:") ? String(id.dropFirst(3).split(separator: ":").first ?? "") : id
            // Live speech translation (Subtitles audio), never a text model.
            if base.hasPrefix("gpt-realtime-translate") {
                return CatalogModel(id: id, uses: [.speechTranslation], catalogDate: model.created?.date)
            }
            guard base.hasPrefix("gpt-") || ["o1", "o3", "o4"].contains(where: { base == $0 || base.hasPrefix($0 + "-") }),
                  !["audio", "realtime", "transcribe", "tts", "image", "search", "codex", "deep-research", "-pro", "instruct"].contains(where: base.contains)
            else { return nil }
            var uses: Set<ModelUse> = [.chat, .chatWithTools]
            if id == ModelRegistry.openAIDecisionModel { uses.insert(.decision) }
            return CatalogModel(id: id, uses: uses, catalogDate: model.created?.date)
        }.sorted { $0.id < $1.id }
    }

    /// Optional metadata must never make an otherwise usable catalog fail.
    private struct ModelDateTimestamp: Decodable {
        let date: Date?

        init(from decoder: Decoder) throws {
            let seconds = try? decoder.singleValueContainer().decode(Double.self)
            date = seconds.flatMap { value in
                guard value.isFinite else { return nil }
                return knownModelDate(Date(timeIntervalSince1970: value))
            }
        }
    }

    private static func knownModelDate(_ date: Date?) -> Date? {
        // Anthropic explicitly uses the Unix epoch for an unknown release.
        guard let date, date.timeIntervalSince1970 > 0, date < .distantFuture else { return nil }
        return date
    }

    private static func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: text)
    }
}

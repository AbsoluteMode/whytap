import Foundation

/// Capabilities come from OpenRouter's catalog, not model-name guesses. In
/// particular Gemini 3.8 Flash rejects both `none` and `minimal`.
struct OpenRouterReasoningCapabilities: Codable, Equatable, Hashable {
    let mandatory: Bool?
    let supportedEfforts: [String]?

    enum CodingKeys: String, CodingKey {
        case mandatory
        case supportedEfforts = "supported_efforts"
    }

    var dictationSetting: OpenRouterReasoningSetting? {
        if mandatory == false { return .init(enabled: false, effort: nil) }
        guard let supportedEfforts else { return nil }
        let candidates = mandatory == true
            ? ["minimal", "low", "medium", "high", "xhigh", "max"]
            : ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        guard let effort = candidates.first(where: supportedEfforts.contains) else { return nil }
        return .init(enabled: nil, effort: effort)
    }
}

struct OpenRouterReasoningSetting: Encodable, Equatable {
    let enabled: Bool?
    let effort: String?

    var diagnosticLabel: String { enabled == false ? "off" : (effort ?? "default") }
}

/// Shared between copies of a client. Discovery is once per catalog refresh,
/// never once per dictation; failures are briefly cached as well. Custom
/// endpoints never use this catalog or receive OpenRouter-specific settings.
actor OpenRouterReasoningCatalog {
    private var entries: [String: OpenRouterReasoningCapabilities] = [:]
    private var expiresAt: Date = .distantPast

    func update(_ models: [OpenRouterModelOption]) {
        entries = Dictionary(models.compactMap { model in
            model.reasoning.map { (model.id, $0) }
        }, uniquingKeysWith: { _, newest in newest })
        expiresAt = Date().addingTimeInterval(3600)
    }

    func setting(model: String, baseURL: URL, session: URLSession) async -> OpenRouterReasoningSetting? {
        if expiresAt > Date() { return entries[model]?.dictationSetting }
        // Do not block cleanup on an unavailable catalog or stampede it when
        // several callers arrive. A later turn retries after a short backoff.
        expiresAt = Date().addingTimeInterval(30)
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 1.5
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            struct Catalog: Decodable {
                struct Model: Decodable {
                    let id: String
                    let reasoning: OpenRouterReasoningCapabilities?
                }
                let data: [Model]
            }
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            entries = Dictionary(catalog.data.compactMap { model in
                model.reasoning.map { (model.id, $0) }
            }, uniquingKeysWith: { _, newest in newest })
            expiresAt = Date().addingTimeInterval(3600)
            return entries[model]?.dictationSetting
        } catch {
            return nil
        }
    }
}

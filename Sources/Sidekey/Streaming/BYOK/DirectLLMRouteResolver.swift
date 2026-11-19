import Foundation

struct DirectLLMRoute {
    let endpoint: OpenAICompatibleLLMEndpoint
    let model: String
    var usageContext: AIUsageContext? = nil
}

extension DirectLLMRoute: Equatable {
    static func == (lhs: DirectLLMRoute, rhs: DirectLLMRoute) -> Bool {
        lhs.model == rhs.model && lhs.endpoint == rhs.endpoint
    }
}

/// Resolves the route of one LLM feature (Drop Smart cleanup, Meeting notes) to
/// a concrete `/chat/completions` target. Each feature reads only its own
/// route in `AIRoutingStore`, so another feature's provider, model or key never
/// leaks in; without a route there is nothing to run on.
struct DirectLLMRouteResolver {
    let feature: AIFeature
    private let routing: AIRoutingStore
    private let keys: ProviderKeyStore

    init(feature: AIFeature, routing: AIRoutingStore, keys: ProviderKeyStore = ProviderKeyStore()) {
        self.feature = feature
        self.routing = routing
        self.keys = keys
    }

    @MainActor
    static func live(_ feature: AIFeature) -> DirectLLMRouteResolver {
        DirectLLMRouteResolver(feature: feature, routing: .shared)
    }

    /// The feature's route, or nil when it has none (never set, a removed
    /// server, or a speech-to-text account that cannot serve an LLM). Read on
    /// the main actor at every call, so a change applies to the next one.
    /// Throws (`OpenRouterLLMError`) when the route lacks its key / base URL:
    /// a missing or unreadable key is never a reason to use another provider.
    func routeIfEnabled() async throws -> DirectLLMRoute? {
        let snapshot = await MainActor.run { () -> Snapshot? in
            guard let route = routing.route(for: feature) else { return nil }
            let server: ServerEndpoint?
            if case .server(let id) = route.account {
                server = routing.server(id)
            } else {
                server = nil
            }
            return Snapshot(route: route, server: server, keyAccount: route.account.keychainAccount(in: routing))
        }
        guard let snapshot else { return nil }
        let model = snapshot.route.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }

        switch snapshot.route.account {
        case .openAI, .anthropic, .groq:
            guard let account = snapshot.keyAccount, case .key(let key) = keys.lookup(account: account) else {
                throw OpenRouterLLMError.missingKey
            }
            let endpoint: OpenAICompatibleLLMEndpoint
            switch snapshot.route.account {
            case .openAI: endpoint = .openAI(apiKey: key)
            case .groq: endpoint = .groq(apiKey: key)
            default: endpoint = .anthropic(apiKey: key)
            }
            return DirectLLMRoute(endpoint: endpoint, model: model,
                                  usageContext: .init(feature: feature, account: snapshot.route.account, model: model))
        case .openRouter:
            guard let account = snapshot.keyAccount, case .key(let key) = keys.lookup(account: account) else {
                throw OpenRouterLLMError.missingKey
            }
            return DirectLLMRoute(endpoint: .openRouter(apiKey: key, provider: snapshot.route.provider), model: model,
                                  usageContext: .init(feature: feature, account: snapshot.route.account, model: model))
        case .server:
            guard let server = snapshot.server else { return nil }
            let rawBaseURL = server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawBaseURL.isEmpty else { throw OpenRouterLLMError.missingBaseURL }
            guard let baseURL = URL(string: rawBaseURL),
                  let scheme = baseURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  baseURL.host != nil
            else {
                throw OpenRouterLLMError.invalidBaseURL(rawBaseURL)
            }
            // The key is optional, but one that exists and cannot be read is
            // not "no key": the server may need it.
            let key: String?
            switch keys.lookup(account: server.keyAccount) {
            case .key(let stored): key = stored
            case .absent: key = nil
            case .unreadable: throw OpenRouterLLMError.missingKey
            }
            return DirectLLMRoute(endpoint: .custom(baseURL: baseURL, apiKey: key), model: model,
                                  usageContext: .init(feature: feature, account: snapshot.route.account, model: model))
        case .soniox, .deepgram, .elevenLabs, .thisMac:
            return nil
        }
    }

    private struct Snapshot {
        let route: FeatureRoute
        let server: ServerEndpoint?
        let keyAccount: String?
    }
}

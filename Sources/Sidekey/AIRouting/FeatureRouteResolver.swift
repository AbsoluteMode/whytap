import Foundation

/// Why a feature cannot run on its route right now.
enum FeatureRouteError: Error, Equatable {
    /// No route, no model, or the server the route named was removed.
    case notSet(AIFeature)
    /// The route's provider account has no usable key: none is stored, or the
    /// Keychain would not give it up (this holds for a server too, whose key is
    /// otherwise optional).
    case missingKey(AIFeature)
    /// The route's server has no base URL.
    case missingBaseURL(AIFeature)
    /// The route's server has a base URL no connection can be built from.
    case invalidBaseURL(AIFeature)
    /// The Deepgram model cannot take the input language. The resolver does not
    /// know the language, so this comes from the session factory that does.
    case invalidLanguageConfiguration(AIFeature, DeepgramLanguageConfigurationError)

    var feature: AIFeature {
        switch self {
        case .notSet(let feature), .missingKey(let feature),
             .missingBaseURL(let feature), .invalidBaseURL(let feature),
             .invalidLanguageConfiguration(let feature, _):
            return feature
        }
    }
}

/// A feature's route with everything a call needs: the model, and the key of
/// the route's own provider account.
struct ResolvedRoute: Equatable, Sendable {
    let feature: AIFeature
    let account: ProviderAccount
    let model: String
    /// Set for every built-in provider: the resolver refuses a route without
    /// its key. A server's key is optional, so this is `nil` when none is
    /// stored; a key that is stored but unreadable is refused, never `nil`.
    let apiKey: String?
    /// The endpoint, when the account is a server.
    let server: ServerEndpoint?
}

/// Turns the route stored for a feature into a `ResolvedRoute`, or says why it
/// cannot run. It reads only the route's own provider account: a missing key
/// is `missingKey`, never a reason to use another provider, and a key the
/// Keychain cannot read counts as missing, never as "no key needed".
@MainActor
struct FeatureRouteResolver {
    /// `nil` means the shared store, looked up when a route is resolved.
    private let injectedRouting: AIRoutingStore?
    private let keys: ProviderKeyStore
    private let onDevice: OnDeviceSpeechReadiness

    private var routing: AIRoutingStore { injectedRouting ?? .shared }

    /// `routing` defaults to the shared store. The init touches no main-actor
    /// state and is `nonisolated`, so `FeatureRouteResolver()` can be a default
    /// argument of a main-actor init or function: Swift 5 evaluates default
    /// arguments outside the actor, where a main-actor init cannot be called.
    nonisolated init(
        routing: AIRoutingStore? = nil, keys: ProviderKeyStore = ProviderKeyStore(),
        onDevice: OnDeviceSpeechReadiness = .live
    ) {
        self.injectedRouting = routing
        self.keys = keys
        self.onDevice = onDevice
    }

    /// The stored route, for a caller that has to look at it before the key is
    /// read (the real-time factory checks the Deepgram language first).
    func route(for feature: AIFeature) -> FeatureRoute? {
        routing.route(for: feature)
    }

    func resolve(_ feature: AIFeature) throws -> ResolvedRoute {
        guard let route = route(for: feature) else { throw FeatureRouteError.notSet(feature) }
        return try resolve(route, for: feature)
    }

    /// The same rules for a route that is not stored (a candidate being
    /// checked before the user picks it).
    func resolve(_ route: FeatureRoute, for feature: AIFeature) throws -> ResolvedRoute {
        guard feature.isActive else { throw FeatureRouteError.notSet(feature) }
        let model = route.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw FeatureRouteError.notSet(feature) }

        switch route.account {
        case .server(let id):
            // A server that was removed leaves nothing to run on.
            guard let server = routing.server(id) else { throw FeatureRouteError.notSet(feature) }
            guard !server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw FeatureRouteError.missingBaseURL(feature)
            }
            // The key is optional: plenty of self-hosted servers run without
            // one. A key that exists but cannot be read is not "no key" though:
            // the server may need it, so the route fails rather than connect
            // without it.
            let apiKey: String?
            switch keys.lookup(account: server.keyAccount) {
            case .key(let key): apiKey = key
            case .absent: apiKey = nil
            case .unreadable: throw FeatureRouteError.missingKey(feature)
            }
            return ResolvedRoute(feature: feature, account: route.account, model: model, apiKey: apiKey, server: server)

        case .thisMac:
            // The downloaded model is this account's credential. Without it
            // the route cannot run, and nothing is sent to a provider instead.
            guard feature.modelUse(on: .onDevice) != nil, OnDeviceSpeechModel(rawValue: model) != nil else {
                throw FeatureRouteError.notSet(feature)
            }
            guard onDevice.isReady() else { throw FeatureRouteError.missingKey(feature) }
            return ResolvedRoute(feature: feature, account: route.account, model: model, apiKey: nil, server: nil)

        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic:
            // A built-in provider cannot run without its own key, absent or
            // unreadable, and never borrows another provider's. (`keychainAccount`
            // answers `nil` only for a removed server.)
            guard let keyAccount = route.account.keychainAccount(in: routing),
                  case .key(let key) = keys.lookup(account: keyAccount)
            else { throw FeatureRouteError.missingKey(feature) }
            return ResolvedRoute(feature: feature, account: route.account, model: model, apiKey: key, server: nil)
        }
    }
}

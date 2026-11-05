import Foundation

/// One-time carry-over of the old Models-tab provider and model choices into
/// per-feature routes (`docs/specs/api-and-models.md`, the migration section).
/// It runs at launch, reads only the old settings and the Keychain, and makes
/// no network call.
///
/// Old settings are read through `SelfKeyPreferences`, so its rules still say
/// what was set: a retired Local level, or no level on Apple Silicon, leaves
/// the features Not set even when their keys are in the Keychain. No model or
/// provider is ever replaced, and a feature gets a route only where its account
/// has a key. The old `UserDefaults` keys are read, never written or removed,
/// so a rollback finds the Models tab as the user left it.
// WHY: .project-docs/decisions/2026-10-19-api-and-models.md
@MainActor
struct AIRoutingMigration {
    private let prefs: SelfKeyPreferences
    private let defaults: UserDefaults
    private let routing: AIRoutingStore
    private let keys: ProviderKeyStore

    /// Read from `defaults` here, not through `AgentSettingsStore`: creating
    /// that store can rewrite other agent keys.
    private static let agentModelKey = "agent.opencode.model"

    private static let realtimeFeatures: [AIFeature] = [.dropFast, .dropSmart, .agentVoice, .voiceSearch]
    private static let llmFeatures: [AIFeature] = [.dropSmartCleanup, .meetingNotes]

    init(prefs: SelfKeyPreferences, defaults: UserDefaults, routing: AIRoutingStore, keys: ProviderKeyStore) {
        self.prefs = prefs
        self.defaults = defaults
        self.routing = routing
        self.keys = keys
    }

    /// The app's own settings, route store and Keychain.
    static func live() -> AIRoutingMigration {
        AIRoutingMigration(prefs: .shared, defaults: .standard, routing: .shared, keys: ProviderKeyStore())
    }

    /// Does nothing once the migration is recorded, so a later change to the
    /// old settings never moves a route.
    func run() {
        if !routing.isMigrated {
            let servers = carriedOverServers()
            var routes = speechRoutes(on: servers.speech)
            // The three groups name different features, so nothing is overwritten.
            routes.merge(llmRoutes(on: servers.llm)) { current, _ in current }
            routes.merge(agentRoutes()) { current, _ in current }
            routing.completeMigration(routes: routes, servers: servers.stored)
        }
        routing.separateSubtitleTranslationIfNeeded()
        routing.retireSmartDecisionIfNeeded()
        routing.retireMeetingRoutesIfNeeded()
    }

    // MARK: - Routes

    /// Real-time features and meetings share the one provider the Models tab
    /// had selected.
    private func speechRoutes(on server: ServerEndpoint?) -> [AIFeature: FeatureRoute] {
        guard prefs.transcriptionLevel == .yourKey else { return [:] }
        let provider = prefs.selectedProvider
        guard let account = speechAccount(for: provider, server: server), hasKey(account) else { return [:] }

        let realtime = FeatureRoute(account: account, model: prefs.transcriptionModel(for: provider))
        // Soniox transcribes a finished recording through its file API; the
        // other providers run it through their real-time model, as before.
        let recorded = provider == .soniox
            ? FeatureRoute(account: account, model: SonioxFileAPI.asyncModel)
            : realtime
        var routes = Dictionary(uniqueKeysWithValues: Self.realtimeFeatures.map { ($0, realtime) })
        routes[.meetings] = recorded
        return routes
    }

    private func speechAccount(for provider: BYOKProvider, server: ServerEndpoint?) -> ProviderAccount? {
        switch provider {
        case .soniox: return .soniox
        case .deepgram: return .deepgram
        case .elevenLabs: return .elevenLabs
        case .selfHosted: return server.map { ProviderAccount.server($0.id) }
        // `selectedProvider` already turns a stored OpenAI choice into Soniox,
        // and API & Models has no OpenAI account.
        case .openAI: return nil
        }
    }

    private func llmRoutes(on server: ServerEndpoint?) -> [AIFeature: FeatureRoute] {
        let route: FeatureRoute
        switch prefs.llmLevel {
        case .yourKey?:
            guard hasKey(.openRouter) else { return [:] }
            route = FeatureRoute(account: .openRouter, model: prefs.openRouterModel)
        case .custom?:
            guard let server else { return [:] }
            route = FeatureRoute(account: .server(server.id), model: prefs.customLLMModel)
        case nil:
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: Self.llmFeatures.map { ($0, route) })
    }

    private func agentRoutes() -> [AIFeature: FeatureRoute] {
        // The same test as `AgentSettingsStore.selectedOpenCodeModel`: a single
        // model ID, without whitespace.
        guard let model = defaults.string(forKey: Self.agentModelKey).map(OpenCodeEnvironment.normalizeModel),
              !model.isEmpty, !model.contains(where: \.isWhitespace),
              hasKey(.openRouter)
        else { return [:] }
        return [.agent: FeatureRoute(account: .openRouter, model: model)]
    }

    /// Whether a route on `account` may be assigned. Only an absent key says
    /// no: an item the Keychain will not read still exists, and skipping its
    /// route would drop the user's choice for good, while the runtime fails
    /// closed on it anyway. A server's key is optional.
    private func hasKey(_ account: ProviderAccount) -> Bool {
        switch account {
        case .server:
            return true
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic:
            guard let keyAccount = account.keychainAccount(in: routing) else { return false }
            return keys.lookup(account: keyAccount) != .absent
        }
    }

    // MARK: - Servers

    /// The servers the Models tab pointed at: `selfHostedBaseURL` for speech
    /// and `customLLMBaseURL` for the LLM.
    private struct CarriedServers {
        /// Real-time and recorded speech.
        let speech: ServerEndpoint?
        /// The LLM routes; the same record as `speech` when one server does both.
        let llm: ServerEndpoint?

        /// The records to store: one when both settings are the same server.
        var stored: [ServerEndpoint] {
            guard let speech else { return llm.map { [$0] } ?? [] }
            guard let llm, llm.id != speech.id else { return [speech] }
            return [speech, llm]
        }
    }

    /// Each server keeps the Keychain account its key already sits in, so no
    /// key moves. A setting without a URL (blank counts) makes no server, and
    /// the routes that would have used it are not assigned.
    private func carriedOverServers() -> CarriedServers {
        let speechKeyAccount = BYOKKeyStore.account(for: .selfHosted)
        let llmKeyAccount = CustomLLMKeyStore.account

        guard let speechURL = Self.trimmed(prefs.selfHostedBaseURL) else {
            let llm = Self.trimmed(prefs.customLLMBaseURL).map { Self.server(at: $0, keyAccount: llmKeyAccount) }
            return CarriedServers(speech: nil, llm: llm)
        }
        var speech = Self.server(at: speechURL, keyAccount: speechKeyAccount)
        guard let llmURL = Self.trimmed(prefs.customLLMBaseURL) else {
            return CarriedServers(speech: speech, llm: nil)
        }

        // One server when both settings name the same URL and the same key
        // stands behind both. It keeps the speech key account.
        if speechURL == llmURL, holdSameKey(speechKeyAccount, llmKeyAccount) {
            return CarriedServers(speech: speech, llm: speech)
        }
        var llm = Self.server(at: llmURL, keyAccount: llmKeyAccount)
        // Only two servers that would look alike get told apart.
        if speech.name == llm.name {
            speech.name += " (speech)"
            llm.name += " (LLM)"
        }
        return CarriedServers(speech: speech, llm: llm)
    }

    /// Whether the same key stands behind both accounts: equal keys, or none
    /// at all. A key the Keychain would not give up is unknown, so it never
    /// counts as equal, not even to another unreadable one.
    private func holdSameKey(_ first: String, _ second: String) -> Bool {
        let firstLookup = keys.lookup(account: first)
        guard firstLookup != .unreadable else { return false }
        return firstLookup == keys.lookup(account: second)
    }

    private static func server(at baseURL: String, keyAccount: String) -> ServerEndpoint {
        ServerEndpoint(id: UUID(), name: name(of: baseURL), baseURL: baseURL, keyAccount: keyAccount)
    }

    /// `host` or `host:port`; the URL text itself when it has no host.
    private static func name(of baseURL: String) -> String {
        let components = URLComponents(string: baseURL)
        guard let host = components?.host, !host.isEmpty else { return baseURL }
        return components?.port.map { "\(host):\($0)" } ?? host
    }

    private static func trimmed(_ url: String?) -> String? {
        let value = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

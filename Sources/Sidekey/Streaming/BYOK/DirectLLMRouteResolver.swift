import Foundation

struct DirectLLMRoute {
    let endpoint: OpenAICompatibleLLMEndpoint
    let model: String
}

/// Where dictation cleanup should run for the current LLM level.
///
/// `.local` = on-device MLX (no server); `.direct` = a user-owned
/// OpenAI-compatible endpoint (OpenRouter or custom). Distinct from
/// `DirectLLMRoute?` because the local path has no cloud endpoint and the
/// meetings BYOK path (cloud-only, the fully-local pipeline owns local) keeps
/// using `routeIfEnabled()`.
enum LLMCleanupRoute: Equatable {
    case local
    case direct(DirectLLMRoute)
}

extension DirectLLMRoute: Equatable {
    static func == (lhs: DirectLLMRoute, rhs: DirectLLMRoute) -> Bool {
        lhs.model == rhs.model && lhs.endpoint == rhs.endpoint
    }
}

/// Resolves the user-selected LLM route for cleanup/workflows. OpenRouter and
/// custom OpenAI-compatible endpoints return a concrete `/chat/completions`
/// target; the on-device level has no cloud route.
struct DirectLLMRouteResolver {
    let prefs: SelfKeyPreferences
    let llmKeyStore: any OpenRouterLLMKeyStoring
    let customLLMKeyStore: any OpenRouterLLMKeyStoring

    init(
        prefs: SelfKeyPreferences,
        llmKeyStore: any OpenRouterLLMKeyStoring = OpenRouterLLMKeyStore(),
        customLLMKeyStore: any OpenRouterLLMKeyStoring = CustomLLMKeyStore()
    ) {
        self.prefs = prefs
        self.llmKeyStore = llmKeyStore
        self.customLLMKeyStore = customLLMKeyStore
    }

    @MainActor
    static func live(
        llmKeyStore: any OpenRouterLLMKeyStoring = OpenRouterLLMKeyStore(),
        customLLMKeyStore: any OpenRouterLLMKeyStoring = CustomLLMKeyStore()
    ) -> DirectLLMRouteResolver {
        DirectLLMRouteResolver(
            prefs: .shared,
            llmKeyStore: llmKeyStore,
            customLLMKeyStore: customLLMKeyStore
        )
    }

    /// Cloud-only direct route (OpenRouter / custom). `.local` returns nil
    /// here: the meetings BYOK path consumes this and the fully-local meeting
    /// pipeline handles the on-device level. Drop cleanup uses
    /// `cleanupRoute()` instead, which surfaces the on-device path.
    func routeIfEnabled() async throws -> DirectLLMRoute? {
        let settings = await resolvedSettings()
        switch settings.level {
        case .local:
            return nil
        case .yourKey, .custom:
            return try directRoute(for: settings)
        }
    }

    /// Resolves where dictation cleanup runs for the current level. `.local`
    /// resolves to the on-device model; the BYOK levels resolve to their
    /// endpoint or throw (`OpenRouterLLMError`) when the key / base URL is
    /// missing, which the Drop path treats as "no cleanup available".
    func cleanupRoute() async throws -> LLMCleanupRoute {
        let settings = await resolvedSettings()
        switch settings.level {
        case .local:
            return .local
        case .yourKey, .custom:
            return .direct(try directRoute(for: settings))
        }
    }

    private struct ResolvedSettings {
        let level: LLMIsolationLevel
        let openRouterModel: String
        let customBaseURL: String?
        let customModel: String
        let defaultOpenRouterModel: String
        let defaultCustomLLMModel: String
    }

    private func resolvedSettings() async -> ResolvedSettings {
        await MainActor.run {
            ResolvedSettings(
                level: prefs.llmLevel,
                openRouterModel: prefs.openRouterModel,
                customBaseURL: prefs.customLLMBaseURL,
                customModel: prefs.customLLMModel,
                defaultOpenRouterModel: SelfKeyPreferences.defaultOpenRouterModel,
                defaultCustomLLMModel: SelfKeyPreferences.defaultCustomLLMModel
            )
        }
    }

    private func directRoute(for settings: ResolvedSettings) throws -> DirectLLMRoute {
        switch settings.level {
        case .yourKey:
            let key = try llmKeyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let key, !key.isEmpty else { throw OpenRouterLLMError.missingKey }
            let model = settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return DirectLLMRoute(
                endpoint: .openRouter(apiKey: key),
                model: model.isEmpty ? settings.defaultOpenRouterModel : model
            )
        case .custom:
            let rawBaseURL = settings.customBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !rawBaseURL.isEmpty else { throw OpenRouterLLMError.missingBaseURL }
            guard let baseURL = URL(string: rawBaseURL),
                  let scheme = baseURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  baseURL.host != nil
            else {
                throw OpenRouterLLMError.invalidBaseURL(rawBaseURL)
            }
            let rawKey = try customLLMKeyStore.read()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey?.isEmpty == false ? rawKey : nil
            let model = settings.customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return DirectLLMRoute(
                endpoint: .custom(baseURL: baseURL, apiKey: key),
                model: model.isEmpty ? settings.defaultCustomLLMModel : model
            )
        case .local:
            // Unreachable: callers only request a direct route for cloud BYOK
            // levels. Treated as a programmer error rather than a silent nil.
            preconditionFailure("directRoute(for:) requires a cloud BYOK level")
        }
    }
}

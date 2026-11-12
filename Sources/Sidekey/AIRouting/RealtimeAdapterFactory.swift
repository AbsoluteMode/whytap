import Foundation

/// Builds the real-time transcription adapter of a route's own provider. It
/// only builds: no socket opens until the adapter does.
enum RealtimeAdapterFactory {
    /// Runtime only. Synthetic model probes deliberately use `make` below.
    static func makeMetered(_ route: ResolvedRoute) throws -> BYOKTranscriptionAdapter {
        AIUsageMeteredAdapter(adapter: try make(route), context: AIUsageContext(route))
    }

    static func make(_ route: ResolvedRoute) throws -> BYOKTranscriptionAdapter {
        switch route.account {
        case .soniox:
            return SonioxBYOKAdapter(apiKey: try requiredKey(route), model: route.model)
        case .deepgram:
            return DeepgramBYOKAdapter(apiKey: try requiredKey(route), model: route.model)
        case .elevenLabs:
            return ElevenLabsBYOKAdapter(apiKey: try requiredKey(route), model: route.model)
        case .server:
            // No default host: a server without a usable address fails here
            // instead of reaching any other host.
            guard let url = BYOKRealtimeURL.openAIRealtime(baseURL: route.server?.baseURL) else {
                throw FeatureRouteError.invalidBaseURL(route.feature)
            }
            return OpenAIRealtimeAdapter(apiKey: route.apiKey ?? "", url: url, model: route.model)
        case .openRouter, .openAI, .anthropic:
            // OpenRouter and Anthropic serve text models only.
            throw FeatureRouteError.notSet(route.feature)
        }
    }

    /// The resolver always supplies a hosted provider's key; this keeps a
    /// hand-built route without one from opening a keyless connection.
    private static func requiredKey(_ route: ResolvedRoute) throws -> String {
        guard let key = route.apiKey, !key.isEmpty else { throw FeatureRouteError.missingKey(route.feature) }
        return key
    }
}

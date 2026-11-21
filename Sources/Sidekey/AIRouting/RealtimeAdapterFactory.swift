import Foundation

/// Builds the real-time transcription adapter of a route's own provider. It
/// only builds: no socket opens until the adapter does.
enum RealtimeAdapterFactory {
    /// Runtime only. Synthetic model probes deliberately use `make` below.
    /// On this Mac costs nothing and records no Costs row.
    static func makeMetered(_ route: ResolvedRoute) throws -> BYOKTranscriptionAdapter {
        let adapter = try make(route)
        if route.account == .thisMac { return adapter }
        return AIUsageMeteredAdapter(adapter: adapter, context: AIUsageContext(route))
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
        case .thisMac:
            // Not a socket: the model on this Mac behind the adapter contract,
            // for Subtitles audio and Meetings. Drop, Agent voice and Voice
            // search get their own session from `TranscriptionSessionFactory`.
            // WHY: .project-docs/decisions/2026-11-21-on-device-everywhere.md
            return OnDeviceStreamingAdapter(feature: route.feature, livePartials: route.feature != .meetings)
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

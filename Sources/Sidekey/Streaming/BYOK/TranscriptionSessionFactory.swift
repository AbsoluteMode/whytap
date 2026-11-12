import Foundation

/// Opens a real-time transcription session on the route of the feature that
/// asks for it: the feature's own provider account, model and key. A feature
/// that is Not set, or whose key is missing, fails with `FeatureRouteError`;
/// nothing is ever opened on another feature's provider.
@MainActor
struct TranscriptionSessionFactory {
    private let resolver: FeatureRouteResolver
    private let vocab: VocabularyCache
    private let makeAdapter: (ResolvedRoute) throws -> BYOKTranscriptionAdapter

    /// `vocab` defaults to the shared cache, looked up when the session is
    /// built: a literal `.shared` default does not compile for a main-actor
    /// value in Swift 5 mode.
    init(
        resolver: FeatureRouteResolver = FeatureRouteResolver(),
        vocab: VocabularyCache? = nil,
        makeAdapter: @escaping (ResolvedRoute) throws -> BYOKTranscriptionAdapter = RealtimeAdapterFactory.makeMetered
    ) {
        self.resolver = resolver
        self.vocab = vocab ?? .shared
        self.makeAdapter = makeAdapter
    }

    /// Build the session for `feature`. `resilient` enables degraded-turn batch
    /// recovery and must be `true` ONLY for the Drop flow; agent-voice and
    /// Google-search pass `false` so they can never resolve `.degraded` (their
    /// handlers treat it as a no-op, which would silently drop dictation).
    /// `endsOnlyByStop` marks a Drop auto-stop take: see the session's field.
    func make(
        feature: AIFeature,
        language: String?,
        resilient: Bool = false,
        endsOnlyByStop: Bool = false
    ) throws -> StreamingSessionRunning {
        guard let route = resolver.route(for: feature) else {
            throw FeatureRouteError.notSet(feature)
        }
        // The language check comes before the key: a model that cannot take
        // the input language is a setup problem whatever the key says.
        if route.account == .deepgram,
           let error = DeepgramLanguagePolicy.configurationError(model: route.model, language: language) {
            throw FeatureRouteError.invalidLanguageConfiguration(feature, error)
        }
        let resolved = try resolver.resolve(route, for: feature)
        let adapter = try makeAdapter(resolved)
        return DirectProviderStreamingSession(
            audioEngine: StreamingAudioEngine(),
            adapter: adapter,
            language: language,
            terms: vocab.terms,
            resilient: resilient,
            endsOnlyByStop: endsOnlyByStop
        )
    }
}

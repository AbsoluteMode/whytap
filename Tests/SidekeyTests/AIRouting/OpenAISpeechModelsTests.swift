import XCTest
@testable import Sidekey

/// OpenAI speech offers two models: `gpt-live-transcribe` for live dictation
/// and `gpt-transcribe` for recorded audio. A route saved on any other OpenAI
/// transcription model moves to them by role at launch, without an error.
// WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
@MainActor
final class OpenAISpeechModelsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "OpenAISpeechModelsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func store(_ routes: [String: FeatureRoute], migrated: [String: FeatureRoute] = [:],
                       in defaults: UserDefaults) throws -> AIRoutingStore {
        let state = AIRoutingState(routes: routes, migratedRoutes: migrated, servers: [], migrationVersion: 4)
        try defaults.set(JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        return AIRoutingStore(defaults: defaults)
    }

    private func openAI(_ model: String) -> FeatureRoute { FeatureRoute(account: .openAI, model: model) }

    func test_the_pool_is_two_models() {
        XCTAssertTrue(ModelRegistry.isVerified("gpt-live-transcribe", kind: .openAI, use: .realtimeSTT))
        XCTAssertTrue(ModelRegistry.isVerified("gpt-transcribe", kind: .openAI, use: .asyncSTT))
        XCTAssertFalse(ModelRegistry.isVerified("gpt-transcribe", kind: .openAI, use: .realtimeSTT))
        for retired in ["gpt-realtime-whisper", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"] {
            XCTAssertFalse(ModelRegistry.isVerified(retired, kind: .openAI, use: .realtimeSTT), retired)
            XCTAssertEqual(ModelCatalogFetcher.openAISpeechUses(retired), [], retired)
        }
        XCTAssertTrue(ModelRegistry.offersOnlyBuiltInModels(.openAI, use: .realtimeSTT))
        XCTAssertFalse(ModelRegistry.offersOnlyBuiltInModels(.openAI, use: .chat), "text models stay the live catalog")
    }

    func test_saved_routes_move_by_role_and_nothing_else_changes() throws {
        let defaults = defaults()
        let text = openAI("gpt-6")
        let other = FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash")
        let routing = try store([
            "dropFast": openAI("gpt-4o-mini-transcribe"),
            "dropSmart": openAI("gpt-realtime-whisper"),
            "agentVoice": openAI("gpt-transcribe"),
            "voiceSearch": openAI("gpt-4o-transcribe-2025-03-20"),
            "meetings": openAI("whisper-1"),
            "dropSmartCleanup": text,
            "meetingNotes": other,
        ], migrated: ["dropFast": openAI("gpt-4o-mini-transcribe")], in: defaults)
        routing.narrowOpenAISpeechModelsIfNeeded()

        let reloaded = AIRoutingStore(defaults: defaults)
        for feature in [AIFeature.dropFast, .dropSmart, .agentVoice, .voiceSearch] {
            XCTAssertEqual(reloaded.route(for: feature), openAI("gpt-live-transcribe"), "\(feature)")
        }
        XCTAssertEqual(reloaded.route(for: .meetings), openAI("gpt-transcribe"), "a recorded route gets the file model")
        XCTAssertEqual(reloaded.route(for: .dropSmartCleanup), text, "a text model on OpenAI stays")
        XCTAssertEqual(reloaded.route(for: .meetingNotes), other, "another provider stays")
        XCTAssertEqual(reloaded.migratedRoute(for: .dropFast), openAI("gpt-4o-mini-transcribe"),
                       "the snapshot keeps what was chosen before")

        let once = defaults.data(forKey: AIRoutingStore.defaultsKey)
        reloaded.narrowOpenAISpeechModelsIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), once, "a second launch writes nothing")
    }

    func test_the_live_model_and_unset_features_stay() throws {
        let defaults = defaults()
        let routing = try store(["dropFast": openAI("gpt-live-transcribe"),
                                 "dropSmart": openAI("gpt-live-transcribe-2026-10-01")], in: defaults)
        let before = defaults.data(forKey: AIRoutingStore.defaultsKey)
        routing.narrowOpenAISpeechModelsIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), before)
        XCTAssertNil(routing.route(for: .agentVoice), "the move never picks OpenAI for anyone")
    }

    /// The same model name on a user's own server is the server's own model.
    func test_a_server_route_with_an_openai_name_stays() throws {
        let defaults = defaults()
        let id = UUID()
        let own = FeatureRoute(account: .server(id), model: "whisper-1")
        let state = AIRoutingState(routes: ["dropFast": own], migratedRoutes: [:],
                                   servers: [ServerEndpoint(id: id, name: "Own", baseURL: "https://stt.example", keyAccount: "k")],
                                   migrationVersion: 4)
        try defaults.set(JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        let routing = AIRoutingStore(defaults: defaults)
        routing.narrowOpenAISpeechModelsIfNeeded()
        XCTAssertEqual(routing.route(for: .dropFast), own)
    }

    /// Retry and Drop's batch rung send recorded audio to gpt-transcribe.
    func test_recorded_audio_goes_to_gpt_transcribe() {
        XCTAssertEqual(
            ProviderBatchRoute.make(for: ResolvedRoute(
                feature: .dropFast, account: .openAI, model: "gpt-live-transcribe", apiKey: "oa-key", server: nil)),
            .openAI(apiKey: "oa-key", model: "gpt-transcribe"))
    }

    func test_the_migration_runs_the_move_at_launch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/AIRouting/AIRoutingMigration.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("routing.narrowOpenAISpeechModelsIfNeeded()"))
    }
}

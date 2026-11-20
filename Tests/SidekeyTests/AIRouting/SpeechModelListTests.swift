import XCTest
@testable import Sidekey

/// Soniox v6 replaced v5 on the owner's decision: a saved Soniox route moves
/// to the same kind of v6 model on the same account, and nothing else moves.
// WHY: .project-docs/decisions/2026-11-20-speech-model-lists.md
@MainActor
final class SpeechModelListTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "SpeechModelListTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let oldLive = FeatureRoute(account: .soniox, model: "stt-rt-v5")
    private let oldRecorded = FeatureRoute(account: .soniox, model: "stt-async-v5")
    private let newLive = FeatureRoute(account: .soniox, model: "stt-rt-v6")
    private let newRecorded = FeatureRoute(account: .soniox, model: "stt-async-v6")
    private let deepgram = FeatureRoute(account: .deepgram, model: "nova-2-meeting")
    private let llm = FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash", provider: "deepinfra/fp4")

    @discardableResult
    private func store(_ routes: [String: FeatureRoute], migrated: [String: FeatureRoute] = [:],
                       servers: [ServerEndpoint] = [], in defaults: UserDefaults) throws -> AIRoutingStore {
        let state = AIRoutingState(routes: routes, migratedRoutes: migrated, servers: servers, migrationVersion: 4)
        try defaults.set(JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        return AIRoutingStore(defaults: defaults)
    }

    func test_the_built_in_soniox_models_are_v6() {
        XCTAssertEqual(ModelRegistry.sonioxRealtimeModel, "stt-rt-v6")
        XCTAssertEqual(ModelRegistry.sonioxRecordedModel, "stt-async-v6")
        XCTAssertEqual(SonioxFileAPI.asyncModel, "stt-async-v6", "recovery and meetings send files to the v6 model")
        XCTAssertFalse(ModelRegistry.isVerified("stt-rt-v5", kind: .soniox, use: .realtimeSTT))
        XCTAssertNotNil(ModelRegistry.documentedReleaseDate(for: "stt-rt-v6", kind: .soniox))
        XCTAssertNotNil(ModelRegistry.documentedReleaseDate(for: "stt-async-v6", kind: .soniox))
    }

    func test_saved_v5_routes_move_to_v6_of_the_same_kind_and_nothing_else_changes() throws {
        let defaults = defaults()
        let routing = try store(
            ["dropFast": oldLive, "agentVoice": oldLive, "meetings": oldRecorded,
             "voiceSearch": deepgram, "dropSmartCleanup": llm],
            migrated: ["dropFast": oldLive], in: defaults)
        routing.upgradeSonioxModelsIfNeeded()

        let reloaded = AIRoutingStore(defaults: defaults)
        XCTAssertEqual(reloaded.route(for: .dropFast), newLive)
        XCTAssertEqual(reloaded.route(for: .agentVoice), newLive)
        XCTAssertEqual(reloaded.route(for: .meetings), newRecorded, "a recorded route never becomes a live one")
        XCTAssertEqual(reloaded.route(for: .voiceSearch), deepgram, "another provider keeps its saved model")
        XCTAssertEqual(reloaded.route(for: .dropSmartCleanup), llm, "a pinned text route keeps its pin")
        XCTAssertEqual(reloaded.migratedRoute(for: .dropFast), oldLive, "the snapshot keeps what was chosen before")

        let once = defaults.data(forKey: AIRoutingStore.defaultsKey)
        reloaded.upgradeSonioxModelsIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), once, "a second launch writes nothing")
    }

    func test_a_feature_without_a_route_stays_not_set() throws {
        let defaults = defaults()
        let routing = try store(["voiceSearch": deepgram], in: defaults)
        let before = defaults.data(forKey: AIRoutingStore.defaultsKey)
        routing.upgradeSonioxModelsIfNeeded()
        XCTAssertNil(routing.route(for: .dropFast), "the upgrade never picks Soniox for anyone")
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), before)
    }

    /// The same model name on another account (a user's own server) is theirs,
    /// and an older Soniox name the app never shipped as v5 is left alone.
    func test_only_soniox_v5_routes_are_upgraded() throws {
        let defaults = defaults()
        let server = UUID()
        let own = FeatureRoute(account: .server(server), model: "stt-rt-v5")
        let older = FeatureRoute(account: .soniox, model: "stt-rt-v4")
        let routing = try store(
            ["dropFast": own, "dropSmart": older],
            servers: [ServerEndpoint(id: server, name: "Own", baseURL: "https://stt.example", keyAccount: "k")],
            in: defaults)
        routing.upgradeSonioxModelsIfNeeded()
        XCTAssertEqual(routing.route(for: .dropFast), own)
        XCTAssertEqual(routing.route(for: .dropSmart), older)
    }

    /// A document this build could not read in full is not rewritten at launch.
    func test_a_partial_document_is_not_overwritten() {
        let defaults = defaults()
        let raw = Data(#"{"routes":{"dropFast":{"account":"soniox","model":"stt-rt-v5"},"future":{"account":"unknown-provider","model":"x"}},"migratedRoutes":{},"servers":[],"migrationVersion":4}"#.utf8)
        defaults.set(raw, forKey: AIRoutingStore.defaultsKey)
        AIRoutingStore(defaults: defaults).upgradeSonioxModelsIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), raw)
    }

    func test_the_migration_runs_the_upgrade_at_launch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/AIRouting/AIRoutingMigration.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("routing.upgradeSonioxModelsIfNeeded()"))
    }

    /// Costs: v6 is estimated at Soniox's public hourly rates, like v5 was.
    func test_v6_speech_keeps_a_price_estimate() {
        for (model, hourly) in [("stt-rt-v6", 0.12), ("stt-async-v6", 0.10), ("stt-rt-v5", 0.12), ("stt-async-v5", 0.10)] {
            let context = AIUsageContext(feature: .dropFast, account: .soniox, model: model)
            let event = AIUsageEvent.speech(context, seconds: 3600)
            XCTAssertEqual(event.amount ?? -1, hourly, accuracy: 0.0001, model)
            XCTAssertEqual(event.basis, .estimated, model)
        }
    }
}

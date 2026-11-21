import XCTest
@testable import Sidekey

/// Meetings on ElevenLabs go to its speech-to-text endpoint, which refuses the
/// streaming model: a saved Meetings route naming Scribe's real-time model
/// moves to Scribe v3 on the same account, and nothing else moves.
// WHY: .project-docs/decisions/2026-11-21-recorded-meeting-models.md
@MainActor
final class MeetingsRecordedModelMigrationTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "MeetingsRecordedModelMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let live = FeatureRoute(account: .elevenLabs, model: "scribe_v3_live")
    private let retiredLive = FeatureRoute(account: .elevenLabs, model: "scribe_v2_realtime")
    private let recorded = FeatureRoute(account: .elevenLabs, model: "scribe_v3")
    private let deepgram = FeatureRoute(account: .deepgram, model: "nova-3")

    @discardableResult
    private func store(_ routes: [String: FeatureRoute], migrated: [String: FeatureRoute] = [:],
                       in defaults: UserDefaults) throws -> AIRoutingStore {
        let state = AIRoutingState(routes: routes, migratedRoutes: migrated, servers: [], migrationVersion: 4)
        try defaults.set(JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        return AIRoutingStore(defaults: defaults)
    }

    func test_launch_moves_the_meetings_route_to_scribe_v3_and_keeps_dictation_live() throws {
        let defaults = defaults()
        let routing = try store(
            ["meetings": retiredLive, "dropFast": retiredLive, "agentVoice": live],
            migrated: ["meetings": retiredLive], in: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })

        AIRoutingMigration(prefs: SelfKeyPreferences(defaults: defaults, isAppleSilicon: true),
                           defaults: defaults, routing: routing, keys: keys).run()

        let reloaded = AIRoutingStore(defaults: defaults)
        XCTAssertEqual(reloaded.route(for: .meetings), recorded, "the same account and key, the recorded model")
        XCTAssertEqual(reloaded.route(for: .dropFast), live, "dictation stays on the streaming model")
        XCTAssertEqual(reloaded.route(for: .agentVoice), live)
        XCTAssertEqual(reloaded.migratedRoute(for: .meetings), retiredLive, "the snapshot keeps what was chosen before")

        let once = defaults.data(forKey: AIRoutingStore.defaultsKey)
        reloaded.moveMeetingsToRecordedModelIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), once, "a second launch writes nothing")
    }

    func test_other_providers_and_a_picked_recorded_model_are_left_alone() throws {
        let defaults = defaults()
        let routing = try store(["meetings": deepgram], in: defaults)
        let before = defaults.data(forKey: AIRoutingStore.defaultsKey)
        routing.moveMeetingsToRecordedModelIfNeeded()
        XCTAssertEqual(routing.route(for: .meetings), deepgram, "nova-3 serves both kinds")
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), before)

        let scribeV2 = FeatureRoute(account: .elevenLabs, model: "scribe_v2")
        let picked = try store(["meetings": scribeV2], in: defaults)
        picked.moveMeetingsToRecordedModelIfNeeded()
        XCTAssertEqual(picked.route(for: .meetings), scribeV2, "a recorded model the user picked is theirs")
    }

    func test_no_meetings_route_stays_not_set() throws {
        let defaults = defaults()
        let routing = try store(["dropFast": live], in: defaults)
        routing.moveMeetingsToRecordedModelIfNeeded()
        XCTAssertNil(routing.route(for: .meetings), "the migration never picks a provider for anyone")
        XCTAssertEqual(routing.route(for: .dropFast), live)
    }

    func test_meetings_offer_recorded_models_on_every_hosted_speech_provider() {
        XCTAssertEqual(AIFeature.meetings.modelUse(on: .soniox), .asyncSTT)
        XCTAssertEqual(AIFeature.meetings.modelUse(on: .elevenLabs), .asyncSTT)
        XCTAssertEqual(AIFeature.meetings.modelUse(on: .deepgram), .asyncSTT)
        XCTAssertEqual(AIFeature.meetings.modelUse(on: .openAICompatible), .realtimeSTT, "a server keeps its realtime path")
        XCTAssertEqual(ModelRegistry.recommended(for: .meetings, kind: .elevenLabs), "scribe_v3")
        XCTAssertEqual(ModelRegistry.recommended(for: .meetings, kind: .deepgram), "nova-3")
        XCTAssertEqual(ModelRegistry.recommended(for: .dropFast, kind: .elevenLabs), "scribe_v3_live")
        XCTAssertTrue(ModelRegistry.isVerified("nova-3", kind: .deepgram, use: .asyncSTT))
        XCTAssertTrue(ModelRegistry.isVerified("scribe_v3", kind: .elevenLabs, use: .asyncSTT))
        XCTAssertFalse(ModelRegistry.isVerified("scribe_v3_live", kind: .elevenLabs, use: .asyncSTT))
    }

    func test_a_streaming_scribe_model_is_never_sent_to_the_recorded_endpoint() {
        XCTAssertEqual(ModelRegistry.elevenLabsRecordedModel(for: "scribe_v3_live"), "scribe_v3")
        XCTAssertEqual(ModelRegistry.elevenLabsRecordedModel(for: "scribe_v2_realtime"), "scribe_v3")
        XCTAssertEqual(ModelRegistry.elevenLabsRecordedModel(for: "scribe_v3"), "scribe_v3")
        XCTAssertEqual(ModelRegistry.elevenLabsRecordedModel(for: "scribe_v2"), "scribe_v2")
    }
}

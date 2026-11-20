import XCTest
@testable import Sidekey

/// Scribe v3 replaced Scribe v2 on the owner's decision: a saved ElevenLabs
/// route moves to the newer model on the same account, and nothing else moves.
// WHY: .project-docs/decisions/2026-11-20-elevenlabs-scribe-v3.md
@MainActor
final class ElevenLabsScribeUpgradeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ElevenLabsScribeUpgradeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private let old = FeatureRoute(account: .elevenLabs, model: "scribe_v2_realtime")
    private let new = FeatureRoute(account: .elevenLabs, model: "scribe_v3_live")
    private let soniox = FeatureRoute(account: .soniox, model: "stt-rt-v5")
    private let llm = FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash", provider: "deepinfra/fp4")

    @discardableResult
    private func store(_ routes: [String: FeatureRoute], migrated: [String: FeatureRoute] = [:],
                       servers: [ServerEndpoint] = [], in defaults: UserDefaults) throws -> AIRoutingStore {
        let state = AIRoutingState(routes: routes, migratedRoutes: migrated, servers: servers, migrationVersion: 4)
        try defaults.set(JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        return AIRoutingStore(defaults: defaults)
    }

    func test_saved_scribe_v2_routes_move_to_v3_live_and_nothing_else_changes() throws {
        let defaults = defaults()
        let routing = try store(
            ["dropFast": old, "meetings": old, "agentVoice": soniox, "dropSmartCleanup": llm],
            migrated: ["dropFast": old], in: defaults)
        routing.upgradeElevenLabsScribeIfNeeded()

        let reloaded = AIRoutingStore(defaults: defaults)
        XCTAssertEqual(reloaded.route(for: .dropFast), new)
        XCTAssertEqual(reloaded.route(for: .meetings), new)
        XCTAssertEqual(reloaded.route(for: .agentVoice), soniox, "another provider is never touched")
        XCTAssertEqual(reloaded.route(for: .dropSmartCleanup), llm, "a pinned text route keeps its pin")
        XCTAssertEqual(reloaded.migratedRoute(for: .dropFast), old, "the snapshot keeps what was chosen before")

        let once = defaults.data(forKey: AIRoutingStore.defaultsKey)
        reloaded.upgradeElevenLabsScribeIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), once, "a second launch writes nothing")
    }

    func test_a_feature_without_a_route_stays_not_set() throws {
        let defaults = defaults()
        let routing = try store(["agentVoice": soniox], in: defaults)
        let before = defaults.data(forKey: AIRoutingStore.defaultsKey)
        routing.upgradeElevenLabsScribeIfNeeded()
        XCTAssertNil(routing.route(for: .dropFast), "the upgrade never picks ElevenLabs for anyone")
        XCTAssertEqual(routing.route(for: .agentVoice), soniox)
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), before)
    }

    /// The same model name on another account (a user's own server) is theirs.
    func test_only_the_elevenlabs_account_is_upgraded() throws {
        let defaults = defaults()
        let server = UUID()
        let own = FeatureRoute(account: .server(server), model: "scribe_v2_realtime")
        let routing = try store(
            ["dropFast": own],
            servers: [ServerEndpoint(id: server, name: "Own", baseURL: "https://stt.example", keyAccount: "k")],
            in: defaults)
        routing.upgradeElevenLabsScribeIfNeeded()
        XCTAssertEqual(routing.route(for: .dropFast), own)
    }

    func test_a_route_restored_from_an_older_backup_moves_again() throws {
        let defaults = defaults()
        try store(["dropSmart": old], in: defaults).upgradeElevenLabsScribeIfNeeded()
        try store(["dropSmart": old], in: defaults).upgradeElevenLabsScribeIfNeeded()
        XCTAssertEqual(AIRoutingStore(defaults: defaults).route(for: .dropSmart), new)
    }

    /// A document this build could not read in full is not rewritten at launch.
    func test_a_partial_document_is_not_overwritten() {
        let defaults = defaults()
        let raw = Data(#"{"routes":{"dropFast":{"account":"elevenLabs","model":"scribe_v2_realtime"},"future":{"account":"unknown-provider","model":"x"}},"migratedRoutes":{},"servers":[],"migrationVersion":4}"#.utf8)
        defaults.set(raw, forKey: AIRoutingStore.defaultsKey)
        AIRoutingStore(defaults: defaults).upgradeElevenLabsScribeIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), raw)
    }

    func test_the_migration_runs_the_upgrade_at_launch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/AIRouting/AIRoutingMigration.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("routing.upgradeElevenLabsScribeIfNeeded()"))
    }
}

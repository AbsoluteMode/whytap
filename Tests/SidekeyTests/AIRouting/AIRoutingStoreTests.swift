import Combine
import XCTest
@testable import Sidekey

/// The persisted route state: which provider account and model each AI
/// feature uses, the user's own servers, and the one-time migration marker.
/// Every test gets its own `UserDefaults` suite, so nothing reaches
/// `.standard` and tests cannot see each other's writes.
@MainActor
final class AIRoutingStoreTests: XCTestCase {

    private let key = "sidekey.aiRouting.v1"

    private func makeDefaults() -> UserDefaults {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func storedJSON(in defaults: UserDefaults) throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: key), "nothing stored under \(key)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Persistence

    func test_fresh_store_is_empty_unmigrated_and_writes_nothing() {
        let defaults = makeDefaults()
        let store = AIRoutingStore(defaults: defaults)

        XCTAssertEqual(store.state, AIRoutingState(routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 0))
        XCTAssertFalse(store.isMigrated)
        XCTAssertNil(defaults.data(forKey: key))
    }

    func test_default_key_is_the_v1_key() {
        XCTAssertEqual(AIRoutingStore.defaultsKey, "sidekey.aiRouting.v1")
    }

    func test_route_round_trips_through_user_defaults() {
        let defaults = makeDefaults()
        let route = FeatureRoute(account: .soniox, model: "stt-rt-v4")
        AIRoutingStore(defaults: defaults).setRoute(route, for: .dropFast)

        let reloaded = AIRoutingStore(defaults: defaults)

        XCTAssertEqual(reloaded.route(for: .dropFast), route)
        XCTAssertNil(reloaded.route(for: .dropSmart))
    }

    func test_stored_json_uses_feature_and_account_ids() throws {
        let defaults = makeDefaults()
        let store = AIRoutingStore(defaults: defaults)
        let server = store.addServer(name: "Home GPU", baseURL: "http://gpu.local:8000/v1")
        store.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v4"), for: .dropFast)
        store.setRoute(FeatureRoute(account: .server(server.id), model: "whisper-large-v3"), for: .meetings)

        let json = try storedJSON(in: defaults)
        XCTAssertEqual(Set(json.keys), ["routes", "migratedRoutes", "servers", "migrationVersion"])
        let routes = try XCTUnwrap(json["routes"] as? [String: [String: Any]])
        XCTAssertEqual(Set(routes.keys), ["dropFast", "meetings"])
        XCTAssertEqual(routes["dropFast"]?["account"] as? String, "soniox")
        XCTAssertEqual(routes["dropFast"]?["model"] as? String, "stt-rt-v4")
        XCTAssertEqual(routes["meetings"]?["account"] as? String, "server:\(server.id.uuidString.lowercased())")
        XCTAssertEqual(json["migrationVersion"] as? Int, 0)
    }

    func test_setting_a_route_replaces_the_previous_one_and_nil_unsets_it() {
        let defaults = makeDefaults()
        let store = AIRoutingStore(defaults: defaults)
        store.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .translation)
        let replacement = FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5")
        store.setRoute(replacement, for: .translation)

        XCTAssertEqual(store.route(for: .translation), replacement)
        XCTAssertEqual(AIRoutingStore(defaults: defaults).route(for: .translation), replacement)

        store.setRoute(nil, for: .translation)

        XCTAssertNil(store.route(for: .translation))
        XCTAssertNil(AIRoutingStore(defaults: defaults).route(for: .translation))
    }

    /// The Agent runs on Claude Code or Codex: its old text route stays in
    /// the stored state for a rollback build, but is neither read nor written.
    func test_the_inactive_agent_route_is_kept_but_never_read_or_written() throws {
        let defaults = makeDefaults()
        let old = FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5")
        let state = AIRoutingState(routes: [AIFeature.agent.rawValue: old], migratedRoutes: [:], servers: [], migrationVersion: 4)
        defaults.set(try JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        let store = AIRoutingStore(defaults: defaults)
        XCTAssertNil(store.route(for: .agent))
        store.setRoute(FeatureRoute(account: .openRouter, model: "other"), for: .agent)
        store.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .translation)
        XCTAssertEqual(AIRoutingStore(defaults: defaults).state.routes[AIFeature.agent.rawValue], old)
    }

    /// A stored state this build cannot read at all is never "not migrated":
    /// running the migration again would overwrite the user's routes from the
    /// frozen old settings (final review I3). Every feature is Not set instead.
    func test_unreadable_state_counts_as_migrated_with_every_feature_not_set() {
        let unreadable: [(label: String, value: Any)] = [
            ("not json", Data("{ not json".utf8)),
            ("empty data", Data()),
            ("wrong shape", Data("[]".utf8)),
            ("not data at all", "garbage"),
        ]
        for entry in unreadable {
            let defaults = makeDefaults()
            defaults.set(entry.value, forKey: key)

            let store = AIRoutingStore(defaults: defaults)

            XCTAssertTrue(store.isMigrated, entry.label)
            XCTAssertEqual(store.state, AIRoutingState(routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 1), entry.label)
            for feature in AIFeature.allCases {
                XCTAssertNil(store.route(for: feature), "\(entry.label): \(feature.rawValue)")
            }
        }
    }

    /// One entry this build does not know (an account a newer build added)
    /// drops only that entry; the rest of the state is read as stored.
    func test_unknown_entries_are_skipped_and_the_rest_is_kept() throws {
        let defaults = makeDefaults()
        let serverID = "6f1c1f7e-1111-4a5b-9c9d-000000000001"
        let json = #"""
        {"routes":{"dropFast":{"account":"openai","model":"gpt-x"},"meetings":{"account":"soniox","model":"stt-async-v5"}},
         "migratedRoutes":{"dropFast":{"account":"openai","model":"gpt-x"},"meetingNotes":{"account":"openRouter","model":"m"}},
         "servers":[{"id":"\#(serverID)","name":"Lab","baseURL":"http://10.0.0.2/v1","keyAccount":"byok.server.x.api_key"},{"id":"bad"}],
         "migrationVersion":1,"futureField":true}
        """#
        defaults.set(Data(json.utf8), forKey: key)

        let store = AIRoutingStore(defaults: defaults)

        XCTAssertTrue(store.isMigrated)
        XCTAssertNil(store.route(for: .dropFast))
        XCTAssertEqual(store.route(for: .meetings), FeatureRoute(account: .soniox, model: "stt-async-v5"))
        XCTAssertNil(store.migratedRoute(for: .dropFast))
        XCTAssertEqual(store.migratedRoute(for: .meetingNotes), FeatureRoute(account: .openRouter, model: "m"))
        XCTAssertEqual(store.state.servers.map(\.name), ["Lab"])
        XCTAssertEqual(defaults.data(forKey: key), Data(json.utf8), "loading must not rewrite the stored value")
    }

    /// The first real change keeps a copy of a value that was not read in
    /// full, so a rollback never destroys a newer build's state outright.
    func test_first_change_backs_up_a_value_that_was_not_read_in_full() {
        let defaults = makeDefaults()
        let partial = Data(#"{"routes":{"dropFast":{"account":"openai","model":"gpt-x"}},"migratedRoutes":{},"servers":[],"migrationVersion":1}"#.utf8)
        defaults.set(partial, forKey: key)
        let store = AIRoutingStore(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: AIRoutingStore.backupKey))

        store.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .dropSmart)

        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.backupKey), partial)
        XCTAssertNotEqual(defaults.data(forKey: key), partial)

        // A state read in full needs no copy.
        let clean = makeDefaults()
        let cleanStore = AIRoutingStore(defaults: clean)
        cleanStore.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .dropSmart)
        AIRoutingStore(defaults: clean).setRoute(nil, for: .dropSmart)
        XCTAssertNil(clean.object(forKey: AIRoutingStore.backupKey))
    }

    func test_unreadable_json_is_replaced_only_by_the_next_real_mutation() {
        let defaults = makeDefaults()
        let garbage = Data("{ not json".utf8)
        defaults.set(garbage, forKey: key)
        let store = AIRoutingStore(defaults: defaults)
        XCTAssertEqual(defaults.data(forKey: key), garbage, "loading must not rewrite the stored value")

        store.setRoute(nil, for: .agent)
        store.removeServer(UUID())
        store.clearRoutes(using: .soniox)
        XCTAssertEqual(defaults.data(forKey: key), garbage, "a mutation that changes nothing must not write")

        let route = FeatureRoute(account: .deepgram, model: "nova-3")
        store.setRoute(route, for: .dropFast)

        XCTAssertNotEqual(defaults.data(forKey: key), garbage)
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.backupKey), garbage, "the unreadable value is kept aside")
        XCTAssertEqual(AIRoutingStore(defaults: defaults).route(for: .dropFast), route)
    }

    func test_is_migrated_means_version_one_or_later() throws {
        for (version, migrated) in [(0, false), (1, true), (2, true)] {
            let defaults = makeDefaults()
            let state = AIRoutingState(routes: [:], migratedRoutes: [:], servers: [], migrationVersion: version)
            defaults.set(try JSONEncoder().encode(state), forKey: key)

            XCTAssertEqual(AIRoutingStore(defaults: defaults).isMigrated, migrated, "version \(version)")
        }
    }

    // MARK: - Servers

    func test_new_server_gets_its_own_keychain_account() {
        let store = AIRoutingStore(defaults: makeDefaults())
        let first = store.addServer(name: "Home GPU", baseURL: "http://gpu.local:8000/v1")
        let second = store.addServer(name: "Office", baseURL: "https://llm.example.com/v1")

        XCTAssertEqual(first.keyAccount, "byok.server.\(first.id.uuidString.lowercased()).api_key")
        XCTAssertEqual(second.keyAccount, "byok.server.\(second.id.uuidString.lowercased()).api_key")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.keyAccount, second.keyAccount)
        XCTAssertEqual(first.name, "Home GPU")
        XCTAssertEqual(first.baseURL, "http://gpu.local:8000/v1")
    }

    func test_servers_are_listed_looked_up_and_persisted() {
        let defaults = makeDefaults()
        let store = AIRoutingStore(defaults: defaults)
        let first = store.addServer(name: "Home GPU", baseURL: "http://gpu.local:8000/v1")
        let second = store.addServer(name: "Office", baseURL: "https://llm.example.com/v1")

        XCTAssertEqual(store.state.servers, [first, second])
        XCTAssertEqual(store.server(first.id), first)
        XCTAssertEqual(store.server(second.id), second)
        XCTAssertNil(store.server(UUID()))

        let reloaded = AIRoutingStore(defaults: defaults)
        XCTAssertEqual(reloaded.state.servers, [first, second])
        XCTAssertEqual(reloaded.server(second.id), second)
    }

    func test_removing_a_server_unsets_its_features() {
        let defaults = makeDefaults()
        let store = AIRoutingStore(defaults: defaults)
        let kept = store.addServer(name: "Kept", baseURL: "http://kept.local/v1")
        let removed = store.addServer(name: "Removed", baseURL: "http://removed.local/v1")
        store.setRoute(FeatureRoute(account: .server(removed.id), model: "whisper-large-v3"), for: .dropFast)
        store.setRoute(FeatureRoute(account: .server(removed.id), model: "qwen3-30b"), for: .dropSmartCleanup)
        store.setRoute(FeatureRoute(account: .server(kept.id), model: "whisper-large-v3"), for: .dropSmart)
        store.setRoute(FeatureRoute(account: .soniox, model: "stt-async-v5"), for: .meetings)

        store.removeServer(removed.id)

        for reloaded in [store, AIRoutingStore(defaults: defaults)] {
            XCTAssertNil(reloaded.server(removed.id))
            XCTAssertEqual(reloaded.server(kept.id), kept)
            XCTAssertNil(reloaded.route(for: .dropFast))
            XCTAssertNil(reloaded.route(for: .dropSmartCleanup))
            XCTAssertEqual(reloaded.route(for: .dropSmart)?.account, .server(kept.id))
            XCTAssertEqual(reloaded.route(for: .meetings)?.account, .soniox)
        }
    }

    // MARK: - Clearing routes

    func test_clear_routes_using_account_unsets_only_that_account() {
        let defaults = makeDefaults()
        let store = AIRoutingStore(defaults: defaults)
        // Set out of registry order: the result must still follow it.
        store.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .agentVoice)
        store.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        let meetings = FeatureRoute(account: .deepgram, model: "nova-3")
        store.setRoute(meetings, for: .meetings)

        let cleared = store.clearRoutes(using: .soniox)

        XCTAssertEqual(cleared, [.dropFast, .agentVoice])
        XCTAssertNil(store.route(for: .dropFast))
        XCTAssertNil(store.route(for: .agentVoice))
        XCTAssertEqual(store.route(for: .meetings), meetings)
        let reloaded = AIRoutingStore(defaults: defaults)
        XCTAssertNil(reloaded.route(for: .dropFast))
        XCTAssertEqual(reloaded.route(for: .meetings), meetings)
        XCTAssertEqual(store.clearRoutes(using: .soniox), [], "nothing is left on that account")
    }

    func test_clearing_routes_never_touches_the_migration_snapshot() {
        let store = AIRoutingStore(defaults: makeDefaults())
        let server = ServerEndpoint(id: UUID(), name: "GPU", baseURL: "http://gpu.local/v1", keyAccount: "byok.custom_llm.api_key")
        let soniox = FeatureRoute(account: .soniox, model: "stt-rt-v5")
        let viaServer = FeatureRoute(account: .server(server.id), model: "qwen3-30b")
        store.completeMigration(routes: [.dropFast: soniox, .dropSmartCleanup: viaServer], servers: [server])

        store.clearRoutes(using: .soniox)
        store.removeServer(server.id)

        XCTAssertNil(store.route(for: .dropFast))
        XCTAssertNil(store.route(for: .dropSmartCleanup))
        XCTAssertEqual(store.migratedRoute(for: .dropFast), soniox)
        XCTAssertEqual(store.migratedRoute(for: .dropSmartCleanup), viaServer)
    }

    // MARK: - Migration

    func test_complete_migration_snapshots_routes_and_marks_the_store_migrated() {
        let defaults = makeDefaults()
        let store = AIRoutingStore(defaults: defaults)
        let server = ServerEndpoint(id: UUID(), name: "Self-hosted", baseURL: "http://gpu.local:8000/v1", keyAccount: "byok.selfHosted.api_key")
        let dropFast = FeatureRoute(account: .server(server.id), model: "gpt-4o-transcribe")
        let cleanup = FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash")

        store.completeMigration(routes: [.dropFast: dropFast, .dropSmartCleanup: cleanup], servers: [server])

        XCTAssertTrue(store.isMigrated)
        XCTAssertEqual(store.state.migrationVersion, 1)
        XCTAssertEqual(store.route(for: .dropFast), dropFast)
        XCTAssertEqual(store.migratedRoute(for: .dropFast), dropFast)
        XCTAssertEqual(store.route(for: .dropSmartCleanup), cleanup)
        XCTAssertEqual(store.migratedRoute(for: .dropSmartCleanup), cleanup)
        XCTAssertNil(store.route(for: .meetings))
        XCTAssertNil(store.migratedRoute(for: .meetings))
        XCTAssertEqual(store.state.routes, store.state.migratedRoutes)
        XCTAssertEqual(store.state.servers, [server])
        XCTAssertEqual(store.server(server.id), server)

        let reloaded = AIRoutingStore(defaults: defaults)
        XCTAssertEqual(reloaded.state, store.state)
        XCTAssertTrue(reloaded.isMigrated)
    }

    func test_routes_changed_after_migration_leave_the_snapshot_as_it_was() {
        let store = AIRoutingStore(defaults: makeDefaults())
        let migrated = FeatureRoute(account: .deepgram, model: "nova-3")
        store.completeMigration(routes: [.dropFast: migrated], servers: [])

        store.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        store.setRoute(nil, for: .dropFast)

        XCTAssertNil(store.route(for: .dropFast))
        XCTAssertEqual(store.migratedRoute(for: .dropFast), migrated)
    }

    // MARK: - Publishing

    func test_each_change_publishes_once_and_a_no_op_publishes_nothing() {
        let store = AIRoutingStore(defaults: makeDefaults())
        let server = store.addServer(name: "GPU", baseURL: "http://gpu.local/v1")
        store.setRoute(FeatureRoute(account: .server(server.id), model: "qwen3-30b"), for: .dropSmartCleanup)
        var published = 0
        let subscription = store.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        store.removeServer(server.id)  // the server and its route go together
        XCTAssertEqual(published, 1)

        store.removeServer(server.id)
        store.setRoute(nil, for: .agent)
        store.clearRoutes(using: .soniox)
        XCTAssertEqual(published, 1)
    }
}

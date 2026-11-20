import XCTest
@testable import Sidekey

/// The one-time carry-over of the old Models-tab choices into per-feature
/// routes. Old settings are written the way old builds stored them (raw
/// `UserDefaults` keys), keys sit in an in-memory Keychain, and every test gets
/// its own `UserDefaults` suite, so nothing reaches `UserDefaults.standard` or
/// the login Keychain.
@MainActor
final class AIRoutingMigrationTests: XCTestCase {

    /// The `UserDefaults` keys old builds wrote.
    private enum Old {
        static let level = "sidekey.models.transcriptionLevel"
        static let provider = "sidekey.models.byokProvider"
        static let sonioxModel = "sidekey.models.byokModel.soniox"
        static let deepgramModel = "sidekey.models.byokModel.deepgram"
        static let selfHostedURL = "sidekey.models.selfHostedBaseURL"
        static let selfHostedModel = "sidekey.models.selfHostedModel"
        static let llmLevel = "sidekey.models.llmLevel"
        static let openRouterModel = "sidekey.models.openRouterModel"
        static let customURL = "sidekey.models.customLLMBaseURL"
        static let customModel = "sidekey.models.customLLMModel"
        static let agentModel = "agent.opencode.model"
    }

    /// The Keychain accounts old builds kept their keys in.
    private enum Account {
        static let soniox = "byok.soniox.api_key"
        static let deepgram = "byok.deepgram.api_key"
        static let openRouter = "byok.openrouter.llm_api_key"
        static let selfHosted = "byok.selfHosted.api_key"
        static let customLLM = "byok.custom_llm.api_key"
    }

    private let realtimeFeatures: [AIFeature] = [.dropFast, .dropSmart, .agentVoice, .voiceSearch]

    private struct Env {
        let defaults: UserDefaults
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
    }

    /// A Keychain slot that is there but will not be read: locked, access
    /// denied or a damaged item.
    private struct UnreadableTokenStore: TokenStore {
        struct Failure: Error {}
        func save(_ token: String) throws {}
        func read() throws -> String? { throw Failure() }
        func delete() throws {}
    }

    /// `unreadable` names the Keychain accounts whose key cannot be read.
    private func makeEnv(unreadable: Set<String> = []) -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { account -> any TokenStore in
            if unreadable.contains(account) { return UnreadableTokenStore() }
            return InMemoryTokenStore(account: account, box: box)
        })
        return Env(defaults: defaults, routing: AIRoutingStore(defaults: defaults), keys: keys)
    }

    /// What the app does at launch, on a Mac with the given CPU.
    private func migrate(_ env: Env, appleSilicon: Bool = false) {
        AIRoutingMigration(
            prefs: SelfKeyPreferences(defaults: env.defaults, isAppleSilicon: appleSilicon),
            defaults: env.defaults, routing: env.routing, keys: env.keys
        ).run()
    }

    private func assertAllNotSet(
        _ routing: AIRoutingStore,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for feature in AIFeature.allCases where feature != .dropSmartDecision {
            XCTAssertNil(routing.route(for: feature), "\(feature) should be Not set", file: file, line: line)
        }
    }

    /// Every old setting this build reads, as it sits in `defaults`.
    private func oldSettings(in defaults: UserDefaults) -> [String: Any] {
        defaults.dictionaryRepresentation().filter {
            $0.key.hasPrefix("sidekey.models.") || $0.key == Old.agentModel
        }
    }

    // MARK: - Speech and LLM choices

    func test_maxims_prod_settings_migrate_without_changing_any_model() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("soniox", forKey: Old.provider)
        env.defaults.set("stt-rt-v4", forKey: Old.sonioxModel)
        env.defaults.set("yourKey", forKey: Old.llmLevel)
        env.defaults.set("google/gemini-3.8-flash", forKey: Old.openRouterModel)
        env.defaults.set("anthropic/claude-sonnet-5.5", forKey: Old.agentModel)
        try env.keys.save("soniox-key", account: Account.soniox)
        try env.keys.save("openrouter-key", account: Account.openRouter)

        migrate(env, appleSilicon: true)

        for feature in realtimeFeatures {
            XCTAssertEqual(
                env.routing.route(for: feature), FeatureRoute(account: .soniox, model: "stt-rt-v4"), "\(feature)"
            )
        }
        XCTAssertEqual(env.routing.route(for: .meetings), FeatureRoute(account: .soniox, model: "stt-async-v6"))
        let llm = FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash")
        XCTAssertEqual(env.routing.route(for: .dropSmartCleanup), llm)
        XCTAssertEqual(env.routing.route(for: .meetingNotes), llm)
        XCTAssertEqual(
            env.routing.route(for: .agent), FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5")
        )
        for feature in AIFeature.allCases where feature != .dropSmartDecision {
            XCTAssertEqual(env.routing.migratedRoute(for: feature), env.routing.route(for: feature), "\(feature)")
        }
        XCTAssertTrue(env.routing.isMigrated)
        XCTAssertTrue(env.routing.state.servers.isEmpty)
    }

    /// Apple Silicon defaulted to the retired on-device models, so no stored
    /// level means the user never chose a provider, whatever keys they have.
    func test_apple_silicon_without_a_level_stays_not_set_even_with_keys() throws {
        let env = makeEnv()
        try env.keys.save("soniox-key", account: Account.soniox)
        try env.keys.save("openrouter-key", account: Account.openRouter)

        migrate(env, appleSilicon: true)

        assertAllNotSet(env.routing)
        XCTAssertTrue(env.routing.isMigrated, "the migration ran; there was just nothing to carry over")
    }

    func test_retired_local_level_stays_not_set() throws {
        let env = makeEnv()
        env.defaults.set("local", forKey: Old.level)
        env.defaults.set("local", forKey: Old.llmLevel)
        try env.keys.save("soniox-key", account: Account.soniox)
        try env.keys.save("openrouter-key", account: Account.openRouter)

        migrate(env, appleSilicon: false)

        assertAllNotSet(env.routing)
    }

    /// Intel always defaulted to the user's own key, so no stored level still
    /// means Soniox with its default model.
    func test_intel_without_a_level_keeps_its_key_default() throws {
        let env = makeEnv()
        try env.keys.save("soniox-key", account: Account.soniox)

        migrate(env, appleSilicon: false)

        for feature in realtimeFeatures {
            XCTAssertEqual(
                env.routing.route(for: feature), FeatureRoute(account: .soniox, model: "stt-rt-v6"), "\(feature)"
            )
        }
        XCTAssertEqual(env.routing.route(for: .meetings), FeatureRoute(account: .soniox, model: "stt-async-v6"))
        XCTAssertNil(env.routing.route(for: .dropSmartCleanup), "no OpenRouter key")
        XCTAssertNil(env.routing.route(for: .agent), "no agent model")
    }

    func test_provider_without_key_stays_not_set() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("deepgram", forKey: Old.provider)
        env.defaults.set("yourKey", forKey: Old.llmLevel)
        env.defaults.set("anthropic/claude-sonnet-5.5", forKey: Old.agentModel)
        // Soniox has a key; Deepgram and OpenRouter have none. Nothing may
        // move to the provider that does.
        try env.keys.save("soniox-key", account: Account.soniox)

        migrate(env)

        assertAllNotSet(env.routing)
    }

    func test_other_providers_keep_their_provider_and_real_time_model_for_meetings() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("deepgram", forKey: Old.provider)
        env.defaults.set("nova-3", forKey: Old.deepgramModel)
        try env.keys.save("deepgram-key", account: Account.deepgram)

        migrate(env)

        for feature in realtimeFeatures + [.meetings] {
            XCTAssertEqual(
                env.routing.route(for: feature), FeatureRoute(account: .deepgram, model: "nova-3"), "\(feature)"
            )
        }
    }

    /// An item the Keychain will not read still exists. Skipping its route
    /// would drop the user's choice for good, while the runtime fails closed
    /// on it anyway.
    func test_unreadable_key_still_gets_the_route() throws {
        let env = makeEnv(unreadable: [Account.soniox, Account.openRouter])
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("soniox", forKey: Old.provider)
        env.defaults.set("stt-rt-v4", forKey: Old.sonioxModel)
        env.defaults.set("yourKey", forKey: Old.llmLevel)
        env.defaults.set("google/gemini-3.8-flash", forKey: Old.openRouterModel)
        env.defaults.set("anthropic/claude-sonnet-5.5", forKey: Old.agentModel)

        migrate(env)

        for feature in realtimeFeatures {
            XCTAssertEqual(
                env.routing.route(for: feature), FeatureRoute(account: .soniox, model: "stt-rt-v4"), "\(feature)"
            )
        }
        XCTAssertEqual(env.routing.route(for: .meetings), FeatureRoute(account: .soniox, model: "stt-async-v6"))
        XCTAssertEqual(
            env.routing.route(for: .dropSmartCleanup), FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash")
        )
        XCTAssertEqual(
            env.routing.route(for: .agent), FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5")
        )
    }

    func test_agent_model_is_normalized_and_only_a_single_id_migrates() throws {
        let cases: [(stored: String, expected: String?)] = [
            ("anthropic/claude-sonnet-5.5", "anthropic/claude-sonnet-5.5"),
            ("openrouter/anthropic/claude-sonnet-5.5", "anthropic/claude-sonnet-5.5"),
            ("  anthropic/claude-sonnet-5.5\n", "anthropic/claude-sonnet-5.5"),
            ("claude sonnet", nil),
            ("   ", nil),
        ]
        for (stored, expected) in cases {
            let env = makeEnv()
            env.defaults.set(stored, forKey: Old.agentModel)
            try env.keys.save("openrouter-key", account: Account.openRouter)

            migrate(env)

            XCTAssertEqual(
                env.routing.route(for: .agent),
                expected.map { FeatureRoute(account: .openRouter, model: $0) },
                "stored \(stored.debugDescription)"
            )
        }
    }

    // MARK: - Servers

    func test_self_hosted_and_custom_llm_become_two_servers_with_legacy_key_accounts() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("selfHosted", forKey: Old.provider)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.selfHostedURL)
        env.defaults.set("whisper-large-v3", forKey: Old.selfHostedModel)
        env.defaults.set("custom", forKey: Old.llmLevel)
        env.defaults.set("https://llm.office.example/v1", forKey: Old.customURL)
        env.defaults.set("qwen3-32b", forKey: Old.customModel)
        // No keys at all: a server's key is optional, so its routes stay.

        migrate(env)

        let servers = env.routing.state.servers
        XCTAssertEqual(servers.count, 2)
        let speech = try XCTUnwrap(servers.first { $0.keyAccount == "byok.selfHosted.api_key" })
        let llm = try XCTUnwrap(servers.first { $0.keyAccount == "byok.custom_llm.api_key" })
        XCTAssertNotEqual(speech.id, llm.id)
        XCTAssertEqual(speech.name, "gpu.local:8000")
        XCTAssertEqual(speech.baseURL, "https://gpu.local:8000/v1")
        XCTAssertEqual(llm.name, "llm.office.example")
        XCTAssertEqual(llm.baseURL, "https://llm.office.example/v1")

        let speechRoute = FeatureRoute(account: .server(speech.id), model: "whisper-large-v3")
        for feature in realtimeFeatures + [.meetings] {
            XCTAssertEqual(env.routing.route(for: feature), speechRoute, "\(feature)")
        }
        let llmRoute = FeatureRoute(account: .server(llm.id), model: "qwen3-32b")
        XCTAssertEqual(env.routing.route(for: .dropSmartCleanup), llmRoute)
        XCTAssertEqual(env.routing.route(for: .meetingNotes), llmRoute)
        XCTAssertNil(env.routing.route(for: .agent))
    }

    func test_same_url_and_key_become_one_server() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("selfHosted", forKey: Old.provider)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.selfHostedURL)
        env.defaults.set("whisper-large-v3", forKey: Old.selfHostedModel)
        env.defaults.set("custom", forKey: Old.llmLevel)
        env.defaults.set(" https://gpu.local:8000/v1\n", forKey: Old.customURL)
        env.defaults.set("qwen3-32b", forKey: Old.customModel)
        try env.keys.save("shared-key", account: Account.selfHosted)
        try env.keys.save("shared-key", account: Account.customLLM)

        migrate(env)

        let server = try XCTUnwrap(env.routing.state.servers.first)
        XCTAssertEqual(env.routing.state.servers.count, 1)
        XCTAssertEqual(server.keyAccount, "byok.selfHosted.api_key")
        XCTAssertEqual(server.name, "gpu.local:8000", "one server, so no suffix")
        XCTAssertEqual(server.baseURL, "https://gpu.local:8000/v1")
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .server(server.id), model: "whisper-large-v3"))
        XCTAssertEqual(env.routing.route(for: .dropSmartCleanup), FeatureRoute(account: .server(server.id), model: "qwen3-32b"))
        XCTAssertEqual(env.routing.route(for: .meetingNotes), FeatureRoute(account: .server(server.id), model: "qwen3-32b"))
    }

    func test_same_url_without_keys_becomes_one_server() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("selfHosted", forKey: Old.provider)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.selfHostedURL)
        env.defaults.set("custom", forKey: Old.llmLevel)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.customURL)

        migrate(env)

        XCTAssertEqual(env.routing.state.servers.count, 1)
        let server = try XCTUnwrap(env.routing.state.servers.first)
        XCTAssertEqual(server.keyAccount, "byok.selfHosted.api_key")
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .server(server.id))
        XCTAssertEqual(env.routing.route(for: .dropSmartCleanup)?.account, .server(server.id))
    }

    func test_same_url_with_different_keys_stays_two_servers_named_apart() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("selfHosted", forKey: Old.provider)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.selfHostedURL)
        env.defaults.set("custom", forKey: Old.llmLevel)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.customURL)
        try env.keys.save("speech-key", account: Account.selfHosted)
        try env.keys.save("llm-key", account: Account.customLLM)

        migrate(env)

        XCTAssertEqual(env.routing.state.servers.count, 2)
        let speech = try XCTUnwrap(env.routing.state.servers.first { $0.keyAccount == "byok.selfHosted.api_key" })
        let llm = try XCTUnwrap(env.routing.state.servers.first { $0.keyAccount == "byok.custom_llm.api_key" })
        XCTAssertEqual(speech.name, "gpu.local:8000 (speech)")
        XCTAssertEqual(llm.name, "gpu.local:8000 (LLM)")
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .server(speech.id))
        XCTAssertEqual(env.routing.route(for: .dropSmartCleanup)?.account, .server(llm.id))
    }

    /// A key nobody could read is unknown, not "the same as" the other one.
    func test_same_url_with_unreadable_keys_stays_two_servers() throws {
        let env = makeEnv(unreadable: [Account.selfHosted, Account.customLLM])
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("selfHosted", forKey: Old.provider)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.selfHostedURL)
        env.defaults.set("custom", forKey: Old.llmLevel)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.customURL)

        migrate(env)

        XCTAssertEqual(Set(env.routing.state.servers.map(\.keyAccount)), ["byok.selfHosted.api_key", "byok.custom_llm.api_key"])
        XCTAssertEqual(env.routing.state.servers.count, 2)
    }

    func test_blank_base_url_creates_no_server_and_no_route() {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("selfHosted", forKey: Old.provider)
        env.defaults.set("   ", forKey: Old.selfHostedURL)
        env.defaults.set("whisper-large-v3", forKey: Old.selfHostedModel)
        env.defaults.set("custom", forKey: Old.llmLevel)
        env.defaults.set("qwen3-32b", forKey: Old.customModel)

        migrate(env)

        XCTAssertTrue(env.routing.state.servers.isEmpty)
        assertAllNotSet(env.routing)
        XCTAssertTrue(env.routing.isMigrated)
    }

    // MARK: - Once, and read-only

    func test_second_run_changes_nothing() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("soniox", forKey: Old.provider)
        env.defaults.set("stt-rt-v4", forKey: Old.sonioxModel)
        env.defaults.set("yourKey", forKey: Old.llmLevel)
        env.defaults.set("google/gemini-3.8-flash", forKey: Old.openRouterModel)
        env.defaults.set("anthropic/claude-sonnet-5.5", forKey: Old.agentModel)
        try env.keys.save("soniox-key", account: Account.soniox)
        try env.keys.save("openrouter-key", account: Account.openRouter)
        migrate(env, appleSilicon: true)
        let afterFirstRun = env.routing.state
        XCTAssertEqual(afterFirstRun.routes.count, 8)
        XCTAssertNil(env.routing.route(for: .translation))
        XCTAssertNil(env.routing.route(for: .subtitlesAudio))

        // The old settings change later (a rollback and back, say), and a key
        // turns up. The next launch must not look at any of it.
        env.defaults.set("deepgram", forKey: Old.provider)
        env.defaults.set("custom", forKey: Old.llmLevel)
        env.defaults.set("https://gpu.local:8000/v1", forKey: Old.customURL)
        env.defaults.set("openai/gpt-5", forKey: Old.agentModel)
        try env.keys.save("deepgram-key", account: Account.deepgram)

        migrate(env, appleSilicon: true)
        XCTAssertEqual(env.routing.state, afterFirstRun)

        // A relaunch loads the stored state and must come to the same answer.
        let relaunched = Env(defaults: env.defaults, routing: AIRoutingStore(defaults: env.defaults), keys: env.keys)
        migrate(relaunched, appleSilicon: true)
        XCTAssertEqual(relaunched.routing.state, afterFirstRun)
    }

    /// Writing an old key, even with the same value, or removing one would
    /// make a rollback to the previous build see settings it never had.
    /// A stored state with an account this build does not know (written by a
    /// newer build before a rollback) keeps its other routes, and the
    /// migration does not run again over it (final review I3).
    func test_unknown_account_in_stored_state_keeps_the_other_routes_and_does_not_migrate_again() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let stored = Data(#"""
        {"routes":{"dropFast":{"account":"openai","model":"gpt-x"},"meetingNotes":{"account":"openRouter","model":"vendor/notes"}},
         "migratedRoutes":{},"servers":[],"migrationVersion":1}
        """#.utf8)
        defaults.set(stored, forKey: AIRoutingStore.defaultsKey)
        // Old settings that a second migration would apply.
        defaults.set("yourKey", forKey: Old.level)
        defaults.set("soniox", forKey: Old.provider)
        defaults.set("yourKey", forKey: Old.llmLevel)
        defaults.set("google/gemini-3.8-flash", forKey: Old.openRouterModel)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("soniox-key", account: Account.soniox)
        try keys.save("openrouter-key", account: Account.openRouter)
        let env = Env(defaults: defaults, routing: AIRoutingStore(defaults: defaults), keys: keys)

        migrate(env)

        XCTAssertNil(env.routing.route(for: .dropFast))
        XCTAssertEqual(env.routing.route(for: .meetingNotes), FeatureRoute(account: .openRouter, model: "vendor/notes"))
        for feature in AIFeature.allCases where feature != .meetingNotes {
            XCTAssertNil(env.routing.route(for: feature), "\(feature) must not be migrated again")
        }
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), stored, "the stored state is not overwritten")
    }

    /// A stored state that cannot be read at all is not "not migrated" either.
    func test_unreadable_stored_state_does_not_migrate_again() throws {
        let env = makeEnv()
        let garbage = Data("{ not json".utf8)
        env.defaults.set(garbage, forKey: AIRoutingStore.defaultsKey)
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("soniox", forKey: Old.provider)
        try env.keys.save("soniox-key", account: Account.soniox)
        let routing = AIRoutingStore(defaults: env.defaults)

        migrate(Env(defaults: env.defaults, routing: routing, keys: env.keys))

        assertAllNotSet(routing)
        XCTAssertEqual(env.defaults.data(forKey: AIRoutingStore.defaultsKey), garbage)
    }

    func test_old_user_defaults_are_left_untouched() throws {
        let env = makeEnv()
        env.defaults.set("yourKey", forKey: Old.level)
        env.defaults.set("selfHosted", forKey: Old.provider)
        env.defaults.set("stt-rt-v4", forKey: Old.sonioxModel)
        // Values the migration trims or normalizes on its way into a route.
        env.defaults.set(" https://gpu.local:8000/v1 ", forKey: Old.selfHostedURL)
        env.defaults.set("whisper-large-v3", forKey: Old.selfHostedModel)
        env.defaults.set("custom", forKey: Old.llmLevel)
        env.defaults.set("google/gemini-3.8-flash", forKey: Old.openRouterModel)
        env.defaults.set("https://llm.office.example/v1\n", forKey: Old.customURL)
        env.defaults.set("qwen3-32b", forKey: Old.customModel)
        env.defaults.set("openrouter/anthropic/claude-sonnet-5.5", forKey: Old.agentModel)
        try env.keys.save("openrouter-key", account: Account.openRouter)
        let before = oldSettings(in: env.defaults)
        XCTAssertEqual(before.count, 10)

        migrate(env)

        XCTAssertEqual(oldSettings(in: env.defaults) as NSDictionary, before as NSDictionary)
        // The migration did its work, so "untouched" is not an empty claim.
        XCTAssertNotNil(env.routing.route(for: .dropFast))
        XCTAssertEqual(env.routing.route(for: .agent)?.model, "anthropic/claude-sonnet-5.5")
    }
}

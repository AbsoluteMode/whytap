import XCTest
@testable import Sidekey

/// A user's server lists IDs only. Speech pickers offer its speech models,
/// text pickers its language models, and the server's own choice overrides
/// the guess. Routes already on a server model never become unavailable.
@MainActor
final class ServerModelKindsTests: XCTestCase {
    private static let speechFeatures: [AIFeature] = [.dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch]
    private static let textFeatures: [AIFeature] = [.dropSmartCleanup, .meetingNotes, .translation]

    private struct Env {
        let defaults: UserDefaults
        let routing: AIRoutingStore
        let server: ServerEndpoint
        let resolver: ModelStatusResolver
        var account: ProviderAccount { .server(server.id) }

        @MainActor func offered(for feature: AIFeature) -> [String] {
            resolver.sections(for: feature).first { $0.account == account }?.options.map(\.model) ?? []
        }

        @MainActor func section(for feature: AIFeature) -> PickerSection? {
            resolver.sections(for: feature).first { $0.account == account }
        }
    }

    /// One Ollama-like server whose `/v1/models` answered `body`.
    private func makeEnv(serverBody body: String, routes: [AIFeature: String] = [:]) throws -> Env {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let routing = AIRoutingStore(defaults: defaults)
        let server = routing.addServer(name: "Ollama", baseURL: "http://localhost:11434/v1")
        for (feature, model) in routes {
            routing.setRoute(FeatureRoute(account: .server(server.id), model: model), for: feature)
        }
        let models = try ModelCatalogFetcher.parseServer(Data(body.utf8))
        let snapshot = CatalogSnapshot(models: models, fetchedAt: Date())
        try JSONEncoder().encode([ProviderAccount.server(server.id).storageID: snapshot]).write(to: file)
        let box = InMemoryTokenStore.Box()
        let resolver = ModelStatusResolver(
            routing: routing,
            keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) }),
            catalogs: ModelCatalogStore(fileURL: file),
            checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults),
            onDevice: OnDeviceSpeechReadiness(isReady: { false }),
            adapterVersion: { _, _ in 1 }
        )
        return Env(defaults: defaults, routing: routing, server: server, resolver: resolver)
    }

    private static let mixed = #"{"object":"list","data":[{"id":"whisper-large-v3"},{"id":"qwen3:0.6b","created":1762000000}]}"#

    // MARK: - By model name

    func test_whisper_goes_to_speech_and_qwen_to_text() throws {
        let env = try makeEnv(serverBody: Self.mixed)
        for feature in Self.speechFeatures {
            XCTAssertEqual(env.offered(for: feature), ["whisper-large-v3"], "\(feature)")
        }
        for feature in Self.textFeatures {
            XCTAssertEqual(env.offered(for: feature), ["qwen3:0.6b"], "\(feature)")
        }
        // A server still cannot run the agent.
        XCTAssertNil(env.section(for: .agent))
        // Picking across kinds is refused with a reason, before any probe.
        XCTAssertEqual(env.resolver.verdict(model: "whisper-large-v3", account: env.account, for: .dropSmartCleanup),
                       .notSupported(reason: "not a text model"))
        XCTAssertEqual(env.resolver.verdict(model: "qwen3:0.6b", account: env.account, for: .dropFast),
                       .notSupported(reason: "not a speech model"))
        XCTAssertEqual(env.resolver.verdict(model: "qwen3:0.6b", account: env.account, for: .meetings),
                       .notSupported(reason: "not a speech model"))
    }

    func test_names_are_sorted_by_what_the_model_does() {
        let speech = ["whisper-1", "Systran/faster-whisper-large-v3", "distil-whisper/distil-large-v3",
                      "gpt-4o-transcribe", "nvidia/parakeet-tdt-0.6b-v3", "nvidia/canary-1b-flash",
                      "my-stt", "ru_asr:latest", "FunAudioLLM/SenseVoiceSmall", "mistralai/Voxtral-Mini-3B-2507",
                      "salute-developers/GigaAM-v3", "facebook/wav2vec2-base-960h", "nemo-fastconformer-ctc"]
        let language = ["qwen3:0.6b", "llama3.2:1b", "gpt-oss:20b", "mistral-nemo:12b", "deepseek-r1:7b",
                        "gemma3:4b", "Qwen/Qwen3-30B-A3B", "company-gateway-default", "phi4", "speechless-llama"]
        let other = ["nomic-embed-text", "mxbai-embed-large:latest", "dengcao/Qwen3-Embedding-0.6B",
                     "text-embedding-3-small", "BAAI/bge-m3", "bge-reranker-v2-m3", "jina-reranker-v2",
                     "tts-1", "kokoro", "hexgrad/Kokoro-82M", "piper-ru", "coqui/XTTS-v2", "all-MiniLM-L6-v2",
                     "intfloat/multilingual-e5-large", "stable-diffusion-xl", "omni-moderation-latest"]
        for id in speech { XCTAssertEqual(ServerModelClassifier.kind(of: id), .speech, id) }
        for id in language { XCTAssertEqual(ServerModelClassifier.kind(of: id), .language, id) }
        for id in other { XCTAssertEqual(ServerModelClassifier.kind(of: id), .other, id) }
    }

    func test_unknown_name_is_a_language_model_and_embeddings_go_nowhere() throws {
        let env = try makeEnv(serverBody: #"{"data":[{"id":"corp-assistant-v2"},{"id":"nomic-embed-text"},{"id":"tts-1"}]}"#)
        for feature in Self.textFeatures { XCTAssertEqual(env.offered(for: feature), ["corp-assistant-v2"], "\(feature)") }
        for feature in Self.speechFeatures {
            XCTAssertEqual(env.offered(for: feature), [], "\(feature)")
            // Nothing of this kind is listed: the section takes a typed name instead.
            XCTAssertEqual(env.section(for: feature)?.acceptsModelName, true, "\(feature)")
        }
        XCTAssertEqual(env.section(for: .translation)?.acceptsModelName, false)
        XCTAssertEqual(env.resolver.verdict(model: "nomic-embed-text", account: env.account, for: .dropSmartCleanup),
                       .notSupported(reason: "not a text model"))
        XCTAssertEqual(env.resolver.verdict(model: "tts-1", account: env.account, for: .voiceSearch),
                       .notSupported(reason: "not a speech model"))
    }

    // MARK: - The server's own choice

    func test_manual_choice_overrides_the_name() throws {
        let body = #"{"data":[{"id":"whisper-large-v3"},{"id":"qwen3:0.6b"},{"id":"nomic-embed-text"}]}"#
        let env = try makeEnv(serverBody: body)
        let all = ["nomic-embed-text", "qwen3:0.6b", "whisper-large-v3"]

        env.routing.setModelKinds(.both, forServer: env.server.id)
        for feature in Self.speechFeatures + Self.textFeatures {
            XCTAssertEqual(env.offered(for: feature), all, "Both offers everything to \(feature)")
        }

        env.routing.setModelKinds(.speech, forServer: env.server.id)
        for feature in Self.speechFeatures { XCTAssertEqual(env.offered(for: feature), all, "\(feature)") }
        for feature in Self.textFeatures { XCTAssertEqual(env.offered(for: feature), [], "\(feature)") }

        env.routing.setModelKinds(.language, forServer: env.server.id)
        for feature in Self.textFeatures { XCTAssertEqual(env.offered(for: feature), all, "\(feature)") }
        for feature in Self.speechFeatures { XCTAssertEqual(env.offered(for: feature), [], "\(feature)") }

        env.routing.setModelKinds(.automatic, forServer: env.server.id)
        XCTAssertEqual(env.offered(for: .dropFast), ["whisper-large-v3"])
        XCTAssertEqual(env.offered(for: .translation), ["qwen3:0.6b"])
    }

    // MARK: - Empty and broken lists

    func test_empty_model_list_lets_the_user_type_a_name_for_either_kind() throws {
        let env = try makeEnv(serverBody: #"{"object":"list","data":[]}"#)
        for feature in Self.speechFeatures + Self.textFeatures {
            let section = try XCTUnwrap(env.section(for: feature), "\(feature)")
            XCTAssertEqual(section.options, [], "\(feature)")
            XCTAssertTrue(section.acceptsModelName, "\(feature)")
        }
        // A typed name the catalog does not know is judged by its probe, not by its name.
        XCTAssertEqual(env.resolver.verdict(model: "qwen3:0.6b", account: env.account, for: .dropFast), .new)
        XCTAssertEqual(env.resolver.verdict(model: "whisper-large-v3", account: env.account, for: .translation), .new)
    }

    func test_broken_model_list_is_malformed_not_a_crash() {
        for body in ["", "not json", #"{"data":"x"}"#, #"{"models":[]}"#, #"{"data":[{"name":"no id"}]}"#] {
            XCTAssertThrowsError(try ModelCatalogFetcher.parseServer(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? CatalogFetchError, .malformed, body)
            }
        }
    }

    // MARK: - Routes saved before

    func test_route_on_a_model_now_sorted_elsewhere_keeps_working() throws {
        // Drop Fast was set to the server's qwen before models were sorted,
        // and translation to its whisper.
        let env = try makeEnv(serverBody: Self.mixed, routes: [.dropFast: "qwen3:0.6b", .translation: "whisper-large-v3"])
        for (feature, model) in [(AIFeature.dropFast, "qwen3:0.6b"), (.translation, "whisper-large-v3")] {
            XCTAssertEqual(env.routing.route(for: feature)?.model, model, "the route is untouched")
            XCTAssertEqual(env.resolver.status(for: feature), .notVerified, "\(feature) is not marked unavailable")
            let option = try XCTUnwrap(env.section(for: feature)?.options.first { $0.model == model }, "\(feature)")
            XCTAssertTrue(option.isSelected)
            XCTAssertEqual(option.state, .new, "\(feature): re-picking it is allowed")
            XCTAssertEqual(env.resolver.verdict(model: model, account: env.account, for: feature), .new)
        }
        // Other features are offered by kind; the route does not leak into them.
        XCTAssertEqual(env.offered(for: .voiceSearch), ["whisper-large-v3"])
        XCTAssertEqual(env.offered(for: .meetingNotes), ["qwen3:0.6b"])
        // Drop Fast's picker still offers the speech model next to the kept route.
        XCTAssertEqual(Set(env.offered(for: .dropFast)), ["qwen3:0.6b", "whisper-large-v3"])

        // An explicit choice that excludes the routed model still keeps the route.
        env.routing.setModelKinds(.language, forServer: env.server.id)
        XCTAssertEqual(env.resolver.status(for: .translation), .notVerified)
        XCTAssertEqual(env.offered(for: .translation).contains("whisper-large-v3"), true)
        XCTAssertEqual(env.routing.route(for: .translation)?.model, "whisper-large-v3")
    }

    // MARK: - Storage

    func test_choice_is_saved_in_the_routing_document_and_read_back() throws {
        let env = try makeEnv(serverBody: Self.mixed)
        let untouched = try XCTUnwrap(env.defaults.data(forKey: AIRoutingStore.defaultsKey))
        XCTAssertFalse(String(decoding: untouched, as: UTF8.self).contains("modelKinds"),
                       "an untouched server stores what it did before")

        env.routing.setModelKinds(.speech, forServer: env.server.id)
        let reloaded = AIRoutingStore(defaults: env.defaults)
        XCTAssertEqual(reloaded.server(env.server.id)?.modelKinds, .speech)
        // Backup and sync read the same document: the server and its key account survive.
        let accounts = try ConfigBackupRegistry.credentialAccounts(in: env.defaults)
        XCTAssertTrue(accounts.contains(env.server.keyAccount))

        env.routing.setModelKinds(.automatic, forServer: env.server.id)
        let reset = try XCTUnwrap(env.defaults.data(forKey: AIRoutingStore.defaultsKey))
        XCTAssertFalse(String(decoding: reset, as: UTF8.self).contains("modelKinds"))

        // An unknown server ID changes nothing.
        env.routing.setModelKinds(.both, forServer: UUID())
        XCTAssertEqual(AIRoutingStore(defaults: env.defaults).state, env.routing.state)
    }

    func test_older_and_newer_documents_keep_their_servers() throws {
        let id = UUID()
        let key = "byok.server.\(id.uuidString.lowercased()).api_key"
        func server(_ extra: String) throws -> ServerEndpoint {
            let json = #"{"id":"\#(id.uuidString)","name":"Box","baseURL":"http://h:8000/v1","keyAccount":"\#(key)"\#(extra)}"#
            return try JSONDecoder().decode(ServerEndpoint.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try server("").modelKinds, .automatic, "written before the choice existed")
        XCTAssertEqual(try server(#","modelKinds":"speech""#).modelKinds, .speech)
        XCTAssertEqual(try server(#","modelKinds":"vision""#).modelKinds, .automatic, "a newer build's value")
        XCTAssertEqual(try server(#","modelKinds":7"#).modelKinds, .automatic)
        XCTAssertEqual(try server(#","modelKinds":"vision""#).name, "Box")

        // An older build's decoder (the same fields, no choice) still reads a stored choice.
        struct OlderServer: Decodable { let id: UUID; let name: String; let baseURL: String; let keyAccount: String }
        let stored = try JSONEncoder().encode(ServerEndpoint(id: id, name: "Box", baseURL: "http://h", keyAccount: key,
                                                              modelKinds: .language))
        XCTAssertEqual(try JSONDecoder().decode(OlderServer.self, from: stored).id, id)
    }
}

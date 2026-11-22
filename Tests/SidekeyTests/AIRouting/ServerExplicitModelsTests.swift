import XCTest
@testable import Sidekey

/// A user's server serves only the models the user added, each as LLM or
/// Transcription, and only in pickers of that kind. `/v1/models` only
/// suggests names; the name only preselects the type; a check runs before a
/// model is saved. Servers from before keep their routes.
// WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
@MainActor
final class ServerExplicitModelsTests: XCTestCase {
    private static let speechFeatures: [AIFeature] = [.dropFast, .dropSmart, .meetings, .agentVoice, .voiceSearch]
    private static let textFeatures: [AIFeature] = [.dropSmartCleanup, .meetingNotes, .translation]

    // MARK: - Fakes

    private final class FakeChecker: ServerModelChecking, @unchecked Sendable {
        var result: ServerModelCheckResult = .passed
        /// Runs while the request is "in flight": changes made here happen during the check.
        var answer: ((ServerEndpoint, String?) async -> ServerModelCheckResult)?
        var calls: [(model: String, kind: ServerModel.Kind, apiKey: String?)] = []
        func check(_ model: String, kind: ServerModel.Kind, on server: ServerEndpoint, apiKey: String?) async -> ServerModelCheckResult {
            calls.append((model, kind, apiKey))
            if let answer { return await answer(server, apiKey) }
            return result
        }
    }

    private struct AcceptingKeys: ProviderKeyChecking {
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
    }

    private final class Probe: ModelProbing, @unchecked Sendable {
        var models: [String] = []
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
            models.append(route.model)
            return .passed
        }
    }

    /// Answers `/v1/models` with `models`, or 404 when `nil` (no list).
    private struct Catalog: ModelCatalogFetching {
        let models: [String]?
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            guard let models else { throw CatalogFetchError.http(404, code: nil) }
            return models.map { CatalogModel(id: $0) }
        }
    }

    private struct Env {
        let defaults: UserDefaults
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let checker: FakeChecker
        let probe: Probe
        let vm: APIAndModelsViewModel
        let resolver: ModelStatusResolver

        @MainActor func offered(_ account: ProviderAccount, for feature: AIFeature) -> [String] {
            vm.sections(for: feature).first { $0.account == account }?.options.map(\.model) ?? []
        }
    }

    private func makeEnv(catalog: [String]? = [], storedRouting: String? = nil) throws -> Env {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        if let storedRouting { defaults.set(Data(storedRouting.utf8), forKey: AIRoutingStore.defaultsKey) }
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let checker = FakeChecker()
        let probe = Probe()
        let catalogs = ModelCatalogStore(fileURL: file, fetcher: Catalog(models: catalog))
        let checks = ModelCheckStore(defaults: defaults)
        let keyStatuses = KeyStatusStore(defaults: defaults)
        let vm = APIAndModelsViewModel(
            routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses,
            keyChecker: AcceptingKeys(), probe: probe, serverModelChecker: checker,
            inputLanguage: { nil }, onDevice: OnDeviceSpeechReadiness(isReady: { false })
        )
        let resolver = ModelStatusResolver(routing: routing, keys: keys, catalogs: catalogs, checks: checks,
                                           keyStatuses: keyStatuses, onDevice: OnDeviceSpeechReadiness(isReady: { false }),
                                           adapterVersion: { _, _ in 1 })
        return Env(defaults: defaults, routing: routing, keys: keys, checker: checker, probe: probe, vm: vm, resolver: resolver)
    }

    /// Connects a server the way the form does and returns its account.
    private func connect(_ env: Env, name: String = "Lab", key: String? = nil) async throws -> ProviderAccount {
        let failure = await env.vm.addServer(name: name, baseURL: "http://localhost:11434/v1", key: key, proposeModels: false)
        XCTAssertNil(failure)
        return try XCTUnwrap(env.vm.lastAddedServer)
    }

    /// Adds a model the way the form does: check, then add from that check.
    @discardableResult
    private func add(_ env: Env, _ name: String, _ kind: ServerModel.Kind, to account: ProviderAccount) async -> ServerModelCheckResult {
        let check = await env.vm.runServerModelCheck(name, kind: kind, on: account)
        if check.result == .passed { XCTAssertNil(env.vm.addServerModel(after: check, to: account)) }
        return check.result
    }

    private func keyAccount(_ env: Env, _ account: ProviderAccount) throws -> String {
        try XCTUnwrap(account.keychainAccount(in: env.routing))
    }

    /// Replaces the stored routing document the way settings sync or a restore does.
    private static func syncBaseURL(_ env: Env, _ account: ProviderAccount, to url: String) throws {
        var state = env.routing.state
        let index = try XCTUnwrap(state.servers.firstIndex { ProviderAccount.server($0.id) == account })
        state.servers[index].baseURL = url
        env.defaults.set(try JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        env.routing.reloadFromDefaults()
    }

    // MARK: - A check counts only for the server as it was checked

    func test_a_pass_under_the_previous_key_adds_nothing() async throws {
        let env = try makeEnv()
        let account = try await connect(env, key: "old-synthetic-credential")
        let keychain = try keyAccount(env, account)
        env.checker.answer = { _, key in
            guard key == "old-synthetic-credential" else { return .failed("Replacement key refused") }
            try? await MainActor.run { try env.keys.save("new-synthetic-credential", account: keychain) }
            return .passed
        }
        let check = await env.vm.runServerModelCheck("example-model", kind: .llm, on: account)
        XCTAssertTrue(check.stale)
        XCTAssertEqual(check.result, .failed(APIAndModelsViewModel.serverChangedDuringCheck))
        XCTAssertEqual(env.vm.addServerModel(after: check, to: account), APIAndModelsViewModel.serverChangedDuringCheck)
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels, [])
        XCTAssertTrue(env.offered(account, for: .dropSmartCleanup).isEmpty)
        // Checking again under the new key is what adds it.
        env.checker.answer = nil
        let retried = await add(env, "example-model", .llm, to: account)
        XCTAssertEqual(retried, .passed)
        XCTAssertEqual(env.checker.calls.last?.apiKey, "new-synthetic-credential")
        XCTAssertEqual(env.offered(account, for: .dropSmartCleanup), ["example-model"])
    }

    func test_a_pass_on_the_previous_base_url_adds_nothing() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        env.checker.answer = { server, _ in
            guard server.baseURL == "http://localhost:11434/v1" else { return .unreachable("Replacement endpoint is down") }
            try? await MainActor.run { try Self.syncBaseURL(env, account, to: "http://localhost:9999/v1") }
            return .passed
        }
        let result = await add(env, "example-model", .transcription, to: account)
        XCTAssertNotEqual(result, .passed)
        XCTAssertTrue(env.offered(account, for: .dropFast).isEmpty)
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels, [])
    }

    func test_save_without_check_is_refused_once_the_key_changed_after_the_refusal() async throws {
        let env = try makeEnv()
        let account = try await connect(env, key: "old-synthetic-credential")
        env.checker.result = .failed("Server answered 404 on /audio/transcriptions — this model can't transcribe here")
        let refused = await env.vm.runServerModelCheck("parakeet", kind: .transcription, on: account)
        XCTAssertFalse(refused.stale)
        try env.keys.save("new-synthetic-credential", account: try keyAccount(env, account))
        XCTAssertEqual(env.vm.addServerModel(after: refused, to: account), APIAndModelsViewModel.serverChangedSinceCheck)
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels, [])
        // A refusal under the current key still allows an explicit unchecked save.
        let again = await env.vm.runServerModelCheck("parakeet", kind: .transcription, on: account)
        XCTAssertNil(env.vm.addServerModel(after: again, to: account))
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels,
                       [ServerModel(name: "parakeet", kind: .transcription, checked: false)])
    }

    func test_save_without_check_is_refused_once_the_address_changed_after_the_refusal() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        env.checker.result = .unreachable("Couldn't reach the server")
        let refused = await env.vm.runServerModelCheck("ut-llm", kind: .llm, on: account)
        try Self.syncBaseURL(env, account, to: "https://gateway.example/v1")
        XCTAssertEqual(env.vm.addServerModel(after: refused, to: account), APIAndModelsViewModel.serverChangedSinceCheck)
        XCTAssertTrue(env.offered(account, for: .meetingNotes).isEmpty)
    }

    func test_a_server_removed_during_the_check_gets_nothing() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        env.checker.answer = { _, _ in
            await MainActor.run { env.vm.remove(account) }
            return .passed
        }
        let check = await env.vm.runServerModelCheck("ut-llm", kind: .llm, on: account)
        XCTAssertTrue(check.stale)
        XCTAssertNotNil(env.vm.addServerModel(after: check, to: account))
        XCTAssertFalse(env.routing.state.servers.contains { ProviderAccount.server($0.id) == account })
        let after = await env.vm.runServerModelCheck("ut-llm", kind: .llm, on: account)
        XCTAssertEqual(after.result, .failed("This server was removed"))
    }

    func test_a_check_for_another_server_is_not_added_here() async throws {
        let env = try makeEnv()
        let lab = try await connect(env, name: "Lab")
        let other = try await connect(env, name: "Other")
        let check = await env.vm.runServerModelCheck("ut-llm", kind: .llm, on: lab)
        XCTAssertEqual(env.vm.addServerModel(after: check, to: other), APIAndModelsViewModel.serverChangedSinceCheck)
        XCTAssertEqual(env.vm.chips.first { $0.account == other }?.serverModels, [])
    }

    func test_the_key_digest_never_holds_the_key() {
        let target = ServerModelTarget(account: .server(UUID()), baseURL: "http://h/v1", apiKey: "sk-synthetic-value")
        XCTAssertNotNil(target.keyDigest)
        XCTAssertFalse(target.keyDigest?.contains("synthetic") ?? true)
        XCTAssertNil(ServerModelTarget(account: .server(UUID()), baseURL: "http://h/v1", apiKey: "").keyDigest)
    }

    // MARK: - A server is called by its address

    func test_a_server_is_named_after_its_address() {
        XCTAssertEqual(ServerEndpoint.displayName(for: "http://localhost:11434/v1"), "Ollama · localhost:11434")
        XCTAssertEqual(ServerEndpoint.displayName(for: "http://127.0.0.1:1234/v1"), "LM Studio · 127.0.0.1:1234")
        XCTAssertEqual(ServerEndpoint.displayName(for: "https://vllm.company.ru/v1"), "vllm.company.ru")
        XCTAssertEqual(ServerEndpoint.displayName(for: "https://GPU.Example.com:8443/openai/v1"), "gpu.example.com:8443")
        XCTAssertEqual(ServerEndpoint.displayName(for: "wss://asr.lab:443/v1"), "asr.lab")
        XCTAssertEqual(ServerEndpoint.displayName(for: "http://box:80"), "box")
        XCTAssertEqual(ServerEndpoint.displayName(for: "vllm.company.ru:8000/v1"), "vllm.company.ru:8000")
        XCTAssertNil(ServerEndpoint.displayName(for: ""))
        XCTAssertNil(ServerEndpoint.displayName(for: "http:///v1"))
        let legacy = ServerEndpoint(id: UUID(), name: "qwen3:0.6b", baseURL: "http://localhost:11434/v1", keyAccount: "k")
        XCTAssertEqual(legacy.displayName, "Ollama · localhost:11434", "a name from before is replaced by the address")
    }

    // MARK: - The form runs one operation at a time

    func test_a_model_check_blocks_key_save_and_remove_until_it_finishes() {
        var activity = ServerFormActivity()
        XCTAssertTrue(activity.beginModelCheck())
        XCTAssertTrue(activity.busy)
        XCTAssertFalse(activity.beginKeySave(), "Save is refused while a model is checked")
        XCTAssertFalse(activity.canRemove, "Remove is refused while a model is checked")
        XCTAssertFalse(activity.beginModelCheck(), "a second Add waits")
        activity.finishKeySave()  // a late key-save completion releases nothing it does not own
        XCTAssertTrue(activity.busy)
        activity.finishModelCheck()
        XCTAssertFalse(activity.busy)
        XCTAssertTrue(activity.canRemove)
    }

    func test_a_key_save_blocks_a_model_check_and_overlapping_completions_keep_the_form_busy() {
        var activity = ServerFormActivity()
        XCTAssertTrue(activity.beginKeySave())
        XCTAssertFalse(activity.beginModelCheck(), "Add is refused while the key is saved")
        XCTAssertFalse(activity.canRemove)
        activity.finishModelCheck()  // a stray model-check completion does not end the save
        XCTAssertTrue(activity.busy)
        activity.finishKeySave()
        XCTAssertFalse(activity.busy)
        XCTAssertTrue(activity.beginModelCheck())
    }

    // MARK: - Adding models

    func test_a_new_server_offers_nothing_until_a_model_is_added() async throws {
        let env = try makeEnv(catalog: ["qwen3:0.6b", "whisper-large-v3"])
        let account = try await connect(env)
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels, [])
        for feature in Self.speechFeatures + Self.textFeatures {
            XCTAssertEqual(env.offered(account, for: feature), [], "\(feature)")
            XCTAssertNil(env.vm.sections(for: feature).first { $0.account == account }, "\(feature): no section")
        }
        // The server's list only suggests names.
        XCTAssertEqual(env.vm.modelSuggestions(for: account), ["qwen3:0.6b", "whisper-large-v3"])
    }

    func test_ut_llm_added_as_llm_is_only_a_text_model() async throws {
        let env = try makeEnv(catalog: [])
        let account = try await connect(env, key: "lab-key")
        XCTAssertEqual(ServerModelClassifier.suggestedKind(for: "ut-llm"), .llm)
        let result = await add(env, "ut-llm", .llm, to: account)
        XCTAssertEqual(result, .passed)
        XCTAssertEqual(env.checker.calls.map(\.model), ["ut-llm"])
        XCTAssertEqual(env.checker.calls.first?.kind, .llm)
        XCTAssertEqual(env.checker.calls.first?.apiKey, "lab-key", "the check uses the server's own key")
        for feature in Self.textFeatures { XCTAssertEqual(env.offered(account, for: feature), ["ut-llm"], "\(feature)") }
        for feature in Self.speechFeatures { XCTAssertEqual(env.offered(account, for: feature), [], "\(feature)") }
        XCTAssertNil(env.vm.sections(for: .agent).first { $0.account == account }, "a server still can't run the Agent")
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels,
                       [ServerModel(name: "ut-llm", kind: .llm, checked: true)])
    }

    func test_qwen3_asr_added_as_transcription_is_only_a_speech_model() async throws {
        let env = try makeEnv(catalog: ["qwen3-asr"])
        let account = try await connect(env)
        XCTAssertEqual(ServerModelClassifier.suggestedKind(for: "qwen3-asr"), .transcription, "the name preselects")
        XCTAssertEqual(ServerModelClassifier.suggestedKind(for: "qwen3:0.6b"), .llm)
        let result = await add(env, "qwen3-asr", .transcription, to: account)
        XCTAssertEqual(result, .passed)
        for feature in Self.speechFeatures { XCTAssertEqual(env.offered(account, for: feature), ["qwen3-asr"], "\(feature)") }
        for feature in Self.textFeatures { XCTAssertEqual(env.offered(account, for: feature), [], "\(feature)") }
        XCTAssertEqual(env.resolver.verdict(model: "qwen3-asr", account: account, for: .translation),
                       .notSupported(reason: "Not added to Lab as an LLM"))
        // Picking it runs the ordinary live probe and sets the route.
        await env.vm.select(model: "qwen3-asr", account: account, for: .dropFast)
        XCTAssertEqual(env.probe.models, ["qwen3-asr"])
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: account, model: "qwen3-asr"))
    }

    func test_one_name_can_be_both_kinds_but_each_kind_once() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        _ = await add(env, "qwen2.5-omni", .llm, to: account)
        XCTAssertEqual(env.vm.serverModelProblem("qwen2.5-omni", kind: .llm, on: account),
                       "qwen2.5-omni is already added as LLM")
        XCTAssertEqual(env.vm.addServerModel("qwen2.5-omni", kind: .llm, checked: true, to: account),
                       "qwen2.5-omni is already added as LLM")
        XCTAssertNil(env.vm.serverModelProblem("qwen2.5-omni", kind: .transcription, on: account))
        _ = await add(env, "qwen2.5-omni", .transcription, to: account)
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels?.map(\.kind), [.llm, .transcription])
        XCTAssertEqual(env.offered(account, for: .dropFast), ["qwen2.5-omni"])
        XCTAssertEqual(env.offered(account, for: .translation), ["qwen2.5-omni"])
        XCTAssertEqual(env.vm.modelSuggestions(for: account), [], "a name added for both kinds is no longer suggested")

        // Removing one kind un-sets only the features of that kind on it.
        env.routing.setRoute(FeatureRoute(account: account, model: "qwen2.5-omni"), for: .dropFast)
        env.routing.setRoute(FeatureRoute(account: account, model: "qwen2.5-omni"), for: .translation)
        let cleared = env.vm.removeServerModel(ServerModel(name: "qwen2.5-omni", kind: .transcription, checked: true), from: account)
        XCTAssertEqual(cleared, [.dropFast])
        XCTAssertNil(env.routing.route(for: .dropFast))
        XCTAssertEqual(env.routing.route(for: .translation)?.model, "qwen2.5-omni")
        XCTAssertEqual(env.offered(account, for: .dropFast), [])
        XCTAssertEqual(env.vm.rows.first { $0.feature == .dropFast }?.message, "qwen2.5-omni was removed from Lab")
    }

    func test_empty_names_are_refused_before_any_request() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        XCTAssertEqual(env.vm.serverModelProblem("  ", kind: .llm, on: account), "Enter the model's name")
        XCTAssertEqual(env.vm.addServerModel("", kind: .llm, checked: true, to: account), "Enter the model's name")
        XCTAssertEqual(env.vm.serverModelProblem("x", kind: .llm, on: .server(UUID())), "This server was removed")
        XCTAssertNil(env.vm.addServerModel("  spaced  ", kind: .llm, checked: true, to: account))
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels?.map(\.name), ["spaced"])
    }

    func test_a_failed_or_unreachable_check_saves_only_on_request_marked_not_checked() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        let refused = "Server answered 404 on /audio/transcriptions — this model can't transcribe here"
        env.checker.result = .failed(refused)
        let result = await add(env, "qwen3:0.6b", .transcription, to: account)
        XCTAssertEqual(result, .failed(refused))
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels, [], "nothing saved by itself")

        env.checker.result = .unreachable("Couldn't reach the server")
        let down = await add(env, "parakeet", .transcription, to: account)
        XCTAssertEqual(down, .unreachable("Couldn't reach the server"))
        XCTAssertNil(env.vm.addServerModel("parakeet", kind: .transcription, checked: false, to: account))
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels,
                       [ServerModel(name: "parakeet", kind: .transcription, checked: false)])
        XCTAssertEqual(env.offered(account, for: .dropFast), ["parakeet"], "a Not checked model is still offered")
    }

    // MARK: - Servers without /v1/models

    func test_server_without_a_model_list_takes_typed_names() async throws {
        let env = try makeEnv(catalog: nil)
        let account = try await connect(env)
        XCTAssertEqual(env.vm.modelSuggestions(for: account), [])
        let result = await add(env, "ut-llm", .llm, to: account)
        XCTAssertEqual(result, .passed)
        XCTAssertEqual(env.offered(account, for: .meetingNotes), ["ut-llm"])
    }

    // MARK: - Servers from before (PR #393 and earlier)

    func test_a_server_from_before_keeps_its_routes_as_entries_of_their_kind() throws {
        let id = UUID()
        let other = UUID()
        let key = "byok.server.\(id.uuidString.lowercased()).api_key"
        let otherKey = "byok.server.\(other.uuidString.lowercased()).api_key"
        let server = "server:\(id.uuidString.lowercased())"
        let stored = #"""
        {"migrationVersion":4,"migratedRoutes":{},
         "routes":{"dropFast":{"account":"\#(server)","model":"whisper-large-v3"},
                   "agentVoice":{"account":"\#(server)","model":"whisper-large-v3"},
                   "translation":{"account":"\#(server)","model":"qwen3:0.6b"},
                   "meetingNotes":{"account":"\#(server)","model":"qwen3:0.6b"},
                   "dropSmartCleanup":{"account":"openRouter","model":"vendor/model"}},
         "servers":[{"id":"\#(id.uuidString)","name":"Ollama","baseURL":"http://localhost:11434/v1","keyAccount":"\#(key)","modelKinds":"both"},
                    {"id":"\#(other.uuidString)","name":"Idle","baseURL":"http://idle:8000/v1","keyAccount":"\#(otherKey)"}]}
        """#
        let env = try makeEnv(catalog: ["qwen3:0.6b", "whisper-large-v3", "nomic-embed-text"], storedRouting: stored)
        let routesBefore = env.routing.state.routes
        env.routing.adoptExplicitServerModelsIfNeeded()

        XCTAssertEqual(env.routing.server(id)?.models, [
            ServerModel(name: "whisper-large-v3", kind: .transcription, checked: true),
            ServerModel(name: "qwen3:0.6b", kind: .llm, checked: true),
        ])
        XCTAssertEqual(env.routing.server(other)?.models, [], "a server without routes gets an empty list")
        XCTAssertEqual(env.routing.state.routes, routesBefore, "no route moves")
        let account = ProviderAccount.server(id)
        for feature in [AIFeature.dropFast, .agentVoice, .translation, .meetingNotes] {
            XCTAssertEqual(env.resolver.verdict(model: env.routing.route(for: feature)!.model, account: account, for: feature), .new,
                           "\(feature) keeps a usable route")
        }
        XCTAssertEqual(env.offered(account, for: .voiceSearch), ["whisper-large-v3"])
        XCTAssertEqual(env.offered(account, for: .dropSmartCleanup), ["qwen3:0.6b"])

        let saved = String(decoding: try XCTUnwrap(env.defaults.data(forKey: AIRoutingStore.defaultsKey)), as: UTF8.self)
        XCTAssertFalse(saved.contains("modelKinds"), "the retired choice is not written back")

        // A second run and a reload change nothing; a list the user emptied stays empty.
        env.routing.removeModel(named: "qwen3:0.6b", kind: .llm, fromServer: id)
        env.routing.adoptExplicitServerModelsIfNeeded()
        let reloaded = AIRoutingStore(defaults: env.defaults)
        reloaded.adoptExplicitServerModelsIfNeeded()
        XCTAssertEqual(reloaded.server(id)?.models?.map(\.name), ["whisper-large-v3"])
        XCTAssertNil(reloaded.route(for: .translation))
    }

    func test_a_route_onto_an_unlisted_model_keeps_working() throws {
        // A route synced from an older Mac after this one adopted its list.
        let env = try makeEnv()
        let server = env.routing.addServer(name: "Lab", baseURL: "http://localhost:11434/v1")
        let account = ProviderAccount.server(server.id)
        env.routing.setRoute(FeatureRoute(account: account, model: "legacy-asr"), for: .dropFast)
        XCTAssertEqual(env.offered(account, for: .dropFast), ["legacy-asr"])
        XCTAssertEqual(env.resolver.verdict(model: "legacy-asr", account: account, for: .dropFast), .new)
        XCTAssertEqual(env.resolver.verdict(model: "legacy-asr", account: account, for: .voiceSearch),
                       .notSupported(reason: "Not added to Lab as a Transcription model"))
    }

    func test_launch_migration_adopts_old_servers() throws {
        let id = UUID()
        let key = "byok.server.\(id.uuidString.lowercased()).api_key"
        let stored = #"""
        {"migrationVersion":4,"migratedRoutes":{},
         "routes":{"meetings":{"account":"server:\#(id.uuidString.lowercased())","model":"whisper-large-v3"}},
         "servers":[{"id":"\#(id.uuidString)","name":"Box","baseURL":"http://h:8000/v1","keyAccount":"\#(key)"}]}
        """#
        let env = try makeEnv(storedRouting: stored)
        XCTAssertNil(env.routing.server(id)?.models, "read as written before")
        env.routing.reloadFromDefaults()
        XCTAssertEqual(env.routing.server(id)?.models, [ServerModel(name: "whisper-large-v3", kind: .transcription, checked: true)])
    }

    // MARK: - Storage

    func test_models_survive_backup_validation_and_unknown_entries_are_skipped() throws {
        let env = try makeEnv()
        let server = env.routing.addServer(name: "Lab", baseURL: "http://localhost:11434/v1")
        env.routing.addModel(ServerModel(name: "ut-llm", kind: .llm, checked: false), toServer: server.id)
        XCTAssertEqual(AIRoutingStore(defaults: env.defaults).server(server.id)?.models,
                       [ServerModel(name: "ut-llm", kind: .llm, checked: false)])
        XCTAssertTrue(try ConfigBackupRegistry.credentialAccounts(in: env.defaults).contains(server.keyAccount))

        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"Box","baseURL":"http://h","keyAccount":"k","models":[{"name":"a","kind":"llm","checked":true},{"name":"b","kind":"vision","checked":true},{"oops":1}]}"#
        let decoded = try JSONDecoder().decode(ServerEndpoint.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.models, [ServerModel(name: "a", kind: .llm, checked: true)], "a newer build's kind is skipped")
        let garbled = #"{"id":"\#(id.uuidString)","name":"Box","baseURL":"http://h","keyAccount":"k","models":7}"#
        XCTAssertEqual(try JSONDecoder().decode(ServerEndpoint.self, from: Data(garbled.utf8)).models, [])

        // An older build's decoder (no models) still reads the server.
        struct OlderServer: Decodable { let id: UUID; let name: String }
        let stored = try JSONEncoder().encode(ServerEndpoint(id: id, name: "Box", baseURL: "http://h", keyAccount: "k",
                                                              models: [ServerModel(name: "a", kind: .transcription, checked: true)]))
        XCTAssertEqual(try JSONDecoder().decode(OlderServer.self, from: stored).id, id)
    }

    func test_api_urls_follow_the_models_url_rules() {
        func url(_ base: String, _ path: String) -> String? {
            ServerEndpoint(id: UUID(), name: "s", baseURL: base, keyAccount: "k").apiURL(path)?.absoluteString
        }
        XCTAssertEqual(url("http://localhost:11434/v1", "chat/completions"), "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(url("http://localhost:11434/v1/", "audio/transcriptions"), "http://localhost:11434/v1/audio/transcriptions")
        XCTAssertEqual(url("http://h:8000", "chat/completions"), "http://h:8000/v1/chat/completions")
        XCTAssertEqual(url("wss://h/v1/realtime", "audio/transcriptions"), "https://h/v1/audio/transcriptions")
        XCTAssertNil(url("not a url", "chat/completions"))
    }
}

/// The check request itself, against a stubbed server.
final class ServerModelCheckerTests: XCTestCase {
    private func checker(status: Int, body: String) -> ServerModelChecker {
        StubURLProtocol.reset()
        addTeardownBlock { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in (status, ["Content-Type": "application/json"], Data(body.utf8)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return ServerModelChecker(session: session)
    }

    private let server = ServerEndpoint(id: UUID(), name: "Ollama", baseURL: "http://localhost:11434/v1", keyAccount: "k")

    func test_404_on_transcriptions_names_the_endpoint_and_the_server_reason() async throws {
        let check = checker(status: 404, body: #"{"error":{"message":"404 page not found"}}"#)
        let result = await check.check("qwen3:0.6b", kind: .transcription, on: server, apiKey: nil)
        XCTAssertEqual(result, .failed("Server answered 404 on /audio/transcriptions — this model can't transcribe here (404 page not found)"))
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/audio/transcriptions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "no key, no header")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        let body = try XCTUnwrap(StubURLProtocol.capturedBodies.first)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nqwen3:0.6b\r\n"))
        XCTAssertTrue(body.count > ServerModelChecker.silence.count, "half a second of WAV silence is sent")
        XCTAssertEqual(ServerModelChecker.silence.count, 16_000, "0.5 s of 16 kHz PCM16")
    }

    func test_llm_check_sends_one_short_chat_and_passes_on_a_choice() async throws {
        let check = checker(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#)
        let result = await check.check("ut-llm", kind: .llm, on: server, apiKey: "lab-key")
        XCTAssertEqual(result, .passed)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer lab-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.capturedBodies.first)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "ut-llm")
        XCTAssertEqual(body["max_tokens"] as? Int, 16)
    }

    func test_transcription_passes_on_an_empty_transcript() async {
        let result = await checker(status: 200, body: #"{"text":""}"#).check("whisper-1", kind: .transcription, on: server, apiKey: nil)
        XCTAssertEqual(result, .passed)
    }

    func test_answers_are_read_into_plain_reasons() {
        func read(_ status: Int, _ body: String, _ kind: ServerModel.Kind, key: String? = nil) -> ServerModelCheckResult {
            ServerModelChecker.interpret(status: status, data: Data(body.utf8), kind: kind, apiKey: key)
        }
        XCTAssertEqual(read(401, "{}", .llm), .failed("Server refused the key (HTTP 401)"))
        XCTAssertEqual(read(404, #"{"error":"model \"x\" not found, try pulling it first"}"#, .llm),
                       .failed(#"Server answered 404 on /chat/completions — this model can't chat here (model "x" not found, try pulling it first)"#))
        XCTAssertEqual(read(400, #"{"detail":"bad key sk-secret here"}"#, .llm, key: "sk-secret"),
                       .failed("Server answered 400 on /chat/completions — this model can't chat here (bad key … here)"))
        XCTAssertEqual(read(500, "boom", .transcription), .failed("Server answered 500 on /audio/transcriptions"))
        XCTAssertEqual(read(200, "not json", .llm), .failed("Server answered on /chat/completions, but not with JSON"))
        XCTAssertEqual(read(200, #"{"choices":[]}"#, .llm), .failed("Server answered on /chat/completions without a reply"))
        XCTAssertEqual(read(200, #"{"segments":[]}"#, .transcription),
                       .failed("Server answered on /audio/transcriptions without a transcript"))
        let long = String(repeating: "x", count: 300)
        guard case .failed(let message) = read(422, #"{"message":"\#(long)"}"#, .llm) else { return XCTFail() }
        XCTAssertLessThan(message.count, 200)
    }

    func test_no_answer_is_unreachable() async {
        StubURLProtocol.reset()
        addTeardownBlock { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let result = await ServerModelChecker(session: session).check("ut-llm", kind: .llm, on: server, apiKey: nil)
        XCTAssertEqual(result, .unreachable("Couldn't reach the server"))
        let bad = ServerEndpoint(id: UUID(), name: "x", baseURL: "nope", keyAccount: "k")
        let invalid = await ServerModelChecker(session: session).check("m", kind: .llm, on: bad, apiKey: nil)
        XCTAssertEqual(invalid, .unreachable("The server's base URL isn't a web address"))
    }
}

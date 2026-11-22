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

    private final class BuilderKeyCheck: ProviderKeyChecking, @unchecked Sendable {
        var result: KeyStatus = .valid
        var onCheck: (() async -> Void)?
        /// The key and address each check was sent with.
        var sent: [(apiKey: String?, baseURL: String?)] = []
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?,
                   allowPaidProbe: Bool) async -> KeyStatus {
            sent.append((apiKey, server?.baseURL))
            await onCheck?()
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

    private func makeEnv(catalog: [String]? = [], storedRouting: String? = nil, keyChecker: ProviderKeyChecking = AcceptingKeys()) throws -> Env {
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
            keyChecker: keyChecker, probe: probe, serverModelChecker: checker,
            inputLanguage: { nil }, onDevice: OnDeviceSpeechReadiness(isReady: { false })
        )
        let resolver = ModelStatusResolver(routing: routing, keys: keys, catalogs: catalogs, checks: checks,
                                           keyStatuses: keyStatuses, onDevice: OnDeviceSpeechReadiness(isReady: { false }),
                                           adapterVersion: { _, _ in 1 })
        return Env(defaults: defaults, routing: routing, keys: keys, checker: checker, probe: probe, vm: vm, resolver: resolver)
    }

    /// Connects a server directly (as an earlier build or a restore would) and returns its account.
    private func connect(_ env: Env, name: String = "Lab", key: String? = nil) async throws -> ProviderAccount {
        let failure = await env.vm.addServer(name: name, baseURL: "http://localhost:11434/v1", key: key, proposeModels: false)
        XCTAssertNil(failure)
        return try XCTUnwrap(env.vm.lastAddedServer)
    }

    /// Opens the server window the way a tile does; checks start without the typing pause.
    private func sheet(_ env: Env, _ account: ProviderAccount? = nil) -> ServerSheetModel {
        ServerSheetModel(viewModel: env.vm, account: account, delay: .zero)
    }

    /// Waits until no row is waiting for or running a check.
    private func settle(_ model: ServerSheetModel) async {
        for _ in 0..<200 {
            let busy = model.draft.rows.contains { row in
                row.status == .checking || (row.status == .pending && !row.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !busy { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func row(_ model: ServerSheetModel, _ index: Int = 0) -> ServerSheetDraft.Row { model.draft.rows[index] }

    /// Types a model into the window's last empty row (adding one if needed).
    private func type(_ model: ServerSheetModel, _ name: String, _ kind: ServerModel.Kind) async {
        if model.draft.rows.last.map({ !$0.name.isEmpty }) ?? true { model.addRow() }
        let id = model.draft.rows[model.draft.rows.count - 1].id
        model.setName(name, of: id)
        model.setKind(kind, of: id)
        await settle(model)
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

    private static let ollama = "Ollama · localhost:11434"

    // MARK: - One window: address, key and models, one Save

    func test_a_new_server_is_saved_with_its_first_model_in_one_window() async throws {
        let env = try makeEnv(catalog: ["qwen3:0.6b", "whisper-large-v3"])
        let model = sheet(env)
        XCTAssertTrue(model.draft.isNew)
        XCTAssertEqual(model.draft.rows.count, 1, "the first model row is there from the start")
        model.setBaseURL("http://localhost:11434/v1")
        await type(model, "ut-llm", .llm)
        XCTAssertEqual(row(model).status, .works)
        XCTAssertEqual(env.checker.calls.map(\.model), ["ut-llm"])
        XCTAssertNil(env.checker.calls.first?.apiKey, "a server without a key is checked without one")
        XCTAssertTrue(env.routing.state.servers.isEmpty, "nothing is stored before Save")

        let saved = await model.save()
        XCTAssertTrue(saved)
        let server = try XCTUnwrap(env.routing.state.servers.first)
        XCTAssertEqual(server.name, Self.ollama, "the server is named after its address")
        XCTAssertEqual(server.models, [ServerModel(name: "ut-llm", kind: .llm, checked: true)])
        let account = ProviderAccount.server(server.id)
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.title, Self.ollama)
        for feature in Self.textFeatures { XCTAssertEqual(env.offered(account, for: feature), ["ut-llm"], "\(feature)") }
        for feature in Self.speechFeatures { XCTAssertEqual(env.offered(account, for: feature), [], "\(feature)") }
        XCTAssertNil(env.vm.sections(for: .agent).first { $0.account == account }, "a server still can't run the Agent")
        XCTAssertEqual(env.vm.modelSuggestions(for: account), ["qwen3:0.6b", "whisper-large-v3"], "the list only suggests")
    }

    func test_save_needs_an_address_and_empty_rows_are_ignored() async throws {
        let env = try makeEnv()
        let model = sheet(env)
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.saveError, "Enter the server's base URL")
        model.setBaseURL("ftp://box")
        let badURL = await model.save()
        XCTAssertFalse(badURL)
        XCTAssertEqual(model.saveError, "Enter an http or https URL")
        model.setBaseURL("https://vllm.company.ru/v1")
        model.addRow()
        let empty = await model.save()
        XCTAssertTrue(empty)
        XCTAssertEqual(env.routing.state.servers.first?.name, "vllm.company.ru")
        XCTAssertEqual(env.routing.state.servers.first?.models, [], "empty rows are not models")
        XCTAssertTrue(env.checker.calls.isEmpty)
    }

    func test_qwen3_asr_chosen_from_the_server_is_preselected_and_saved_as_transcription() async throws {
        let env = try makeEnv(catalog: ["qwen3-asr", "qwen3:0.6b"])
        let account = try await connect(env)
        let model = sheet(env, account)
        XCTAssertEqual(model.suggestions, ["qwen3-asr", "qwen3:0.6b"])
        model.choose("qwen3-asr", for: row(model).id)
        XCTAssertEqual(row(model).kind, .transcription, "the name preselects the type")
        await settle(model)
        XCTAssertEqual(env.checker.calls.first?.kind, .transcription)
        let saved = await model.save()
        XCTAssertTrue(saved)
        for feature in Self.speechFeatures { XCTAssertEqual(env.offered(account, for: feature), ["qwen3-asr"], "\(feature)") }
        for feature in Self.textFeatures { XCTAssertEqual(env.offered(account, for: feature), [], "\(feature)") }
        XCTAssertEqual(env.resolver.verdict(model: "qwen3-asr", account: account, for: .translation),
                       .notSupported(reason: "Not added to \(Self.ollama) as an LLM"))
        // Picking it runs the ordinary live probe and sets the route.
        await env.vm.select(model: "qwen3-asr", account: account, for: .dropFast)
        XCTAssertEqual(env.probe.models, ["qwen3-asr"])
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: account, model: "qwen3-asr"))
    }

    func test_a_qwen_named_model_can_be_transcription_when_the_user_says_so() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        let model = sheet(env, account)
        await type(model, "qwen-audio", .transcription)
        XCTAssertEqual(ServerModelClassifier.suggestedKind(for: "qwen-audio"), .llm, "the guess says LLM")
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(env.offered(account, for: .dropFast), ["qwen-audio"], "the user's type wins")
    }

    func test_one_name_can_be_both_types_but_each_type_once() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        let model = sheet(env, account)
        await type(model, "qwen2.5-omni", .llm)
        await type(model, "qwen2.5-omni", .transcription)
        await type(model, "qwen2.5-omni", .llm)
        let duplicate = await model.save()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(row(model, 2).status, .failed("qwen2.5-omni is already listed as LLM"))
        model.removeRow(row(model, 2).id)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.models?.map(\.kind), [.llm, .transcription])
        XCTAssertEqual(env.offered(account, for: .dropFast), ["qwen2.5-omni"])
        XCTAssertEqual(env.offered(account, for: .translation), ["qwen2.5-omni"])
        XCTAssertEqual(env.vm.modelSuggestions(for: account), [], "a name added for both types is no longer suggested")

        // Removing one type in the window un-sets only the features of that type on it.
        env.routing.setRoute(FeatureRoute(account: account, model: "qwen2.5-omni"), for: .dropFast)
        env.routing.setRoute(FeatureRoute(account: account, model: "qwen2.5-omni"), for: .translation)
        let edit = sheet(env, account)
        XCTAssertEqual(edit.draft.rows.map(\.status), [.works, .works])
        edit.removeRow(edit.draft.rows[1].id)
        let removed = await edit.save()
        XCTAssertTrue(removed)
        XCTAssertNil(env.routing.route(for: .dropFast))
        XCTAssertEqual(env.routing.route(for: .translation)?.model, "qwen2.5-omni")
        XCTAssertEqual(env.offered(account, for: .dropFast), [])
        XCTAssertEqual(env.vm.rows.first { $0.feature == .dropFast }?.message, "qwen2.5-omni was removed from \(Self.ollama)")
    }

    func test_a_failed_check_stops_save_once_then_save_anyway_keeps_it_not_checked() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        let refused = "Server answered 404 on /audio/transcriptions — this model can't transcribe here"
        env.checker.result = .failed(refused)
        let model = sheet(env, account)
        model.setName("qwen3:0.6b", of: row(model).id)
        model.setKind(.transcription, of: row(model).id)
        // Save before the row's own check ran: it checks, and stops on the new failure.
        let first = await model.save()
        XCTAssertFalse(first)
        XCTAssertEqual(row(model).status, .failed(refused))
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.models, [], "nothing saved by itself")
        let calls = env.checker.calls.count
        // The failure is on screen: Save anyway keeps it, marked Not checked, without asking again.
        let anyway = await model.save()
        XCTAssertTrue(anyway)
        XCTAssertEqual(env.checker.calls.count, calls)
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.models,
                       [ServerModel(name: "qwen3:0.6b", kind: .transcription, checked: false)])
        XCTAssertEqual(env.offered(account, for: .dropFast), ["qwen3:0.6b"], "a Not checked model is still offered")
        XCTAssertEqual(sheet(env, account).draft.rows.first?.status, .notChecked)
    }

    func test_an_unreachable_server_shows_why_and_saves_only_on_request() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        env.checker.result = .unreachable("Couldn't reach the server")
        let model = sheet(env, account)
        await type(model, "parakeet", .transcription)
        XCTAssertEqual(row(model).status, .failed("Couldn't reach the server"))
        let saved = await model.save()
        XCTAssertTrue(saved, "the failure was on screen, so this Save is Save anyway")
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.models?.first?.checked, false)
    }

    func test_cancel_changes_nothing() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        let model = sheet(env, account)
        await type(model, "ut-llm", .llm)
        model.setBaseURL("http://elsewhere:8000/v1")
        model.cancel()
        let server = try XCTUnwrap(env.routing.server(try XCTUnwrap(Self.id(account))))
        XCTAssertEqual(server.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(server.models, [])
    }

    func testBuilderAnUnsavedAddressCannotReceiveTheStoredCredential() async throws {
        let env = try makeEnv()
        let account = try await connect(env, key: "synthetic-original-key")
        let model = sheet(env, account)
        await type(model, "model", .llm)
        let before = env.checker.calls.count
        model.setBaseURL("https://separate-server.example.invalid/v1")
        await settle(model)
        let forwarded = env.checker.calls.dropFirst(before).contains { $0.apiKey != nil }
        XCTAssertFalse(forwarded, "editing a new host must not send the saved credential before Save")
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.baseURL, "http://localhost:11434/v1")
        model.cancel()
    }

    func testBuilderSuggestionsDoNotIdentifyOldModelsAsBelongingToTheDraftServer() async throws {
        let env = try makeEnv(catalog: ["only-on-the-original-server"])
        let account = try await connect(env)
        let model = sheet(env, account)
        XCTAssertEqual(model.suggestions, ["only-on-the-original-server"])
        model.setBaseURL("https://separate-server.example.invalid/v1")
        XCTAssertTrue(model.suggestions.isEmpty, "old server's catalog is not the draft server's catalog")
    }

    func testBuilderSavedKeyChangeDuringFinalKeyCheckCannotCommitCheckedRows() async throws {
        let keyChecker = BuilderKeyCheck()
        let env = try makeEnv(keyChecker: keyChecker)
        let account = try await connect(env, key: "synthetic-original-key")
        let keychain = try keyAccount(env, account)
        let model = sheet(env, account)
        model.setBaseURL("http://localhost:11434/other/v1")
        await type(model, "model", .llm)
        XCTAssertEqual(row(model).status, .works)
        keyChecker.onCheck = {
            await MainActor.run {
                try? env.keys.save("synthetic-replacement-key", account: keychain)
            }
        }
        let saved = await model.save()
        let server = try XCTUnwrap(env.routing.server(try XCTUnwrap(Self.id(account))))
        XCTAssertFalse(saved && server.models?.contains(where: { $0.checked }) == true,
                       "a check under the obsolete credential cannot survive Save")
    }

    func testBuilderRejectedKeyNeverPublishesAnUnsavedServer() async throws {
        let keyChecker = BuilderKeyCheck()
        let env = try makeEnv(keyChecker: keyChecker)
        let model = sheet(env)
        model.setBaseURL("https://separate-server.example.invalid/v1")
        await type(model, "model", .llm)
        keyChecker.result = .rejected(.invalidKey)
        keyChecker.onCheck = {
            await MainActor.run {
                XCTAssertTrue(env.routing.state.servers.isEmpty,
                              "the draft must not enter stored routing before the final key check")
            }
        }
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertTrue(env.routing.state.servers.isEmpty)
    }

    // MARK: - The saved key stays with its address

    func test_a_saved_key_is_not_sent_to_another_address_and_save_removes_it() async throws {
        let keyChecker = BuilderKeyCheck()
        let env = try makeEnv(keyChecker: keyChecker)
        let account = try await connect(env, key: "synthetic-original-key")
        let model = sheet(env, account)
        XCTAssertFalse(model.keyWithheld)
        model.setBaseURL("https://vllm.company.ru/v1")
        XCTAssertTrue(model.keyWithheld, "the window says the saved key is not used here")
        await type(model, "ut-llm", .llm)
        XCTAssertEqual(row(model).status, .works)
        XCTAssertEqual(env.checker.calls.last?.apiKey, nil, "the model check goes without the old key")
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(keyChecker.sent.last?.apiKey, nil, "the key check on Save goes without it too")
        XCTAssertEqual(keyChecker.sent.last?.baseURL, "https://vllm.company.ru/v1")
        XCTAssertEqual(env.keys.lookup(account: try keyAccount(env, account)), .absent,
                       "the old address's key is not kept for the new one")
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.baseURL, "https://vllm.company.ru/v1")
    }

    func test_another_path_on_the_same_server_keeps_the_saved_key() async throws {
        let keyChecker = BuilderKeyCheck()
        let env = try makeEnv(keyChecker: keyChecker)
        let account = try await connect(env, key: "synthetic-original-key")
        let model = sheet(env, account)
        model.setBaseURL("http://LOCALHOST:11434/openai/v1")
        XCTAssertFalse(model.keyWithheld)
        await type(model, "ut-llm", .llm)
        XCTAssertEqual(env.checker.calls.last?.apiKey, "synthetic-original-key")
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(keyChecker.sent.last?.apiKey, "synthetic-original-key")
        XCTAssertEqual(env.keys.read(account: try keyAccount(env, account)), "synthetic-original-key")
    }

    func test_a_key_typed_for_the_new_address_is_used_and_saved() async throws {
        let keyChecker = BuilderKeyCheck()
        let env = try makeEnv(keyChecker: keyChecker)
        let account = try await connect(env, key: "synthetic-original-key")
        let model = sheet(env, account)
        model.setBaseURL("https://vllm.company.ru/v1")
        model.setKey("synthetic-new-key")
        XCTAssertFalse(model.keyWithheld)
        await type(model, "ut-llm", .llm)
        XCTAssertEqual(env.checker.calls.last?.apiKey, "synthetic-new-key")
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(keyChecker.sent.last?.apiKey, "synthetic-new-key")
        XCTAssertEqual(env.keys.read(account: try keyAccount(env, account)), "synthetic-new-key")
    }

    func test_suggestions_come_back_with_the_saved_address_and_a_new_server_has_none() async throws {
        let env = try makeEnv(catalog: ["listed-model"])
        let account = try await connect(env)
        let model = sheet(env, account)
        model.setBaseURL("https://vllm.company.ru/v1")
        XCTAssertEqual(model.suggestions, [])
        model.setBaseURL("http://localhost:11434/v1")
        XCTAssertEqual(model.suggestions, ["listed-model"])
        XCTAssertEqual(sheet(env).suggestions, [])
    }

    // MARK: - Save writes everything at once, after the key check

    func test_a_new_server_with_its_key_and_models_is_stored_only_after_the_key_check() async throws {
        let keyChecker = BuilderKeyCheck()
        let env = try makeEnv(keyChecker: keyChecker)
        let model = sheet(env)
        let id = try XCTUnwrap(Self.id(model.account))
        let keychain = AIRoutingStore.serverKeyAccount(for: id)
        model.setBaseURL("https://vllm.company.ru/v1")
        model.setKey("synthetic-new-key")
        await type(model, "ut-llm", .llm)
        keyChecker.onCheck = {
            await MainActor.run {
                XCTAssertNil(env.routing.server(id), "not listed while its key is checked")
                XCTAssertEqual(env.keys.lookup(account: keychain), .absent, "and its key is not stored yet")
            }
        }
        let saved = await model.save()
        XCTAssertTrue(saved)
        let server = try XCTUnwrap(env.routing.server(id))
        XCTAssertEqual(server.models, [ServerModel(name: "ut-llm", kind: .llm, checked: true)])
        XCTAssertEqual(server.keyAccount, keychain)
        XCTAssertEqual(env.keys.read(account: keychain), "synthetic-new-key")
    }

    func test_a_refused_key_stores_neither_the_server_nor_the_key() async throws {
        let keyChecker = BuilderKeyCheck()
        keyChecker.result = .rejected(.invalidKey)
        let env = try makeEnv(keyChecker: keyChecker)
        let model = sheet(env)
        let id = try XCTUnwrap(Self.id(model.account))
        model.setBaseURL("https://vllm.company.ru/v1")
        model.setKey("synthetic-wrong-key")
        await type(model, "ut-llm", .llm)
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.saveError, "Key not accepted")
        XCTAssertNil(env.routing.server(id))
        XCTAssertEqual(env.keys.lookup(account: AIRoutingStore.serverKeyAccount(for: id)), .absent)
    }

    func test_a_server_removed_during_the_key_check_is_not_brought_back() async throws {
        let keyChecker = BuilderKeyCheck()
        let env = try makeEnv(keyChecker: keyChecker)
        let account = try await connect(env)
        let model = sheet(env, account)
        model.setBaseURL("https://vllm.company.ru/v1")
        await type(model, "ut-llm", .llm)
        keyChecker.onCheck = { await MainActor.run { env.vm.remove(account) } }
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertNil(env.routing.server(try XCTUnwrap(Self.id(account))))
    }

    func test_a_changed_address_and_a_typed_key_are_saved_with_the_models() async throws {
        let env = try makeEnv()
        let account = try await connect(env, key: "old-synthetic-credential")
        env.routing.setRoute(FeatureRoute(account: account, model: "legacy"), for: .dropFast)
        let model = sheet(env, account)
        XCTAssertTrue(model.draft.hasStoredKey)
        model.setBaseURL("https://vllm.company.ru/v1")
        model.setKey("new-synthetic-credential")
        await type(model, "ut-llm", .llm)
        XCTAssertEqual(env.checker.calls.last?.apiKey, "new-synthetic-credential", "checks use the typed key")
        let saved = await model.save()
        XCTAssertTrue(saved)
        let server = try XCTUnwrap(env.routing.server(try XCTUnwrap(Self.id(account))))
        XCTAssertEqual(server.baseURL, "https://vllm.company.ru/v1")
        XCTAssertEqual(server.name, "vllm.company.ru")
        XCTAssertEqual(env.keys.read(account: try keyAccount(env, account)), "new-synthetic-credential")
        XCTAssertEqual(env.routing.route(for: .dropFast)?.model, "legacy", "routes stay with the server")
    }

    func test_a_legacy_name_is_replaced_by_the_address() async throws {
        let env = try makeEnv()
        let account = try await connect(env, name: "qwen3:0.6b")
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.title, Self.ollama, "the tile shows the address")
        let model = sheet(env, account)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.name, Self.ollama, "and Save stores it")
    }

    // MARK: - A check counts only for the server as it was checked

    func test_a_pass_under_the_previous_key_does_not_count() async throws {
        let env = try makeEnv()
        let account = try await connect(env, key: "old-synthetic-credential")
        let keychain = try keyAccount(env, account)
        env.checker.answer = { _, key in
            guard key == "old-synthetic-credential" else { return .failed("Replacement key refused") }
            try? await MainActor.run { try env.keys.save("new-synthetic-credential", account: keychain) }
            return .passed
        }
        let model = sheet(env, account)
        await type(model, "example-model", .llm)
        XCTAssertEqual(row(model).status, .pending, "the pass was for the key that is gone")
        let saved = await model.save()
        XCTAssertFalse(saved, "Save checks again under the new key, which refuses")
        XCTAssertEqual(env.checker.calls.last?.apiKey, "new-synthetic-credential")
        XCTAssertEqual(row(model).status, .failed("Replacement key refused"))
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.models, [])
        XCTAssertTrue(env.offered(account, for: .dropSmartCleanup).isEmpty)
    }

    func test_an_address_synced_while_the_window_is_open_does_not_change_what_was_checked() async throws {
        // The window saves the address it shows, and its checks ran against
        // that address: a synced change elsewhere is replaced by this Save
        // (the later edit wins), and the checked mark stays true for it.
        let env = try makeEnv()
        let account = try await connect(env)
        env.checker.answer = { server, _ in
            guard server.baseURL == "http://localhost:11434/v1" else { return .unreachable("Wrong endpoint was checked") }
            try? await MainActor.run { try Self.syncBaseURL(env, account, to: "http://localhost:9999/v1") }
            return .passed
        }
        let model = sheet(env, account)
        await type(model, "example-model", .transcription)
        XCTAssertEqual(row(model).status, .works)
        let saved = await model.save()
        XCTAssertTrue(saved)
        let server = try XCTUnwrap(env.routing.server(try XCTUnwrap(Self.id(account))))
        XCTAssertEqual(server.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(server.models, [ServerModel(name: "example-model", kind: .transcription, checked: true)])
    }

    func test_typing_a_new_address_during_a_check_discards_its_result() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        let model = sheet(env, account)
        env.checker.answer = { server, _ in
            if server.baseURL == "http://localhost:11434/v1" {
                await MainActor.run { model.setBaseURL("http://gpu:8000/v1") }
                return .passed
            }
            return .failed("Server answered 404 on /chat/completions — this model can't chat here")
        }
        await type(model, "ut-llm", .llm)
        XCTAssertEqual(row(model).status, .failed("Server answered 404 on /chat/completions — this model can't chat here"),
                       "only the check against the address now typed counts")
    }

    func test_a_failure_shown_under_the_old_key_is_checked_again_before_save_anyway() async throws {
        let env = try makeEnv()
        let account = try await connect(env, key: "old-synthetic-credential")
        env.checker.result = .failed("Server refused the key (HTTP 401)")
        let model = sheet(env, account)
        await type(model, "parakeet", .transcription)
        try env.keys.save("new-synthetic-credential", account: try keyAccount(env, account))
        let saved = await model.save()
        XCTAssertFalse(saved, "the failure on screen was for another key: Save checks again and stops")
        XCTAssertEqual(env.checker.calls.last?.apiKey, "new-synthetic-credential")
        env.checker.result = .passed
        model.setKind(.llm, of: row(model).id)
        await settle(model)
        let fixed = await model.save()
        XCTAssertTrue(fixed)
        XCTAssertEqual(env.routing.server(try XCTUnwrap(Self.id(account)))?.models,
                       [ServerModel(name: "parakeet", kind: .llm, checked: true)])
    }

    func test_a_server_removed_while_the_window_is_open_is_not_brought_back() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        let model = sheet(env, account)
        await type(model, "ut-llm", .llm)
        env.vm.remove(account)
        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(model.saveError, "This server was removed")
        XCTAssertTrue(env.routing.state.servers.isEmpty)
    }

    func test_remove_server_un_sets_its_features() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        env.routing.setRoute(FeatureRoute(account: account, model: "ut-llm"), for: .translation)
        sheet(env, account).removeServer()
        XCTAssertTrue(env.routing.state.servers.isEmpty)
        XCTAssertNil(env.routing.route(for: .translation))
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

    // MARK: - Programmatic adds

    func test_empty_and_repeated_names_are_refused_before_any_request() async throws {
        let env = try makeEnv()
        let account = try await connect(env)
        XCTAssertEqual(env.vm.serverModelProblem("  ", kind: .llm, on: account), "Enter the model's name")
        XCTAssertEqual(env.vm.addServerModel("", kind: .llm, checked: true, to: account), "Enter the model's name")
        XCTAssertEqual(env.vm.serverModelProblem("x", kind: .llm, on: .server(UUID())), "This server was removed")
        XCTAssertNil(env.vm.addServerModel("  spaced  ", kind: .llm, checked: true, to: account))
        XCTAssertEqual(env.vm.addServerModel("spaced", kind: .llm, checked: true, to: account), "spaced is already added as LLM")
        XCTAssertEqual(env.vm.chips.first { $0.account == account }?.serverModels?.map(\.name), ["spaced"])
        XCTAssertTrue(env.checker.calls.isEmpty)
    }

    // MARK: - Servers without /v1/models

    func test_server_without_a_model_list_takes_typed_names() async throws {
        let env = try makeEnv(catalog: nil)
        let account = try await connect(env)
        let model = sheet(env, account)
        XCTAssertEqual(model.suggestions, [])
        await type(model, "ut-llm", .llm)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(env.offered(account, for: .meetingNotes), ["ut-llm"])
    }

    private static func id(_ account: ProviderAccount) -> UUID? {
        if case .server(let id) = account { return id }
        return nil
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
                       .notSupported(reason: "Not added to \(Self.ollama) as a Transcription model"))
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

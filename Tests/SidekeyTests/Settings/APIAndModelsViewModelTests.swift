import Combine
import XCTest
@testable import Sidekey

@MainActor
final class APIAndModelsViewModelTests: XCTestCase {
    // MARK: - Fakes

    private final class FakeChecker: ProviderKeyChecking, @unchecked Sendable {
        private let lock = NSLock()
        private var results: [ProviderAccount: KeyStatus] = [:]
        private var log: [(account: ProviderAccount, paid: Bool)] = []

        func set(_ status: KeyStatus, for account: ProviderAccount) {
            lock.lock(); defer { lock.unlock() }
            results[account] = status
        }

        var calls: [(account: ProviderAccount, paid: Bool)] {
            lock.lock(); defer { lock.unlock() }
            return log
        }

        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
            lock.withLock {
                log.append((account, allowPaidProbe))
                return results[account] ?? .valid
            }
        }
    }

    private final class FakeProbe: ModelProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var next: ProbeOutcome = .passed
        private var log: [String] = []

        func answer(_ outcome: ProbeOutcome) {
            lock.lock(); defer { lock.unlock() }
            next = outcome
        }

        var probedModels: [String] {
            lock.lock(); defer { lock.unlock() }
            return log
        }

        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
            lock.withLock {
                log.append(route.model)
                return next
            }
        }
    }

    /// Every refresh fails as if offline: the cache stays as seeded.
    private struct OfflineFetcher: ModelCatalogFetching {
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            throw CatalogFetchError.offline
        }
    }

    private actor SequencedFetcher: ModelCatalogFetching {
        var results: [Result<[CatalogModel], CatalogFetchError>]
        private(set) var calls = 0
        init(_ results: [Result<[CatalogModel], CatalogFetchError>]) { self.results = results }
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            calls += 1
            return try (results.count > 1 ? results.removeFirst() : results[0]).get()
        }
    }

    private struct UnreadableTokenStore: TokenStore {
        struct Failure: Error {}
        func save(_ token: String) throws {}
        func read() throws -> String? { throw Failure() }
        func delete() throws {}
    }

    private actor PausedProbe: ModelProbing {
        private(set) var calls = 0
        private var pending: CheckedContinuation<ProbeOutcome, Never>?

        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
            calls += 1
            return await withCheckedContinuation { pending = $0 }
        }

        func finish() {
            pending?.resume(returning: .passed)
            pending = nil
        }
    }

    @MainActor private final class Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let catalogs: ModelCatalogStore
        let checks: ModelCheckStore
        let keyStatuses: KeyStatusStore
        let checker = FakeChecker()
        let probe = FakeProbe()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var language: String?

        init(routing: AIRoutingStore, keys: ProviderKeyStore, catalogs: ModelCatalogStore,
             checks: ModelCheckStore, keyStatuses: KeyStatusStore) {
            self.routing = routing
            self.keys = keys
            self.catalogs = catalogs
            self.checks = checks
            self.keyStatuses = keyStatuses
        }

        func addKey(_ account: ProviderAccount) {
            if let name = account.keychainAccount(in: routing) { try? keys.save("key", account: name) }
        }

        func lookup(_ account: ProviderAccount) -> ProviderKeyStore.KeyLookup? {
            account.keychainAccount(in: routing).map { keys.lookup(account: $0) }
        }

        func makeViewModel(probeOverride: (any ModelProbing)? = nil) -> APIAndModelsViewModel {
            let now = self.now
            return APIAndModelsViewModel(
                routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses,
                keyChecker: checker, probe: probeOverride ?? probe, now: { now },
                inputLanguage: { [unowned self] in self.language }
            )
        }
    }

    private func makeEnv(
        snapshots: [ProviderAccount: CatalogSnapshot] = [:],
        keyed: [ProviderAccount] = [],
        unreadable: Set<String> = [],
        fetcher: any ModelCatalogFetching = OfflineFetcher()
    ) throws -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let stored = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.storageID, $0.value) })
        try JSONEncoder().encode(stored).write(to: file)

        let box = InMemoryTokenStore.Box()
        let env = Env(
            routing: AIRoutingStore(defaults: defaults),
            keys: ProviderKeyStore(makeStore: { name in
                unreadable.contains(name) ? UnreadableTokenStore() as any TokenStore : InMemoryTokenStore(account: name, box: box)
            }),
            catalogs: ModelCatalogStore(fileURL: file, fetcher: fetcher),
            checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults)
        )
        for account in keyed { env.addKey(account) }
        return env
    }

    private func fresh(_ models: [CatalogModel]) -> CatalogSnapshot {
        CatalogSnapshot(models: models, fetchedAt: Date(), lastRefreshFailed: false, limited: false)
    }

    private func row(_ feature: AIFeature, in vm: APIAndModelsViewModel) -> FeatureRow? {
        vm.rows.first { $0.feature == feature }
    }

    func test_inline_first_key_save_checks_without_proposing_or_assigning_models() async throws {
        let env = try makeEnv(snapshots: [.openAI: fresh([CatalogModel(id: "text-model", uses: [.chat])])])
        let vm = env.makeViewModel()
        let failure = await vm.replaceKey("new-inline-key", for: .openAI)
        XCTAssertNil(failure)
        XCTAssertEqual(env.lookup(.openAI), .key("new-inline-key"))
        XCTAssertEqual(env.checker.calls.map(\.account), [.openAI])
        XCTAssertNil(vm.proposal)
        XCTAssertTrue(AIFeature.allCases.allSatisfy { env.routing.route(for: $0) == nil })
    }

    func test_inline_server_save_can_skip_the_model_proposal() async throws {
        let fetcher = SequencedFetcher([.success([CatalogModel(id: "text-model", uses: [.chat])])])
        let env = try makeEnv(fetcher: fetcher)
        let vm = env.makeViewModel()
        let failure = await vm.addServer(name: "My server", baseURL: "http://localhost:8000/v1", key: "inline-key", proposeModels: false)
        XCTAssertNil(failure)
        XCTAssertEqual(env.routing.state.servers.count, 1)
        XCTAssertNil(vm.proposal)
        XCTAssertTrue(AIFeature.allCases.allSatisfy { env.routing.route(for: $0) == nil })
    }

    // MARK: - Chips

    func test_opening_picker_uses_fresh_cache_without_requests_or_model_probes() async throws {
        let snapshot = fresh([CatalogModel(id: "chat-model", uses: [.chat])])
        let fetcher = SequencedFetcher([.failure(.offline)])
        let env = try makeEnv(snapshots: [.openAI: snapshot], keyed: [.openAI], fetcher: fetcher)
        let vm = env.makeViewModel()
        await vm.refreshModels()
        await vm.refreshModels()
        let calls = await fetcher.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(env.catalogs.snapshot(for: .openAI), snapshot)
        XCTAssertTrue(env.probe.probedModels.isEmpty)
    }

    func test_settings_catalog_load_notifies_an_already_open_picker_with_unchanged_routes() async throws {
        let fetcher = SequencedFetcher([.success([CatalogModel(id: "new-model", uses: [.chat])])])
        let env = try makeEnv(snapshots: [.openAI: CatalogSnapshot(models: [], fetchedAt: .distantPast)],
                              keyed: [.openAI], fetcher: fetcher)
        env.keyStatuses.set(.valid, for: .openAI, at: env.now)
        let vm = env.makeViewModel()
        let rows = vm.rows
        var notifications = 0
        let subscription = vm.objectWillChange.sink { notifications += 1 }
        await vm.onAppear()
        XCTAssertGreaterThan(notifications, 0, "Settings owns an in-flight catalog request if the picker opens early")
        XCTAssertEqual(vm.rows, rows)
        XCTAssertTrue(vm.sections(for: .translation).flatMap(\.options).contains { $0.model == "new-model" })
        XCTAssertTrue(env.checker.calls.isEmpty)
        XCTAssertTrue(env.probe.probedModels.isEmpty)
        withExtendedLifetime(subscription) {}
    }

    func test_opening_picker_retries_failed_catalog_and_exposes_recovered_models() async throws {
        let old = CatalogModel(id: "old-model", uses: [.chat])
        let recovered = CatalogModel(id: "new-model", uses: [.chat])
        let fetcher = SequencedFetcher([.failure(.offline), .success([recovered])])
        let env = try makeEnv(snapshots: [.openAI: CatalogSnapshot(models: [old], fetchedAt: Date(), lastRefreshFailed: true)],
                              keyed: [.openAI], fetcher: fetcher)
        let vm = env.makeViewModel()
        let routes = env.routing.state
        await vm.refreshModels()
        XCTAssertEqual(env.catalogs.snapshot(for: .openAI)?.models, [old])
        await vm.refreshModels()
        XCTAssertEqual(env.catalogs.snapshot(for: .openAI)?.models, [recovered])
        XCTAssertTrue(vm.sections(for: .translation).flatMap(\.options).contains { $0.model == "new-model" })
        XCTAssertEqual(env.routing.state, routes)
        XCTAssertTrue(env.probe.probedModels.isEmpty)
    }

    func test_direct_provider_keys_are_checked_and_failed_replacements_preserve_saved_keys() async throws {
        for (kind, account) in [(AIProviderKind.openAI, ProviderAccount.openAI), (.anthropic, .anthropic)] {
            let env = try makeEnv()
            let vm = env.makeViewModel()
            let result = await vm.addKey("working-key", kind: kind)
            XCTAssertNil(result)
            XCTAssertEqual(env.lookup(account), .key("working-key"))
            XCTAssertEqual(env.checker.calls.last?.account, account)
            let routes = env.routing.state
            for status in [KeyStatus.rejected(.invalidKey), .rejected(.outOfCredit), .unreachable] {
                env.checker.set(status, for: account)
                let failure = await vm.replaceKey("unverified-candidate", for: account)
                XCTAssertNotNil(failure)
                XCTAssertEqual(env.lookup(account), .key("working-key"))
                XCTAssertEqual(env.routing.state, routes)
            }
        }
    }

    func test_openai_key_without_catalog_access_is_not_saved_as_a_working_connection() async throws {
        let env = try makeEnv()
        env.checker.set(.limited, for: .openAI)
        let failure = await env.makeViewModel().addKey("restricted", kind: .openAI)
        XCTAssertNotNil(failure)
        XCTAssertEqual(env.lookup(.openAI), .absent)
    }

    func test_catalogless_server_can_pick_a_named_model_through_the_same_probe() async throws {
        let env = try makeEnv()
        let server = env.routing.addServer(name: "My server", baseURL: "https://server.example/v1")
        let vm = env.makeViewModel()
        XCTAssertTrue(vm.sections(for: .translation).first { $0.account == .server(server.id) }?.options.isEmpty == true)
        await vm.select(model: "my-local-model", account: .server(server.id), for: .translation)
        XCTAssertEqual(env.probe.probedModels, ["my-local-model"])
        XCTAssertEqual(env.routing.route(for: .translation), FeatureRoute(account: .server(server.id), model: "my-local-model"))
        let reopened = try XCTUnwrap(vm.sections(for: .translation).first { $0.account == .server(server.id) })
        XCTAssertFalse(reopened.options.isEmpty)
        XCTAssertTrue(reopened.acceptsModelName, "The saved route must not hide the server model-name field")
        await vm.select(model: "replacement-model", account: .server(server.id), for: .translation)
        XCTAssertEqual(env.routing.route(for: .translation)?.model, "replacement-model")
    }

    func test_catalog_refresh_notifies_open_picker_without_changing_routes_or_rows() async throws {
        let env = try makeEnv(keyed: [.openRouter])
        let vm = env.makeViewModel()
        let rows = vm.rows
        let routes = env.routing.state
        var notifications = 0
        let subscription = vm.objectWillChange.sink { notifications += 1 }

        await vm.refreshModels()

        XCTAssertGreaterThan(notifications, 0, "An open picker must update even when only its catalog changes")
        XCTAssertEqual(vm.rows, rows)
        XCTAssertEqual(env.routing.state, routes)
        XCTAssertTrue(env.probe.probedModels.isEmpty)
        XCTAssertTrue(vm.sections(for: .translation).allSatisfy(\.refreshFailed))
        withExtendedLifetime(subscription) {}
    }

    func test_chips_show_keyed_providers_and_servers_only() throws {
        let env = try makeEnv(keyed: [.soniox, .openRouter], unreadable: [BYOKKeyStore.account(for: .elevenLabs)])
        let server = env.routing.addServer(name: "Lab", baseURL: "http://10.0.0.2:8000/v1")
        env.keyStatuses.set(.valid, for: .soniox, at: env.now)
        env.keyStatuses.set(.rejected(.outOfCredit), for: .openRouter, at: env.now)

        let vm = env.makeViewModel()

        XCTAssertEqual(vm.chips.map(\.account), [.soniox, .elevenLabs, .openRouter, .server(server.id)])
        XCTAssertEqual(vm.chips[0], KeyChip(account: .soniox, title: "Soniox", statusText: "Key works", checkedAt: env.now))
        XCTAssertEqual(vm.chips[1].statusText, "Couldn't read the key from the Keychain",
                       "an unreadable key is a key problem, never no key")
        XCTAssertEqual(vm.chips[2].statusText, "Out of credit or key limit reached")
        XCTAssertEqual(vm.chips[3].title, "Lab")
        XCTAssertEqual(vm.chips[3].statusText, "Not checked yet")
        XCTAssertEqual(vm.addableKinds, [.deepgram, .openAI, .anthropic, .openAICompatible])
    }

    // MARK: - Adding keys

    func test_add_key_proposes_but_never_assigns() async throws {
        let env = try makeEnv()
        let vm = env.makeViewModel()

        let error = await vm.addKey("  sk-soniox  ", kind: .soniox)

        XCTAssertNil(error)
        XCTAssertEqual(env.lookup(.soniox), .key("sk-soniox"))
        XCTAssertTrue(env.checker.calls.allSatisfy { $0.paid })
        XCTAssertEqual(env.checker.calls.map(\.account), [.soniox])
        for feature in AIFeature.allCases {
            XCTAssertNil(env.routing.route(for: feature), "\(feature) must not be assigned by adding a key")
        }
        XCTAssertEqual(env.keyStatuses.record(for: .soniox)?.status, .valid)
        XCTAssertEqual(vm.proposal?.title, "Use Soniox for")
        XCTAssertEqual(vm.proposal?.items, [
            AssignItem(feature: .dropFast, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .dropSmart, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .meetings, account: .soniox, model: "stt-async-v5"),
            AssignItem(feature: .agentVoice, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .meetingAssistantAudio, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .voiceSearch, account: .soniox, model: "stt-rt-v5"),
            AssignItem(feature: .subtitlesAudio, account: .soniox, model: "stt-rt-v5"),
        ])
    }

    func test_rejected_key_is_not_saved() async throws {
        let env = try makeEnv()
        env.checker.set(.rejected(.invalidKey), for: .soniox)
        let vm = env.makeViewModel()

        let error = await vm.addKey("sk-wrong", kind: .soniox)

        XCTAssertEqual(error, "Key not accepted. Regional keys aren't supported yet.")
        XCTAssertEqual(env.lookup(.soniox), .absent)
        XCTAssertNil(env.keyStatuses.record(for: .soniox))
        XCTAssertTrue(vm.chips.isEmpty)
        XCTAssertNil(vm.proposal)
        XCTAssertEqual(vm.addableKinds.first, .soniox)
    }

    func test_add_server_refuses_bad_input_and_stores_nothing() async throws {
        let env = try makeEnv()
        let vm = env.makeViewModel()

        for (name, url) in [("", "http://a:1"), ("Lab", "ftp://host/v1"), ("Lab", "http:///v1"),
                            ("Lab", "https://user:pass@host/v1"), ("Lab", "not a url")] {
            let error = await vm.addServer(name: name, baseURL: url, key: nil)
            XCTAssertNotNil(error, "\(name) \(url)")
        }
        let blank = await vm.addKey("   ", kind: .deepgram)
        XCTAssertNotNil(blank)
        XCTAssertTrue(env.routing.state.servers.isEmpty)
        XCTAssertTrue(env.checker.calls.isEmpty)

        let added = await vm.addServer(name: "  Lab  ", baseURL: " http://10.0.0.2:8000/v1 ", key: "  ")
        XCTAssertNil(added)
        XCTAssertEqual(env.routing.state.servers.map(\.name), ["Lab"])
        XCTAssertEqual(env.routing.state.servers.map(\.baseURL), ["http://10.0.0.2:8000/v1"])
        let server = try XCTUnwrap(env.routing.state.servers.first)
        XCTAssertEqual(env.keys.lookup(account: server.keyAccount), .absent, "a blank key field means keyless")
    }

    func test_apply_proposal_assigns_only_checked_features() async throws {
        let env = try makeEnv()
        let vm = env.makeViewModel()
        _ = await vm.addKey("sk-soniox", kind: .soniox)

        vm.applyProposal(selected: [.dropFast, .meetings])

        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        XCTAssertEqual(env.routing.route(for: .meetings), FeatureRoute(account: .soniox, model: "stt-async-v5"))
        XCTAssertNil(env.routing.route(for: .dropSmart))
        XCTAssertNil(env.routing.route(for: .agentVoice))
        XCTAssertNil(env.probe.probedModels.first, "registry models are assigned without a probe")
        XCTAssertNil(vm.proposal)
    }

    // MARK: - Removing keys (Review Focus 3)

    func test_remove_key_unsets_features_and_reassigns_nothing() throws {
        let env = try makeEnv(snapshots: [.soniox: fresh([CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT])])],
                              keyed: [.soniox, .deepgram])
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropSmart)
        env.routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .meetings)
        env.keyStatuses.set(.valid, for: .soniox, at: env.now)
        let vm = env.makeViewModel()

        XCTAssertEqual(vm.featuresUsing(.soniox), [.dropFast, .dropSmart])
        vm.remove(.soniox)

        XCTAssertEqual(env.lookup(.soniox), .absent)
        XCTAssertNil(env.routing.route(for: .dropFast))
        XCTAssertNil(env.routing.route(for: .dropSmart))
        XCTAssertEqual(env.routing.route(for: .meetings), FeatureRoute(account: .deepgram, model: "nova-3"))
        XCTAssertFalse(AIFeature.allCases.contains { env.routing.route(for: $0)?.account == .deepgram && $0 != .meetings })
        XCTAssertNil(env.keyStatuses.record(for: .soniox))
        XCTAssertNil(env.catalogs.snapshot(for: .soniox))
        XCTAssertNil(vm.proposal)
        XCTAssertEqual(row(.dropFast, in: vm)?.status, .notSet)
        XCTAssertEqual(row(.dropFast, in: vm)?.selectionLabel, "Choose a model")
        XCTAssertEqual(row(.dropFast, in: vm)?.modelSummary, "Choose a model")
        XCTAssertEqual(vm.chips.map(\.account), [.deepgram])
    }

    // MARK: - Picking a model

    private func sonioxWithNewModel() throws -> Env {
        let env = try makeEnv(
            snapshots: [.soniox: fresh([
                CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT]),
                CatalogModel(id: "stt-rt-v6", uses: [.realtimeSTT]),
            ])],
            keyed: [.soniox]
        )
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        return env
    }

    func test_new_model_is_assigned_after_a_passed_probe() async throws {
        let env = try sonioxWithNewModel()
        let vm = env.makeViewModel()
        XCTAssertEqual(row(.dropFast, in: vm)?.selectionLabel, "Soniox · stt-rt-v5")
        XCTAssertEqual(row(.dropFast, in: vm)?.modelSummary, "stt-rt-v5")

        await vm.select(model: "stt-rt-v6", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.probe.probedModels, ["stt-rt-v6"])
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v6"))
        XCTAssertEqual(row(.dropFast, in: vm)?.modelSummary, "stt-rt-v6")
        XCTAssertEqual(row(.dropFast, in: vm)?.status, .ok)
        XCTAssertEqual(row(.dropFast, in: vm)?.isChecking, false)
        XCTAssertNil(row(.dropFast, in: vm)?.message)
    }

    func test_check_now_exposes_pending_state_and_does_not_repeat_a_running_probe() async throws {
        let env = try sonioxWithNewModel()
        let probe = PausedProbe()
        let vm = env.makeViewModel(probeOverride: probe)
        let first = Task { await vm.checkNow(.dropFast) }
        for _ in 0..<1_000 {
            if await probe.calls > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(row(.dropFast, in: vm)?.isChecking, true)
        XCTAssertEqual(row(.dropFast, in: vm)?.modelSummary, "stt-rt-v5")
        await vm.checkNow(.dropFast)
        let count = await probe.calls
        XCTAssertEqual(count, 1)
        await probe.finish()
        await first.value
        XCTAssertEqual(row(.dropFast, in: vm)?.isChecking, false)
        XCTAssertEqual(env.routing.route(for: .dropFast)?.model, "stt-rt-v5")
    }

    func test_failed_probe_keeps_the_previous_model_and_says_why() async throws {
        let env = try sonioxWithNewModel()
        env.probe.answer(.failed(reason: "no partial results"))
        let vm = env.makeViewModel()

        await vm.select(model: "stt-rt-v6", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        XCTAssertEqual(row(.dropFast, in: vm)?.message, "no partial results")
        XCTAssertEqual(row(.dropFast, in: vm)?.isChecking, false)
    }

    func test_offline_probe_keeps_the_previous_model() async throws {
        let env = try sonioxWithNewModel()
        env.probe.answer(.inconclusive(reason: "offline"))
        let vm = env.makeViewModel()

        await vm.select(model: "stt-rt-v6", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        XCTAssertEqual(row(.dropFast, in: vm)?.message, "Couldn't check: offline")
        XCTAssertNil(env.checks.record(for: ModelCheckKey(account: "soniox", model: "stt-rt-v6", use: .realtimeSTT)))
    }

    /// A stored probe failure is not a ban: picking the model again probes it
    /// again, and a pass assigns it (final review I1).
    func test_picking_a_model_with_a_stored_failure_probes_it_again() async throws {
        let env = try sonioxWithNewModel()
        let key = ModelCheckKey(account: "soniox", model: "stt-rt-v6", use: .realtimeSTT)
        env.checks.store(.failed(reason: "Provider refused: provider"), for: key, adapterVersion: 1, at: env.now)
        let vm = env.makeViewModel()

        await vm.select(model: "stt-rt-v6", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.probe.probedModels, ["stt-rt-v6"])
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v6"))
        XCTAssertEqual(env.checks.record(for: key)?.outcome, .passed)
        XCTAssertEqual(row(.dropFast, in: vm)?.status, .ok)
    }

    /// A registry model that once failed is probed on the next pick too, so the
    /// stored failure does not keep showing after it is assigned.
    func test_picking_a_registry_model_with_a_stored_failure_probes_it_again() async throws {
        let env = try sonioxWithNewModel()
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v6"), for: .dropFast)
        let key = ModelCheckKey(account: "soniox", model: "stt-rt-v5", use: .realtimeSTT)
        env.checks.store(.failed(reason: "Provider refused: provider"), for: key, adapterVersion: 1, at: env.now)
        let vm = env.makeViewModel()

        await vm.select(model: "stt-rt-v5", account: .soniox, for: .dropFast)

        XCTAssertEqual(env.probe.probedModels, ["stt-rt-v5"])
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        XCTAssertEqual(row(.dropFast, in: vm)?.status, .ok)
    }

    /// A runtime refusal clears on a passed Check now and on picking the model
    /// again (final review I2).
    func test_refusal_clears_on_a_passed_check_and_on_a_new_pick() async throws {
        let env = try makeEnv(keyed: [.openRouter])
        let model = "google/gemini-3.8-flash"
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: model), for: .dropSmartCleanup)
        env.checks.recordRefusal(feature: .dropSmartCleanup, model: model, at: env.now)
        let vm = env.makeViewModel()
        XCTAssertEqual(row(.dropSmartCleanup, in: vm)?.status, .notSupported(reason: ModelStatusResolver.refusedReason))

        await vm.checkNow(.dropSmartCleanup)
        XCTAssertNil(env.checks.refusedModel(for: .dropSmartCleanup))
        XCTAssertEqual(row(.dropSmartCleanup, in: vm)?.status, .ok)

        env.checks.recordRefusal(feature: .dropSmartCleanup, model: model, at: env.now)
        await vm.select(model: model, account: .openRouter, for: .dropSmartCleanup)
        XCTAssertNil(env.checks.refusedModel(for: .dropSmartCleanup))
        XCTAssertEqual(row(.dropSmartCleanup, in: vm)?.status, .ok)
    }

    func test_switch_group_moves_all_four_features_to_stt_rt_v5() async throws {
        let env = try makeEnv(
            snapshots: [.soniox: fresh([
                CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT]),
                CatalogModel(id: "stt-rt-v4", uses: [.realtimeSTT], aliasOf: "stt-rt-v5"),
            ])],
            keyed: [.soniox]
        )
        let realtime: [AIFeature] = [.dropFast, .dropSmart, .agentVoice, .voiceSearch]
        for feature in realtime {
            env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v4"), for: feature)
        }
        let vm = env.makeViewModel()
        let group = try XCTUnwrap(vm.aliasGroups.first)
        XCTAssertEqual(group.features, realtime)

        await vm.apply(group)

        for feature in realtime {
            XCTAssertEqual(env.routing.route(for: feature), FeatureRoute(account: .soniox, model: "stt-rt-v5"))
        }
        XCTAssertTrue(env.probe.probedModels.isEmpty)
        XCTAssertTrue(vm.aliasGroups.isEmpty)
    }

    // MARK: - Opening the tab

    func test_opening_the_tab_runs_only_free_checks_older_than_a_day() async throws {
        let env = try makeEnv(keyed: [.soniox, .deepgram, .openRouter])
        env.keyStatuses.set(.valid, for: .soniox, at: env.now.addingTimeInterval(-3_600))
        env.keyStatuses.set(.valid, for: .deepgram, at: env.now.addingTimeInterval(-2 * 86_400))
        let vm = env.makeViewModel()

        await vm.onAppear()

        XCTAssertEqual(Set(env.checker.calls.map(\.account)), [.deepgram, .openRouter])
        XCTAssertEqual(env.checker.calls.count, 2)
        XCTAssertTrue(env.checker.calls.allSatisfy { !$0.paid })
        XCTAssertEqual(env.keyStatuses.record(for: .openRouter)?.checkedAt, env.now)
    }

    func test_reopening_settings_recovers_a_cached_credit_refusal_without_replacing_the_key() async throws {
        let env = try makeEnv(keyed: [.openRouter])
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "openai/gpt-6-sol"), for: .dropSmartCleanup)
        env.keyStatuses.set(.rejected(.outOfCredit), for: .openRouter, at: env.now.addingTimeInterval(-301))
        let vm = env.makeViewModel()
        XCTAssertEqual(vm.rows.first { $0.feature == .dropSmartCleanup }?.status, .keyProblem)

        await vm.onAppear()

        XCTAssertEqual(vm.chips.first { $0.account == .openRouter }?.statusText, "Key works")
        XCTAssertNotEqual(vm.rows.first { $0.feature == .dropSmartCleanup }?.status, .keyProblem)
        XCTAssertEqual(env.lookup(.openRouter), .key("key"))
        XCTAssertEqual(env.checker.calls.count, 1)
        XCTAssertFalse(env.checker.calls[0].paid)
    }

    // MARK: - Banner

    func test_banner_counts_unset_features_only_when_a_key_exists() throws {
        let env = try makeEnv()
        XCTAssertNil(env.makeViewModel().unsetBanner)

        env.addKey(.soniox)
        XCTAssertEqual(env.makeViewModel().unsetBanner, "13 features have no model")

        for feature in AIFeature.allCases where feature != .dropFast {
            env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: feature)
        }
        XCTAssertEqual(env.makeViewModel().unsetBanner, "1 feature has no model")

        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        XCTAssertNil(env.makeViewModel().unsetBanner)
    }

    // MARK: - Deepgram input language (PR #35)

    func test_deepgram_row_warns_when_the_input_language_does_not_fit() async throws {
        let env = try makeEnv(keyed: [.deepgram])
        let route = FeatureRoute(account: .deepgram, model: "nova-3")
        env.routing.setRoute(route, for: .agentVoice)
        env.language = "cy"
        let vm = env.makeViewModel()

        XCTAssertEqual(row(.agentVoice, in: vm)?.message,
                       "This Deepgram model doesn't support the current input language. Pick another model or input language.")

        env.language = "ru"
        let updated = expectation(description: "rows recomputed")
        let watch = vm.$rows.dropFirst().sink { rows in
            if rows.first(where: { $0.feature == .agentVoice })?.message == nil { updated.fulfill() }
        }
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        await fulfillment(of: [updated], timeout: 2)
        watch.cancel()

        XCTAssertNil(row(.agentVoice, in: vm)?.message)
        XCTAssertEqual(env.routing.route(for: .agentVoice), route)
    }
}

// MARK: - OpenRouter provider

@MainActor
final class APIAndModelsProviderTests: XCTestCase {
    private final class FakeEndpoints: OpenRouterEndpointsFetching, @unchecked Sendable {
        private let lock = NSLock()
        var result: Result<[OpenRouterEndpoint], Error> = .success([])
        private(set) var calls: [(model: String, key: String)] = []
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] {
            try lock.withLock {
                calls.append((model, apiKey))
                return try result.get()
            }
        }
    }

    private func endpoint(_ tag: String, _ name: String, tps: Double?) -> OpenRouterEndpoint {
        OpenRouterEndpoint(tag: tag, providerName: name, quantization: nil, latencyMs: 300, tokensPerSecond: tps, isUp: true)
    }

    private func make() throws -> (APIAndModelsViewModel, AIRoutingStore, FakeEndpoints, ProviderKeyStore) {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        try Data("{}".utf8).write(to: file)
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let fake = FakeEndpoints()
        let vm = APIAndModelsViewModel(
            routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: file), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults), endpoints: fake,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, inputLanguage: { nil }
        )
        return (vm, routing, fake, keys)
    }

    func test_groups_pair_speech_with_its_llm_and_cover_every_feature_once() throws {
        let (vm, _, _, _) = try make()
        let features = vm.groups.flatMap { $0.rows.map(\.feature) }
        XCTAssertEqual(features.sorted { $0.rawValue < $1.rawValue }, AIFeature.activeCases.sorted { $0.rawValue < $1.rawValue })
        XCTAssertEqual(vm.groups.map(\.title), ["Drop Fast", "Drop Smart", "Meetings", "Agent", "Agent voice", "Voice search", "Translation", "Subtitles", "Meeting Assistant (Beta)"])
        XCTAssertEqual(vm.groups.first { $0.title == "Drop Smart" }?.rows.map(\.feature), [.dropSmart, .dropSmartCleanup])
        XCTAssertEqual(vm.groups.first { $0.title == "Meetings" }?.rows.map(\.feature), [.meetings, .meetingNotes])
        XCTAssertEqual(vm.groups.first { $0.title == "Translation" }?.rows.map(\.feature), [.translation])
        let subtitles = try XCTUnwrap(vm.groups.first { $0.title == "Subtitles" })
        XCTAssertEqual(subtitles.rows.map(\.feature), [.subtitlesAudio, .subtitlesTranslation])
        XCTAssertEqual(subtitles.rows.map(\.fieldLabel), ["Speech", "LLM"])
        let assistant = try XCTUnwrap(vm.groups.first { $0.title == "Meeting Assistant (Beta)" })
        XCTAssertEqual(assistant.rows.map(\.feature), [.meetingAssistantAudio, .meetingAssistantDetector, .meetingAssistant])
        XCTAssertEqual(assistant.rows.map(\.fieldLabel), ["Speech", "Decision", "Text"])
    }

    func test_only_openrouter_rows_offer_a_provider_and_auto_is_the_default() throws {
        let (vm, routing, _, _) = try make()
        routing.setRoute(FeatureRoute(account: .openRouter, model: "x/m"), for: .meetingNotes)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        vm.selectProvider(nil, for: .meetingNotes)

        let notes = try XCTUnwrap(vm.rows.first { $0.feature == .meetingNotes })
        XCTAssertEqual(notes.provider, ProviderChoice(model: "x/m", pinned: nil, label: "Auto"))
        XCTAssertNil(vm.rows.first { $0.feature == .dropFast }?.provider)
    }

    func test_loads_providers_with_the_openrouter_key_and_names_the_pin() async throws {
        let (vm, routing, fake, keys) = try make()
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "x/m"), for: .meetingNotes)
        fake.result = .success([endpoint("slow/fp8", "Slow", tps: 20), endpoint("fast", "Fast", tps: 200)])

        await vm.loadProviders(for: .meetingNotes)
        await vm.loadProviders(for: .meetingNotes)

        XCTAssertEqual(fake.calls.count, 1, "a fresh list is reused")
        XCTAssertEqual(fake.calls.first?.key, "or-key")
        guard case .loaded(let list, _) = vm.providerLists["x/m"] else { return XCTFail("not loaded") }
        XCTAssertEqual(list.map(\.tag), ["fast", "slow/fp8"])

        vm.selectProvider("slow/fp8", for: .meetingNotes)
        XCTAssertEqual(routing.route(for: .meetingNotes)?.provider, "slow/fp8")
        XCTAssertEqual(vm.rows.first { $0.feature == .meetingNotes }?.provider?.label, "Slow")
    }

    func test_failed_load_is_retried_on_force() async throws {
        let (vm, routing, fake, keys) = try make()
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "x/m"), for: .agent)
        fake.result = .failure(URLError(.notConnectedToInternet))
        await vm.loadProviders(for: .agent)
        XCTAssertEqual(vm.providerLists["x/m"], .failed)
        fake.result = .success([endpoint("a", "A", tps: 1)])
        await vm.loadProviders(for: .agent, force: true)
        if case .loaded = vm.providerLists["x/m"] {} else { XCTFail("retry did not load") }
    }

    func test_without_a_key_nothing_is_requested() async throws {
        let (vm, routing, fake, _) = try make()
        routing.setRoute(FeatureRoute(account: .openRouter, model: "x/m"), for: .agent)
        await vm.loadProviders(for: .agent)
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func test_repicking_the_current_model_keeps_the_pin() async throws {
        let (vm, routing, _, keys) = try make()
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5", provider: "anthropic"),
                         for: .agent)
        await vm.select(model: "anthropic/claude-sonnet-5.5", account: .openRouter, for: .agent)
        XCTAssertEqual(routing.route(for: .agent)?.provider, "anthropic")
    }
}

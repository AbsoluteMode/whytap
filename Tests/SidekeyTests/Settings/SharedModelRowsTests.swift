import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The shared Speech and LLM rows, from the user's side: an empty Mac set up
/// in two picks, a text model the Agent cannot use, a custom per-feature
/// model, an older Mac whose features disagree, a speech provider without a
/// usable recorded model and a self-hosted server.
@MainActor
final class SharedModelRowsTests: XCTestCase {
    private final class RecordingProbe: ModelProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [(model: String, use: ModelUse)] = []
        private var outcome: ProbeOutcome = .passed
        func answer(_ next: ProbeOutcome) { lock.withLock { outcome = next } }
        var calls: [(model: String, use: ModelUse)] { lock.withLock { log } }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
            lock.withLock {
                log.append((route.model, use))
                return outcome
            }
        }
    }

    private struct AlwaysValid: ProviderKeyChecking {
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
    }

    private struct Offline: ModelCatalogFetching {
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            throw CatalogFetchError.offline
        }
    }

    @MainActor private struct Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let catalogs: ModelCatalogStore
        let checks: ModelCheckStore
        let keyStatuses: KeyStatusStore
        let probe = RecordingProbe()

        func makeViewModel() -> APIAndModelsViewModel {
            APIAndModelsViewModel(routing: routing, keys: keys, catalogs: catalogs, checks: checks,
                                  keyStatuses: keyStatuses, keyChecker: AlwaysValid(), probe: probe,
                                  now: { Date(timeIntervalSince1970: 1_800_000_000) }, inputLanguage: { nil },
                                  onDevice: OnDeviceSpeechReadiness(isReady: { false }))
        }
    }

    private func fresh(_ models: [CatalogModel]) -> CatalogSnapshot {
        CatalogSnapshot(models: models, fetchedAt: Date(), lastRefreshFailed: false, limited: false)
    }

    private func makeEnv(snapshots: [ProviderAccount: CatalogSnapshot] = [:], keyed: [ProviderAccount]) throws -> Env {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.storageID, $0.value) }))
            .write(to: file)
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        for account in keyed {
            if let name = account.keychainAccount(in: routing) { try keys.save("key", account: name) }
        }
        return Env(routing: routing, keys: keys, catalogs: ModelCatalogStore(fileURL: file, fetcher: Offline()),
                   checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults))
    }

    private func llm(_ id: String, tools: Bool = true) -> CatalogModel {
        CatalogModel(id: id, uses: tools ? [.chat, .chatWithTools] : [.chat], contextLength: 1_000_000, supportsTools: tools)
    }

    private func row(_ kind: SharedModelKind, _ vm: APIAndModelsViewModel) throws -> SharedModelRow {
        try XCTUnwrap(vm.sharedRow(kind))
    }

    // MARK: - Scenarios

    func test_every_active_feature_belongs_to_exactly_one_shared_row() {
        let shared = SharedModelKind.allCases.flatMap(\.features)
        XCTAssertEqual(Set(shared), Set(AIFeature.activeCases))
        XCTAssertEqual(shared.count, Set(shared).count)
        XCTAssertTrue(SharedModelKind.speech.features.allSatisfy { [.realtime, .recorded].contains($0.mode) })
        XCTAssertTrue(SharedModelKind.llm.features.allSatisfy { [.llm, .llmWithTools].contains($0.mode) })
    }

    func test_empty_mac_is_set_up_with_two_picks_and_one_check() async throws {
        let env = try makeEnv(snapshots: [.anthropic: fresh([llm("claude-opus-5")])], keyed: [.elevenLabs, .anthropic])
        let vm = env.makeViewModel()
        XCTAssertEqual(try row(.speech, vm).label, "Choose a model")
        XCTAssertEqual(try row(.llm, vm).label, "Choose a model")
        XCTAssertTrue(try row(.speech, vm).needsSetup)
        XCTAssertEqual(vm.rows.filter { $0.status == .notSet }.count, AIFeature.activeCases.count)

        let speech = await vm.selectShared(model: ModelRegistry.elevenLabsRealtimeModel, account: .elevenLabs,
                                           kind: .speech, replaceCustom: false)
        XCTAssertTrue(speech)
        XCTAssertTrue(env.probe.calls.isEmpty, "built-in speech models need no check")
        for feature in [AIFeature.dropFast, .dropSmart, .agentVoice, .voiceSearch] {
            XCTAssertEqual(env.routing.route(for: feature), FeatureRoute(account: .elevenLabs, model: "scribe_v3_live"))
        }
        XCTAssertEqual(env.routing.route(for: .meetings), FeatureRoute(account: .elevenLabs, model: "scribe_v3"),
                       "Meetings get the recorded counterpart")

        let text = await vm.selectShared(model: "claude-opus-5", account: .anthropic, kind: .llm, replaceCustom: false)
        XCTAssertTrue(text)
        XCTAssertEqual(env.probe.calls.map(\.model), ["claude-opus-5"], "one check for the whole pick")
        XCTAssertEqual(env.probe.calls.map(\.use), [.chatWithTools], "tool use covers plain text")
        for feature in SharedModelKind.llm.features {
            XCTAssertEqual(env.routing.route(for: feature), FeatureRoute(account: .anthropic, model: "claude-opus-5"))
        }
        XCTAssertEqual(try row(.speech, vm).label, "ElevenLabs · scribe_v3_live")
        XCTAssertEqual(try row(.llm, vm).label, "Anthropic · claude-opus-5")
        XCTAssertFalse(try row(.llm, vm).needsSetup)
        XCTAssertTrue(vm.rows.allSatisfy { $0.status == .ok }, "\(vm.rows.map { ($0.feature, $0.status) })")
    }

    func test_text_model_without_tools_leaves_the_agent_alone() async throws {
        let env = try makeEnv(snapshots: [.openRouter: fresh([llm("vendor/no-tools", tools: false),
                                                              llm("anthropic/claude-sonnet-5.5")])],
                              keyed: [.openRouter])
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5"), for: .agent)
        let vm = env.makeViewModel()
        XCTAssertEqual(try row(.llm, vm).label, "OpenRouter · anthropic/claude-sonnet-5.5 · 3 not set")

        await vm.selectShared(model: "vendor/no-tools", account: .openRouter, kind: .llm, replaceCustom: false)
        XCTAssertEqual(env.routing.route(for: .agent), FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5"))
        for feature in [AIFeature.dropSmartCleanup, .meetingNotes, .translation] {
            XCTAssertEqual(env.routing.route(for: feature)?.model, "vendor/no-tools")
        }
        let shared = try row(.llm, vm)
        XCTAssertEqual(shared.label, "OpenRouter · vendor/no-tools · 1 custom")
        XCTAssertEqual(shared.custom, [.agent])
        XCTAssertEqual(shared.notes, ["Agent: no tool support · kept anthropic/claude-sonnet-5.5"])
        XCTAssertEqual(env.probe.calls.map(\.use), [.chat])
    }

    func test_custom_model_in_advanced_survives_a_shared_pick_unless_replaced() async throws {
        let env = try makeEnv(snapshots: [.anthropic: fresh([llm("claude-opus-5"), llm("claude-haiku-5-5"), llm("claude-sonnet-5")])],
                              keyed: [.anthropic])
        let vm = env.makeViewModel()
        await vm.selectShared(model: "claude-opus-5", account: .anthropic, kind: .llm, replaceCustom: false)
        // Advanced: Translation on its own model.
        await vm.select(model: "claude-haiku-5-5", account: .anthropic, for: .translation)
        XCTAssertEqual(try row(.llm, vm).label, "Anthropic · claude-opus-5 · 1 custom")
        XCTAssertEqual(try row(.llm, vm).custom, [.translation])

        await vm.selectShared(model: "claude-sonnet-5", account: .anthropic, kind: .llm, replaceCustom: false)
        XCTAssertEqual(env.routing.route(for: .translation)?.model, "claude-haiku-5-5", "custom kept")
        XCTAssertEqual(env.routing.route(for: .agent)?.model, "claude-sonnet-5")
        XCTAssertEqual(try row(.llm, vm).label, "Anthropic · claude-sonnet-5 · 1 custom")

        await vm.selectShared(model: "claude-sonnet-5", account: .anthropic, kind: .llm, replaceCustom: true)
        XCTAssertEqual(env.routing.route(for: .translation)?.model, "claude-sonnet-5")
        XCTAssertEqual(try row(.llm, vm).label, "Anthropic · claude-sonnet-5")
        XCTAssertEqual(APIAndModelsView.replaceQuestion(1), "1 feature has its own model. Replace it too?")
    }

    func test_older_mac_with_different_models_reads_as_mixed_and_nothing_moves() throws {
        let env = try makeEnv(snapshots: [.openRouter: fresh([llm("a/one"), llm("b/two")]),
                                          .anthropic: fresh([llm("claude-opus-5")])],
                              keyed: [.openRouter, .anthropic, .elevenLabs])
        let routes: [AIFeature: FeatureRoute] = [
            .dropSmartCleanup: FeatureRoute(account: .openRouter, model: "a/one"),
            .meetingNotes: FeatureRoute(account: .openRouter, model: "b/two"),
            .translation: FeatureRoute(account: .openRouter, model: "b/two"),
            .agent: FeatureRoute(account: .anthropic, model: "claude-opus-5"),
            .dropFast: FeatureRoute(account: .elevenLabs, model: "scribe_v3_live"),
            .dropSmart: FeatureRoute(account: .elevenLabs, model: "scribe_v3_live"),
            .agentVoice: FeatureRoute(account: .elevenLabs, model: "scribe_v3_live"),
            .voiceSearch: FeatureRoute(account: .elevenLabs, model: "scribe_v3_live"),
            .meetings: FeatureRoute(account: .elevenLabs, model: "scribe_v3"),
        ]
        for (feature, route) in routes { env.routing.setRoute(route, for: feature) }
        let before = env.routing.state
        let vm = env.makeViewModel()
        XCTAssertEqual(env.routing.state, before, "reading the shared rows changes no route")
        let text = try row(.llm, vm)
        XCTAssertTrue(text.isMixed)
        XCTAssertEqual(text.label, "Mixed · 4 custom")
        XCTAssertNil(text.choice)
        XCTAssertEqual(try row(.speech, vm).label, "ElevenLabs · scribe_v3_live", "Scribe v3 on Meetings follows v3 Live")
        XCTAssertFalse(try row(.speech, vm).isMixed)
    }

    func test_speech_provider_without_a_usable_recorded_model_says_which_feature_missed_out() async throws {
        let env = try makeEnv(keyed: [.soniox])
        env.checks.store(.failed(reason: "answered 403"),
                         for: ModelCheckKey(account: ProviderAccount.soniox.storageID, model: ModelRegistry.sonioxRecordedModel, use: .asyncSTT),
                         adapterVersion: 1, at: Date())
        let vm = env.makeViewModel()
        await vm.selectShared(model: ModelRegistry.sonioxRealtimeModel, account: .soniox, kind: .speech, replaceCustom: false)
        XCTAssertNil(env.routing.route(for: .meetings))
        XCTAssertEqual(env.routing.route(for: .dropSmart)?.model, ModelRegistry.sonioxRealtimeModel)
        let shared = try row(.speech, vm)
        XCTAssertEqual(shared.label, "Soniox · stt-rt-v6 · 1 not set")
        XCTAssertEqual(shared.uncovered.map(\.feature), [.meetings])
        XCTAssertEqual(shared.notes.count, 1)
        XCTAssertTrue(shared.notes[0].hasPrefix("Meetings: "), shared.notes[0])
        XCTAssertTrue(APIAndModelsView.sharedStatusLines(shared).allSatisfy { $0.hasPrefix("Meetings: ") })
    }

    // OpenAI speech on the shared OpenAI key: one pick in Speech sets the four
    // live features; Meetings has no OpenAI model and says so. The picker
    // has an OpenAI section with the live models and the turn-based ones from
    // the catalog, the diarizing model left out.
    // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
    func test_openai_speech_pick_sets_live_features_and_names_meetings() async throws {
        let catalog = try ModelCatalogFetcher.parseOpenAI(Data(#"""
        {"data":[{"id":"gpt-live-transcribe","created":1790000000},{"id":"gpt-realtime-whisper"},
                 {"id":"gpt-4o-mini-transcribe"},{"id":"gpt-4o-transcribe-diarize"},{"id":"gpt-6"},
                 {"id":"gpt-realtime-translate"}]}
        """#.utf8))
        let env = try makeEnv(snapshots: [.openAI: fresh(catalog)], keyed: [.openAI])
        let vm = env.makeViewModel()

        // One live model on offer, with its price; the catalog's other
        // transcription models are not.
        // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
        let section = try XCTUnwrap(vm.sections(for: SharedModelKind.speech.pickerFeature).first { $0.account == .openAI })
        XCTAssertEqual(section.options.map(\.model), ["gpt-live-transcribe"])
        XCTAssertNil(section.options.first?.hint)
        XCTAssertEqual(section.options.first?.priceLabel, "$0.017 per min")

        let picked = await vm.selectShared(model: ModelRegistry.openAILiveModel, account: .openAI,
                                           kind: .speech, replaceCustom: false)
        XCTAssertTrue(picked)
        XCTAssertTrue(env.probe.calls.isEmpty, "built-in speech models need no check")
        for feature in [AIFeature.dropFast, .dropSmart, .agentVoice, .voiceSearch] {
            XCTAssertEqual(env.routing.route(for: feature), FeatureRoute(account: .openAI, model: "gpt-live-transcribe"))
        }
        XCTAssertNil(env.routing.route(for: .meetings))
        let shared = try row(.speech, vm)
        XCTAssertEqual(shared.label, "OpenAI · gpt-live-transcribe · 1 not set")
        XCTAssertEqual(shared.uncovered.map(\.feature), [.meetings])
        XCTAssertEqual(shared.uncovered.first?.skipReason, "OpenAI can't serve Meetings")
    }

    func test_self_hosted_server_serves_its_kinds_with_one_check_each() async throws {
        let env = try makeEnv(keyed: [])
        let server = env.routing.addServer(name: "Lab", baseURL: "http://localhost:8000/v1")
        env.routing.addModel(ServerModel(name: "whisper-large-v3", kind: .transcription, checked: true), toServer: server.id)
        env.routing.addModel(ServerModel(name: "qwen3:8b", kind: .llm, checked: true), toServer: server.id)
        let account = ProviderAccount.server(server.id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode([account.storageID: fresh([CatalogModel(id: "whisper-large-v3"), CatalogModel(id: "qwen3:8b")])])
            .write(to: file)
        let env2 = Env(routing: env.routing, keys: env.keys, catalogs: ModelCatalogStore(fileURL: file, fetcher: Offline()),
                       checks: env.checks, keyStatuses: env.keyStatuses)
        let vm = env2.makeViewModel()

        await vm.selectShared(model: "whisper-large-v3", account: account, kind: .speech, replaceCustom: false)
        for feature in SharedModelKind.speech.features {
            XCTAssertEqual(env.routing.route(for: feature), FeatureRoute(account: account, model: "whisper-large-v3"), "\(feature)")
        }
        XCTAssertEqual(env2.probe.calls.map(\.use), [.realtimeSTT], "Meetings on a server use the same live check")

        await vm.selectShared(model: "qwen3:8b", account: account, kind: .llm, replaceCustom: false)
        XCTAssertNil(env.routing.route(for: .agent), "a server can't serve the Agent")
        for feature in [AIFeature.dropSmartCleanup, .meetingNotes, .translation] {
            XCTAssertEqual(env.routing.route(for: feature)?.model, "qwen3:8b")
        }
        XCTAssertEqual(env2.probe.calls.map(\.use), [.realtimeSTT, .chat])
        let text = try row(.llm, vm)
        XCTAssertEqual(text.label, "localhost:8000 · qwen3:8b · 1 not set", "a server is named by its address")
        XCTAssertEqual(text.uncovered.map(\.feature), [.agent])
    }

    func test_a_failed_check_changes_nothing_and_says_why() async throws {
        let env = try makeEnv(snapshots: [.anthropic: fresh([llm("claude-opus-5")])], keyed: [.anthropic])
        env.probe.answer(.failed(reason: "answered 404"))
        let vm = env.makeViewModel()
        let applied = await vm.selectShared(model: "claude-opus-5", account: .anthropic, kind: .llm, replaceCustom: false)
        XCTAssertFalse(applied)
        XCTAssertTrue(SharedModelKind.llm.features.allSatisfy { env.routing.route(for: $0) == nil })
        let notes = try row(.llm, vm).notes
        XCTAssertTrue(notes.contains { $0.contains("answered 404") }, "\(notes)")
    }

    /// A server serves a model only as the kind the user added it as. Its
    /// LLM is refused in the shared Speech row like in Advanced, before any
    /// check or write, and so is a name the user never added; adding it as
    /// Transcription makes it a speech model.
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    func test_server_llm_is_refused_as_speech_until_added_as_transcription() async throws {
        let env = try makeEnv(keyed: [])
        let server = env.routing.addServer(name: "Lab", baseURL: "http://localhost:11434/v1")
        env.routing.addModel(ServerModel(name: "qwen3:8b", kind: .llm, checked: true), toServer: server.id)
        let account = ProviderAccount.server(server.id)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode([account.storageID: fresh([CatalogModel(id: "qwen3:8b"), CatalogModel(id: "parakeet-rt")])]).write(to: file)
        let env2 = Env(routing: env.routing, keys: env.keys, catalogs: ModelCatalogStore(fileURL: file, fetcher: Offline()),
                       checks: env.checks, keyStatuses: env.keyStatuses)
        let vm = env2.makeViewModel()
        XCTAssertNil(vm.sharedSections(.speech).first { $0.account == account }, "no Transcription model: no speech section")
        XCTAssertEqual(vm.sharedSections(.llm).first { $0.account == account }?.options.map(\.model), ["qwen3:8b"])

        // Advanced refuses it without a check.
        await vm.select(model: "qwen3:8b", account: account, for: .dropFast)
        XCTAssertNil(env.routing.route(for: .dropFast))

        for model in ["qwen3:8b", "parakeet-rt"] {
            let applied = await vm.selectShared(model: model, account: account, kind: .speech, replaceCustom: false)
            XCTAssertFalse(applied, model)
        }
        XCTAssertTrue(env2.probe.calls.isEmpty, "\(env2.probe.calls)")
        XCTAssertTrue(SharedModelKind.speech.features.allSatisfy { env.routing.route(for: $0) == nil })
        let notes = try row(.speech, vm).notes
        XCTAssertEqual(notes.count, SharedModelKind.speech.features.count)
        XCTAssertTrue(notes.allSatisfy { $0.contains("Not added to Ollama · localhost:11434 as a Transcription model") }, "\(notes)")

        // Added as Transcription, the same name is a speech model too.
        XCTAssertNil(vm.addServerModel("qwen3:8b", kind: .transcription, checked: true, to: account))
        let typed = await vm.selectShared(model: "qwen3:8b", account: account, kind: .speech, replaceCustom: false)
        XCTAssertTrue(typed)
        for feature in SharedModelKind.speech.features {
            XCTAssertEqual(env.routing.route(for: feature), FeatureRoute(account: account, model: "qwen3:8b"), "\(feature)")
        }
    }

    /// Build queue 397: the rows are recomputed when Settings opens and on
    /// every preference change, so they must not build picker lists. A
    /// 2,500-model OpenRouter cache cost 3.7 s on the main actor when they did.
    func test_rows_stay_fast_with_a_large_cached_catalog() throws {
        let models = (0..<2_500).map { llm("vendor/model-\($0)") }
        let env = try makeEnv(snapshots: [.openRouter: fresh(models)], keyed: [.openRouter])
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "vendor/model-1200"), for: .dropSmartCleanup)
        let start = Date()
        let vm = env.makeViewModel()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(try row(.llm, vm).label, "OpenRouter · vendor/model-1200 · 3 not set")
        XCTAssertLessThan(elapsed, 1.0, "view model init took \(elapsed) s")
    }

    // MARK: - Offscreen renders

    /// The top of Models in three states: nothing set, both rows filled, and
    /// an Advanced override ("· 1 custom"). Written to
    /// `WHYTAP_MODEL_METADATA_RENDER_DIR` when set; always compared by bytes.
    func test_render_shared_rows_empty_filled_and_with_an_override() async throws {
        let env = try makeEnv(snapshots: [.anthropic: fresh([llm("claude-opus-5"), llm("claude-haiku-5-5")])],
                              keyed: [.elevenLabs, .anthropic])
        let vm = env.makeViewModel()
        let empty = try await render(vm, name: "shared-empty")
        await vm.selectShared(model: ModelRegistry.elevenLabsRealtimeModel, account: .elevenLabs, kind: .speech, replaceCustom: false)
        await vm.selectShared(model: "claude-opus-5", account: .anthropic, kind: .llm, replaceCustom: false)
        let filled = try await render(vm, name: "shared-filled")
        await vm.select(model: "claude-haiku-5-5", account: .anthropic, for: .translation)
        XCTAssertEqual(try row(.llm, vm).label, "Anthropic · claude-opus-5 · 1 custom")
        let custom = try await render(vm, name: "shared-override")
        XCTAssertNotEqual(empty, filled)
        XCTAssertNotEqual(filled, custom)
    }

    private func render(_ vm: APIAndModelsViewModel, name: String) async throws -> Data {
        let view = APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil))
            .background(MacSettingsTheme.bgContent)
            .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .aqua)
        let size = NSSize(width: 720, height: 640)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        if let output = ProcessInfo.processInfo.environment["WHYTAP_MODEL_METADATA_RENDER_DIR"] {
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        }
        return png
    }
}

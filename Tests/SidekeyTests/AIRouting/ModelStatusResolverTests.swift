import XCTest
@testable import Sidekey

@MainActor
final class ModelStatusResolverTests: XCTestCase {
    @MainActor private struct Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let catalogs: ModelCatalogStore
        let checks: ModelCheckStore
        let keyStatuses: KeyStatusStore
        let resolver: ModelStatusResolver

        func addKey(_ account: ProviderAccount) {
            if let name = account.keychainAccount(in: routing) { try? keys.save("key", account: name) }
        }
    }

    private func fresh(_ models: [CatalogModel]) -> CatalogSnapshot {
        CatalogSnapshot(models: models, fetchedAt: Date(), lastRefreshFailed: false, limited: false)
    }

    private func makeEnv(
        snapshots: [ProviderAccount: CatalogSnapshot] = [:],
        keyed: [ProviderAccount] = [],
        adapterVersion: Int = 1
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

        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let checks = ModelCheckStore(defaults: defaults)
        let keyStatuses = KeyStatusStore(defaults: defaults)
        let catalogs = ModelCatalogStore(fileURL: file)
        let env = Env(
            routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses,
            resolver: ModelStatusResolver(
                routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses,
                adapterVersion: { _, _ in adapterVersion }
            )
        )
        for account in keyed { env.addKey(account) }
        return env
    }

    private func sonioxCatalog() -> CatalogSnapshot {
        fresh([
            CatalogModel(id: "stt-rt-v6", uses: [.realtimeSTT]),
            CatalogModel(id: "stt-rt-v4", uses: [.realtimeSTT], aliasOf: "stt-rt-v6"),
            CatalogModel(id: "stt-async-v6", uses: [.asyncSTT]),
        ])
    }

    func test_picker_keeps_provider_date_meanings_and_hides_unknown_dates() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z"))
        let dated = CatalogModel(id: "gpt-date-test", uses: [.chat, .chatWithTools], catalogDate: date)
        let unknown = CatalogModel(id: "gpt-unknown-date", uses: [.chat, .chatWithTools])
        let accounts: [ProviderAccount] = [.anthropic, .openAI, .openRouter]
        let env = try makeEnv(snapshots: Dictionary(uniqueKeysWithValues: accounts.map { ($0, fresh([dated, unknown])) }),
                              keyed: accounts)
        for (account, prefix) in [(ProviderAccount.anthropic, "Released "), (.openAI, "Created "),
                                  (.openRouter, "Added to OpenRouter ")] {
            let options = try XCTUnwrap(env.resolver.sections(for: .dropSmartCleanup).first { $0.account == account }).options
            let label = try XCTUnwrap(options.first { $0.model == dated.id }?.dateLabel)
            XCTAssertTrue(label.hasPrefix(prefix))
            XCTAssertTrue(label.contains("2026"))
            XCTAssertNil(options.first { $0.model == unknown.id }?.dateLabel)
            XCTAssertNil(ModelStatusResolver.catalogDateLabel(Date(timeIntervalSince1970: 0), account: account))
        }
        XCTAssertNil(ModelStatusResolver.catalogDateLabel(date, account: .server(UUID())))
    }

    func test_speech_picker_uses_documented_releases_and_live_deepgram_updates() throws {
        let json = #"""
        {"stt":[
          {"canonical_name":"nova-3-general","streaming":true,"batch":true,"version":"2026-10-20.1"},
          {"canonical_name":"nova-3-general","streaming":true,"batch":true,"version":"2026-10-15.0"},
          {"canonical_name":"nova-3-medical","streaming":true,"batch":true,"version":"2026-10-06.0"},
          {"canonical_name":"nova-undated","streaming":true,"batch":true,"version":"latest"}
        ]}
        """#
        let models = try ModelCatalogFetcher.parseDeepgram(Data(json.utf8))
        let env = try makeEnv(snapshots: [.deepgram: fresh(models)], keyed: [.soniox, .deepgram, .elevenLabs])
        let sections = env.resolver.sections(for: .meetings)
        for (account, model, day) in [(ProviderAccount.soniox, "stt-async-v6", "2026-11-03"),
                                      (.elevenLabs, "scribe_v3", "2026-11-10")] {
            let option = try XCTUnwrap(sections.first { $0.account == account }?.options.first { $0.model == model })
            XCTAssertTrue(try XCTUnwrap(option.dateLabel).hasPrefix("Released "))
            XCTAssertEqual(option.catalogDate, ModelCatalogFetcher.deepgramVersionDate(day))
        }
        // Meetings offer the recorded Scribe model, never the streaming one.
        let meetingScribe = try XCTUnwrap(sections.first { $0.account == .elevenLabs }?.options.map(\.model))
        XCTAssertFalse(meetingScribe.contains("scribe_v3_live"), "\(meetingScribe)")
        let speechOptions = try XCTUnwrap(env.resolver.sections(for: .dropFast).first { $0.account == .soniox }?.options)
        XCTAssertEqual(speechOptions.first { $0.model == "stt-rt-v6" }?.catalogDate,
                       ModelCatalogFetcher.deepgramVersionDate("2026-11-03"))
        XCTAssertEqual(ModelRegistry.documentedReleaseDate(for: "scribe_v2", kind: .elevenLabs),
                       ModelCatalogFetcher.deepgramVersionDate("2026-01-09"))
        XCTAssertNil(ModelRegistry.documentedReleaseDate(for: "stt-rt-v7", kind: .soniox))
        XCTAssertNil(ModelRegistry.documentedReleaseDate(for: "scribe_v3_realtime", kind: .elevenLabs))
        XCTAssertNil(ModelRegistry.documentedReleaseDate(for: "stt-rt-v6", kind: .openAICompatible))

        let deepgram = try XCTUnwrap(sections.first { $0.account == .deepgram })
        XCTAssertTrue(try XCTUnwrap(deepgram.options.first { $0.model == "nova-3" }?.dateLabel).hasPrefix("Updated "))
        XCTAssertEqual(deepgram.options.first { $0.model == "nova-3" }?.catalogDate,
                       ModelCatalogFetcher.deepgramVersionDate("2026-10-20"))
        let sorted = ModelPickerSearch.results(in: [deepgram], query: "nova")
        XCTAssertEqual(sorted.map(\.option.model), ["nova-3"], "the rest of Deepgram's catalog is not offered")
    }

    func test_prod_after_migration_shows_one_switch_for_four_features() throws {
        let env = try makeEnv(snapshots: [.soniox: sonioxCatalog()], keyed: [.soniox])
        let rt = FeatureRoute(account: .soniox, model: "stt-rt-v4")
        env.routing.completeMigration(
            routes: [
                .dropFast: rt, .dropSmart: rt, .agentVoice: rt, .voiceSearch: rt,
                .meetings: FeatureRoute(account: .soniox, model: "stt-async-v6"),
            ],
            servers: []
        )

        XCTAssertEqual(env.resolver.aliasGroups(), [AliasGroupAction(
            account: .soniox, from: "stt-rt-v4", to: "stt-rt-v6",
            features: [.dropFast, .dropSmart, .agentVoice, .voiceSearch]
        )])
        XCTAssertEqual(env.resolver.status(for: .dropFast), .deprecatedAlias(of: "stt-rt-v6"))
        XCTAssertEqual(env.resolver.status(for: .meetings), .ok)
    }

    func test_migrated_model_without_problem_signs_has_no_badge() throws {
        let model = "vendor/legacy-model"
        let env = try makeEnv(
            snapshots: [.openRouter: fresh([CatalogModel(id: model, uses: [.chat])])], keyed: [.openRouter]
        )
        let route = FeatureRoute(account: .openRouter, model: model)
        env.routing.completeMigration(routes: [.dropSmartCleanup: route], servers: [])

        XCTAssertEqual(env.resolver.status(for: .dropSmartCleanup), .ok)
    }

    func test_adapter_version_bump_marks_unregistered_models_not_verified() throws {
        let model = "vendor/legacy-model"
        let snapshot = fresh([
            CatalogModel(id: model, uses: [.chat]),
            CatalogModel(id: "google/gemini-3.8-flash", uses: [.chat]),
        ])
        let route = FeatureRoute(account: .openRouter, model: model)

        let bumped = try makeEnv(snapshots: [.openRouter: snapshot], keyed: [.openRouter], adapterVersion: 2)
        bumped.routing.completeMigration(routes: [.dropSmartCleanup: route], servers: [])
        let key = ModelCheckKey(account: "openRouter", model: model, use: .chat)
        bumped.checks.store(.passed, for: key, adapterVersion: 1, at: Date())
        XCTAssertEqual(bumped.resolver.status(for: .dropSmartCleanup), .notVerified)

        bumped.checks.store(.passed, for: key, adapterVersion: 2, at: Date())
        XCTAssertEqual(bumped.resolver.status(for: .dropSmartCleanup), .ok)

        // A registry model stays checked across a bump.
        bumped.routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .meetingNotes)
        XCTAssertEqual(bumped.resolver.status(for: .meetingNotes), .ok)
    }

    func test_removed_only_when_the_catalog_is_authoritative() throws {
        let route = FeatureRoute(account: .openRouter, model: "vendor/gone")
        let other = [CatalogModel(id: "vendor/other", uses: [.chat])]
        let cases: [(CatalogSnapshot, ModelRowStatus)] = [
            (CatalogSnapshot(models: other, fetchedAt: Date(), lastRefreshFailed: true, limited: false), .ok),
            (CatalogSnapshot(models: other, fetchedAt: Date(), lastRefreshFailed: false, limited: true), .ok),
            (fresh(other), .removedByProvider),
        ]
        for (snapshot, expected) in cases {
            let env = try makeEnv(snapshots: [.openRouter: snapshot], keyed: [.openRouter])
            env.routing.completeMigration(routes: [.dropSmartCleanup: route], servers: [])
            XCTAssertEqual(env.resolver.status(for: .dropSmartCleanup), expected)
        }
    }

    func test_deepgram_versions_give_the_newest_update_date() throws {
        let json = #"""
        {"stt":[
          {"canonical_name":"nova-3-general","streaming":true,"batch":true,"version":"2026-10-15.0"},
          {"canonical_name":"nova-3-general","streaming":true,"batch":true,"version":"2025-02-25.0"},
          {"canonical_name":"whisper-large","streaming":false,"batch":true,"version":"2022-12-08.0"},
          {"canonical_name":"odd","streaming":true,"batch":true,"version":"latest"}
        ]}
        """#
        let models = try ModelCatalogFetcher.parseDeepgram(Data(json.utf8))
        let day = { (s: String) in ModelCatalogFetcher.deepgramVersionDate(s) }
        XCTAssertEqual(models.first { $0.id == "nova-3" }?.updatedAt, day("2026-10-15"), "the -general alias shares the date")
        XCTAssertEqual(models.first { $0.id == "nova-3-general" }?.updatedAt, day("2026-10-15"))
        XCTAssertEqual(models.first { $0.id == "whisper-large" }?.updatedAt, day("2022-12-08"))
        XCTAssertNil(models.first { $0.id == "odd" }?.updatedAt, "an undated model is never hidden")
    }

    /// The owner's decision: Deepgram's other rows are noise. Only Nova-3 is
    /// offered, for live and recorded features alike; a saved route stays.
    func test_deepgram_picker_offers_only_nova_3_and_keeps_a_saved_route() throws {
        let fetched = try XCTUnwrap(ModelCatalogFetcher.deepgramVersionDate("2026-10-19"))
        let day = { (s: String) in ModelCatalogFetcher.deepgramVersionDate(s) }
        let models = [
            CatalogModel(id: "nova-3", uses: [.realtimeSTT, .asyncSTT], updatedAt: day("2026-10-15")),
            CatalogModel(id: "nova-3-medical", uses: [.realtimeSTT, .asyncSTT], updatedAt: day("2026-10-06")),
            CatalogModel(id: "nova-2-general", uses: [.realtimeSTT, .asyncSTT], updatedAt: day("2025-03-31")),
            CatalogModel(id: "nova-2-meeting", uses: [.realtimeSTT, .asyncSTT], updatedAt: day("2024-02-07")),
            CatalogModel(id: "enhanced-general", uses: [.realtimeSTT, .asyncSTT], updatedAt: day("1983-05-08")),
        ]
        let snapshot = CatalogSnapshot(models: models, fetchedAt: fetched, lastRefreshFailed: false, limited: false)
        let env = try makeEnv(snapshots: [.deepgram: snapshot], keyed: [.deepgram])
        env.routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-2-meeting"), for: .dropFast)

        let ids = try XCTUnwrap(env.resolver.sections(for: .dropFast).first).options.map(\.model)
        XCTAssertEqual(Set(ids), ["nova-3", "nova-2-meeting"], "the saved model stays selectable on its own feature")
        XCTAssertNotEqual(env.resolver.status(for: .dropFast), .removedByProvider, "a hidden model is not removed")
        XCTAssertEqual(env.routing.route(for: .dropFast)?.model, "nova-2-meeting", "the route is not rewritten")
        for feature in [AIFeature.voiceSearch, .agentVoice, .subtitlesAudio, .meetings] {
            let offered = try XCTUnwrap(env.resolver.sections(for: feature).first).options.map(\.model)
            XCTAssertEqual(offered, ["nova-3"], "\(feature)")
        }
        XCTAssertTrue(ModelRegistry.offersOnlyBuiltInModels(.soniox))
        XCTAssertFalse(ModelRegistry.offersOnlyBuiltInModels(.elevenLabs))
        XCTAssertFalse(ModelRegistry.offersOnlyBuiltInModels(.openRouter))
    }

    func test_deepgram_nova_3_is_not_removed() throws {
        let json = #"{"stt":[{"canonical_name":"nova-3-general","streaming":true,"batch":true}]}"#
        let models = try ModelCatalogFetcher.parseDeepgram(Data(json.utf8))
        let env = try makeEnv(snapshots: [.deepgram: fresh(models)], keyed: [.deepgram])
        env.routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .dropFast)

        XCTAssertEqual(env.resolver.status(for: .dropFast), .ok)
    }

    func test_agent_picker_marks_models_without_tools() throws {
        let env = try makeEnv(
            snapshots: [.openRouter: fresh([
                CatalogModel(id: "x/with-tools", uses: [.chat, .chatWithTools], contextLength: 128_000, supportsTools: true),
                CatalogModel(id: "x/no-tools", uses: [.chat], contextLength: 128_000, supportsTools: false),
            ])],
            keyed: [.openRouter]
        )
        let section = try XCTUnwrap(env.resolver.sections(for: .agent).first)

        XCTAssertEqual(section.options.map(\.model), ["anthropic/claude-sonnet-5.5", "x/with-tools"],
                       "a model without tools is left out of the agent picker")
        XCTAssertEqual(section.options.map(\.state), [.verified, .new])
    }

    func test_small_context_is_not_supported_for_agent_and_notes() throws {
        let env = try makeEnv(
            snapshots: [.openRouter: fresh([CatalogModel(id: "x/tiny", uses: [.chat, .chatWithTools], contextLength: 8_000, supportsTools: true)])],
            keyed: [.openRouter]
        )
        for feature in [AIFeature.agent, .meetingNotes] {
            XCTAssertEqual(
                env.resolver.verdict(model: "x/tiny", account: .openRouter, for: feature),
                .notSupported(reason: "context under 64K tokens")
            )
        }
        XCTAssertEqual(env.resolver.verdict(model: "x/tiny", account: .openRouter, for: .dropSmartCleanup), .new)
    }

    /// Soniox keeps deprecated versions in its catalog; only v6 is offered.
    func test_soniox_picker_offers_only_v6_and_keeps_a_saved_route() throws {
        let catalog = fresh([
            CatalogModel(id: "stt-rt-v6", uses: [.realtimeSTT]),
            CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT]),
            CatalogModel(id: "stt-rt-v3", uses: [.realtimeSTT]),
            CatalogModel(id: "stt-async-v6", uses: [.asyncSTT]),
            CatalogModel(id: "stt-async-v5", uses: [.asyncSTT]),
        ])
        let env = try makeEnv(snapshots: [.soniox: catalog], keyed: [.soniox])
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v3"), for: .agentVoice)

        XCTAssertEqual(try XCTUnwrap(env.resolver.sections(for: .dropFast).first).options.map(\.model), ["stt-rt-v6"])
        XCTAssertEqual(try XCTUnwrap(env.resolver.sections(for: .meetings).first).options.map(\.model), ["stt-async-v6"])
        XCTAssertEqual(Set(try XCTUnwrap(env.resolver.sections(for: .agentVoice).first).options.map(\.model)),
                       ["stt-rt-v6", "stt-rt-v3"], "a saved model stays listed on its own feature")
    }

    func test_soniox_meetings_offer_async_models_only() throws {
        let env = try makeEnv(snapshots: [.soniox: sonioxCatalog()], keyed: [.soniox])
        let section = try XCTUnwrap(env.resolver.sections(for: .meetings).first)

        XCTAssertEqual(section.options.map(\.model), ["stt-async-v6"])
        XCTAssertEqual(section.options.first?.hint, "with speakers")
        XCTAssertFalse(section.options.contains { $0.model == "stt-rt-v4" })
    }

    func test_picker_lists_only_keyed_providers_that_support_the_feature() throws {
        let env = try makeEnv(keyed: [.soniox, .openRouter])
        let b = env.routing.addServer(name: "b-box", baseURL: "http://b:8000/v1")
        let a = env.routing.addServer(name: "A-box", baseURL: "http://a:8000/v1")

        XCTAssertEqual(
            env.resolver.sections(for: .dropFast).map(\.account),
            [.soniox, .server(a.id), .server(b.id)]
        )
        XCTAssertEqual(
            env.resolver.sections(for: .dropSmartCleanup).map(\.account),
            [.openRouter, .server(a.id), .server(b.id)]
        )
        XCTAssertEqual(env.resolver.sections(for: .agent).map(\.account), [.openRouter])
        XCTAssertEqual(env.resolver.sections(for: .dropFast).first?.title, "Soniox")
        XCTAssertEqual(env.resolver.sections(for: .dropFast).dropFirst().first?.title, "A-box")
    }

    func test_missing_provider_hint_lists_providers_for_the_feature() throws {
        let env = try makeEnv()
        XCTAssertEqual(env.resolver.missingProviderHint(for: .agent), "Add a key for OpenRouter, OpenAI or Anthropic")
        XCTAssertEqual(
            env.resolver.missingProviderHint(for: .dropFast),
            "Add a key for Soniox, Deepgram, ElevenLabs or an OpenAI-compatible server"
                + (HostArchitecture.isAppleSilicon ? ", or download the On this Mac model" : "")
        )
        env.addKey(.soniox)
        XCTAssertNil(env.resolver.missingProviderHint(for: .dropFast))
    }

    func test_rejected_key_shows_key_problem() throws {
        let env = try makeEnv(snapshots: [.soniox: sonioxCatalog()], keyed: [.soniox])
        env.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v6"), for: .dropFast)
        XCTAssertEqual(env.resolver.status(for: .dropFast), .ok)

        env.keyStatuses.set(.rejected(.invalidKey), for: .soniox, at: Date())
        XCTAssertEqual(env.resolver.status(for: .dropFast), .keyProblem)

        let keyless = try makeEnv()
        keyless.routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v6"), for: .dropFast)
        XCTAssertEqual(keyless.resolver.status(for: .dropFast), .notSet)
        XCTAssertEqual(keyless.resolver.status(for: .meetings), .notSet)
    }

    func test_runtime_refusal_shows_until_the_model_changes() throws {
        let env = try makeEnv(keyed: [.openRouter])
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "vendor/refused"), for: .dropSmartCleanup)
        env.checks.recordRefusal(feature: .dropSmartCleanup, model: "vendor/refused", at: Date())
        XCTAssertEqual(
            env.resolver.status(for: .dropSmartCleanup),
            .notSupported(reason: "The provider refused this model")
        )

        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .dropSmartCleanup)
        XCTAssertEqual(env.resolver.status(for: .dropSmartCleanup), .ok)
    }

    func test_failed_probe_and_reasoning_hint() throws {
        let env = try makeEnv(
            snapshots: [.openRouter: fresh([
                CatalogModel(id: "x/thinker", uses: [.chat], reasoning: OpenRouterReasoningCapabilities(mandatory: true, supportedEfforts: nil)),
                CatalogModel(id: "x/broken", uses: [.chat]),
            ])],
            keyed: [.openRouter]
        )
        env.checks.store(
            .failed(reason: "answered 400"),
            for: ModelCheckKey(account: "openRouter", model: "x/broken", use: .chat),
            adapterVersion: 1, at: Date()
        )
        XCTAssertEqual(
            env.resolver.verdict(model: "x/broken", account: .openRouter, for: .dropSmartCleanup),
            .notSupported(reason: "answered 400")
        )
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "x/broken"), for: .dropSmartCleanup)
        XCTAssertEqual(env.resolver.status(for: .dropSmartCleanup), .notSupported(reason: "answered 400"))

        let options = try XCTUnwrap(env.resolver.sections(for: .dropSmartCleanup).first).options
        XCTAssertEqual(options.first { $0.model == "x/thinker" }?.hint, "always reasons, slower")
        XCTAssertNil(options.first { $0.model == "google/gemini-3.8-flash" }?.hint)
    }

    private func price(_ input: Decimal, _ output: Decimal) -> CatalogTokenPrice? {
        CatalogTokenPrice(promptPerToken: input / 1_000_000, completionPerToken: output / 1_000_000)
    }

    func test_price_label_formats_per_million_and_never_rounds_a_price_to_zero() throws {
        let label = { (input: Decimal, output: Decimal) in
            ModelStatusResolver.catalogPriceLabel(self.price(input, output), account: .openRouter)
        }
        XCTAssertEqual(label(1.25, 10), "$1.25 in / $10 out per 1M tokens")
        XCTAssertEqual(label(0.075, 0.3), "$0.075 in / $0.3 out per 1M tokens")
        XCTAssertEqual(label(0.0375, 0.15), "$0.0375 in / $0.15 out per 1M tokens")
        XCTAssertEqual(label(15, 75), "$15 in / $75 out per 1M tokens")
        XCTAssertEqual(label(1250, 2.505), "$1250 in / $2.5 out per 1M tokens")
        XCTAssertEqual(label(0.000004, 0.00123456), "$0.000004 in / $0.00123 out per 1M tokens")
        // One free side is still a paid model.
        XCTAssertEqual(label(0, 0.4), "$0 in / $0.4 out per 1M tokens")
        XCTAssertEqual(label(0, 0), "Free")
    }

    func test_price_label_is_absent_for_unknown_prices_and_other_providers() throws {
        XCTAssertNil(ModelStatusResolver.catalogPriceLabel(nil, account: .openRouter))
        XCTAssertNil(CatalogTokenPrice(promptPerToken: nil, completionPerToken: 0))
        XCTAssertNil(CatalogTokenPrice(promptPerToken: 0, completionPerToken: nil))
        XCTAssertNil(CatalogTokenPrice(promptPerToken: -1, completionPerToken: -1))
        for account in [ProviderAccount.openAI, .anthropic, .soniox, .deepgram, .elevenLabs, .server(UUID())] {
            XCTAssertNil(ModelStatusResolver.catalogPriceLabel(price(1, 2), account: account))
        }
    }

    func test_picker_shows_prices_only_on_openrouter_rows_without_changing_the_choice() throws {
        let priced = CatalogModel(id: "vendor/priced", uses: [.chat, .chatWithTools], tokenPrice: price(0.3, 2.5))
        let free = CatalogModel(id: "vendor/free", uses: [.chat, .chatWithTools], tokenPrice: price(0, 0))
        let unknown = CatalogModel(id: "vendor/unknown", uses: [.chat, .chatWithTools])
        let accounts: [ProviderAccount] = [.openRouter, .openAI]
        let models = [priced, free, unknown]
        let env = try makeEnv(snapshots: Dictionary(uniqueKeysWithValues: accounts.map { ($0, fresh(models)) }),
                              keyed: accounts)
        let sections = env.resolver.sections(for: .dropSmartCleanup)
        let openRouter = try XCTUnwrap(sections.first { $0.account == .openRouter }).options
        XCTAssertEqual(openRouter.first { $0.model == priced.id }?.priceLabel, "$0.3 in / $2.5 out per 1M tokens")
        XCTAssertEqual(openRouter.first { $0.model == free.id }?.priceLabel, "Free")
        let unpriced = try XCTUnwrap(openRouter.first { $0.model == unknown.id })
        XCTAssertNil(unpriced.priceLabel)
        // The same catalog rows under another provider never get a price.
        let openAI = try XCTUnwrap(sections.first { $0.account == .openAI }).options
        XCTAssertTrue(models.allSatisfy { model in openAI.contains { $0.model == model.id } })
        XCTAssertTrue(openAI.allSatisfy { $0.priceLabel == nil })
        // Built-in registry models absent from the catalog have no price either.
        XCTAssertTrue(openRouter.filter { option in !models.contains { $0.id == option.model } }
            .allSatisfy { $0.priceLabel == nil })

        // Display only: a price changes neither the state nor the search results.
        let plain = try makeEnv(
            snapshots: [.openRouter: fresh(models.map { var model = $0; model.tokenPrice = nil; return model })],
            keyed: [.openRouter])
        let plainOptions = try XCTUnwrap(plain.resolver.sections(for: .dropSmartCleanup).first).options
        XCTAssertEqual(plainOptions.map(\.model), openRouter.map(\.model))
        XCTAssertEqual(plainOptions.map(\.state), openRouter.map(\.state))
        let found = ModelPickerSearch.results(in: sections, query: "0.3").map(\.option.model)
        XCTAssertFalse(found.contains(priced.id), "a price is not searchable text")
    }
}

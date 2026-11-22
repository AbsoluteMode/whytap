import XCTest
@testable import Sidekey

/// On-device models were removed. A user whose audio and text stayed on this
/// Mac, by choosing Local or by never choosing on Apple Silicon (where Local
/// was the default), must not start sending them to a provider until they
/// choose one in Settings, even when a provider key is stored.
@MainActor
final class RetiredLocalRouteTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "retired.local.\(UUID().uuidString)")!
    }

    private func retiredLocalDefaults() -> UserDefaults {
        let defaults = makeDefaults()
        defaults.set("local", forKey: "sidekey.models.transcriptionLevel")
        defaults.set("local", forKey: "sidekey.models.llmLevel")
        return defaults
    }

    func test_storedLocalLevels_areNotConfigured_onAnyHardware() {
        for isAppleSilicon in [true, false] {
            let prefs = SelfKeyPreferences(defaults: retiredLocalDefaults(), isAppleSilicon: isAppleSilicon)
            XCTAssertNil(prefs.transcriptionLevel, "appleSilicon=\(isAppleSilicon)")
            XCTAssertNil(prefs.llmLevel, "appleSilicon=\(isAppleSilicon)")
        }
    }

    func test_noStoredLevel_onAppleSilicon_isNotConfigured() {
        let prefs = SelfKeyPreferences(defaults: makeDefaults(), isAppleSilicon: true)
        XCTAssertNil(prefs.transcriptionLevel)
        XCTAssertNil(prefs.llmLevel)
    }

    func test_noStoredLevel_onIntel_staysYourKey() {
        let prefs = SelfKeyPreferences(defaults: makeDefaults(), isAppleSilicon: false)
        XCTAssertEqual(prefs.transcriptionLevel, .yourKey)
        XCTAssertEqual(prefs.llmLevel, .yourKey)
    }

    /// The one-time migration over a Keychain that holds a Soniox key, with the
    /// old settings in `defaults`. Returns the factory built on its result.
    private func migratedFactory(
        defaults: UserDefaults, isAppleSilicon: Bool, mutate: (SelfKeyPreferences) -> Void = { _ in }
    ) throws -> (factory: TranscriptionSessionFactory, adapters: AdapterLog) {
        let prefs = SelfKeyPreferences(defaults: defaults, isAppleSilicon: isAppleSilicon)
        mutate(prefs)
        let routing = AIRoutingStore(defaults: makeDefaults())
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("soniox-key", account: BYOKKeyStore.account(for: .soniox))
        AIRoutingMigration(prefs: prefs, defaults: defaults, routing: routing, keys: keys).run()
        let log = AdapterLog()
        let factory = TranscriptionSessionFactory(
            resolver: FeatureRouteResolver(routing: routing, keys: keys),
            vocab: VocabularyCache(defaults: makeDefaults()),
            makeAdapter: { route in
                log.count += 1
                return try RealtimeAdapterFactory.make(route)
            }
        )
        return (factory, log)
    }

    private final class AdapterLog {
        var count = 0
    }

    func test_drop_withRetiredLocal_doesNotUseStoredProviderKey() throws {
        for isAppleSilicon in [true, false] {
            let (factory, adapters) = try migratedFactory(
                defaults: retiredLocalDefaults(), isAppleSilicon: isAppleSilicon
            ) { $0.selectedProvider = .soniox }
            XCTAssertThrowsError(try factory.make(feature: .dropFast, language: "en"), "appleSilicon=\(isAppleSilicon)") {
                XCTAssertEqual($0 as? FeatureRouteError, .notSet(.dropFast))
            }
            XCTAssertEqual(adapters.count, 0)
        }
    }

    func test_appleSilicon_withoutALevel_doesNotUseStoredProviderKey() throws {
        let (factory, adapters) = try migratedFactory(defaults: makeDefaults(), isAppleSilicon: true) {
            $0.selectedProvider = .soniox
        }
        XCTAssertThrowsError(try factory.make(feature: .dropFast, language: "en")) {
            XCTAssertEqual($0 as? FeatureRouteError, .notSet(.dropFast))
        }
        XCTAssertEqual(adapters.count, 0)
    }

    func test_cleanup_withoutChoice_doesNotUseStoredOpenRouterKey() async throws {
        // The OpenRouter key may come from Settings -> Agents; it does not
        // choose where Drop cleanup or meeting notes go.
        for defaults in [retiredLocalDefaults(), makeDefaults()] {
            let prefs = SelfKeyPreferences(defaults: defaults, isAppleSilicon: true)
            let routing = AIRoutingStore(defaults: makeDefaults())
            let box = InMemoryTokenStore.Box()
            let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
            try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
            AIRoutingMigration(prefs: prefs, defaults: defaults, routing: routing, keys: keys).run()

            let client = SpyLLMClient()
            let processor = PostProcessor(
                llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys),
                openRouterClient: client
            )
            do {
                let cleaned = try await processor.process("raw")
                XCTFail("expected no cleanup, got \(cleaned)")
            } catch let error as OpenRouterLLMError {
                XCTAssertEqual(error, .notConfigured)
            }
            XCTAssertEqual(client.completeCalls, 0)

            let meetingRoute = try await DirectLLMRouteResolver(
                feature: .meetingNotes, routing: routing, keys: keys
            ).routeIfEnabled()
            XCTAssertNil(meetingRoute)
        }
    }

    func test_meetings_withRetiredLocal_areNotProcessedByProviders() throws {
        // The retired on-device level migrates to no routes, even with keys
        // stored: nothing picks a provider for the meeting by itself.
        let defaults = retiredLocalDefaults()
        let prefs = SelfKeyPreferences(defaults: defaults, isAppleSilicon: true)
        prefs.selectedProvider = .soniox
        let routing = AIRoutingStore(defaults: makeDefaults())
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("soniox-key", account: BYOKKeyStore.account(for: .soniox))
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        AIRoutingMigration(prefs: prefs, defaults: defaults, routing: routing, keys: keys).run()
        let processor = MeetingBYOKProcessor(
            routing: routing,
            keys: keys,
            vocab: VocabularyCache(defaults: makeDefaults()),
            notesRoute: DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys)
        )
        XCTAssertFalse(processor.shouldProcessDirectly())
    }

    func test_choosingYourKey_afterRetiredLocal_buildsProviderSession() throws {
        let (factory, adapters) = try migratedFactory(defaults: retiredLocalDefaults(), isAppleSilicon: true) {
            $0.selectedProvider = .soniox
            $0.transcriptionLevel = .yourKey
        }
        XCTAssertTrue(try factory.make(feature: .dropFast, language: "en") is DirectProviderStreamingSession)
        XCTAssertEqual(adapters.count, 1)
    }
}

private final class SpyLLMClient: OpenRouterLLMClienting {
    private(set) var completeCalls = 0

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] { [] }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        completeCalls += 1
        return "cleaned"
    }
}

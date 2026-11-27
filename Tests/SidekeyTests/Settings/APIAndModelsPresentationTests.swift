import XCTest
@testable import Sidekey

/// The Settings -> Models model lives for the app's whole life, but only the
/// Settings window shows it. Its recompute reads every provider key from the
/// Keychain on the main thread, so a defaults write from the island (Drop
/// Mode, languages) must not pay for it while the window is closed.
// WHY: .project-docs/decisions/2026-11-27-settings-models-recompute-while-hidden.md
@MainActor
final class APIAndModelsPresentationTests: XCTestCase {
    private final class Counter: @unchecked Sendable { var reads = 0 }

    private struct CountingStore: TokenStore {
        let inner: InMemoryTokenStore
        let counter: Counter
        func save(_ token: String) throws { try inner.save(token) }
        func read() throws -> String? { counter.reads += 1; return try inner.read() }
        func delete() throws { try inner.delete() }
    }

    private struct Offline: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            throw CatalogFetchError.offline
        }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
    }

    private var defaults: UserDefaults!
    private var routing: AIRoutingStore!
    private var keys: ProviderKeyStore!
    private let counter = Counter()

    override func setUp() async throws {
        let suite = "APIAndModelsPresentationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        try Data("{}".utf8).write(to: file)
        addTeardownBlock { [defaults] in
            defaults?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let counter = counter
        keys = ProviderKeyStore(makeStore: { CountingStore(inner: InMemoryTokenStore(account: $0, box: box), counter: counter) })
        try keys.save("synthetic-key", account: XCTUnwrap(ProviderAccount.soniox.keychainAccount(in: routing)))
    }

    private func makeModel() -> APIAndModelsViewModel {
        let offline = Offline()
        let catalogs = ModelCatalogStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json"),
            fetcher: offline
        )
        return APIAndModelsViewModel(
            routing: routing, keys: keys, catalogs: catalogs,
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults),
            keyChecker: offline, probe: offline, endpoints: offline, inputLanguage: { nil },
            onDevice: OnDeviceSpeechReadiness(isReady: { false }),
            agentSettings: AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing, catalogs: catalogs)
        )
    }

    /// A key added by another Mac (Settings Sync) or the app control plugin,
    /// followed by a preference write, as the island's Drop Mode toggle does.
    private func addOpenRouterKeyAndWriteDefaults() throws {
        try keys.save("synthetic-key", account: XCTUnwrap(ProviderAccount.openRouter.keychainAccount(in: routing)))
        defaults.set(UUID().uuidString, forKey: "probe.transcriptionMode")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    /// Longer than the model's 100 ms debounce.
    private func waitPastDebounce() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    }

    func testClosedSettingsWindowSkipsKeychainReadsOnADefaultsWrite() throws {
        let model = makeModel()
        model.setPresented(false)
        XCTAssertEqual(model.chips.map(\.account), [.soniox])
        counter.reads = 0

        try addOpenRouterKeyAndWriteDefaults()
        waitPastDebounce()

        XCTAssertEqual(counter.reads, 0, "No Keychain read on the main thread while nothing shows the model")
        XCTAssertEqual(model.chips.map(\.account), [.soniox], "Stale until shown")
    }

    func testShowingTheWindowBringsTheModelUpToDateBeforeItDraws() throws {
        let model = makeModel()
        model.setPresented(false)
        try addOpenRouterKeyAndWriteDefaults()
        waitPastDebounce()

        model.setPresented(true)

        XCTAssertEqual(model.chips.map(\.account), [.soniox, .openRouter],
                       "Synchronous: the first frame shows the key added while the window was closed")
    }

    func testShowingWithoutChangesDoesNotRecompute() {
        let model = makeModel()
        model.setPresented(false)
        counter.reads = 0

        model.setPresented(true)

        XCTAssertEqual(counter.reads, 0)
    }

    func testAnOpenWindowStillFollowsChangesAndClosingStopsAgain() throws {
        let model = makeModel()
        model.setPresented(false)
        model.setPresented(true)

        try addOpenRouterKeyAndWriteDefaults()
        waitPastDebounce()
        XCTAssertEqual(model.chips.map(\.account), [.soniox, .openRouter], "Open window: live as before")

        model.setPresented(false)
        counter.reads = 0
        try keys.delete(account: XCTUnwrap(ProviderAccount.openRouter.keychainAccount(in: routing)))
        defaults.set(UUID().uuidString, forKey: "probe.transcriptionMode")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        waitPastDebounce()
        XCTAssertEqual(counter.reads, 0)

        model.setPresented(true)
        XCTAssertEqual(model.chips.map(\.account), [.soniox])
    }

    /// Onboarding and the app control plugin create their own model and never
    /// call `setPresented`: they keep recomputing on every change.
    func testOtherOwnersKeepRecomputingByDefault() throws {
        let model = makeModel()
        counter.reads = 0

        try addOpenRouterKeyAndWriteDefaults()
        waitPastDebounce()

        XCTAssertGreaterThan(counter.reads, 0)
        XCTAssertEqual(model.chips.map(\.account), [.soniox, .openRouter])
    }
}

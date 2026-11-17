import XCTest
@testable import Sidekey

private final class FakeCatalogFetcher: ModelCatalogFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<[CatalogModel], CatalogFetchError>]
    private var count = 0

    init(_ results: [Result<[CatalogModel], CatalogFetchError>]) {
        self.results = results
    }

    var fetchCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        return try next().get()
    }

    private func next() -> Result<[CatalogModel], CatalogFetchError> {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return results.count > 1 ? results.removeFirst() : results[0]
    }
}

@MainActor
final class ModelCatalogStoreTests: XCTestCase {
    private var directory: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCatalogStoreTests-\(UUID().uuidString)", isDirectory: true)
        clock = Date(timeIntervalSince1970: 1_800_000_000)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("model-catalog-v1.json") }

    private func makeStore(_ fetcher: FakeCatalogFetcher) -> ModelCatalogStore {
        ModelCatalogStore(fileURL: fileURL, fetcher: fetcher, now: { [unowned self] in self.clock })
    }

    private let models = [CatalogModel(id: "stt-rt-v5", uses: [.realtimeSTT])]

    func test_fresh_v2_cache_gains_decision_capabilities_offline_and_refreshes_without_waiting() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var jev = CatalogSnapshot(models: [CatalogModel(id: "typesafe/jev-1.14", uses: [.chat])], fetchedAt: clock)
        var openAI = CatalogSnapshot(models: [CatalogModel(id: "gpt-6-luna", uses: [.chat, .chatWithTools])], fetchedAt: clock)
        jev.metadataVersion = 2; openAI.metadataVersion = 2
        try JSONEncoder().encode(["openRouter": jev, "openAI": openAI]).write(to: fileURL)
        let offline = FakeCatalogFetcher([.failure(.offline)])
        let store = makeStore(offline)
        XCTAssertEqual(store.snapshot(for: .openRouter)?.models.first?.uses, [.decision])
        XCTAssertEqual(store.snapshot(for: .openAI)?.models.first?.uses, [.chat, .chatWithTools, .decision])
        await store.refreshIfStale(.openRouter, apiKey: "synthetic", server: nil)
        await store.refreshIfStale(.openAI, apiKey: "synthetic", server: nil)
        XCTAssertEqual(offline.fetchCount, 2)
        XCTAssertEqual(store.snapshot(for: .openRouter)?.models.first?.uses, [.decision])
    }

    func test_offline_refresh_keeps_models_and_marks_couldnt_refresh() async {
        let fetcher = FakeCatalogFetcher([.success(models), .failure(.offline)])
        let store = makeStore(fetcher)
        await store.refresh(.soniox, apiKey: "k", server: nil)
        let fetchedAt = clock
        clock = clock.addingTimeInterval(3600)
        await store.refresh(.soniox, apiKey: "k", server: nil)

        let snapshot = store.snapshot(for: .soniox)
        XCTAssertEqual(snapshot?.models, models)
        XCTAssertEqual(snapshot?.fetchedAt, fetchedAt)
        XCTAssertEqual(snapshot?.lastRefreshFailed, true)
        XCTAssertEqual(snapshot?.isAuthoritative, false)
    }

    func test_server_error_keeps_the_cache() async {
        let fetcher = FakeCatalogFetcher([.success(models), .failure(.http(503, code: nil))])
        let store = makeStore(fetcher)
        await store.refresh(.openRouter, apiKey: nil, server: nil)
        await store.refresh(.openRouter, apiKey: nil, server: nil)

        XCTAssertEqual(store.snapshot(for: .openRouter)?.models, models)
        XCTAssertEqual(store.snapshot(for: .openRouter)?.lastRefreshFailed, true)

        let recovered = FakeCatalogFetcher([.success(models)])
        let again = makeStore(recovered)
        await again.refresh(.openRouter, apiKey: nil, server: nil)
        XCTAssertEqual(again.snapshot(for: .openRouter)?.lastRefreshFailed, false)
        XCTAssertEqual(again.snapshot(for: .openRouter)?.isAuthoritative, true)
    }

    func test_fresh_cache_is_not_refetched_within_a_day() async {
        let fetcher = FakeCatalogFetcher([.success(models)])
        let store = makeStore(fetcher)
        await store.refreshIfStale(.soniox, apiKey: "k", server: nil)
        clock = clock.addingTimeInterval(23 * 3600)
        await store.refreshIfStale(.soniox, apiKey: "k", server: nil)
        XCTAssertEqual(fetcher.fetchCount, 1)
        clock = clock.addingTimeInterval(2 * 3600)
        await store.refreshIfStale(.soniox, apiKey: "k", server: nil)
        XCTAssertEqual(fetcher.fetchCount, 2)
    }

    func test_cache_survives_relaunch() async throws {
        let fetcher = FakeCatalogFetcher([.success(models)])
        let store = makeStore(fetcher)
        await store.refresh(.soniox, apiKey: "k", server: nil)

        let relaunched = makeStore(FakeCatalogFetcher([.failure(.offline)]))
        XCTAssertEqual(relaunched.snapshot(for: .soniox), store.snapshot(for: .soniox))
        XCTAssertEqual(relaunched.snapshot(for: .soniox)?.models, models)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(text.contains("\"k\""), "the cache holds model metadata only")

        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(makeStore(fetcher).snapshots.isEmpty, "an unreadable file is an empty cache")
    }

    func test_soniox_permission_denied_marks_limited() async {
        let fetcher = FakeCatalogFetcher([.success(models), .failure(.http(403, code: nil))])
        let store = makeStore(fetcher)
        await store.refresh(.soniox, apiKey: "k", server: nil)
        await store.refresh(.soniox, apiKey: "k", server: nil)
        XCTAssertEqual(store.snapshot(for: .soniox)?.limited, true)
        XCTAssertEqual(store.snapshot(for: .soniox)?.models, models)
        XCTAssertEqual(store.snapshot(for: .soniox)?.isAuthoritative, false)

        let deepgram = makeStore(FakeCatalogFetcher([.failure(.http(403, code: "INSUFFICIENT_PERMISSIONS"))]))
        await deepgram.refresh(.deepgram, apiKey: "k", server: nil)
        XCTAssertEqual(deepgram.snapshot(for: .deepgram)?.limited, true)

        try? FileManager.default.removeItem(at: fileURL)
        let other = makeStore(FakeCatalogFetcher([.failure(.http(403, code: "SOMETHING_ELSE"))]))
        await other.refresh(.deepgram, apiKey: "k", server: nil)
        XCTAssertEqual(other.snapshot(for: .deepgram)?.limited, false)
        XCTAssertEqual(other.snapshot(for: .deepgram)?.lastRefreshFailed, true)
    }

    func test_server_without_models_endpoint_is_an_empty_valid_catalog() async {
        let id = UUID()
        let server = ServerEndpoint(id: id, name: "S", baseURL: "http://localhost:8000", keyAccount: "byok.server.x.api_key")
        let store = makeStore(FakeCatalogFetcher([.failure(.http(404, code: nil))]))
        await store.refresh(.server(id), apiKey: nil, server: server)
        let snapshot = store.snapshot(for: .server(id))
        XCTAssertEqual(snapshot?.models, [])
        XCTAssertEqual(snapshot?.lastRefreshFailed, false)
        XCTAssertNotNil(snapshot?.fetchedAt)
    }

    func test_forget_removes_the_account() async {
        let store = makeStore(FakeCatalogFetcher([.success(models)]))
        await store.refresh(.soniox, apiKey: "k", server: nil)
        store.forget(.soniox)
        XCTAssertNil(store.snapshot(for: .soniox))
        XCTAssertNil(makeStore(FakeCatalogFetcher([.failure(.offline)])).snapshot(for: .soniox))
    }

    func test_legacy_cache_is_kept_offline_then_refreshed_once_for_dates() async throws {
        let legacy = #"{"openAI":{"models":[{"id":"gpt-cached"}],"fetchedAt":0,"lastRefreshFailed":false,"limited":false}}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: fileURL)
        // Keep the old cache fresh by age: only the metadata version should refetch it.
        let decoded = try JSONDecoder().decode([String: CatalogSnapshot].self, from: Data(legacy.utf8))
        clock = try XCTUnwrap(decoded["openAI"]?.fetchedAt)
        let dated = CatalogModel(id: "gpt-cached", catalogDate: Date(timeIntervalSince1970: 1_790_000_000))
        let fetcher = FakeCatalogFetcher([.failure(.offline), .success([dated])])
        let store = makeStore(fetcher)
        XCTAssertEqual(store.snapshot(for: .openAI)?.models.first?.id, "gpt-cached")
        await store.refreshIfStale(.openAI, apiKey: "fake", server: nil)
        XCTAssertEqual(store.snapshot(for: .openAI)?.models.first?.id, "gpt-cached")
        XCTAssertNil(store.snapshot(for: .openAI)?.models.first?.catalogDate)
        await store.refreshIfStale(.openAI, apiKey: "fake", server: nil)
        await store.refreshIfStale(.openAI, apiKey: "fake", server: nil)
        XCTAssertEqual(fetcher.fetchCount, 2)
        XCTAssertEqual(store.snapshot(for: .openAI)?.models, [dated])
        XCTAssertEqual(makeStore(fetcher).snapshot(for: .openAI)?.models, [dated])
    }

    func test_date_metadata_does_not_invalidate_fresh_legacy_server_cache() async throws {
        let account = ProviderAccount.server(UUID())
        let legacy: [String: Any] = [account.storageID: [
            "models": [], "fetchedAt": 0, "lastRefreshFailed": false, "limited": false,
        ]]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: fileURL)
        clock = Date(timeIntervalSinceReferenceDate: 0)
        let fetcher = FakeCatalogFetcher([.failure(.http(404, code: nil))])
        let store = makeStore(fetcher)
        await store.refreshIfStale(account, apiKey: nil, server: nil)
        XCTAssertEqual(fetcher.fetchCount, 0)
        XCTAssertNotNil(store.snapshot(for: account))
    }

    func test_cache_without_prices_is_kept_offline_then_refreshed_once() async throws {
        // What 2.2.24 wrote: dates known (metadata version 3), no prices.
        let legacy = #"{"openRouter":{"models":[{"id":"vendor/cached","catalogDate":0}],"fetchedAt":0,"lastRefreshFailed":false,"limited":false,"metadataVersion":3}}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: fileURL)
        let decoded = try JSONDecoder().decode([String: CatalogSnapshot].self, from: Data(legacy.utf8))
        XCTAssertEqual(Array(decoded.keys), [ProviderAccount.openRouter.storageID])
        // Fresh by age: only the metadata version may refetch it.
        clock = try XCTUnwrap(decoded.values.first?.fetchedAt)
        let priced = CatalogModel(
            id: "vendor/cached",
            tokenPrice: CatalogTokenPrice(promptPerToken: Decimal(string: "0.0000003"),
                                          completionPerToken: Decimal(string: "0.0000025")))
        XCTAssertNotNil(priced.tokenPrice)
        let fetcher = FakeCatalogFetcher([.failure(.offline), .success([priced])])
        let store = makeStore(fetcher)
        XCTAssertNil(store.snapshot(for: .openRouter)?.models.first?.tokenPrice)

        await store.refreshIfStale(.openRouter, apiKey: nil, server: nil)
        XCTAssertEqual(store.snapshot(for: .openRouter)?.models.first?.id, "vendor/cached", "offline keeps the old list")
        XCTAssertNil(store.snapshot(for: .openRouter)?.models.first?.tokenPrice)

        await store.refreshIfStale(.openRouter, apiKey: nil, server: nil)
        await store.refreshIfStale(.openRouter, apiKey: nil, server: nil)
        XCTAssertEqual(fetcher.fetchCount, 2, "one failed and one successful refresh, then the TTL applies")
        XCTAssertEqual(store.snapshot(for: .openRouter)?.models, [priced])
        XCTAssertEqual(makeStore(fetcher).snapshot(for: .openRouter)?.models, [priced])
    }
}

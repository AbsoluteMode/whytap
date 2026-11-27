import XCTest
@testable import Sidekey

/// The OpenRouter provider choice: Auto, or one endpoint pinned with no
/// fallback, everywhere an OpenRouter route runs.
@MainActor
final class OpenRouterProviderTests: XCTestCase {
    private func makeRouting() -> AIRoutingStore {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AIRoutingStore(defaults: defaults)
    }

    // MARK: - Endpoints response

    /// Shaped like a real `/models/{id}/endpoints` answer to a request with a key.
    private let fixture = Data(#"""
    {"data":{"id":"deepseek/deepseek-chat-v3.1","endpoints":[
      {"provider_name":"DeepInfra","tag":"deepinfra/fp4","quantization":"fp4","status":0,
       "latency_last_30m":{"p50":420.0,"p75":600,"p90":900,"p99":2000},
       "throughput_last_30m":{"p50":85.4,"p75":70,"p90":50,"p99":20}},
      {"provider_name":"SambaNova","tag":"sambanova/fp8","quantization":"fp8","status":0,
       "latency_last_30m":{"p50":250.0},"throughput_last_30m":{"p50":190.0}},
      {"provider_name":"Mara","tag":"mara","quantization":"unknown","status":-2,
       "latency_last_30m":null,"throughput_last_30m":null},
      {"provider_name":"CoreWeave","tag":"coreweave/fp8","quantization":"fp8","status":0,
       "latency_last_30m":null,"throughput_last_30m":null}
    ]}}
    """#.utf8)

    func test_decodes_median_latency_and_throughput() throws {
        let endpoints = try OpenRouterEndpointsClient.decode(fixture)
        let deepInfra = try XCTUnwrap(endpoints.first { $0.tag == "deepinfra/fp4" })
        XCTAssertEqual(deepInfra.title, "DeepInfra · fp4")
        XCTAssertEqual(deepInfra.speedText, "0.42 s · 85 tok/s")
        let mara = try XCTUnwrap(endpoints.first { $0.tag == "mara" })
        XCTAssertEqual(mara.title, "Mara", "an unknown quantization is not shown")
        XCTAssertEqual(mara.speedText, "— s · — tok/s", "no figures without a key: a dash, never zero")
        XCTAssertFalse(mara.isUp)
    }

    func test_sorted_fastest_first_and_down_last() throws {
        let sorted = OpenRouterEndpointsClient.sorted(try OpenRouterEndpointsClient.decode(fixture))
        XCTAssertEqual(sorted.map(\.tag), ["sambanova/fp8", "deepinfra/fp4", "coreweave/fp8", "mara"])
    }

    func test_url_keeps_the_model_slashes() throws {
        let base = URL(string: "https://openrouter.ai/api/v1")!
        XCTAssertEqual(OpenRouterEndpointsClient.url(base: base, model: "deepseek/deepseek-chat-v3.1")?.absoluteString,
                       "https://openrouter.ai/api/v1/models/deepseek/deepseek-chat-v3.1/endpoints")
        XCTAssertEqual(OpenRouterEndpointsClient.url(base: base, model: "x/y:free")?.absoluteString,
                       "https://openrouter.ai/api/v1/models/x/y:free/endpoints")
        XCTAssertNil(OpenRouterEndpointsClient.url(base: base, model: "a/../../keys"))
        XCTAssertNil(OpenRouterEndpointsClient.url(base: base, model: "a b"))
        XCTAssertNil(OpenRouterEndpointsClient.url(base: base, model: "x/y?z=1#f")?.query)
    }

    // MARK: - Request body

    func test_pinned_provider_is_used_alone() {
        let client = OpenRouterLLMClient(profile: .dictation)
        XCTAssertEqual(client.providerPreferences(for: .openRouter(apiKey: "k", provider: "deepinfra/fp4")),
                       .init(order: ["deepinfra/fp4"], allow_fallbacks: false))
        XCTAssertEqual(OpenRouterLLMClient().providerPreferences(for: .openRouter(apiKey: "k", provider: "groq")),
                       .init(order: ["groq"], allow_fallbacks: false))
    }

    func test_auto_keeps_openrouter_routing() {
        XCTAssertEqual(OpenRouterLLMClient(profile: .dictation).providerPreferences(for: .openRouter(apiKey: "k")),
                       .init(sort: "throughput"))
        XCTAssertNil(OpenRouterLLMClient().providerPreferences(for: .openRouter(apiKey: "k")))
        XCTAssertNil(OpenRouterLLMClient(profile: .dictation)
            .providerPreferences(for: .custom(baseURL: URL(string: "http://10.0.0.2/v1")!, apiKey: nil)))
    }

    func test_pinned_body_omits_sort() throws {
        let body = try JSONEncoder().encode(OpenRouterLLMClient.ProviderPreferences(order: ["a/b"], allow_fallbacks: false))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["order", "allow_fallbacks"])
    }

    // MARK: - Route

    /// Auto writes no `provider` key: the route JSON is what older builds
    /// wrote and read, and a pinned route still decodes there (unknown keys
    /// are ignored).
    func test_auto_route_json_matches_older_builds() throws {
        let auto = try JSONEncoder().encode(FeatureRoute(account: .openRouter, model: "m"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: auto) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["account", "model"])
        XCTAssertNil(try JSONDecoder().decode(FeatureRoute.self, from: auto).provider)
        let pinned = try JSONEncoder().encode(FeatureRoute(account: .openRouter, model: "m", provider: "groq"))
        XCTAssertEqual(try JSONDecoder().decode(FeatureRoute.self, from: pinned).provider, "groq")
    }

    func test_provider_is_set_only_on_openrouter_routes() {
        let routing = makeRouting()
        routing.setRoute(FeatureRoute(account: .openRouter, model: "m"), for: .meetingNotes)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        routing.setProvider("deepinfra/fp4", for: .meetingNotes)
        routing.setProvider("deepinfra/fp4", for: .dropFast)
        XCTAssertEqual(routing.route(for: .meetingNotes)?.provider, "deepinfra/fp4")
        XCTAssertNil(routing.route(for: .dropFast)?.provider)
        routing.setProvider(nil, for: .meetingNotes)
        XCTAssertNil(routing.route(for: .meetingNotes)?.provider)
    }

    func test_llm_route_carries_the_pinned_provider() async throws {
        let routing = makeRouting()
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "m", provider: "groq"), for: .meetingNotes)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "m"), for: .dropSmartCleanup)

        let notes = try await DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys).routeIfEnabled()
        let cleanup = try await DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys).routeIfEnabled()
        XCTAssertEqual(notes?.endpoint.pinnedProvider, "groq")
        XCTAssertNil(cleanup?.endpoint.pinnedProvider, "another feature's pin never leaks in")
    }

    // MARK: - Agent

    private func modelDeclaration(_ env: [String: String], provider: String, model: String) throws -> [String: Any] {
        let content = try XCTUnwrap(env["OPENCODE_CONFIG_CONTENT"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let providers = try XCTUnwrap(json["provider"] as? [String: Any])
        let entry = try XCTUnwrap(providers[provider] as? [String: Any])
        let models = try XCTUnwrap(entry["models"] as? [String: Any])
        return try XCTUnwrap(models[model] as? [String: Any])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

}

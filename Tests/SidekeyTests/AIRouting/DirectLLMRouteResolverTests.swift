import XCTest
@testable import Sidekey

/// An LLM feature runs on the route stored for that feature, and on nothing
/// else: not another feature's route, not a stored key of another provider.
@MainActor
final class DirectLLMRouteResolverTests: XCTestCase {
    private struct UnreadableTokenStore: TokenStore {
        struct Failure: Error {}
        func save(_ token: String) throws {}
        func read() throws -> String? { throw Failure() }
        func delete() throws {}
    }

    private func makeRouting() -> AIRoutingStore {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AIRoutingStore(defaults: defaults)
    }

    private func makeKeys() -> ProviderKeyStore {
        let box = InMemoryTokenStore.Box()
        return ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
    }

    func test_notes_resolver_reads_its_own_feature() async throws {
        let routing = makeRouting()
        let keys = makeKeys()
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "notes-model"), for: .meetingNotes)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "cleanup-model"), for: .dropSmartCleanup)

        let notes = try await DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys).routeIfEnabled()
        let cleanup = try await DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys).routeIfEnabled()

        XCTAssertEqual(notes?.model, "notes-model")
        XCTAssertEqual(cleanup?.model, "cleanup-model")
        XCTAssertEqual(notes?.endpoint.apiKey, "or-key")
    }

    func test_direct_providers_use_only_their_own_key_and_endpoint() async throws {
        let routing = makeRouting()
        let keys = makeKeys()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        try keys.save("unrelated-key", account: OpenRouterLLMKeyStore.account)
        for feature in AIFeature.activeCases where feature.mode == .llm {
            for (account, host, key) in [(ProviderAccount.openAI, "api.openai.com", "openai-key"),
                                         (.anthropic, "api.anthropic.com", "anthropic-key")] {
                routing.setRoute(FeatureRoute(account: account, model: "chosen-model"), for: feature)
                let route = try await DirectLLMRouteResolver(feature: feature, routing: routing, keys: keys).routeIfEnabled()
                XCTAssertEqual(route?.endpoint.baseURL.host, host)
                XCTAssertEqual(route?.endpoint.apiKey, key)
                XCTAssertEqual(route?.endpoint.sendsOpenRouterHeaders, false)
                XCTAssertEqual(route?.model, "chosen-model")
                XCTAssertEqual(route?.usageContext?.account, account)
            }
        }
        try keys.delete(account: ProviderAccount.openAIKeychainAccount)
        routing.setRoute(FeatureRoute(account: .openAI, model: "chosen-model"), for: .translation)
        do {
            _ = try await DirectLLMRouteResolver(feature: .translation, routing: routing, keys: keys).routeIfEnabled()
            XCTFail("A missing OpenAI key must not borrow another provider's key")
        } catch { XCTAssertEqual(error as? OpenRouterLLMError, .missingKey) }
    }

    func test_live_resolver_reads_the_shared_store() async throws {
        let feature = AIFeature.meetingNotes
        let shared = AIRoutingStore.shared
        let before = shared.route(for: feature)
        defer { shared.setRoute(before, for: feature) }
        shared.setRoute(FeatureRoute(account: .soniox, model: "stt"), for: feature)
        let route = try await DirectLLMRouteResolver.live(feature).routeIfEnabled()
        XCTAssertNil(route, "a speech-to-text account cannot serve an LLM feature")
    }

    func test_no_route_is_nil_and_other_features_do_not_count() async throws {
        let routing = makeRouting()
        let keys = makeKeys()
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "m"), for: .meetingNotes)
        let route = try await DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys).routeIfEnabled()
        XCTAssertNil(route)
    }

    func test_openrouter_without_a_key_throws_missing_key() async throws {
        let routing = makeRouting()
        routing.setRoute(FeatureRoute(account: .openRouter, model: "m"), for: .dropSmartCleanup)
        let resolver = DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: makeKeys())
        do {
            _ = try await resolver.routeIfEnabled()
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? OpenRouterLLMError, .missingKey)
        }
    }

    func test_server_without_a_key_is_keyless() async throws {
        let routing = makeRouting()
        let server = routing.addServer(name: "Local", baseURL: "http://llm.local:8080/v1")
        routing.setRoute(FeatureRoute(account: .server(server.id), model: "qwen"), for: .meetingNotes)
        let route = try await DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: makeKeys()).routeIfEnabled()
        XCTAssertEqual(route?.model, "qwen")
        XCTAssertEqual(route?.endpoint.baseURL.absoluteString, "http://llm.local:8080/v1")
        XCTAssertNil(route?.endpoint.apiKey)
        XCTAssertEqual(route?.endpoint.sendsOpenRouterHeaders, false)
    }

    func test_server_key_is_used_when_stored() async throws {
        let routing = makeRouting()
        let keys = makeKeys()
        let server = routing.addServer(name: "Local", baseURL: "https://llm.example.com/v1")
        try keys.save("srv-key", account: server.keyAccount)
        routing.setRoute(FeatureRoute(account: .server(server.id), model: "qwen"), for: .meetingNotes)
        let route = try await DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys).routeIfEnabled()
        XCTAssertEqual(route?.endpoint.apiKey, "srv-key")
    }

    func test_unreadable_server_key_is_missing_key_never_keyless() async throws {
        let routing = makeRouting()
        let server = routing.addServer(name: "Local", baseURL: "http://llm.local/v1")
        routing.setRoute(FeatureRoute(account: .server(server.id), model: "qwen"), for: .meetingNotes)
        let keys = ProviderKeyStore(makeStore: { _ in UnreadableTokenStore() })
        do {
            _ = try await DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys).routeIfEnabled()
            XCTFail("expected missingKey")
        } catch {
            XCTAssertEqual(error as? OpenRouterLLMError, .missingKey)
        }
    }

    func test_server_base_url_problems() async throws {
        let cases: [(String, OpenRouterLLMError)] = [
            ("  ", .missingBaseURL),
            ("ftp://llm.local/v1", .invalidBaseURL("ftp://llm.local/v1")),
            ("not a url", .invalidBaseURL("not a url")),
            ("http://", .invalidBaseURL("http://")),
        ]
        for (baseURL, expected) in cases {
            let routing = makeRouting()
            let server = routing.addServer(name: "Local", baseURL: baseURL)
            routing.setRoute(FeatureRoute(account: .server(server.id), model: "qwen"), for: .meetingNotes)
            do {
                _ = try await DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: makeKeys()).routeIfEnabled()
                XCTFail("expected \(expected) for \(baseURL)")
            } catch {
                XCTAssertEqual(error as? OpenRouterLLMError, expected, baseURL)
            }
        }
    }

    func test_stt_account_is_not_an_llm_route() async throws {
        let routing = makeRouting()
        let keys = makeKeys()
        try keys.save("k", account: BYOKKeyStore.account(for: .deepgram))
        routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .meetingNotes)
        let route = try await DirectLLMRouteResolver(feature: .meetingNotes, routing: routing, keys: keys).routeIfEnabled()
        XCTAssertNil(route)
    }

    func test_route_is_read_at_each_call() async throws {
        let routing = makeRouting()
        let keys = makeKeys()
        try keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        let resolver = DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys)
        let first = try await resolver.routeIfEnabled()
        XCTAssertNil(first)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "a"), for: .dropSmartCleanup)
        let second = try await resolver.routeIfEnabled()
        XCTAssertEqual(second?.model, "a")
        routing.setRoute(FeatureRoute(account: .openRouter, model: "b"), for: .dropSmartCleanup)
        let third = try await resolver.routeIfEnabled()
        XCTAssertEqual(third?.model, "b")
    }
}

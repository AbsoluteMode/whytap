import XCTest
@testable import Sidekey

final class ModelCatalogFetcherTests: XCTestCase {
    private func makeFetcher(status: Int = 200, body: String = "{}") -> ModelCatalogFetcher {
        StubURLProtocol.reset()
        addTeardownBlock { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in (status, [:], Data(body.utf8)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return ModelCatalogFetcher(session: session)
    }

    private func server(_ baseURL: String) -> ServerEndpoint {
        ServerEndpoint(id: UUID(), name: "Local", baseURL: baseURL, keyAccount: "byok.server.test.api_key")
    }

    func test_openai_catalog_authenticates_and_excludes_non_text_endpoints() async throws {
        let fetcher = makeFetcher(body: #"{"data":[{"id":"gpt-6.1-sol"},{"id":"gpt-4.1-mini"},{"id":"o3"},{"id":"text-embedding-3-small"},{"id":"gpt-4o-transcribe"},{"id":"gpt-realtime"},{"id":"gpt-image-1"},{"id":"gpt-5-pro"},{"id":"gpt-5-codex"}]}"#)
        let models = try await fetcher.fetch(account: .openAI, apiKey: "openai-key", server: nil)
        XCTAssertEqual(models.map(\.id), ["gpt-4.1-mini", "gpt-6.1-sol", "o3"])
        XCTAssertTrue(models.allSatisfy { $0.uses == [.chat, .chatWithTools] })
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func test_soniox_catalog_maps_modes_and_aliases() async throws {
        let fetcher = makeFetcher(body: """
        {"models":[
          {"id":"stt-rt-v5","transcription_mode":"real_time","aliased_model_id":null},
          {"id":"stt-rt-v4","transcription_mode":"real_time","aliased_model_id":"stt-rt-v5"},
          {"id":"stt-async-v5","transcription_mode":"async"}
        ]}
        """)
        let models = try await fetcher.fetch(account: .soniox, apiKey: "sx-key", server: nil)
        XCTAssertEqual(models.map(\.id), ["stt-rt-v5", "stt-rt-v4", "stt-async-v5"])
        XCTAssertEqual(models.map(\.uses), [[.realtimeSTT], [.realtimeSTT], [.asyncSTT]])
        XCTAssertEqual(models.map(\.aliasOf), [nil, "stt-rt-v5", nil])
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.soniox.com/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sx-key")
    }

    func test_deepgram_catalog_merges_rows_and_keeps_nova_3() async throws {
        let fetcher = makeFetcher(body: """
        {"stt":[
          {"name":"general","canonical_name":"nova-3-general","streaming":true,"batch":false},
          {"name":"general","canonical_name":"nova-3-general","streaming":false,"batch":true},
          {"name":"medical","canonical_name":"nova-3-medical","streaming":true,"batch":true}
        ]}
        """)
        let models = try await fetcher.fetch(account: .deepgram, apiKey: "dg-key", server: nil)
        XCTAssertEqual(models.map(\.id), ["nova-3", "nova-3-general", "nova-3-medical"])
        XCTAssertEqual(models[0].uses, [.realtimeSTT, .asyncSTT])
        XCTAssertEqual(models[1].uses, [.realtimeSTT, .asyncSTT])
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepgram.com/v1/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_openrouter_catalog_drops_batch_aliases_and_routers_but_keeps_auto() async throws {
        let fetcher = makeFetcher(body: """
        {"data":[
          {"id":"google/gemini-3.8-flash","context_length":1048576,
           "supported_parameters":["tools","reasoning","max_tokens"],
           "architecture":{"output_modalities":["text"]},
           "pricing":{"prompt":"0.0000003"},
           "top_provider":{"max_completion_tokens":65536},
           "expiration_date":"2027-03-01",
           "reasoning":{"mandatory":true,"supported_efforts":["low","high"]}},
          {"id":"google/gemini-3.8-flash:batch","architecture":{"output_modalities":["text"]},"pricing":{"prompt":"0.1"}},
          {"id":"~anthropic/claude-sonnet-latest","architecture":{"output_modalities":["text"]},"pricing":{"prompt":"0.1"}},
          {"id":"openrouter/fusion","architecture":{"output_modalities":["text"]},"pricing":{"prompt":"-1"}},
          {"id":"openrouter/auto","architecture":{"output_modalities":["text"]},"pricing":{"prompt":"-1"}},
          {"id":"some/image-model","architecture":{"output_modalities":["image"]},"pricing":{"prompt":"0.1"}}
        ]}
        """)
        let models = try await fetcher.fetch(account: .openRouter, apiKey: "or-key", server: nil)
        XCTAssertEqual(models.map(\.id), ["google/gemini-3.8-flash", "openrouter/auto"])
        let gemini = models[0]
        XCTAssertEqual(gemini.contextLength, 1_048_576)
        XCTAssertEqual(gemini.maxOutputTokens, 65_536)
        XCTAssertEqual(gemini.supportsTools, true)
        XCTAssertEqual(gemini.supportsReasoning, true)
        XCTAssertEqual(gemini.uses, [.chat, .chatWithTools])
        XCTAssertEqual(gemini.reasoning?.mandatory, true)
        XCTAssertNotNil(gemini.expiresAt)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// Two pages: the second asks for `after_id=<last_id>` of the first.
    func test_anthropic_catalog_pages_and_maps_limits() async throws {
        let fetcher = makeFetcher()
        StubURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("after_id=") {
                return (200, [:], Data(#"""
                {"data":[{"type":"model","id":"claude-haiku-5","display_name":"Claude Haiku 5",
                  "created_at":"2026-05-01T00:00:00Z","max_input_tokens":200000,"max_tokens":64000}],
                 "has_more":false,"first_id":"claude-haiku-5","last_id":"claude-haiku-5"}
                """#.utf8))
            }
            return (200, [:], Data(#"""
            {"data":[{"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5",
              "created_at":"2026-09-01T00:00:00Z","max_input_tokens":1000000,"max_tokens":128000,
              "capabilities":{"thinking":{"supported":true}}}],
             "has_more":true,"first_id":"claude-sonnet-5-5","last_id":"claude-sonnet-5-5"}
            """#.utf8))
        }
        let models = try await fetcher.fetch(account: .anthropic, apiKey: "sk-ant", server: nil)
        XCTAssertEqual(models.map(\.id), ["claude-sonnet-5-5", "claude-haiku-5"])
        XCTAssertEqual(models.map(\.contextLength), [1_000_000, 200_000])
        XCTAssertEqual(models.map(\.maxOutputTokens), [128_000, 64_000])
        XCTAssertEqual(models.map(\.supportsTools), [true, true])
        XCTAssertEqual(models[0].supportsReasoning, true)
        XCTAssertTrue(models.allSatisfy { $0.uses?.contains(.chatWithTools) == true })

        let requests = StubURLProtocol.capturedRequests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://api.anthropic.com/v1/models?limit=1000",
            "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-sonnet-5-5",
        ])
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func test_server_models_url_rules() {
        XCTAssertEqual(server("http://h:8000/v1").modelsURL?.absoluteString, "http://h:8000/v1/models")
        XCTAssertEqual(server("http://h:8000/v1/").modelsURL?.absoluteString, "http://h:8000/v1/models")
        XCTAssertEqual(server("wss://h/v1/realtime").modelsURL?.absoluteString, "https://h/v1/models")
        XCTAssertEqual(server("ws://h:9000/v1").modelsURL?.absoluteString, "http://h:9000/v1/models")
        XCTAssertEqual(server("http://h:11434").modelsURL?.absoluteString, "http://h:11434/v1/models")
        XCTAssertNil(server("not a url").modelsURL)
        XCTAssertNil(server("ftp://h/v1").modelsURL)
    }

    func test_model_dates_are_optional_and_bad_metadata_does_not_break_catalogs() throws {
        let timestamp: TimeInterval = 1_790_000_000
        for parse in [ModelCatalogFetcher.parseOpenAI, ModelCatalogFetcher.parseOpenRouter] {
            let models = try parse(Data(#"""
            {"data":[
              {"id":"gpt-valid","created":1790000000},
              {"id":"gpt-missing"}, {"id":"gpt-null","created":null},
              {"id":"gpt-epoch","created":0}, {"id":"gpt-negative","created":-1},
              {"id":"gpt-bad","created":"unknown"}, {"id":"gpt-extreme","created":1e100}
            ]}
            """#.utf8))
            XCTAssertEqual(models.count, 7)
            XCTAssertEqual(models.first { $0.id == "gpt-valid" }?.catalogDate,
                           Date(timeIntervalSince1970: timestamp))
            XCTAssertTrue(models.filter { $0.id != "gpt-valid" }.allSatisfy { $0.catalogDate == nil })
        }
        let page = try ModelCatalogFetcher.parseAnthropicPage(Data(#"""
        {"data":[
          {"id":"valid","created_at":"2026-09-21T00:00:00.000Z"},
          {"id":"missing"}, {"id":"null","created_at":null},
          {"id":"epoch","created_at":"1970-01-01T00:00:00Z"},
          {"id":"bad","created_at":"unknown"}, {"id":"wrong-type","created_at":123}
        ]}
        """#.utf8))
        XCTAssertEqual(page.models.count, 6)
        XCTAssertEqual(page.models[0].catalogDate,
                       ISO8601DateFormatter().date(from: "2026-09-21T00:00:00Z"))
        XCTAssertTrue(page.models.dropFirst().allSatisfy { $0.catalogDate == nil })
    }

    func test_server_catalog_without_key_sends_no_authorization() async throws {
        let fetcher = makeFetcher(body: #"{"data":[{"id":"qwen"},{"id":"llama"}]}"#)
        for key in [nil, ""] as [String?] {
            StubURLProtocol.capturedRequests = []
            let models = try await fetcher.fetch(
                account: .server(UUID()), apiKey: key, server: server("http://h:8000/v1"))
            XCTAssertEqual(models.map(\.id), ["qwen", "llama"])
            XCTAssertNil(models[0].uses)
            let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        StubURLProtocol.capturedRequests = []
        _ = try await fetcher.fetch(account: .server(UUID()), apiKey: "k", server: server("http://h:8000/v1"))
        XCTAssertEqual(StubURLProtocol.capturedRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func test_elevenlabs_catalog_makes_no_request() async throws {
        let fetcher = makeFetcher()
        let models = try await fetcher.fetch(account: .elevenLabs, apiKey: "xi", server: nil)
        XCTAssertEqual(models, [])
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    func test_errors_map_to_http_offline_and_malformed() async throws {
        var fetcher = makeFetcher(status: 401, body: #"{"error_type":"unauthenticated","error_message":"x"}"#)
        await assertFetchThrows(fetcher, .http(401, code: "unauthenticated"))

        fetcher = makeFetcher(status: 403, body: #"{"detail":{"status":"insufficient_permissions"}}"#)
        await assertFetchThrows(fetcher, .http(403, code: "insufficient_permissions"))

        fetcher = makeFetcher(status: 401, body: #"{"err_code":"INVALID_AUTH","category":"auth"}"#)
        await assertFetchThrows(fetcher, .http(401, code: "INVALID_AUTH"))

        fetcher = makeFetcher(status: 502, body: "<html>bad gateway</html>")
        await assertFetchThrows(fetcher, .http(502, code: nil))

        fetcher = makeFetcher(status: 200, body: "<html>not json</html>")
        await assertFetchThrows(fetcher, .malformed)

        fetcher = makeFetcher()
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await assertFetchThrows(fetcher, .offline)

        fetcher = makeFetcher(status: 404)
        await assertFetchThrows(fetcher, .http(404, code: nil), account: .server(UUID()))
    }

    private func assertFetchThrows(
        _ fetcher: ModelCatalogFetcher,
        _ expected: CatalogFetchError,
        account: ProviderAccount = .soniox,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await fetcher.fetch(account: account, apiKey: "k", server: server("http://h/v1"))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CatalogFetchError, expected, file: file, line: line)
        }
    }

    func test_openrouter_prices_are_per_million_and_unknown_amounts_stay_unknown() throws {
        let body = """
        {"data":[
          {"id":"a/priced","pricing":{"prompt":"0.00000125","completion":"0.00001"}},
          {"id":"a/free","pricing":{"prompt":"0","completion":"0"}},
          {"id":"a/numeric","pricing":{"prompt":0.0000003,"completion":0.0000025}},
          {"id":"a/no-completion","pricing":{"prompt":"0.000001"}},
          {"id":"a/no-pricing"},
          {"id":"a/garbage","pricing":{"prompt":"1abc","completion":"0.000001"}},
          {"id":"a/empty","pricing":{"prompt":"","completion":""}},
          {"id":"a/wrong-shape","pricing":"cheap"},
          {"id":"a/negative-output","pricing":{"prompt":"0.000001","completion":"-1"}},
          {"id":"openrouter/auto","pricing":{"prompt":"-1","completion":"-1"}},
          {"id":"openrouter/other-router","pricing":{"prompt":-1,"completion":-1}}
        ]}
        """
        let models = try ModelCatalogFetcher.parseOpenRouter(Data(body.utf8))
        let prices = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.tokenPrice) })
        XCTAssertEqual(models.count, 10, "optional price metadata never drops a model; routers at -1 still do")
        XCTAssertNil(prices["openrouter/other-router"] ?? nil)

        let priced = try XCTUnwrap(prices["a/priced"] ?? nil)
        XCTAssertEqual(priced.inputPerMillion, 1.25, accuracy: 1e-9)
        XCTAssertEqual(priced.outputPerMillion, 10, accuracy: 1e-9)
        let free = try XCTUnwrap(prices["a/free"] ?? nil)
        XCTAssertEqual(free.inputPerMillion, 0)
        XCTAssertEqual(free.outputPerMillion, 0)
        let numeric = try XCTUnwrap(prices["a/numeric"] ?? nil)
        XCTAssertEqual(numeric.inputPerMillion, 0.3, accuracy: 1e-9)
        XCTAssertEqual(numeric.outputPerMillion, 2.5, accuracy: 1e-9)

        for id in ["a/no-completion", "a/no-pricing", "a/garbage", "a/empty", "a/wrong-shape",
                   "a/negative-output", "openrouter/auto"] {
            XCTAssertTrue(prices.keys.contains(id), id)
            XCTAssertNil(prices[id] ?? nil, "\(id) must have no price, never a zero")
        }
    }

    func test_only_openrouter_catalogs_carry_prices_and_they_survive_the_cache_format() throws {
        let openAI = try ModelCatalogFetcher.parseOpenAI(
            Data(#"{"data":[{"id":"gpt-priced","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}"#.utf8))
        XCTAssertNil(openAI.first?.tokenPrice)

        let model = try XCTUnwrap(ModelCatalogFetcher.parseOpenRouter(
            Data(#"{"data":[{"id":"a/b","pricing":{"prompt":"0.000000075","completion":"0.0000003"}}]}"#.utf8)).first)
        let restored = try JSONDecoder().decode(CatalogModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored, model)
        // A cache written before prices existed decodes without one.
        let legacy = try JSONDecoder().decode(CatalogModel.self, from: Data(#"{"id":"a/b"}"#.utf8))
        XCTAssertNil(legacy.tokenPrice)
    }
}

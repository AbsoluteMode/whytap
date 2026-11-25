import XCTest
@testable import Sidekey

final class OpenRouterLLMClientTests: XCTestCase {
    private var session: URLSession!
    private var client: OpenRouterLLMClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        client = OpenRouterLLMClient(
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            session: session
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session.invalidateAndCancel()
        client = nil
        session = nil
        super.tearDown()
    }

    func testListModelsSendsBearerAndDecodesTextModels() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
            let body = Data(#"""
            {
              "data": [
                {"id":"openai/gpt-4o-mini","name":"GPT-4o mini","architecture":{"output_modalities":["text"]}},
                {"id":"image/model","name":"Image","architecture":{"output_modalities":["image"]}}
              ]
            }
            """#.utf8)
            return (200, [:], body)
        }

        let models = try await client.listModels(apiKey: "or-key")

        XCTAssertEqual(models, [
            OpenRouterModelOption(id: "openai/gpt-4o-mini", name: "GPT-4o mini")
        ])
    }

    func testCompleteSendsChatCompletionRequestAndDecodesContent() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer or-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "HTTP-Referer"), BuildConfig.landingURL.absoluteString)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Whytap")
            let body = try XCTUnwrap(StubURLProtocol.capturedBodies.last)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "openrouter/auto")
            XCTAssertEqual(json["stream"] as? Bool, false)
            XCTAssertNil(json["reasoning"])
            XCTAssertNil(json["provider"])
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.first?["role"] as? String, "system")
            let response = Data(#"{"choices":[{"message":{"content":"clean text"}}]}"#.utf8)
            return (200, [:], response)
        }

        let result = try await client.complete(
            apiKey: "or-key",
            model: "openrouter/auto",
            messages: [OpenRouterChatMessage(role: "system", content: "prompt")]
        )

        XCTAssertEqual(result, "clean text")
    }

    func testDirectOpenAIUsesOnlyItsAuthAndOmitsUnsupportedSamplingOverrides() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "HTTP-Referer"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
            let body = try XCTUnwrap(StubURLProtocol.capturedBodies.last)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "selected-openai-model")
            XCTAssertNil(json["temperature"])
            XCTAssertNil(json["reasoning"])
            XCTAssertNil(json["provider"])
            return (200, [:], Data(#"{"choices":[{"message":{"content":"direct text"}}]}"#.utf8))
        }
        let result = try await client.complete(endpoint: .openAI(apiKey: "openai-key"), model: "selected-openai-model",
                                               messages: [.init(role: "user", content: "example")])
        XCTAssertEqual(result, "direct text")
    }

    func testDirectAnthropicUsesMessagesAndSeparatesSystemInstructions() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "HTTP-Referer"))
            let body = try XCTUnwrap(StubURLProtocol.capturedBodies.last)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "selected-claude-model")
            XCTAssertEqual(json["system"] as? String, "instruction")
            XCTAssertEqual(json["max_tokens"] as? Int, 8192)
            XCTAssertEqual(json["messages"] as? [[String: String]], [["role": "user", "content": "example"]])
            XCTAssertNil(json["provider"])
            return (200, [:], Data(#"{"content":[{"type":"thinking","thinking":"ignored"},{"type":"text","text":"direct answer"}],"stop_reason":"end_turn"}"#.utf8))
        }
        let result = try await client.complete(endpoint: .anthropic(apiKey: "anthropic-key"), model: "selected-claude-model",
                                               messages: [.init(role: "system", content: "instruction"), .init(role: "user", content: "example")])
        XCTAssertEqual(result, "direct answer")
    }

    func testDirectAnthropicRejectsEmptyAndTruncatedReplies() async throws {
        for (body, expected) in [
            (#"{"content":[],"stop_reason":"end_turn"}"#, OpenRouterLLMError.emptyContent),
            (#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#, .outputLimitReached),
        ] {
            StubURLProtocol.handler = { _ in (200, [:], Data(body.utf8)) }
            do {
                _ = try await client.complete(endpoint: .anthropic(apiKey: "key"), model: "selected",
                                                messages: [.init(role: "user", content: "example")])
                XCTFail("Expected incomplete output to fail")
            } catch { XCTAssertEqual(error as? OpenRouterLLMError, expected) }
        }
    }

    func testAnthropicInputOverflowDoesNotMarkTheModelUnsupported() async throws {
        StubURLProtocol.handler = { _ in
            (400, [:], Data(#"{"error":{"type":"invalid_request_error","message":"prompt is too long"}}"#.utf8))
        }
        do {
            _ = try await client.complete(endpoint: .anthropic(apiKey: "key"), model: "selected",
                                            messages: [.init(role: "user", content: "example")])
            XCTFail("Expected rejected input")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .inputRejected)
            XCTAssertFalse(error.isModelRefusal)
        }
    }

    func testCustomEndpointSendsChatCompletionWithoutOpenRouterHeadersOrKey() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://localhost:8000/v1/chat/completions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "HTTP-Referer"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Title"))
            let body = try XCTUnwrap(StubURLProtocol.capturedBodies.last)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "llama/local")
            let response = Data(#"{"choices":[{"message":{"content":"local clean text"}}]}"#.utf8)
            return (200, [:], response)
        }

        let endpoint = OpenAICompatibleLLMEndpoint.custom(
            baseURL: URL(string: "http://localhost:8000/v1")!,
            apiKey: nil
        )

        let result = try await client.complete(
            endpoint: endpoint,
            model: "llama/local",
            messages: [OpenRouterChatMessage(role: "system", content: "prompt")]
        )

        XCTAssertEqual(result, "local clean text")
    }
    func testDictationDiscoversLowestSupportedEffortAndCachesCatalog() async throws {
        var catalogCalls = 0
        var completionCalls = 0
        StubURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "models" {
                catalogCalls += 1
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, [:], Data(#"{"data":[{"id":"google/gemini-3.8-flash","reasoning":{"mandatory":true,"supported_efforts":["high","medium","low"]}}]}"#.utf8))
            }
            completionCalls += 1
            let json = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.capturedBodies.last)) as! [String: Any]
            let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
            XCTAssertEqual(reasoning["effort"] as? String, "low")
            XCTAssertNil(reasoning["enabled"])
            XCTAssertEqual(json["model"] as? String, "google/gemini-3.8-flash")
            let provider = try XCTUnwrap(json["provider"] as? [String: String])
            XCTAssertEqual(provider, ["sort": "throughput"])
            return (200, [:], Data(#"{"id":"gen-test","usage":{"completion_tokens":25,"completion_tokens_details":{"reasoning_tokens":10}},"choices":[{"message":{"content":"clean"}}]}"#.utf8))
        }
        let dictation = OpenRouterLLMClient(session: session, profile: .dictation)
        for _ in 0..<2 {
            let value = try await dictation.complete(apiKey: "test", model: "google/gemini-3.8-flash", messages: [])
            XCTAssertEqual(value, "clean")
        }
        XCTAssertEqual(catalogCalls, 1)
        XCTAssertEqual(completionCalls, 2)
    }

    func testDictationCustomEndpointNeverDiscoversOrSendsReasoning() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.lastPathComponent, "completions")
            let json = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.capturedBodies.last)) as! [String: Any]
            XCTAssertNil(json["reasoning"])
            XCTAssertNil(json["provider"])
            return (200, [:], Data(#"{"choices":[{"message":{"content":"clean"}}]}"#.utf8))
        }
        let dictation = OpenRouterLLMClient(session: session, profile: .dictation)
        _ = try await dictation.complete(endpoint: .custom(baseURL: URL(string: "http://localhost/v1")!, apiKey: nil), model: "local", messages: [])
    }

    func testUnavailableCatalogDoesNotLoseDictationOrInventUnsupportedEffort() async throws {
        StubURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "models" { return (503, [:], Data()) }
            let json = try JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.capturedBodies.last)) as! [String: Any]
            XCTAssertNil(json["reasoning"])
            XCTAssertEqual(json["provider"] as? [String: String], ["sort": "throughput"])
            return (200, [:], Data(#"{"choices":[{"message":{"content":"clean"}}]}"#.utf8))
        }
        let dictation = OpenRouterLLMClient(session: session, profile: .dictation)
        let value = try await dictation.complete(apiKey: "test", model: "unknown", messages: [])
        XCTAssertEqual(value, "clean")
    }

    func testReasoningPolicyDistinguishesMandatoryOptionalAndUnknownModels() {
        XCTAssertEqual(OpenRouterReasoningCapabilities(mandatory: true, supportedEfforts: ["high", "minimal", "low"]).dictationSetting?.effort, "minimal")
        XCTAssertEqual(OpenRouterReasoningCapabilities(mandatory: false, supportedEfforts: ["high", "low"]).dictationSetting?.enabled, false)
        XCTAssertNil(OpenRouterReasoningCapabilities(mandatory: nil, supportedEfforts: nil).dictationSetting)
        XCTAssertNil(OpenRouterReasoningCapabilities(mandatory: true, supportedEfforts: ["none"]).dictationSetting)
    }

    func testNotConfiguredPointsToAPIAndModels() {
        XCTAssertEqual(OpenRouterLLMError.notConfigured.description, "No LLM is chosen in Settings > Keys & models.")
    }
}

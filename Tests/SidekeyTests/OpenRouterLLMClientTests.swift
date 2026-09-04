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
}

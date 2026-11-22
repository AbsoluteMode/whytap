import XCTest
@testable import Sidekey

@MainActor
final class PostProcessorOpenRouterTests: XCTestCase {
    private struct Env {
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        func processor(_ client: any OpenRouterLLMClienting) -> PostProcessor {
            PostProcessor(
                llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys),
                openRouterClient: client
            )
        }
    }

    private func makeEnv() -> Env {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let box = InMemoryTokenStore.Box()
        return Env(
            routing: AIRoutingStore(defaults: defaults),
            keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        )
    }

    func testOpenRouterBYOKProcessesDirectlyWithoutBackendProcessCall() async throws {
        let env = makeEnv()
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/auto"), for: .dropSmartCleanup)
        let openRouter = FakeOpenRouterClient(completion: "cleaned by openrouter")
        let processor = env.processor(openRouter)

        let result = try await processor.process(
            "raw text",
            targetApp: "Slack",
            language: "en",
            outputLanguage: "ru",
            transcriptionMode: "smart"
        )

        XCTAssertEqual(result, "cleaned by openrouter")
        XCTAssertEqual(openRouter.lastAPIKey, "or-key")
        XCTAssertEqual(openRouter.lastEndpoint?.baseURL.absoluteString, "https://openrouter.ai/api/v1")
        XCTAssertEqual(openRouter.lastEndpoint?.requiresAPIKey, true)
        XCTAssertEqual(openRouter.lastEndpoint?.sendsOpenRouterHeaders, true)
        XCTAssertEqual(openRouter.lastModel, "openrouter/auto")
        XCTAssertEqual(openRouter.lastMessages.first?.role, "system")
        XCTAssertEqual(openRouter.lastMessages.first?.content, PostProcessor.systemPrompt)
        let userMessage = try XCTUnwrap(openRouter.lastMessages.last?.content)
        XCTAssertEqual(
            userMessage,
            "Active app: Slack\n\nInput language hint: en\n\nOutput language hint: ru\n\nTranscription mode: smart\n\n<transcript>\nraw text\n</transcript>",
            "Smart sends the app name, its own hints and the transcript"
        )
    }

    /// Scenario: the user dictates into a window full of private text (a chat
    /// thread, a document). Smart's request to the provider carries the app's
    /// name, Whytap's own instructions and hints and the dictated transcript,
    /// never the window's text, whatever the destination format.
    /// WHY: .project-docs/decisions/2026-11-22-smart-no-window-context.md
    func testSmartRequestCarriesOnlyTranscriptAndOwnPromptWhateverTheWindowShows() async throws {
        let env = makeEnv()
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/auto"), for: .dropSmartCleanup)
        for profile in [SmartFormattingProfile.plain, .slack, .telegram, .github, .commonMark] {
            let client = FakeOpenRouterClient(completion: "Проверь импорт.")
            _ = try await env.processor(client).processOutput(
                "ну проверь импорт", targetApp: "Telegram", language: "ru", transcriptionMode: "smart", formatting: profile
            )
            XCTAssertEqual(client.lastMessages.count, 2)
            XCTAssertEqual(client.lastMessages[0].role, "system")
            XCTAssertEqual(
                client.lastMessages[0].content,
                profile.instructions.map { PostProcessor.systemPrompt + "\n\n" + $0 } ?? PostProcessor.systemPrompt
            )
            XCTAssertEqual(
                client.lastMessages[1].content,
                "Active app: Telegram\n\nInput language hint: ru\n\nTranscription mode: smart\n\n<transcript>\nну проверь импорт\n</transcript>"
            )
            let sent = client.lastMessages.map(\.content).joined(separator: "\n")
            XCTAssertFalse(sent.contains("active_app_context"))
        }
    }

    func test_openrouter_route_without_key_throws_missing_key() async throws {
        let env = makeEnv()
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/auto"), for: .dropSmartCleanup)
        let openRouter = FakeOpenRouterClient(completion: "unused")

        do {
            _ = try await env.processor(openRouter).process("raw")
            XCTFail("Expected missing key")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .missingKey)
        }
        XCTAssertNil(openRouter.lastEndpoint)
    }

    func testDestinationFormattingUsesSelectedCleanupRoute() async throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Test", baseURL: "http://localhost:8000/v1")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "selected-model"), for: .dropSmartCleanup)
        let client = FakeOpenRouterClient(completion: "Проверь `timeout_ms`, пожалуйста.")
        let result = try await env.processor(client).process("Проверь timeout_ms", language: "ru", transcriptionMode: "smart", formatting: .commonMark)
        XCTAssertEqual(result, "Проверь `timeout_ms`, пожалуйста.")
        XCTAssertEqual(client.lastModel, "selected-model")
        XCTAssertTrue(client.lastMessages[0].content.contains("CommonMark"))
        XCTAssertTrue(client.lastMessages[0].content.hasPrefix(PostProcessor.systemPrompt))
    }

    func testServerRouteProcessesDirectlyWithoutRequiredKey() async throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Local", baseURL: "http://localhost:8000/v1")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "llama/local"), for: .dropSmartCleanup)
        let openRouter = FakeOpenRouterClient(completion: "cleaned by custom llm")

        let result = try await env.processor(openRouter).process("raw text")

        XCTAssertEqual(result, "cleaned by custom llm")
        XCTAssertEqual(openRouter.lastAPIKey, nil)
        XCTAssertEqual(openRouter.lastEndpoint?.baseURL.absoluteString, "http://localhost:8000/v1")
        XCTAssertEqual(openRouter.lastEndpoint?.requiresAPIKey, false)
        XCTAssertEqual(openRouter.lastEndpoint?.sendsOpenRouterHeaders, false)
        XCTAssertEqual(openRouter.lastModel, "llama/local")
    }

    func testSmartSolParagraphsAndListsReachDeliveryWithoutFlattening() async throws {
        let env = makeEnv()
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "openai/gpt-6-sol"), for: .dropSmartCleanup)
        let output = "Проверь импорт, пожалуйста.\n\nНа staging:\n- мм, сохрани валидацию;\n- проверь возврат;\n- не трогай production."
        let client = FakeOpenRouterClient(completion: output)
        let result = try await DropOutputPolicy(mode: .smart).prepare(rawText: "messy speech", fillerTerms: ["мм"]) {
            try await env.processor(client).process("messy speech", language: "ru", transcriptionMode: "smart")
        }
        XCTAssertEqual(result, "Проверь импорт, пожалуйста.\n\nНа staging:\n- Сохрани валидацию;\n- проверь возврат;\n- не трогай production.")
        XCTAssertEqual(client.lastModel, "openai/gpt-6-sol")
        XCTAssertEqual(client.lastMessages.first?.content, PostProcessor.systemPrompt)
    }

    func testSmartOutputLanguageHintAndEditorParagraphsArePreservedTogether() async throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Test", baseURL: "http://localhost:8000/v1")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "test-model"), for: .dropSmartCleanup)
        let output = "Please check the import.\n\nKeep validation enabled; do not change production."
        let client = FakeOpenRouterClient(completion: output)
        let result = try await env.processor(client).process("Проверь импорт", language: "ru", outputLanguage: "en", transcriptionMode: "smart")
        XCTAssertEqual(result, output)
        XCTAssertTrue(client.lastMessages.last?.content.contains("Output language hint: en") == true)
    }

    func testServerWithoutBaseURLDoesNotFallbackToBackend() async throws {
        let env = makeEnv()
        let server = env.routing.addServer(name: "Local", baseURL: "")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "llama/local"), for: .dropSmartCleanup)
        let openRouter = FakeOpenRouterClient(completion: "unused")

        do {
            _ = try await env.processor(openRouter).process("raw")
            XCTFail("Expected missing base URL")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .missingBaseURL)
        }
        XCTAssertNil(openRouter.lastEndpoint)
    }

    func test_model_refusal_is_recorded_for_cleanup() async throws {
        let env = makeEnv()
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "vendor/gone"), for: .dropSmartCleanup)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let checks = ModelCheckStore(defaults: defaults)

        for status in [400, 404, 422] {
            let processor = PostProcessor(
                llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: env.routing, keys: env.keys),
                openRouterClient: RefusingOpenRouterClient(status: status),
                checks: checks
            )
            do {
                _ = try await processor.process("raw")
                XCTFail("Expected the refusal to reach the caller")
            } catch let error as OpenRouterLLMError {
                XCTAssertEqual(error, .unexpectedStatus(status, nil))
            }
            XCTAssertEqual(checks.refusedModel(for: .dropSmartCleanup), "vendor/gone")
            checks.recordRefusal(feature: .dropSmartCleanup, model: "reset", at: Date())
        }

        // A key or quota problem is not a refusal of the model.
        checks.recordRefusal(feature: .dropSmartCleanup, model: "reset", at: Date())
        let unauthorized = PostProcessor(
            llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: env.routing, keys: env.keys),
            openRouterClient: RefusingOpenRouterClient(status: 401),
            checks: checks
        )
        _ = try? await unauthorized.process("raw")
        XCTAssertEqual(checks.refusedModel(for: .dropSmartCleanup), "reset")
    }

    func test_successful_cleanup_clears_the_refusal_of_that_model() async throws {
        let env = makeEnv()
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "vendor/back"), for: .dropSmartCleanup)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let checks = ModelCheckStore(defaults: defaults)
        checks.recordRefusal(feature: .dropSmartCleanup, model: "vendor/back", at: Date())

        let processor = PostProcessor(
            llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: env.routing, keys: env.keys),
            openRouterClient: FakeOpenRouterClient(completion: "clean"),
            checks: checks
        )
        _ = try await processor.process("raw")

        XCTAssertNil(checks.refusedModel(for: .dropSmartCleanup))
    }

    func test_cleanup_without_route_throws_not_configured() async throws {
        let env = makeEnv()
        // Another feature's route and a stored OpenRouter key do not choose
        // where cleanup goes.
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "notes"), for: .meetingNotes)
        let openRouter = FakeOpenRouterClient(completion: "unused")

        do {
            _ = try await env.processor(openRouter).process("raw")
            XCTFail("Expected notConfigured")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .notConfigured)
        }
        XCTAssertNil(openRouter.lastEndpoint)
    }

    func test_cleanup_uses_only_the_cleanup_route() async throws {
        let env = makeEnv()
        try env.keys.save("or-key", account: OpenRouterLLMKeyStore.account)
        let server = env.routing.addServer(name: "Local", baseURL: "http://llm.local:8080/v1")
        env.routing.setRoute(FeatureRoute(account: .server(server.id), model: "qwen"), for: .dropSmartCleanup)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "notes-model"), for: .meetingNotes)

        StubURLProtocol.reset()
        addTeardownBlock { StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in
            let body: [String: Any] = ["choices": [["message": ["role": "assistant", "content": "cleaned"]]]]
            return (200, [:], try JSONSerialization.data(withJSONObject: body))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }

        let result = try await env.processor(OpenRouterLLMClient(session: session, profile: .dictation))
            .process("raw")

        XCTAssertEqual(result, "cleaned")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://llm.local:8080/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(StubURLProtocol.capturedBodies.first)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "qwen")
    }
}

private final class FakeOpenRouterClient: OpenRouterLLMClienting {
    let completion: String
    var models: [OpenRouterModelOption]
    private(set) var lastEndpoint: OpenAICompatibleLLMEndpoint?
    var lastAPIKey: String? { lastEndpoint?.apiKey }
    private(set) var lastModel: String?
    private(set) var lastMessages: [OpenRouterChatMessage] = []

    init(
        completion: String,
        models: [OpenRouterModelOption] = [.init(id: "openrouter/auto", name: "Auto Router")]
    ) {
        self.completion = completion
        self.models = models
    }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        models
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        lastEndpoint = endpoint
        lastModel = model
        lastMessages = messages
        return completion
    }
}

private final class RefusingOpenRouterClient: OpenRouterLLMClienting {
    let status: Int

    init(status: Int) {
        self.status = status
    }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] {
        []
    }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        throw OpenRouterLLMError.unexpectedStatus(status, nil)
    }
}

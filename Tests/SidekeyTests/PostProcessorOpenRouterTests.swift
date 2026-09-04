import XCTest
@testable import Sidekey

final class PostProcessorOpenRouterTests: XCTestCase {
    @MainActor
    func testOpenRouterBYOKProcessesDirectlyWithoutBackendProcessCall() async throws {
        let defaults = UserDefaults(suiteName: "post.openrouter.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.llmLevel = .yourKey
        prefs.openRouterModel = "openrouter/auto"

        let keyStore = FakeOpenRouterKeyStore(key: "or-key")
        let openRouter = FakeOpenRouterClient(completion: "cleaned by openrouter")

        let processor = PostProcessor(
            prefs: prefs,
            llmKeyStore: keyStore,
            openRouterClient: openRouter,
        )

        let result = try await processor.process(
            "raw text",
            targetApp: "Slack",
            appContext: "Thread with Alice",
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
        XCTAssertTrue(openRouter.lastMessages.first?.content.contains("Главное правило") == true)
        let userMessage = try XCTUnwrap(openRouter.lastMessages.last?.content)
        XCTAssertTrue(userMessage.contains("Active app: Slack"))
        XCTAssertTrue(userMessage.contains("Thread with Alice"))
        XCTAssertTrue(userMessage.contains("<transcript>"))
        XCTAssertTrue(userMessage.contains("raw text"))
        XCTAssertTrue(userMessage.contains("Output language hint: ru"))
        XCTAssertTrue(userMessage.contains("Transcription mode: smart"))
    }

    @MainActor
    func testOpenRouterBYOKMissingKeyDoesNotFallbackToBackend() async throws {
        let defaults = UserDefaults(suiteName: "post.openrouter.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.llmLevel = .yourKey
        prefs.openRouterModel = "openrouter/auto"


        let processor = PostProcessor(
            prefs: prefs,
            llmKeyStore: FakeOpenRouterKeyStore(key: nil),
            openRouterClient: FakeOpenRouterClient(completion: "unused"),
        )

        do {
            _ = try await processor.process("raw", targetApp: nil)
            XCTFail("Expected missing key")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .missingKey)
        }

    }

    @MainActor
    func testCustomOpenAICompatibleProcessesDirectlyWithoutBackendOrRequiredKey() async throws {
        let defaults = UserDefaults(suiteName: "post.custom-llm.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.llmLevel = .custom
        prefs.customLLMBaseURL = "http://localhost:8000/v1"
        prefs.customLLMModel = "llama/local"

        let openRouter = FakeOpenRouterClient(completion: "cleaned by custom llm")

        let processor = PostProcessor(
            prefs: prefs,
            llmKeyStore: FakeOpenRouterKeyStore(key: nil),
            customLLMKeyStore: FakeOpenRouterKeyStore(key: nil),
            openRouterClient: openRouter,
        )

        let result = try await processor.process("raw text", targetApp: "Notes")

        XCTAssertEqual(result, "cleaned by custom llm")
        XCTAssertEqual(openRouter.lastAPIKey, nil)
        XCTAssertEqual(openRouter.lastEndpoint?.baseURL.absoluteString, "http://localhost:8000/v1")
        XCTAssertEqual(openRouter.lastEndpoint?.requiresAPIKey, false)
        XCTAssertEqual(openRouter.lastEndpoint?.sendsOpenRouterHeaders, false)
        XCTAssertEqual(openRouter.lastModel, "llama/local")
    }

    @MainActor
    func testCustomOpenAICompatibleMissingBaseURLDoesNotFallbackToBackend() async throws {
        let defaults = UserDefaults(suiteName: "post.custom-llm.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.llmLevel = .custom
        prefs.customLLMModel = "llama/local"


        let openRouter = FakeOpenRouterClient(completion: "unused")
        let processor = PostProcessor(
            prefs: prefs,
            llmKeyStore: FakeOpenRouterKeyStore(key: nil),
            customLLMKeyStore: FakeOpenRouterKeyStore(key: nil),
            openRouterClient: openRouter,
        )

        do {
            _ = try await processor.process("raw", targetApp: nil)
            XCTFail("Expected missing base URL")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .missingBaseURL)
        }

        XCTAssertNil(openRouter.lastEndpoint)
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

private final class FakeOpenRouterKeyStore: OpenRouterLLMKeyStoring {
    var key: String?

    init(key: String? = nil) {
        self.key = key
    }

    func save(key: String) throws {
        self.key = key
    }

    func read() throws -> String? {
        key
    }

    func delete() throws {
        key = nil
    }
}

import XCTest
@testable import Sidekey

/// With the `.local` LLM level selected, drop cleanup runs on-device through
/// `LocalLLMSession`; with a BYOK level it goes to the user's own endpoint.
/// Nothing here ever reaches a Whytap server.
final class PostProcessorLocalTests: XCTestCase {
    @MainActor
    func testLocalLLMCleanupRunsOnDevice() async throws {
        let defaults = UserDefaults(suiteName: "post.local.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.llmLevel = .local

        let localLLM = FakeLocalLLM(reply: "cleaned on device")
        let openRouter = FakeOpenRouterClient(completion: "should not be used")
        let evictSpy = EvictionSpy()

        let processor = PostProcessor(
            prefs: prefs,
            llmKeyStore: FakeOpenRouterKeyStore(key: nil),
            customLLMKeyStore: FakeOpenRouterKeyStore(key: nil),
            openRouterClient: openRouter,
            localLLM: localLLM,
            evictLocalLLM: { await evictSpy.record() }
        )

        let result = try await processor.process(
            "raw text",
            targetApp: "Slack",
            appContext: "Thread with Alice",
            language: "en",
            outputLanguage: "ru",
            transcriptionMode: "smart"
        )

        XCTAssertEqual(result, "cleaned on device")
        // The on-device weights are evicted after the local cleanup turn so STT
        // and the LLM are not co-resident at idle (ROO-257 persistent lag).
        try await evictSpy.waitForCount(1)
        // The OpenRouter direct path is not used on `.local`.
        XCTAssertNil(openRouter.lastEndpoint)
        // On-device session was driven once.
        XCTAssertEqual(localLLM.calls.count, 1)
        // Cleanup uses the SLIM local prompt, NOT the full ~25KB prompt
        // (ROO-257: the full prompt makes the 4-bit model emit empty/refusal).
        XCTAssertEqual(localLLM.calls.first?.system, PostProcessor.localCleanupSystemPrompt)
        XCTAssertNotEqual(localLLM.calls.first?.system, PostProcessor.systemPrompt)
        let userMessage = try XCTUnwrap(localLLM.calls.first?.user)
        XCTAssertTrue(userMessage.contains("<transcript>"))
        XCTAssertTrue(userMessage.contains("raw text"))
        XCTAssertTrue(userMessage.contains("Active app: Slack"))
        XCTAssertTrue(userMessage.contains("Transcription mode: smart"))
    }

    /// The direct (OpenRouter) route must NOT evict the local LLM — no
    /// on-device weights were loaded, so eviction is meaningless work (and
    /// would mask a routing regression where local accidentally ran).
    @MainActor
    func testDirectRouteDoesNotEvictLocalLLM() async throws {
        let defaults = UserDefaults(suiteName: "post.local.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.llmLevel = .yourKey

        let evictSpy = EvictionSpy()
        let localLLM = FakeLocalLLM(reply: "unused")

        let processor = PostProcessor(
            prefs: prefs,
            llmKeyStore: FakeOpenRouterKeyStore(key: "or-key"),
            customLLMKeyStore: FakeOpenRouterKeyStore(key: nil),
            openRouterClient: FakeOpenRouterClient(completion: "cleaned by openrouter"),
            localLLM: localLLM,
            evictLocalLLM: { await evictSpy.record() }
        )

        let result = try await processor.process("raw", targetApp: nil, transcriptionMode: "smart")
        XCTAssertEqual(result, "cleaned by openrouter")
        XCTAssertEqual(localLLM.calls.count, 0)
        // Give any erroneously-scheduled eviction a chance to fire.
        try await Task.sleep(nanoseconds: 20_000_000)
        let count = await evictSpy.count
        XCTAssertEqual(count, 0, "direct route must not evict the local LLM")
    }

    /// No usable route (BYOK level without a key) surfaces as an error the
    /// Drop path turns into a raw-transcript paste; the local model is never
    /// touched.
    @MainActor
    func testMissingKeyOnYourKeyLevelThrowsWithoutRunningLocalLLM() async {
        let defaults = UserDefaults(suiteName: "post.local.\(UUID().uuidString)")!
        let prefs = SelfKeyPreferences(defaults: defaults)
        prefs.llmLevel = .yourKey

        let localLLM = FakeLocalLLM(reply: "must not run")
        let processor = PostProcessor(
            prefs: prefs,
            llmKeyStore: FakeOpenRouterKeyStore(key: nil),
            customLLMKeyStore: FakeOpenRouterKeyStore(key: nil),
            openRouterClient: FakeOpenRouterClient(completion: "unused"),
            localLLM: localLLM
        )

        do {
            _ = try await processor.process("raw", targetApp: nil)
            XCTFail("expected missingKey")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .missingKey)
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(localLLM.calls.count, 0)
    }
}

/// Async-safe counter for the injected `evictLocalLLM` hook.
private actor EvictionSpy {
    private(set) var count = 0
    func record() { count += 1 }

    /// Poll until the eviction count reaches `target` (the hook fires from a
    /// detached `Task` after `process` returns, so it may land slightly after).
    func waitForCount(_ target: Int, timeoutMs: Int = 1000) async throws {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while count < target {
            if Date() > deadline {
                throw NSError(
                    domain: "EvictionSpy", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "eviction not observed: \(count)/\(target)"]
                )
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class FakeLocalLLM: LocalLLMCompleting, @unchecked Sendable {
    struct Call { let system: String; let user: String }
    let reply: String
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    init(reply: String) { self.reply = reply }

    func complete(system: String, user: String) async throws -> String {
        lock.lock()
        _calls.append(Call(system: system, user: user))
        lock.unlock()
        return reply
    }
}

private final class FakeOpenRouterClient: OpenRouterLLMClienting {
    let completion: String
    private(set) var lastEndpoint: OpenAICompatibleLLMEndpoint?
    private(set) var lastModel: String?
    private(set) var lastMessages: [OpenRouterChatMessage] = []

    init(completion: String) { self.completion = completion }

    func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] { [] }

    func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
        lastEndpoint = endpoint
        lastModel = model
        lastMessages = messages
        return completion
    }
}

private final class FakeOpenRouterKeyStore: OpenRouterLLMKeyStoring {
    var key: String?
    init(key: String? = nil) { self.key = key }
    func save(key: String) throws { self.key = key }
    func read() throws -> String? { key }
    func delete() throws { key = nil }
}

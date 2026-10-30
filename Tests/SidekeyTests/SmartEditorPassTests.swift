import XCTest
@testable import Sidekey

@MainActor
final class SmartEditorPassTests: XCTestCase {
    private final class Editor: OpenRouterLLMClienting {
        var calls = 0
        var response = PostProcessor.passMarker
        var cancels = false
        var error: Error?
        func listModels(endpoint: OpenAICompatibleLLMEndpoint) async throws -> [OpenRouterModelOption] { [] }
        func complete(endpoint: OpenAICompatibleLLMEndpoint, model: String, messages: [OpenRouterChatMessage]) async throws -> String {
            calls += 1
            if cancels { withUnsafeCurrentTask { $0?.cancel() } }
            if let error { throw error }
            return response
        }
    }

    private func environment() throws -> (UserDefaults, AIRoutingStore, ProviderKeyStore) {
        let suite = UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let routing = AIRoutingStore(defaults: defaults), box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("synthetic-key", account: OpenRouterLLMKeyStore.account)
        routing.setRoute(.init(account: .openRouter, model: "openai/gpt-6-sol", provider: "openai/fast"), for: .dropSmartCleanup)
        return (defaults, routing, keys)
    }

    private func processor(_ routing: AIRoutingStore, _ keys: ProviderKeyStore, _ editor: Editor) -> PostProcessor {
        PostProcessor(llmRoute: .init(feature: .dropSmartCleanup, routing: routing, keys: keys), openRouterClient: editor)
    }

    func testPassUsesOneEditorCallAndVerbatimPlainDeliveryForRichDestinations() async throws {
        let (_, routing, keys) = try environment(), editor = Editor()
        editor.response = " \n" + PostProcessor.passMarker + "\n"
        let raw = "Проверь a*b*c, __literal__ и https://example.invalid/a_b."
        let output = try await processor(routing, keys, editor).processOutput(raw, targetApp: "Telegram", formatting: .telegram)
        XCTAssertEqual(output.text, raw)
        XCTAssertFalse(output.usedEditor)
        XCTAssertEqual(output.deliveryProfile(.telegram), .plain)
        XCTAssertEqual(editor.calls, 1)
        XCTAssertNil(routing.route(for: .dropSmartDecision))
    }

    func testUsefulEditKeepsFormattingAndIdenticalOutputStaysPlain() async throws {
        let (_, routing, keys) = try environment(), editor = Editor()
        editor.response = "Исправленная мысль.\n\nЕщё одна тема."
        let output = try await processor(routing, keys, editor).processOutput("broken speech", targetApp: "Slack", formatting: .slack)
        XCTAssertEqual(output.text, editor.response)
        XCTAssertTrue(output.usedEditor)
        XCTAssertEqual(output.deliveryProfile(.slack), .slack)
        let raw = "literal *word*"
        editor.response = raw
        let unchanged = try await processor(routing, keys, editor).processOutput(raw, targetApp: "Slack", formatting: .slack)
        XCTAssertEqual(unchanged.text, raw)
        XCTAssertFalse(unchanged.usedEditor)
    }

    func testOrdinaryPassAndZeroAreTextNotControlVerdicts() async throws {
        let (_, routing, keys) = try environment(), editor = Editor()
        for text in ["0", "pass", "PASS", "pass в Python", "Верни pass, если всё подходит."] {
            editor.response = text
            let output = try await processor(routing, keys, editor).processOutput("Synthetic transcription", targetApp: nil)
            XCTAssertEqual(output.text, text)
            XCTAssertTrue(output.usedEditor)
        }
    }

    func testTranslationCannotPassAndMalformedControlOrEmptyOutputReachesRetry() async throws {
        let (_, routing, keys) = try environment(), editor = Editor()
        do {
            _ = try await processor(routing, keys, editor).process("Привет", targetApp: nil, outputLanguage: "en")
            XCTFail("Translation must not silently use the transcript")
        } catch let error as OpenRouterLLMError {
            guard case .decoding = error else { return XCTFail("Unexpected error") }
        }
        for response in ["<WHYTAP_PASS> because it is clean", "<WHYTAP_PAS", " \n"] {
            editor.response = response
            do {
                _ = try await processor(routing, keys, editor).process("Synthetic transcription", targetApp: nil)
                XCTFail("Malformed/empty output must reach Retry")
            } catch { XCTAssertTrue(error is OpenRouterLLMError) }
        }
        editor.error = URLError(.timedOut)
        do {
            _ = try await processor(routing, keys, editor).process("Synthetic transcription", targetApp: nil)
            XCTFail("An editor failure must reach Retry")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    }

    func testCancelledEditorCannotDeliverPassOrEditedText() async throws {
        let (_, routing, keys) = try environment(), editor = Editor()
        editor.cancels = true
        let task = Task { try await processor(routing, keys, editor).process("Synthetic transcription", targetApp: nil) }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRetirementRemovesOnlyDecisionRouteAndKeepsHistoryDecodable() throws {
        let (defaults, routing, _) = try environment()
        let cleanup = try XCTUnwrap(routing.route(for: .dropSmartCleanup))
        var state = routing.state
        let decision = FeatureRoute(account: .openRouter, model: "typesafe/jev-1.14")
        state.routes[AIFeature.dropSmartDecision.rawValue] = decision
        state.migratedRoutes[AIFeature.dropSmartDecision.rawValue] = decision
        state.routes[AIFeature.agent.rawValue] = .init(account: .openRouter, model: "agent", provider: "pinned")
        state.migrationVersion = 3
        defaults.set(try JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)
        let restored = AIRoutingStore(defaults: defaults)
        XCTAssertNil(restored.route(for: .dropSmartDecision))
        restored.retireSmartDecisionIfNeeded()
        XCTAssertEqual(restored.state.migrationVersion, 4)
        XCTAssertNil(restored.state.routes[AIFeature.dropSmartDecision.rawValue])
        XCTAssertNil(restored.state.migratedRoutes[AIFeature.dropSmartDecision.rawValue])
        XCTAssertEqual(restored.route(for: .dropSmartCleanup), cleanup)
        XCTAssertEqual(restored.route(for: .agent), state.routes[AIFeature.agent.rawValue])
        let saved = defaults.data(forKey: AIRoutingStore.defaultsKey)
        restored.retireSmartDecisionIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), saved)
        restored.setRoute(decision, for: .dropSmartDecision)
        XCTAssertNil(restored.state.routes[AIFeature.dropSmartDecision.rawValue])
        XCTAssertEqual(try JSONDecoder().decode(AIFeature.self, from: Data(#""dropSmartDecision""#.utf8)), .dropSmartDecision)
        XCTAssertFalse(AIFeature.activeCases.contains(.dropSmartDecision))
        XCTAssertTrue(AIFeature.allCases.contains(.dropSmartDecision))
        // Jev returns only as the Meeting Assistant detector's decision model, never for Smart text.
        XCTAssertTrue(ModelRegistry.models.filter { $0.id.hasPrefix("typesafe/jev-") }.allSatisfy { $0.uses == [.decision] })
        XCTAssertEqual(AIFeature.activeCases.filter { $0.mode == .decision }, [.meetingAssistantDetector])
        XCTAssertTrue(AIProviderKind.allCases.allSatisfy { AIFeature.dropSmartDecision.modelUse(on: $0) == nil })
    }

    func testCatalogStillExcludesDecisionModelsFromTextGeneration() throws {
        let models = try ModelCatalogFetcher.parseOpenRouter(Data(#"{"data":[{"id":"typesafe/jev-1.14","architecture":{"output_modalities":["text"]}},{"id":"example/decision","architecture":{"output_modalities":["decision"]}},{"id":"example/chat","architecture":{"output_modalities":["text"]}}]}"#.utf8))
        XCTAssertEqual(models.first { $0.id == "typesafe/jev-1.14" }?.uses, [.decision])
        XCTAssertEqual(models.first { $0.id == "example/decision" }?.uses, [.decision])
        XCTAssertEqual(models.first { $0.id == "example/chat" }?.uses, [.chat])
        XCTAssertNotNil(ModelRegistry.knownUnsupportedReason("typesafe/jev-1.14", kind: .openRouter, use: .chat))
    }

    func testUnreadableRoutingIsNotRewrittenAndRetiredChoiceNeverResolves() throws {
        let (defaults, routing, keys) = try environment()
        var state = routing.state
        state.routes[AIFeature.dropSmartDecision.rawValue] = .init(account: .openAI, model: "gpt-6-luna")
        state.migrationVersion = 3
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var routes = try XCTUnwrap(object["routes"] as? [String: Any])
        routes["future-feature"] = ["account": "unknown-new-account", "model": "future-model"]
        object["routes"] = routes
        let original = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        defaults.set(original, forKey: AIRoutingStore.defaultsKey)
        let restored = AIRoutingStore(defaults: defaults)
        restored.retireSmartDecisionIfNeeded()
        XCTAssertEqual(defaults.data(forKey: AIRoutingStore.defaultsKey), original)
        XCTAssertEqual(restored.route(for: .dropSmartCleanup), routing.route(for: .dropSmartCleanup))
        XCTAssertNil(restored.route(for: .dropSmartDecision))
        let resolver = FeatureRouteResolver(routing: restored, keys: keys)
        XCTAssertThrowsError(try resolver.resolve(.dropSmartDecision))
        XCTAssertThrowsError(try resolver.resolve(.init(account: .openAI, model: "gpt-6-luna"), for: .dropSmartDecision))
    }
}

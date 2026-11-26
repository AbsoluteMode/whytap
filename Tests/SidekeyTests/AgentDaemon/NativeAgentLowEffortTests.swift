import XCTest
@testable import Sidekey

/// The built-in Agent asks direct Anthropic and OpenAI models for low effort,
/// accepts a plain-text answer on Anthropic, and reports long or cut answers
/// plainly. Each scenario runs the real native loop against a stubbed provider.
@MainActor
final class NativeAgentLowEffortTests: XCTestCase {
    private func fixture() throws -> (URL, ProviderKeyStore, NativeAgentHTTP) {
        // The Agent's in-memory refusal list is process-wide: start clean.
        NativeAgentEffort.refusals.removeAll()
        StubURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        try keys.save("router-key", account: OpenRouterLLMKeyStore.account)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); StubURLProtocol.reset(); try? FileManager.default.removeItem(at: directory) }
        return (directory, keys, NativeAgentHTTP(session: session))
    }

    private func serve(_ object: [String: Any]) -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    private func finish(_ answer: String) -> [String: Any] {
        ["status": "answered", "answer": answer, "sources": [], "actions": []]
    }

    private func anthropicFinal(_ answer: String) -> [String: Any] {
        ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "final", "name": "finish_answer", "input": finish(answer)]]]
    }

    private func openAIFinal(_ answer: String) -> [String: Any] {
        let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: finish(answer)), as: UTF8.self)
        return ["status": "completed", "output": [["type": "function_call", "call_id": "final", "name": "finish_answer",
                                                    "arguments": arguments]]]
    }

    private func routerFinal(_ answer: String) -> [String: Any] {
        let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: finish(answer)), as: UTF8.self)
        return ["choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "final", "type": "function",
            "function": ["name": "finish_answer", "arguments": arguments]]]], "finish_reason": "tool_calls"]]]
    }

    private struct Result {
        let store: AskResponseStore
        let bodies: [[String: Any]]
        let requests: [URLRequest]
        let diagnostics: [NativeAgentDiagnostics.Event]
        let sessionID: String?
    }

    /// One turn whose provider answers with `steps` in order.
    private func run(_ prompt: String, _ options: AgentRunOptions, _ steps: [[String: Any]]) async throws -> Result {
        let (directory, keys, http) = try fixture()
        var index = 0
        StubURLProtocol.handler = { _ in
            defer { index += 1 }
            return self.serve(steps[min(index, steps.count - 1)])
        }
        var diagnostics: [NativeAgentDiagnostics.Event] = []
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, appControl: { nil },
                                           usageSink: { _ in }, diagnosticsSink: { diagnostics.append($0) })
        let store = AskResponseStore()
        await store.consume(provider.run(prompt: prompt, resumeSessionID: nil, options: options))
        let bodies = try StubURLProtocol.capturedBodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        return Result(store: store, bodies: bodies, requests: StubURLProtocol.capturedRequests,
                      diagnostics: diagnostics, sessionID: provider.lastSessionID)
    }

    private func anthropic(_ model: String = "claude-sonnet-5-5", lowEffort: Bool? = nil,
                           spec: OpenCodeModelSpec? = nil) -> AgentRunOptions {
        AgentRunOptions(model: model, allowActions: false, openCodeModelSpec: spec, openCodeProvider: .anthropic,
                        lowEffortSupport: lowEffort)
    }

    private func effort(_ body: [String: Any]) -> String? {
        (body["output_config"] as? [String: Any])?["effort"] as? String
    }

    // MARK: Simple question

    /// Maxim's case: "160 умножить на 120" on Sonnet 5.5. One request at low
    /// effort; the model's plain-text reply is shown and kept as the answer.
    func testSimpleQuestionOnSonnetIsOneLowEffortRequestAndItsPlainReplyIsTheAnswer() async throws {
        let result = try await run("160 умножить на 120", anthropic(), [
            ["stop_reason": "end_turn", "content": [["type": "text", "text": "19 200"]],
             "usage": ["input_tokens": 8100, "output_tokens": 12, "output_tokens_details": ["thinking_tokens": 0]]]
        ])
        XCTAssertEqual(result.store.status, .ready, result.store.errorMessage ?? "")
        XCTAssertEqual(result.store.streamingText, "19 200")
        XCTAssertEqual(result.bodies.count, 1, "no repair request")
        let body = result.bodies[0]
        XCTAssertEqual(effort(body), "low")
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "between_tools",
                       "Sonnet 5.5 gets its lowest thinking also beside the provider's search")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_384)
        XCTAssertEqual(result.requests.first?.timeoutInterval, 180)
        XCTAssertNotNil(result.sessionID, "the answer is kept for a follow-up")
        // Diagnostics: the level asked for and the tokens spent, no text.
        let accepted = try XCTUnwrap(result.diagnostics.last)
        XCTAssertEqual(accepted.stage, .accepted)
        XCTAssertEqual(accepted.effort, .low)
        XCTAssertEqual(accepted.usage, .init(input: 8100, output: 12, thinking: 0))
        XCTAssertFalse(accepted.json?.contains("19 200") == true)
    }

    /// A plain reply still has to be an answer: blank text or a bare link
    /// list fails as before, and OpenRouter keeps its structured-only rule.
    func testPlainReplyIsCheckedLikeAStructuredAnswer() async throws {
        for text in ["   ", "https://example.com\nhttps://example.org"] {
            let result = try await run("question", anthropic(), [["stop_reason": "end_turn", "content": [["type": "text", "text": text]]]])
            XCTAssertEqual(result.store.status, .failed, text)
            XCTAssertTrue(result.store.errorMessage?.contains("structured answer") == true)
            XCTAssertNil(result.sessionID)
        }
        let router = try await run("question", AgentRunOptions(model: "anthropic/claude-sonnet-5.5", allowActions: false), [
            ["choices": [["message": ["role": "assistant", "content": "19 200"], "finish_reason": "stop"]]]
        ])
        XCTAssertEqual(router.store.status, .failed)
    }

    /// Only a finished reply counts: `end_turn` with text (and thinking)
    /// blocks. A tool_use stop with text only, or text inside an unknown
    /// block, fails and is not saved; thinking beside the text is fine.
    func testOnlyAFinishedTextReplyIsAPlainAnswer() async throws {
        let rejected: [[String: Any]] = [
            ["stop_reason": "tool_use", "content": [["type": "text", "text": "19 200"]]],
            ["stop_reason": "end_turn", "content": [["type": "future_block", "text": "19 200"]]],
            ["stop_reason": "end_turn", "content": [["type": "text", "text": "19 200"], ["type": "future_block", "text": "x"]]],
        ]
        for response in rejected {
            let result = try await run("160 умножить на 120", anthropic(), [response])
            XCTAssertEqual(result.store.status, .failed, "\(response)")
            XCTAssertTrue(result.store.streamingText.isEmpty)
            XCTAssertNil(result.sessionID, "nothing is saved")
            XCTAssertEqual(result.bodies.count, 1, "no repair request")
        }
        let thinking = try await run("160 умножить на 120", anthropic(), [
            ["stop_reason": "end_turn", "content": [["type": "thinking", "thinking": "160*120", "signature": "s"],
                                                    ["type": "text", "text": "19 200"]]]
        ])
        XCTAssertEqual(thinking.store.streamingText, "19 200")
        XCTAssertNotNil(thinking.sessionID)
    }

    /// A plain reply has no sources or actions of its own, but a link and a
    /// shell command in its text become the same cards a finish_answer with
    /// that text gets, as for every answer.
    func testPlainReplyWithALinkAndAShellCommandGetsTheSameCardsAsFinishAnswer() async throws {
        let answer = "Install it:\n\n```bash\nbrew install whytap\n```\n\nDocs: https://example.com/install"
        func cards(_ response: [String: Any]) async throws -> (String?, [String]) {
            let (directory, keys, http) = try fixture()
            StubURLProtocol.handler = { _ in self.serve(response) }
            let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, appControl: { nil },
                                               usageSink: { _ in }, diagnosticsSink: { _ in })
            var final: String?, items: [String] = []
            for await event in provider.run(prompt: "how do I install whytap?", resumeSessionID: nil, options: anthropic()) {
                if case .finalAnswer(let text) = event { final = text }
                if case .blockComplete(.usefulActions(let block)) = event { items = block.items.map(\.insertText) }
            }
            return (final, items)
        }
        let plain = try await cards(["stop_reason": "end_turn", "content": [["type": "text", "text": answer]]])
        let structured = try await cards(anthropicFinal(answer))
        XCTAssertEqual(plain.0, answer)
        XCTAssertEqual(plain.0, structured.0)
        XCTAssertEqual(plain.1, structured.1)
        XCTAssertTrue(plain.1.contains("https://example.com/install"), "\(plain.1)")
        XCTAssertTrue(plain.1.contains("brew install whytap"), "\(plain.1)")
    }

    // MARK: Question with a tool

    /// A question that needs a tool: the model still calls it at low effort,
    /// the tool runs, and every request of the turn carries the same level.
    func testToolQuestionStillCallsTheToolAndEveryRequestStaysLow() async throws {
        let result = try await run("what is in my workspace?", anthropic("claude-opus-5-5"), [
            ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": "list_directory", "input": ["path": NSNull()]]]],
            anthropicFinal("The workspace holds AGENTS.md.")
        ])
        XCTAssertEqual(result.store.status, .ready, result.store.errorMessage ?? "")
        XCTAssertEqual(result.store.streamingText, "The workspace holds AGENTS.md.")
        XCTAssertEqual(result.bodies.count, 2)
        XCTAssertEqual(result.bodies.map(effort), ["low", "low"])
        let messages = try XCTUnwrap(result.bodies[1]["messages"] as? [[String: Any]])
        let toolResult = (messages.last?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(toolResult?["type"] as? String, "tool_result")
        XCTAssertEqual(toolResult?["tool_use_id"] as? String, "t1")
    }

    /// OpenAI Responses: reasoning models get the lowest `reasoning.effort`
    /// they take with the required finish_answer; chat and pre-reasoning
    /// models get nothing.
    func testOpenAIReasoningModelsGetTheirLowestReasoningEffortOthersGetNone() async throws {
        for (model, expected) in [("gpt-6.2-astra", "low"), ("gpt-5.5-2026-04-23", "none"), ("o4-mini", "low"),
                                  ("gpt-4.1", nil), ("gpt-5-chat-latest", nil), ("gpt-5-pro", nil)] {
            let result = try await run("160 × 120", AgentRunOptions(model: model, allowActions: false, openCodeProvider: .openAI),
                                       [openAIFinal("19,200")])
            XCTAssertEqual(result.store.streamingText, "19,200", model)
            let body = try XCTUnwrap(result.bodies.first)
            XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, expected, model)
            XCTAssertNil(body["output_config"], model)
            XCTAssertEqual(body["tool_choice"] as? String, "required", model)
            XCTAssertEqual(body["max_output_tokens"] as? Int, 16_384, model)
            XCTAssertEqual(result.requests.first?.timeoutInterval, 180, model)
        }
    }

    // MARK: Models without the parameter

    /// Anthropic: the Models API flag wins; without it, only families the
    /// effort page lists get it. OpenRouter without a catalog entry gets nothing.
    func testEffortIsSentOnlyToModelsThatTakeIt() async throws {
        let cases: [(AgentRunOptions, String?)] = [
            (anthropic("claude-haiku-5-5"), "low"),
            (anthropic("claude-opus-4-5-20251101"), "low"),
            (anthropic("claude-sonnet-4-5"), nil),
            (anthropic("claude-haiku-4-5"), nil),
            (anthropic("claude-sonnet-5-5", lowEffort: false), nil),
            (anthropic("claude-future-7", lowEffort: true), "low"),
        ]
        for (options, expected) in cases {
            let result = try await run("hi", options, [anthropicFinal("Hello.")])
            XCTAssertEqual(result.store.status, .ready, options.model ?? "")
            XCTAssertEqual(effort(try XCTUnwrap(result.bodies.first)), expected, options.model ?? "")
        }
        let router = try await run("hi", AgentRunOptions(model: "anthropic/claude-sonnet-5.5", allowActions: false), [routerFinal("Hello.")])
        let body = try XCTUnwrap(router.bodies.first)
        XCTAssertNil(body["output_config"]); XCTAssertNil(body["reasoning"])
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertEqual(router.requests.first?.timeoutInterval, 60)
        XCTAssertNil(router.diagnostics.last?.effort)
    }

    // MARK: Long answers

    /// A long answer fits: the request allows 16,384 output tokens (or the
    /// model's own lower limit), and a 20,000-character answer is shown whole.
    func testLongAnswerFitsTheOutputLimitAndAModelLimitBelowItWins() async throws {
        let long = String(repeating: "Шаг: проверить настройку и записать результат. ", count: 420)
        let result = try await run("explain everything", anthropic(), [anthropicFinal(long)])
        XCTAssertEqual(result.store.status, .ready, result.store.errorMessage ?? "")
        XCTAssertEqual(result.store.streamingText, long.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(result.bodies.first?["max_tokens"] as? Int, 16_384)
        let small = try await run("hi", anthropic(spec: OpenCodeModelSpec(toolCall: true, reasoning: true, contextLimit: 200_000, outputLimit: 4096)),
                                  [anthropicFinal("Hello.")])
        XCTAssertEqual(small.bodies.first?["max_tokens"] as? Int, 4096)
    }

    /// A catalog entry with an output limit but no context length (no spec):
    /// its limit wins over the raised cap. A snapshot without a limit, as
    /// saved before, keeps the cap.
    func testCatalogOutputLimitWinsWithoutContextLength() async throws {
        func options(_ entry: CatalogModel) throws -> AgentRunOptions {
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
            addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
            let snapshot = CatalogSnapshot(models: [entry], fetchedAt: Date(), lastRefreshFailed: false, limited: false)
            try JSONEncoder().encode([ProviderAccount.anthropic.storageID: snapshot]).write(to: file)
            let routing = AIRoutingStore(defaults: defaults)
            routing.setRoute(FeatureRoute(account: .anthropic, model: entry.id), for: .agent)
            return AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing,
                                      catalogs: ModelCatalogStore(fileURL: file)).options(for: .native)
        }
        let partial = try options(CatalogModel(id: "claude-sonnet-5-5", maxOutputTokens: 8192))
        XCTAssertNil(partial.openCodeModelSpec)
        XCTAssertEqual(partial.outputTokenLimit, 8192)
        let sent = try await run("hi", partial, [anthropicFinal("Hello.")])
        XCTAssertEqual(sent.bodies.first?["max_tokens"] as? Int, 8192)
        let old = try JSONDecoder().decode(CatalogModel.self, from: Data(#"{"id":"claude-sonnet-5-5","contextLength":200000}"#.utf8))
        let oldOptions = try options(old)
        XCTAssertNil(oldOptions.outputTokenLimit)
        XCTAssertEqual(oldOptions.openCodeModelSpec?.outputLimit, 16_384)
        let oldSent = try await run("hi", oldOptions, [anthropicFinal("Hello.")])
        XCTAssertEqual(oldSent.bodies.first?["max_tokens"] as? Int, 16_384)
    }

    /// OpenRouter's HTTP-200 error envelope: the single failed event keeps
    /// the typed envelope and the response's token counts.
    func testOpenRouterHTTP200ErrorKeepsUsageOnTheFailedEvent() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { _ in self.serve(["error": ["message": "PRIVATE", "metadata": ["error_type": "invalid_request"]],
                                                     "usage": ["prompt_tokens": 123, "completion_tokens": 45, "cost": 0.001]]) }
        var diagnostics: [NativeAgentDiagnostics.Event] = []
        var model = NativeAgentModel(options: .init(model: "vendor/model"), key: "key", system: "system", history: [], prompt: "q",
                                     http: http, usageSink: { _ in }, diagnosticsSink: { diagnostics.append($0) })
        do { _ = try await model.next(tools: []); XCTFail("Expected error") } catch {}
        XCTAssertEqual(diagnostics.map(\.stage), [.request, .failed])
        XCTAssertEqual(diagnostics.last?.error?.envelope, .root200)
        XCTAssertEqual(diagnostics.last?.usage, .init(input: 123, output: 45))
        XCTAssertFalse(diagnostics.compactMap(\.json).joined().contains("PRIVATE"))
    }

    /// An answer cut at the limit says so instead of a generic failure, on
    /// both direct routes, with the usage still in diagnostics.
    func testAnswerCutAtTheOutputLimitSaysSo() async throws {
        let cut = try await run("write a book", anthropic(), [
            ["stop_reason": "max_tokens", "content": [["type": "text", "text": "Chapter one"]],
             "usage": ["input_tokens": 8000, "output_tokens": 16_384, "output_tokens_details": ["thinking_tokens": 900]]]
        ])
        XCTAssertEqual(cut.store.status, .failed)
        XCTAssertEqual(cut.store.errorMessage, NativeAgentModel.outputLimitMessage)
        XCTAssertTrue(cut.store.streamingText.isEmpty)
        XCTAssertEqual(cut.diagnostics.last?.stage, .failed)
        XCTAssertEqual(cut.diagnostics.last?.usage?.thinking, 900)
        let openAI = try await run("write a book", AgentRunOptions(model: "gpt-6.2-astra", allowActions: false, openCodeProvider: .openAI), [
            ["status": "incomplete", "incomplete_details": ["reason": "max_output_tokens"], "output": [],
             "usage": ["input_tokens": 8000, "output_tokens": 16_384, "output_tokens_details": ["reasoning_tokens": 16_000]]]
        ])
        XCTAssertEqual(openAI.store.errorMessage, NativeAgentModel.outputLimitMessage)
        XCTAssertEqual(openAI.diagnostics.last?.usage?.thinking, 16_000)
    }

    // MARK: Catalog

    /// Anthropic's Models API states low effort per model.
    func testAnthropicCatalogReadsLowEffortSupport() throws {
        let page = """
        {"data": [
          {"id": "claude-sonnet-5-5", "capabilities": {"effort": {"supported": true, "low": {"supported": true}}}},
          {"id": "claude-a", "capabilities": {"effort": {"supported": false}}},
          {"id": "claude-b", "capabilities": {"effort": {"supported": true, "low": {"supported": false}}}},
          {"id": "claude-c", "capabilities": {"effort": "odd", "thinking": {"supported": true}}},
          {"id": "claude-d"}
        ], "has_more": false}
        """
        let models = try ModelCatalogFetcher.parseAnthropicPage(Data(page.utf8)).models
        XCTAssertEqual(models.map(\.supportsLowEffort), [true, false, false, nil, nil])
        XCTAssertEqual(models[3].supportsReasoning, true, "an odd effort value costs only that flag")
    }

    /// The saved catalog's flag reaches the turn's options; a snapshot saved
    /// before the flag existed still loads, and the family list decides.
    func testSavedCatalogFlagReachesTheTurnAndOldSnapshotsStillLoad() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let snapshot = CatalogSnapshot(models: [CatalogModel(id: "claude-sonnet-5-5", supportsLowEffort: false)],
                                       fetchedAt: Date(), lastRefreshFailed: false, limited: false)
        try JSONEncoder().encode([ProviderAccount.anthropic.storageID: snapshot]).write(to: file)
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(FeatureRoute(account: .anthropic, model: "claude-sonnet-5-5"), for: .agent)
        let options = AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing,
                                         catalogs: ModelCatalogStore(fileURL: file)).options(for: .native)
        XCTAssertEqual(options.lowEffortSupport, false)
        XCTAssertNil(NativeAgentEffort.request(provider: .anthropic, model: "claude-sonnet-5-5", catalogFlag: options.lowEffortSupport,
                                               providerSearch: true))
        let old = try JSONDecoder().decode(CatalogModel.self, from: Data(#"{"id":"claude-sonnet-5-5"}"#.utf8))
        XCTAssertNil(old.supportsLowEffort)
        XCTAssertNotNil(NativeAgentEffort.request(provider: .anthropic, model: old.id, catalogFlag: old.supportsLowEffort))
    }

    func testUsageReadsEachProvidersTokenFields() {
        XCTAssertEqual(NativeAgentDiagnostics.Usage(["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 7,
                                                     "cache_creation_input_tokens": 3, "output_tokens_details": ["thinking_tokens": 2]]),
                       .init(input: 10, output: 5, thinking: 2, cacheRead: 7, cacheWrite: 3))
        XCTAssertEqual(NativeAgentDiagnostics.Usage(["input_tokens": 10, "output_tokens": 5, "input_tokens_details": ["cached_tokens": 4],
                                                     "output_tokens_details": ["reasoning_tokens": 3]]),
                       .init(input: 10, output: 5, thinking: 3, cacheRead: 4))
        XCTAssertEqual(NativeAgentDiagnostics.Usage(["prompt_tokens": 10, "completion_tokens": 5,
                                                     "completion_tokens_details": ["reasoning_tokens": 1]]),
                       .init(input: 10, output: 5, thinking: 1))
        XCTAssertNil(NativeAgentDiagnostics.Usage(nil))
        XCTAssertEqual(NativeAgentDiagnostics.Usage(["input_tokens": "secret", "output_tokens": -1]), .init())
    }
}

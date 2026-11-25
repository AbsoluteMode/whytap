import XCTest
@testable import Sidekey

/// The built-in Agent asks for the least reasoning its model accepts, keeps
/// tool calls working, steps up where the provider's web search needs it, and
/// repeats a refused request without the fields. Each scenario runs the real
/// native loop against a stubbed provider.
@MainActor
final class NativeAgentMinimalReasoningTests: XCTestCase {
    private struct Result {
        let store: AskResponseStore
        let bodies: [[String: Any]]
        let diagnostics: [NativeAgentDiagnostics.Event]
        let usage: [AIUsageEvent]
    }

    private var refusals: SmartReasoningRefusals!

    override func setUp() async throws {
        refusals = SmartReasoningRefusals()
    }

    private func json(_ object: [String: Any], status: Int = 200) -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    private func finish(_ answer: String) -> [String: Any] {
        ["status": "answered", "answer": answer, "sources": [], "actions": []]
    }

    private func anthropicFinal(_ answer: String) -> [String: Any] {
        ["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "final", "name": "finish_answer", "input": finish(answer)]],
         "usage": ["input_tokens": 900, "output_tokens": 20, "output_tokens_details": ["thinking_tokens": 0]]]
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

    /// One turn; the provider answers request `n` with `steps[n]` (the last
    /// one again after that).
    private func run(_ prompt: String, _ options: AgentRunOptions,
                     _ steps: [(Int, [String: String], Data)]) async throws -> Result {
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
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
        var index = 0
        StubURLProtocol.handler = { _ in
            defer { index += 1 }
            return steps[min(index, steps.count - 1)]
        }
        var diagnostics: [NativeAgentDiagnostics.Event] = []
        var usage: [AIUsageEvent] = []
        let provider = NativeAgentProvider(keys: keys, http: NativeAgentHTTP(session: session), workspace: { directory },
                                           appControl: { nil }, usageSink: { usage.append($0) },
                                           diagnosticsSink: { diagnostics.append($0) }, reasoningRefusals: refusals)
        let store = AskResponseStore()
        await store.consume(provider.run(prompt: prompt, resumeSessionID: nil, options: options))
        let bodies = try StubURLProtocol.capturedBodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        StubURLProtocol.reset()
        return Result(store: store, bodies: bodies, diagnostics: diagnostics, usage: usage)
    }

    /// `search: false`: the catalog says the model has no web search of its
    /// own, so the turn runs without the provider's search tool.
    private func anthropic(_ model: String, search: Bool = true) -> AgentRunOptions {
        AgentRunOptions(model: model, allowActions: false, openCodeProvider: .anthropic, webSearchSupport: search ? nil : false)
    }

    private func openAI(_ model: String, search: Bool = true) -> AgentRunOptions {
        AgentRunOptions(model: model, allowActions: false, openCodeProvider: .openAI, webSearchSupport: search ? nil : false)
    }

    private func effort(_ body: [String: Any]) -> String? { (body["output_config"] as? [String: Any])?["effort"] as? String }
    private func thinking(_ body: [String: Any]) -> String? { (body["thinking"] as? [String: Any])?["type"] as? String }
    private func reasoning(_ body: [String: Any]) -> String? { (body["reasoning"] as? [String: Any])?["effort"] as? String }
    private func toolTypes(_ body: [String: Any]) -> [String] {
        (body["tools"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
    }

    // MARK: Anthropic

    /// A question that needs a tool on Claude Haiku 5.5: thinking is off on
    /// every request of the turn, the tool still runs and its result goes
    /// back, and the stored events name the setting.
    func testHaikuTurnWithAToolRunsWithThinkingOffOnEveryRequest() async throws {
        let result = try await run("what is in my workspace?", anthropic("claude-haiku-5-5"), [
            json(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": "list_directory", "input": ["path": NSNull()]]]]),
            json(anthropicFinal("The workspace is empty.")),
        ])
        XCTAssertEqual(result.store.status, .ready, result.store.errorMessage ?? "")
        XCTAssertEqual(result.store.streamingText, "The workspace is empty.")
        XCTAssertEqual(result.bodies.count, 2)
        XCTAssertEqual(result.bodies.map(effort), ["low", "low"])
        XCTAssertEqual(result.bodies.map(thinking), ["disabled", "disabled"])
        XCTAssertTrue(toolTypes(result.bodies[0]).contains("web_search_20250305"), "the provider's search stays in the turn")
        let toolResult = ((result.bodies[1]["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(toolResult?["tool_use_id"] as? String, "t1")
        let accepted = try XCTUnwrap(result.diagnostics.last)
        XCTAssertEqual(accepted.stage, .accepted)
        XCTAssertEqual(accepted.effort, .low)
        XCTAssertEqual(accepted.thinking, .disabled)
        XCTAssertNil(accepted.effortRetry)
        XCTAssertEqual(accepted.usage?.thinking, 0)
    }

    /// Claude Sonnet 5.5 cannot take `disabled`. Without the provider's
    /// search it gets `between_tools`; in a turn with that search it keeps
    /// its own thinking at low effort, because with `between_tools` it
    /// repeats finish_answer after a search.
    func testSonnetGetsBetweenToolsOnlyInATurnWithoutProviderSearch() async throws {
        let plain = try await run("160 умножить на 120", anthropic("claude-sonnet-5-5", search: false), [
            json(["stop_reason": "end_turn", "content": [["type": "text", "text": "19 200"]]])
        ])
        XCTAssertEqual(plain.store.streamingText, "19 200")
        XCTAssertEqual(plain.bodies.map(effort), ["low"])
        XCTAssertEqual(plain.bodies.map(thinking), ["between_tools"])
        XCTAssertFalse(toolTypes(plain.bodies[0]).contains("web_search_20250305"))
        XCTAssertEqual(plain.diagnostics.last?.thinking, .betweenTools)

        let searching = try await run("latest Swift version?", anthropic("claude-sonnet-5-5"), [
            json(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": "list_directory", "input": ["path": NSNull()]]]]),
            json(anthropicFinal("Swift 6.4.2.")),
        ])
        XCTAssertEqual(searching.store.status, .ready, searching.store.errorMessage ?? "")
        XCTAssertEqual(searching.bodies.map(effort), ["low", "low"])
        XCTAssertEqual(searching.bodies.map(thinking), [nil, nil])
        XCTAssertNil(searching.diagnostics.last?.thinking)
    }

    /// The shared table decides per model: Claude Sonnet 5 turns thinking
    /// off; Opus 5.5 and Fable cannot; Opus 5 is left on (it may write
    /// thinking tags or a tool call into its text when off); models that do
    /// not think unless asked get effort only; old models get nothing.
    func testThinkingFieldFollowsTheSharedTable() async throws {
        let cases: [(String, String?, String?)] = [
            ("claude-sonnet-5", "low", "disabled"),
            ("claude-opus-5-5", "low", nil),
            ("claude-opus-5", "low", nil),
            ("claude-fable-5-2", "low", nil),
            ("claude-opus-4-8", "low", nil),
            ("claude-haiku-4-5", nil, nil),
        ]
        for (model, expectedEffort, expectedThinking) in cases {
            let result = try await run("hi", anthropic(model), [json(anthropicFinal("Hello."))])
            XCTAssertEqual(result.store.status, .ready, model)
            let body = try XCTUnwrap(result.bodies.first)
            XCTAssertEqual(effort(body), expectedEffort, model)
            XCTAssertEqual(thinking(body), expectedThinking, model)
        }
    }

    // MARK: OpenAI

    /// OpenAI: `none` where the model takes it, with or without the search
    /// tool. `minimal` models get `low` in a turn with the provider's search
    /// (OpenAI refuses `minimal` beside web_search) and `minimal` without it.
    func testOpenAIGetsItsLowestLevelAndStepsUpBesideProviderSearch() async throws {
        let cases: [(AgentRunOptions, String)] = [
            (openAI("gpt-5.5"), "none"),
            (openAI("gpt-6-luna", search: false), "none"),
            (openAI("gpt-5-mini"), "low"),
            (openAI("gpt-5-mini", search: false), "minimal"),
            (openAI("gpt-6.2-sol"), "low"),
        ]
        for (options, expected) in cases {
            let result = try await run("160 × 120", options, [json(openAIFinal("19,200"))])
            let name = "\(options.model ?? "") search=\(options.webSearchSupport != false)"
            XCTAssertEqual(result.store.streamingText, "19,200", name)
            let body = try XCTUnwrap(result.bodies.first)
            XCTAssertEqual(reasoning(body), expected, name)
            XCTAssertEqual(toolTypes(body).contains("web_search"), options.webSearchSupport != false, name)
            XCTAssertEqual(body["tool_choice"] as? String, "required", name)
            XCTAssertEqual(result.diagnostics.last?.effort?.rawValue, expected, name)
        }
    }

    // MARK: OpenRouter

    /// OpenRouter follows its own catalog entry: reasoning off where it is
    /// optional, else the lowest level listed; no entry, no field. The
    /// structured-completion request keeps `require_parameters`.
    func testOpenRouterFollowsItsCatalogEntry() async throws {
        typealias Capabilities = OpenRouterReasoningCapabilities
        func router(_ model: String, _ capabilities: Capabilities?) -> AgentRunOptions {
            AgentRunOptions(model: model, allowActions: false, openRouterReasoning: capabilities)
        }
        let optional = try await run("hi", router("openai/gpt-5.5", .init(mandatory: false, supportedEfforts: ["high", "low", "none"])),
                                     [json(routerFinal("Hello."))])
        XCTAssertEqual(optional.store.streamingText, "Hello.")
        XCTAssertEqual(optional.bodies.first?["reasoning"] as? [String: Bool], ["enabled": false])
        XCTAssertEqual((optional.bodies.first?["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
        XCTAssertEqual(optional.diagnostics.last?.effort, .off)

        let mandatory = try await run("hi", router("anthropic/claude-sonnet-5.5", .init(mandatory: true, supportedEfforts: ["max", "high", "low"])),
                                      [json(routerFinal("Hello."))])
        XCTAssertEqual(mandatory.bodies.first?["reasoning"] as? [String: String], ["effort": "low"])
        XCTAssertEqual(mandatory.diagnostics.last?.effort, .low)

        // `minimal` beside the search tool steps up when the model lists `low`.
        let minimal = try await run("hi", router("openai/gpt-5-mini", .init(mandatory: true, supportedEfforts: ["high", "low", "minimal"])),
                                    [json(routerFinal("Hello."))])
        XCTAssertTrue(toolTypes(minimal.bodies[0]).contains("openrouter:web_search"))
        XCTAssertEqual(minimal.bodies.first?["reasoning"] as? [String: String], ["effort": "low"])

        for capabilities in [nil, Capabilities(mandatory: nil, supportedEfforts: nil)] {
            let unknown = try await run("hi", router("vendor/model", capabilities), [json(routerFinal("Hello."))])
            XCTAssertEqual(unknown.store.streamingText, "Hello.")
            XCTAssertNil(unknown.bodies.first?["reasoning"])
            XCTAssertNil(unknown.diagnostics.last?.effort)
        }
    }

    /// Settings hand the turn the OpenRouter catalog entry of the Agent's
    /// model; a direct route gets none.
    func testOpenRouterCatalogEntryReachesTheTurn() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let capabilities = OpenRouterReasoningCapabilities(mandatory: false, supportedEfforts: ["low", "none"])
        let snapshot = CatalogSnapshot(models: [CatalogModel(id: "openai/gpt-5.5", uses: [.chat, .chatWithTools], contextLength: 400_000,
                                                             supportsTools: true, reasoning: capabilities)],
                                       fetchedAt: Date(), lastRefreshFailed: false, limited: false)
        try JSONEncoder().encode([ProviderAccount.openRouter.storageID: snapshot,
                                  ProviderAccount.openAI.storageID: snapshot]).write(to: file)
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "openai/gpt-5.5"), for: .agent)
        let store = AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing,
                                       catalogs: ModelCatalogStore(fileURL: file))
        XCTAssertEqual(store.options(for: .native).openRouterReasoning, capabilities)
        routing.setRoute(FeatureRoute(account: .openAI, model: "openai/gpt-5.5"), for: .agent)
        XCTAssertNil(store.options(for: .native).openRouterReasoning)
    }

    // MARK: A provider that refuses the fields

    /// The provider answers HTTP 400 to the request with the fields: the
    /// same request goes once more without them and the answer is shown. The
    /// model then goes without the fields until relaunch: the next turn is
    /// one request. The refused request is not counted as usage.
    func testRefusedFieldsAreDroppedOnceAndTheAnswerStillArrives() async throws {
        let refusal = json(["type": "error", "error": ["type": "invalid_request_error", "message": "thinking: not supported"]], status: 400)
        let first = try await run("hi", anthropic("claude-haiku-5-5"), [refusal, json(anthropicFinal("Hello."))])
        XCTAssertEqual(first.store.status, .ready, first.store.errorMessage ?? "")
        XCTAssertEqual(first.store.streamingText, "Hello.")
        XCTAssertEqual(first.bodies.count, 2)
        XCTAssertEqual(first.bodies.map(thinking), ["disabled", nil])
        XCTAssertEqual(first.bodies.map(effort), ["low", nil])
        var repeated = first.bodies[0]
        repeated["thinking"] = nil; repeated["output_config"] = nil
        XCTAssertEqual(NSDictionary(dictionary: repeated), NSDictionary(dictionary: first.bodies[1]), "the same request, minus the fields")
        XCTAssertEqual(first.diagnostics.map(\.stage), [.request, .failed, .request, .accepted])
        XCTAssertEqual(first.diagnostics.map(\.effortRetry), [nil, nil, true, true])
        XCTAssertEqual(first.diagnostics.map(\.effort), [.low, .low, nil, nil])
        XCTAssertEqual(first.diagnostics[1].status, 400)
        XCTAssertEqual(first.usage.count, 1, "only the request the model answered")

        let second = try await run("hi again", anthropic("claude-haiku-5-5"), [json(anthropicFinal("Hello again."))])
        XCTAssertEqual(second.store.streamingText, "Hello again.")
        XCTAssertEqual(second.bodies.count, 1)
        XCTAssertNil(second.bodies[0]["thinking"]); XCTAssertNil(second.bodies[0]["output_config"])
        // Another model of the same provider is not affected.
        let other = try await run("hi", anthropic("claude-sonnet-5"), [json(anthropicFinal("Hello."))])
        XCTAssertEqual(other.bodies.map(thinking), ["disabled"])
    }

    /// OpenAI: a refused `none` goes once more at `low` (which every
    /// reasoning model takes), not without the field, and the model keeps
    /// `low` until relaunch. OpenRouter (HTTP 404: no endpoint takes the
    /// parameter) goes without the field.
    func testRefusalFallbackOnOpenAIAndOpenRouter() async throws {
        let openAIRefusal = json(["error": ["message": "Unsupported value: 'none' is not supported with this model.",
                                            "type": "invalid_request_error", "param": "reasoning.effort", "code": "unsupported_value"]], status: 400)
        let direct = try await run("hi", openAI("gpt-5.1-codex"), [openAIRefusal, json(openAIFinal("Hello."))])
        XCTAssertEqual(direct.store.streamingText, "Hello.")
        XCTAssertEqual(direct.bodies.map(reasoning), ["none", "low"])
        XCTAssertEqual(direct.bodies.map { toolTypes($0).contains("web_search") }, [true, true], "the search tool is not dropped")
        XCTAssertEqual(direct.diagnostics.map(\.effort), [.noReasoning, .noReasoning, .low, .low])
        let directAgain = try await run("hi", openAI("gpt-5.1-codex", search: false), [json(openAIFinal("Hello."))])
        XCTAssertEqual(directAgain.bodies.map(reasoning), ["low"])
        XCTAssertEqual(directAgain.diagnostics.map(\.effortRetry), [nil, nil], "no repeat, no refusal")

        let options = AgentRunOptions(model: "vendor/model", allowActions: false,
                                      openRouterReasoning: .init(mandatory: false, supportedEfforts: ["low"]))
        let noEndpoint = json(["error": ["message": "No endpoints found that can handle the requested parameters.", "code": 404]],
                              status: 404)
        let routed = try await run("hi", options, [noEndpoint, json(routerFinal("Hello."))])
        XCTAssertEqual(routed.store.streamingText, "Hello.")
        XCTAssertEqual(routed.bodies.count, 2)
        XCTAssertNotNil(routed.bodies[0]["reasoning"]); XCTAssertNil(routed.bodies[1]["reasoning"])
        XCTAssertEqual(routed.usage.count, 1)
        let again = try await run("hi", options, [json(routerFinal("Hello."))])
        XCTAssertNil(again.bodies.first?["reasoning"])

        // A 404 for another reason, and one that fails again, mark nothing.
        let other = AgentRunOptions(model: "vendor/other", allowActions: false,
                                    openRouterReasoning: .init(mandatory: false, supportedEfforts: ["low"]))
        let missing = try await run("hi", other, [json(["error": ["message": "Model vendor/other not found", "code": 404]], status: 404)])
        XCTAssertEqual(missing.bodies.count, 1)
        let twice = try await run("hi", other, [noEndpoint, noEndpoint])
        XCTAssertEqual(twice.store.status, .failed)
        XCTAssertEqual(twice.bodies.count, 2)
        let still = try await run("hi", other, [json(routerFinal("Hello."))])
        XCTAssertNotNil(still.bodies.first?["reasoning"])
    }

    /// A refusal that dropping the fields does not cure: the repeat fails
    /// too, the turn fails with the provider's error, and the model is not
    /// marked, so the next turn asks for the least reasoning again. An
    /// HTTP-200 body that is not an answer on the repeat does not mark it
    /// either.
    func testAModelIsMarkedOnlyWhenTheRepeatIsAnswered() async throws {
        let bad = json(["type": "error", "error": ["type": "invalid_request_error",
                                                    "message": "\"thinking.type.disabled\" is not supported for this model."]], status: 400)
        let failed = try await run("hi", anthropic("claude-haiku-5-5"), [bad, bad])
        XCTAssertEqual(failed.store.status, .failed)
        XCTAssertTrue(failed.store.errorMessage?.contains("HTTP 400") == true, failed.store.errorMessage ?? "")
        XCTAssertEqual(failed.bodies.count, 2, "one repeat, no more")
        XCTAssertEqual(failed.usage.count, 1)

        let proxyPage = try await run("hi", anthropic("claude-haiku-5-5"), [bad, json(["page": "sign in"])])
        XCTAssertEqual(proxyPage.store.status, .failed)

        let next = try await run("hi", anthropic("claude-haiku-5-5"), [json(anthropicFinal("Hello."))])
        XCTAssertEqual(next.store.streamingText, "Hello.")
        XCTAssertEqual(next.bodies.map(thinking), ["disabled"])
    }

    /// Only the turn's first exchange may repeat: after the model answered
    /// once, a refusal fails the turn and the setting is not changed inside
    /// the tool loop.
    func testARefusalAfterTheFirstAnswerOfTheTurnIsNotRepeated() async throws {
        let refusal = json(["type": "error", "error": ["type": "invalid_request_error", "message": "thinking: not supported"]], status: 400)
        let result = try await run("what is in my workspace?", anthropic("claude-haiku-5-5"), [
            json(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": "list_directory", "input": ["path": NSNull()]]]]),
            refusal, json(anthropicFinal("Done.")),
        ])
        XCTAssertEqual(result.store.status, .failed)
        XCTAssertEqual(result.bodies.count, 2)
        XCTAssertEqual(result.bodies.map(thinking), ["disabled", "disabled"])
        let next = try await run("hi", anthropic("claude-haiku-5-5"), [json(anthropicFinal("Hello."))])
        XCTAssertEqual(next.bodies.map(thinking), ["disabled"], "not marked")
    }

    /// The Models API saying a model takes no effort setting: nothing is
    /// sent, the thinking field included, with or without search.
    func testCatalogWithoutEffortSendsNoReasoningField() async throws {
        for search in [true, false] {
            let options = AgentRunOptions(model: "claude-sonnet-5-5", allowActions: false, openCodeProvider: .anthropic,
                                          webSearchSupport: search ? nil : false, lowEffortSupport: false)
            let result = try await run("hi", options, [json(anthropicFinal("Hello."))])
            XCTAssertNil(result.bodies.first?["thinking"], "search=\(search)")
            XCTAssertNil(result.bodies.first?["output_config"], "search=\(search)")
        }
    }

    /// OpenRouter: `minimal` stays beside the search tool when the entry
    /// lists no `low`.
    func testOpenRouterMinimalStaysWithoutALowLevel() async throws {
        let options = AgentRunOptions(model: "vendor/model", allowActions: false,
                                      openRouterReasoning: .init(mandatory: true, supportedEfforts: ["high", "minimal"]))
        let result = try await run("hi", options, [json(routerFinal("Hello."))])
        XCTAssertTrue(toolTypes(result.bodies[0]).contains("openrouter:web_search"))
        XCTAssertEqual(result.bodies.first?["reasoning"] as? [String: String], ["effort": "minimal"])
    }

    /// Other failures are not repeated: a refused key (401), a busy provider
    /// (429) and a server error (500) fail after one request, as before; so
    /// do 400s that mention thinking or reasoning without refusing a setting.
    func testOtherFailuresAreNotRepeated() async throws {
        for status in [401, 429, 500] {
            let result = try await run("hi", anthropic("claude-haiku-5-5"),
                                       [json(["type": "error", "error": ["type": "x", "message": "thinking: not supported"]], status: status)])
            XCTAssertEqual(result.store.status, .failed, "\(status)")
            XCTAssertEqual(result.bodies.count, 1, "\(status)")
        }
        let unrelated: [(Int, [String: String], Data)] = [
            json(["type": "error", "error": ["type": "invalid_request_error", "message": "prompt is too long: 250000 tokens"]], status: 400),
            json(["type": "error", "error": ["type": "invalid_request_error", "message": "messages.1: thinking blocks cannot be modified"]], status: 400),
            json(["type": "error", "error": ["type": "invalid_request_error",
                                             "message": "Item 'rs_1' of type 'reasoning' was provided without its required following item."]], status: 400),
            json(["type": "error", "error": ["type": "invalid_request_error",
                                             "message": "Your text 'no thinking is not supported here' was flagged"]], status: 400),
            (400, [:], Data("<html>Bad Request</html>".utf8)),
        ]
        for response in unrelated {
            let result = try await run("hi", anthropic("claude-haiku-5-5"), [response])
            XCTAssertEqual(result.store.status, .failed)
            XCTAssertEqual(result.bodies.count, 1, String(decoding: response.2, as: UTF8.self))
            XCTAssertEqual(result.usage.count, 1)
        }
        // A model that gets no fields has nothing to repeat without.
        let plain = try await run("hi", anthropic("claude-haiku-4-5"),
                                  [json(["type": "error", "error": ["type": "x", "message": "thinking: not supported"]], status: 400)])
        XCTAssertEqual(plain.bodies.count, 1)
    }

    /// The refusal rule on its own: the setting in `param`, a quoted field
    /// name with a refusal, OpenAI's search message, OpenRouter's quoted
    /// upstream text; not a mention without a refusal.
    func testRefusalRecognition() {
        typealias Shape = NativeAgentDiagnostics.ErrorShape
        func names(_ error: [String: Any]) -> Bool? { Shape(object: ["error": error]).namesReasoning }
        XCTAssertEqual(names(["message": "Unsupported value", "param": "reasoning.effort"]), true)
        XCTAssertEqual(names(["message": "\"thinking.type.between_tools\" is not supported for this model."]), true)
        XCTAssertEqual(names(["message": "The following tools cannot be used with reasoning.effort 'minimal': web_search."]), true)
        XCTAssertEqual(names(["message": "Provider returned error", "metadata": ["raw": "output_config.effort: unknown parameter"]]), true)
        XCTAssertEqual(names(["message": "thinking blocks in the latest assistant message cannot be modified"]), false)
        XCTAssertEqual(names(["message": "Model 'vendor/sonar-reasoning' is not available in your region."]), false)
        XCTAssertEqual(names(["message": "max_tokens: must be greater than thinking.budget_tokens"]), false)
        // Builder review, queue #543: unrelated 400s that mention a setting.
        XCTAssertEqual(names(["message": "Extra inputs are not permitted", "param": "messages.1.content.0.thinking"]), false)
        XCTAssertEqual(names(["message": "messages.1.content.0.thinking: Extra inputs are not permitted"]), false)
        XCTAssertEqual(names(["message": "tools.0.input_schema.properties.effort: this keyword is not supported"]), false)
        XCTAssertEqual(names(["message": "max_tokens is too large for reasoning models; this value is not supported"]), false)
        XCTAssertEqual(names(["message": "messages.3.content.0: thinking blocks are not allowed at this position"]), false)
        XCTAssertEqual(names(["message": "The tool schema is not supported by reasoning models with thinking enabled."]), false)
        XCTAssertEqual(names(["message": "output_config.effort 'xhigh' is not supported when thinking is disabled on this model."]), true)
        XCTAssertEqual(names(["message": "thinking.type: Input tag 'between_tools' is not supported"]), true)
        // Builder review, queue #548: a request field opening the message
        // decides it; a setting quoted alone with a refusal is one.
        XCTAssertEqual(names(["message": "tools: The function schema property 'reasoning.effort' is not supported."]), false)
        XCTAssertEqual(names(["message": "messages: Thinking block field 'thinking.type' is not supported at this position."]), false)
        XCTAssertEqual(names(["message": "max_tokens: The requested limit is not supported, see output_config.effort in the examples."]), false)
        XCTAssertEqual(names(["message": "'thinking' is not supported for this model."]), true)
        XCTAssertEqual(names(["message": "\"thinking\": Extra inputs are not permitted."]), true)
        XCTAssertEqual(names(["message": "The model does not support the 'output_config' parameter."]), true)
        XCTAssertEqual(names(["message": "Error: reasoning.effort 'none' is not supported with this model."]), true)
        XCTAssertEqual(names(["message": "Item 'rs_1' of type 'reasoning' was provided without its required following item."]), false)
    }

    /// Builder review, queue #548, on the real loop: the three unrelated
    /// 400s stay one request each; the three refusals of a setting quoted
    /// alone are repeated without the fields and deliver the answer.
    func testQuotedSettingRefusalsRepeatAndUnrelatedRootsDoNot() async throws {
        for message in ["tools: The function schema property 'reasoning.effort' is not supported.",
                        "messages: Thinking block field 'thinking.type' is not supported at this position.",
                        "max_tokens: The requested limit is not supported, see output_config.effort in the examples."] {
            let result = try await run("hi", anthropic("claude-haiku-5-5"),
                                       [json(["type": "error", "error": ["type": "invalid_request_error", "message": message]], status: 400)])
            XCTAssertEqual(result.store.status, .failed, message)
            XCTAssertEqual(result.bodies.count, 1, message)
            XCTAssertEqual(result.usage.count, 1, message)
        }
        for message in ["'thinking' is not supported for this model.", "\"thinking\": Extra inputs are not permitted.",
                        "The model does not support the 'output_config' parameter."] {
            refusals = SmartReasoningRefusals()
            let result = try await run("hi", anthropic("claude-haiku-5-5"), [
                json(["type": "error", "error": ["type": "invalid_request_error", "message": message]], status: 400),
                json(anthropicFinal("Hello.")),
            ])
            XCTAssertEqual(result.store.streamingText, "Hello.", message)
            XCTAssertEqual(result.bodies.map(thinking), ["disabled", nil], message)
        }
    }

    /// Builder review, queue #543: OpenAI GPT-5 mini beside the provider's
    /// search already sends `low`; a refusal of it goes once more without the
    /// field, never with the same `low` again.
    func testARepeatAlwaysChangesWhatWasSent() async throws {
        let refusal = json(["error": ["message": "Unsupported value", "type": "invalid_request_error", "param": "reasoning.effort"]], status: 400)
        let result = try await run("hi", openAI("gpt-5-mini"), [refusal, json(openAIFinal("Hello."))])
        XCTAssertEqual(result.store.streamingText, "Hello.")
        XCTAssertEqual(result.bodies.map(reasoning), ["low", nil])
        // A refused OpenRouter setting goes without the field.
        let router = AgentRunOptions(model: "vendor/model", allowActions: false,
                                     openRouterReasoning: .init(mandatory: true, supportedEfforts: ["low"]))
        let routed = try await run("hi", router, [json(["error": ["message": "x", "metadata": ["raw": "reasoning.effort: not supported"]]], status: 400),
                                                  json(routerFinal("Hello."))])
        XCTAssertEqual(routed.bodies.count, 2)
        XCTAssertNotNil(routed.bodies[0]["reasoning"]); XCTAssertNil(routed.bodies[1]["reasoning"])
    }

    /// Builder review, queue #543: an OpenRouter refusal is remembered for the
    /// endpoint the route pins (or Auto); another endpoint of the same model
    /// still gets the least reasoning.
    func testOpenRouterRefusalIsKeptPerPinnedEndpoint() async throws {
        let capabilities = OpenRouterReasoningCapabilities(mandatory: false, supportedEfforts: ["low", "none"])
        func pinned(_ pin: String?) -> AgentRunOptions {
            AgentRunOptions(model: "openai/gpt-5.5", allowActions: false, openRouterProvider: pin, openRouterReasoning: capabilities)
        }
        let noEndpoint = json(["error": ["message": "No endpoints found that can handle the requested parameters.", "code": 404]], status: 404)
        let a = try await run("hi", pinned("endpoint/a"), [noEndpoint, json(routerFinal("Hello."))])
        XCTAssertEqual(a.bodies.count, 2)
        let aAgain = try await run("hi", pinned("endpoint/a"), [json(routerFinal("Hi."))])
        XCTAssertNil(aAgain.bodies.first?["reasoning"])
        let b = try await run("hi", pinned("endpoint/b"), [json(routerFinal("Hi."))])
        XCTAssertEqual(b.bodies.first?["reasoning"] as? [String: Bool], ["enabled": false])
        let auto = try await run("hi", pinned(nil), [json(routerFinal("Hi."))])
        XCTAssertEqual(auto.bodies.first?["reasoning"] as? [String: Bool], ["enabled": false])
        XCTAssertEqual((b.bodies.first?["provider"] as? [String: Any])?["only"] as? [String], ["endpoint/b"], "the saved route stays")
    }

    /// Builder review, queue #543: when the provider refuses its own search on
    /// the first request, the request that starts the turn has no search, so
    /// Claude Sonnet 5.5 gets `between_tools` there and keeps it for the turn.
    func testAfterARefusedSearchTheTurnUsesTheSettingOfTheRequestThatRuns() async throws {
        let refused = json(["type": "error", "error": ["type": "invalid_request_error", "message": "Web search is disabled for this organization."]],
                           status: 400)
        let result = try await run("what is in my workspace?", anthropic("claude-sonnet-5-5"), [
            refused,
            json(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": "list_directory", "input": ["path": NSNull()]]]]),
            json(anthropicFinal("Empty.")),
        ])
        XCTAssertEqual(result.store.status, .ready, result.store.errorMessage ?? "")
        XCTAssertEqual(result.bodies.count, 3)
        XCTAssertEqual(result.bodies.map { toolTypes($0).contains("web_search_20250305") }, [true, false, false])
        XCTAssertEqual(result.bodies.map(thinking), [nil, "between_tools", "between_tools"])
        XCTAssertEqual(result.bodies.map(effort), ["low", "low", "low"])
    }
}

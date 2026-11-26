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

    /// Claude Sonnet 5.5 cannot take `disabled`: it gets `between_tools`
    /// with and without the provider's search (its own default thinking
    /// held the first byte about 9 s on a weather question, 2026-11-26).
    func testSonnetGetsBetweenToolsWithAndWithoutProviderSearch() async throws {
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
        XCTAssertEqual(searching.bodies.map(thinking), ["between_tools", "between_tools"])
        XCTAssertTrue(toolTypes(searching.bodies[0]).contains("web_search_20250305"))
        XCTAssertEqual(searching.diagnostics.last?.thinking, .betweenTools)
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

    /// Any HTTP 400 on the turn's first request goes once more, as in Drop
    /// Smart; the error text is not read. An unrelated 400 is repeated
    /// exactly once and fails with the same error, no loop; the model is not
    /// marked, so the next turn asks for the least reasoning again. An
    /// HTTP-200 body that is not an answer on the repeat does not mark it
    /// either. The refused request is not counted as usage; the failed
    /// repeat is.
    func testAnUnrelated400IsRepeatedExactlyOnceThenFails() async throws {
        let unrelated: [(Int, [String: String], Data)] = [
            json(["type": "error", "error": ["type": "invalid_request_error", "message": "prompt is too long: 250000 tokens"]], status: 400),
            json(["type": "error", "error": ["type": "invalid_request_error", "message": "messages.1: thinking blocks cannot be modified"]], status: 400),
            json(["type": "error", "error": ["type": "invalid_request_error",
                                             "message": "'tools': The function schema property 'reasoning.effort' is not supported."]], status: 400),
            (400, [:], Data("<html>Bad Request</html>".utf8)),
        ]
        for response in unrelated {
            let name = String(decoding: response.2, as: UTF8.self)
            let failed = try await run("hi", anthropic("claude-haiku-5-5"), [response, response, json(anthropicFinal("never"))])
            XCTAssertEqual(failed.store.status, .failed, name)
            XCTAssertTrue(failed.store.errorMessage?.contains("HTTP 400") == true, failed.store.errorMessage ?? name)
            XCTAssertEqual(failed.bodies.count, 2, "exactly one repeat: \(name)")
            XCTAssertEqual(failed.bodies.map(thinking), ["disabled", nil], name)
            XCTAssertEqual(failed.usage.count, 1, name)
            XCTAssertEqual(failed.diagnostics.map(\.stage), [.request, .failed, .request, .failed], name)
            XCTAssertEqual(failed.diagnostics.map(\.effortRetry), [nil, nil, true, true], name)
        }
        let proxyPage = try await run("hi", anthropic("claude-haiku-5-5"), [unrelated[0], json(["page": "sign in"])])
        XCTAssertEqual(proxyPage.store.status, .failed)
        XCTAssertEqual(proxyPage.bodies.count, 2)

        let next = try await run("hi", anthropic("claude-haiku-5-5"), [json(anthropicFinal("Hello."))])
        XCTAssertEqual(next.store.streamingText, "Hello.")
        XCTAssertEqual(next.bodies.map(thinking), ["disabled"], "not marked")
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
    /// (429), a server error (500), an OpenRouter 404 for a missing model and
    /// a refused provider web search (which has its own fallback). A model
    /// that gets no fields has nothing to repeat without.
    func testOtherFailuresAreNotRepeated() async throws {
        for status in [401, 429, 500] {
            let result = try await run("hi", anthropic("claude-haiku-5-5"),
                                       [json(["type": "error", "error": ["type": "x", "message": "thinking: not supported"]], status: status)])
            XCTAssertEqual(result.store.status, .failed, "\(status)")
            XCTAssertEqual(result.bodies.count, 1, "\(status)")
            XCTAssertEqual(result.usage.count, 1, "\(status)")
        }
        let plain = try await run("hi", anthropic("claude-haiku-4-5"),
                                  [json(["type": "error", "error": ["type": "x", "message": "thinking: not supported"]], status: 400)])
        XCTAssertEqual(plain.bodies.count, 1)
        // The provider refuses its own search: the search fallback goes
        // without the tool, keeping the reasoning fields; no reasoning repeat.
        let search = try await run("hi", anthropic("claude-haiku-5-5"), [
            json(["type": "error", "error": ["type": "invalid_request_error", "message": "Web search is disabled for this organization."]], status: 400),
            json(anthropicFinal("Hello.")),
        ])
        XCTAssertEqual(search.store.streamingText, "Hello.")
        XCTAssertEqual(search.bodies.count, 2)
        XCTAssertEqual(search.bodies.map { toolTypes($0).contains("web_search_20250305") }, [true, false])
        XCTAssertEqual(search.bodies.map(thinking), ["disabled", "disabled"])
        XCTAssertEqual(search.diagnostics.compactMap(\.effortRetry), [])
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
        XCTAssertEqual(result.bodies.map(thinking), ["between_tools", "between_tools", "between_tools"])
        XCTAssertEqual(result.bodies.map(effort), ["low", "low", "low"])
    }

    /// Builder review, queue #589: the reasoning repeat is spent on the
    /// turn's very first request, once, also when the provider's search
    /// fallback sends the turn's next request. Search refusal → unrelated
    /// 400: two requests, no reasoning repeat. Unrelated 400 → repeat refused
    /// for search → unrelated 400: three requests, one reasoning repeat, and
    /// the search-free request keeps the fallback. OpenRouter's Exa 403 →
    /// 400: two requests.
    func testTheReasoningRepeatIsSpentOncePerTurnAcrossTheSearchFallback() async throws {
        let router = AgentRunOptions(model: "vendor/model", allowActions: false,
                                     openRouterReasoning: .init(mandatory: false, supportedEfforts: ["low"]))
        let routes: [(AgentRunOptions, (Int, [String: String], Data), (Int, [String: String], Data), (([String: Any]) -> String?))] = [
            (anthropic("claude-haiku-5-5"),
             json(["type": "error", "error": ["type": "invalid_request_error", "message": "Web search is disabled for this organization."]], status: 400),
             json(["type": "error", "error": ["type": "invalid_request_error", "message": "prompt is too long: 250000 tokens"]], status: 400),
             { self.thinking($0) }),
            (openAI("gpt-5.5"),
             json(["error": ["message": "Tool 'web_search' is not supported with this model.", "type": "invalid_request_error"]], status: 400),
             json(["error": ["message": "Your input exceeds the context window of this model.", "type": "invalid_request_error",
                             "code": "context_length_exceeded"]], status: 400),
             { self.reasoning($0) }),
            (router,
             json(["error": ["message": "Tool type openrouter:web_search is not supported for this endpoint", "code": 400]], status: 400),
             json(["error": ["message": "maximum context length exceeded", "code": 400,
                             "metadata": ["error_type": "context_length_exceeded"]]], status: 400),
             { (($0["reasoning"] as? [String: Any])?["enabled"] as? Bool).map { "enabled:\($0)" } }),
        ]
        for (options, searchRefusal, unrelated, setting) in routes {
            let name = options.openCodeProvider.rawValue
            let first = try await run("hi", options, [searchRefusal, unrelated, json(["never": true])])
            XCTAssertEqual(first.store.status, .failed, name)
            XCTAssertEqual(first.bodies.count, 2, "search refusal, then the unrelated 400 is not repeated: \(name)")
            XCTAssertEqual(first.diagnostics.compactMap(\.effortRetry), [], name)

            let second = try await run("hi", options, [unrelated, searchRefusal, unrelated, json(["never": true])])
            XCTAssertEqual(second.store.status, .failed, name)
            XCTAssertEqual(second.bodies.count, 3, "one reasoning repeat in the turn: \(name)")
            XCTAssertEqual(second.diagnostics.filter { $0.effortRetry == true && $0.stage == .request }.count, 1, name)
            XCTAssertNotNil(setting(second.bodies[0]), name)
            XCTAssertEqual(second.diagnostics.filter { $0.stage == .request }.map(\.effortRetry), [nil, true, nil], name)
            XCTAssertEqual(setting(second.bodies[2]), setting(second.bodies[1]), "the search-free request keeps the fallback: \(name)")
        }
        let exa = try await run("hi", router, [
            (403, ["Content-Type": "application/json"], Data(#"{"error":{"message":"Forbidden","code":403}}"#.utf8)),
            json(["error": ["message": "maximum context length exceeded", "code": 400]], status: 400),
            json(["never": true]),
        ])
        XCTAssertEqual(exa.store.status, .failed)
        XCTAssertEqual(exa.bodies.count, 2, "Exa 403 fallback, then no reasoning repeat")
    }

    /// Builder review, queue #589: OpenRouter's 404 counts only when one
    /// message says no endpoint takes the requested parameters, in the
    /// message or in the upstream text, never two fragments joined.
    func testOpenRouter404NeedsTheNoEndpointRefusalInOneMessage() async throws {
        let options = AgentRunOptions(model: "vendor/probe", allowActions: false,
                                      openRouterReasoning: .init(mandatory: false, supportedEfforts: ["low"]))
        let split = json(["error": ["message": "No endpoints found for model vendor/probe.", "code": 404,
                                    "metadata": ["raw": "The requested parameters are in the request summary."]]], status: 404)
        let splitParam = json(["error": ["message": "No endpoints found for model vendor/probe.", "code": 404, "param": "model",
                                         "metadata": ["raw": "The requested parameters are in the request summary."]]], status: 404)
        for response in [split, splitParam] {
            let result = try await run("hi", options, [response, json(routerFinal("never"))])
            XCTAssertEqual(result.store.status, .failed)
            XCTAssertEqual(result.bodies.count, 1)
        }
        let upstream = json(["error": ["message": "Provider returned error", "code": 404,
                                       "metadata": ["raw": "No endpoints found that can handle the requested parameters."]]], status: 404)
        let routed = try await run("hi", options, [upstream, json(routerFinal("Hello."))])
        XCTAssertEqual(routed.store.streamingText, "Hello.")
        XCTAssertEqual(routed.bodies.count, 2)
    }

    /// 2026-11-26: Claude Sonnet 5.5 with `between_tools` after a search
    /// may write finish_answer more than once; the first valid call is the
    /// answer and the turn ends with it. A batch mixing finish_answer with
    /// another tool still fails, and so do only invalid finish_answer calls.
    func testRepeatedFinishAnswerTakesTheFirstValidCall() async throws {
        func use(_ id: String, _ input: [String: Any], name: String = "finish_answer") -> [String: Any] {
            ["type": "tool_use", "id": id, "name": name, "input": input]
        }
        let invalid: [String: Any] = ["status": "answered", "answer": "", "sources": [], "actions": []]
        let repeated = try await run("погода в спб", anthropic("claude-sonnet-5-5"), [
            json(["stop_reason": "tool_use", "content": [use("f1", invalid), use("f2", finish("Около −2°, ясно.")),
                                                         use("f3", finish("Second copy."))]]),
            json(anthropicFinal("never")),
        ])
        XCTAssertEqual(repeated.store.status, .ready, repeated.store.errorMessage ?? "")
        XCTAssertEqual(repeated.store.streamingText, "Около −2°, ясно.")
        XCTAssertEqual(repeated.bodies.count, 1, "the turn ends on the first valid answer")

        let mixed = try await run("hi", anthropic("claude-sonnet-5-5"), [
            json(["stop_reason": "tool_use", "content": [use("f1", finish("Hi.")), use("t1", ["path": NSNull()], name: "list_directory")]]),
        ])
        XCTAssertEqual(mixed.store.status, .failed)
        let none = try await run("hi", anthropic("claude-sonnet-5-5"), [
            json(["stop_reason": "tool_use", "content": [use("f1", invalid), use("f2", invalid)]]),
        ])
        XCTAssertEqual(none.store.status, .failed)
    }

    /// 2026-11-26: Claude copied its search citation tags into the answer
    /// (`<cite index="1-9">` with no closing tag). They are removed on
    /// Claude turns, the cited words kept; code and other providers stay.
    func testClaudeCitationTagsAreRemovedFromTheAnswer() async throws {
        let search: [String: Any] = ["type": "server_tool_use", "id": "s1", "name": "web_search", "input": ["query": "q"]]
        let found: [String: Any] = ["type": "web_search_tool_result", "tool_use_id": "s1",
                                    "content": [["type": "web_search_result", "title": "P", "url": "https://example.com/p", "encrypted_content": "x"]]]
        func searched(_ input: [String: Any]) -> (Int, [String: String], Data) {
            json(["stop_reason": "tool_use", "content": [search, found,
                                                         ["type": "tool_use", "id": "f", "name": "finish_answer", "input": input]]])
        }
        let answer = "Около −2°.\n\n- <cite index=\"1-9\">Днём −3…0°, без осадков.</cite>\n- `<cite index=\"1-2\">` stays in code."
        let result = try await run("погода в спб", anthropic("claude-sonnet-5-5"), [searched(finish(answer))])
        XCTAssertEqual(result.store.streamingText, "Около −2°.\n\n- Днём −3…0°, без осадков.\n- `<cite index=\"1-2\">` stays in code.")
        XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags("a <cite index=\"0-1, 2-3\">b</cite> c"), "a b c")
        // Builder review, queue #643: ordinary HTML <cite> is not provider
        // markup, and Insert and Copy payloads are literal.
        XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags("a <cite>Walden</cite> c"), "a <cite>Walden</cite> c")
        XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags("<cite index=\"x\">a</cite>"), "<cite index=\"x\">a</cite>")
        XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags("<cite index=\"1-2\">x</cite> and <cite>Walden</cite>"),
                       "x and <cite>Walden</cite>", "a plain tag keeps its closing tag")
        XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags("`<cite index=\"1-2\">` and <cite>Walden</cite>"),
                       "`<cite index=\"1-2\">` and <cite>Walden</cite>", "an indexed tag in code does not pair")
        XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags("<cite index=\"1-2\">a <cite>W</cite> b</cite>"), "a <cite>W</cite> b")
        // Builder review, queue #653: Markdown-escaped tags are literal text.
        for literal in ["\\<cite index=\"1-2\">a\\</cite>", "\\<cite index=\"1-2\">a</cite>", "x \\</cite> y"] {
            XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags(literal), literal)
        }
        XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags("\\\\<cite index=\"1-2\">a</cite>"), "\\\\a",
                       "an escaped backslash does not escape the tag")
        XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags("<cite index=\"1-2\">C:\\Users\\</cite>"), "C:\\Users\\",
                       "a backslash ending the cited text does not keep the provider's closing tag")
        XCTAssertFalse(NativeAgentFinalAnswer.answersAfterSearch("<https://example.com/spb>"))
        XCTAssertTrue(NativeAgentFinalAnswer.answersAfterSearch("Около −2° <https://example.com/spb>"))
        var html = finish("The tag is below <cite index=\"1-1\">here</cite>.")
        html["insert_text"] = "<p><cite>Walden</cite> <cite index=\"1-1\">kept</cite></p>"
        html["actions"] = [["type": "copy", "text": "<cite>Walden</cite>", "description": "HTML"]]
        let cards = try await run("html", anthropic("claude-sonnet-5-5"), [searched(html)])
        XCTAssertEqual(cards.store.streamingText, "The tag is below here.")
        let card = try XCTUnwrap(NativeAgentFinalAnswer(arguments: html, openAICitations: false, anthropicCitations: true))
        XCTAssertEqual(card.insert?.insertText, "<p><cite>Walden</cite> <cite index=\"1-1\">kept</cite></p>")
        XCTAssertTrue(card.actions.items.contains { $0.insertText == "<cite>Walden</cite>" })
        // A Claude turn without a search, and OpenAI, keep the text.
        let plain = try await run("hi", anthropic("claude-sonnet-5-5", search: false), [json(anthropicFinal("<cite index=\"1-1\">kept</cite>"))])
        XCTAssertEqual(plain.store.streamingText, "<cite index=\"1-1\">kept</cite>")
        let openAI = try await run("hi", openAI("gpt-5.5", search: false), [json(openAIFinal("<cite index=\"1-1\">kept</cite>"))])
        XCTAssertEqual(openAI.store.streamingText, "<cite index=\"1-1\">kept</cite>")
    }

    /// The tools and system prompt are marked for the prompt cache from a
    /// turn's second request on, where they repeat; a single-request
    /// question pays no cache write. OpenAI bodies are unchanged.
    func testAnthropicSystemPromptIsCachedFromTheTurnsSecondRequest() async throws {
        let result = try await run("what is in my workspace?", anthropic("claude-haiku-5-5"), [
            json(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": "list_directory", "input": ["path": NSNull()]]]]),
            json(anthropicFinal("Empty.")),
        ])
        XCTAssertEqual(result.store.status, .ready, result.store.errorMessage ?? "")
        let systems = try result.bodies.map { try XCTUnwrap($0["system"] as? [[String: Any]]) }
        XCTAssertEqual(systems.map(\.count), [1, 1])
        XCTAssertTrue((systems[0][0]["text"] as? String)?.contains("finish_answer") == true)
        XCTAssertEqual(systems.map { ($0[0]["cache_control"] as? [String: Any])?["type"] as? String }, [nil, "ephemeral"])
        XCTAssertEqual(systems[0][0]["text"] as? String, systems[1][0]["text"] as? String)
        let direct = try await run("hi", openAI("gpt-5.5", search: false), [json(openAIFinal("Hello."))])
        XCTAssertTrue(direct.bodies.first?["instructions"] is String)

        // Builder review, queue #643: a refused first request did not run;
        // the first accepted, search-free request (its tools and system
        // changed) gets no breakpoint, the next unchanged step does.
        let refused = try await run("what is in my workspace?", anthropic("claude-haiku-5-5"), [
            json(["type": "error", "error": ["type": "invalid_request_error", "message": "Web search is disabled for this organization."]], status: 400),
            json(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "t1", "name": "list_directory", "input": ["path": NSNull()]]]]),
            json(anthropicFinal("Empty.")),
        ])
        XCTAssertEqual(refused.store.status, .ready, refused.store.errorMessage ?? "")
        XCTAssertEqual(refused.bodies.map { (($0["system"] as? [[String: Any]])?.first?["cache_control"] as? [String: Any])?["type"] as? String },
                       [nil, nil, "ephemeral"])
    }

    /// Builder review, queue #643: a search still pending beside several
    /// finish_answer calls is waited for, every call gets the wait result,
    /// and the answer written after the results is the one shown.
    func testSeveralFinishAnswersBesideAPendingSearchWaitForIt() async throws {
        let result = try await run("погода в спб", anthropic("claude-sonnet-5-5"), [
            json(["stop_reason": "tool_use", "content": [
                ["type": "server_tool_use", "id": "s1", "name": "web_search", "input": ["query": "q"]],
                ["type": "tool_use", "id": "f1", "name": "finish_answer", "input": finish("Guess one.")],
                ["type": "tool_use", "id": "f2", "name": "finish_answer", "input": finish("Guess two.")],
            ]]),
            json(["stop_reason": "tool_use", "content": [
                ["type": "web_search_tool_result", "tool_use_id": "s1",
                 "content": [["type": "web_search_result", "title": "P", "url": "https://example.com/p", "encrypted_content": "x"]]],
                ["type": "tool_use", "id": "f3", "name": "finish_answer", "input": finish("Checked.")],
            ]]),
        ])
        XCTAssertEqual(result.store.status, .ready, result.store.errorMessage ?? "")
        XCTAssertEqual(result.store.streamingText, "Checked.")
        XCTAssertEqual(result.bodies.count, 2)
        let waits = ((result.bodies[1]["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])?.compactMap { $0["tool_use_id"] as? String }
        XCTAssertEqual(waits, ["f1", "f2"])
    }

    /// Builder review, queue #643: a malformed finish_answer beside a valid
    /// one does not hide it, on every route and in either order; a malformed
    /// call of another tool, and only malformed answers, still fail.
    func testAMalformedFinishAnswerDoesNotHideAValidSibling() async throws {
        let valid = String(decoding: try JSONSerialization.data(withJSONObject: finish("Valid.")), as: UTF8.self)
        func openAIBatch(_ arguments: [String]) -> (Int, [String: String], Data) {
            json(["status": "completed", "output": arguments.enumerated().map { index, args in
                ["type": "function_call", "call_id": "c\(index)", "name": "finish_answer", "arguments": args] }])
        }
        for order in [["{not json", valid], [valid, "{not json"]] {
            let result = try await run("hi", openAI("gpt-5.5", search: false), [openAIBatch(order)])
            XCTAssertEqual(result.store.streamingText, "Valid.", "\(order)")
        }
        let router = AgentRunOptions(model: "vendor/model", allowActions: false)
        let routed = try await run("hi", router, [json(["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
            "tool_calls": [["id": "a", "type": "function", "function": ["name": "finish_answer", "arguments": "{oops"]],
                           ["id": "b", "type": "function", "function": ["name": "finish_answer", "arguments": valid]]]]]]])])
        XCTAssertEqual(routed.store.streamingText, "Valid.")
        let claude = try await run("hi", anthropic("claude-haiku-5-5", search: false), [json(["stop_reason": "tool_use", "content": [
            ["type": "tool_use", "id": "a", "name": "finish_answer", "input": "not an object"],
            ["type": "tool_use", "id": "b", "name": "finish_answer", "input": finish("Valid.")]]])])
        XCTAssertEqual(claude.store.streamingText, "Valid.")

        let broken = try await run("hi", openAI("gpt-5.5", search: false), [json(["status": "completed", "output": [
            ["type": "function_call", "call_id": "c0", "name": "list_directory", "arguments": "{oops"],
            ["type": "function_call", "call_id": "c1", "name": "finish_answer", "arguments": valid]]])])
        XCTAssertEqual(broken.store.status, .failed)
        let none = try await run("hi", openAI("gpt-5.5", search: false), [openAIBatch(["{x", "{y"])])
        XCTAssertEqual(none.store.status, .failed)
    }

    /// 2026-11-26: after its search the model may finish (end_turn) with
    /// plain text instead of finish_answer. That text, after the last search
    /// result and without the preamble, is the answer: one request, no
    /// "Continue" request. A search still pending, or no text after the
    /// result, still asks for finish_answer.
    func testTextAfterTheSearchIsTheAnswerWithoutASecondRequest() async throws {
        let search: [String: Any] = ["type": "server_tool_use", "id": "s1", "name": "web_search", "input": ["query": "погода спб"]]
        let result: [String: Any] = ["type": "web_search_tool_result", "tool_use_id": "s1",
                                     "content": [["type": "web_search_result", "title": "Погода", "url": "https://example.com/spb",
                                                  "encrypted_content": "x"]]]
        let answered = try await run("погода в спб", anthropic("claude-haiku-5-5"), [
            json(["stop_reason": "end_turn", "content": [
                ["type": "text", "text": "Нужны свежие данные, ищу."], search, result,
                ["type": "text", "text": "Около −2°, ясно, без осадков.",
                 "citations": [["type": "web_search_result_location", "title": "Погода", "url": "https://example.com/spb"]]],
            ]]),
            json(anthropicFinal("never")),
        ])
        XCTAssertEqual(answered.store.status, .ready, answered.store.errorMessage ?? "")
        XCTAssertEqual(answered.store.streamingText, "Около −2°, ясно, без осадков.")
        XCTAssertEqual(answered.bodies.count, 1, "no Continue request")

        let empty = try await run("погода в спб", anthropic("claude-haiku-5-5"), [
            json(["stop_reason": "end_turn", "content": [["type": "text", "text": "Ищу."], search, result]]),
            json(anthropicFinal("Около −2°.")),
        ])
        XCTAssertEqual(empty.store.streamingText, "Около −2°.")
        XCTAssertEqual(empty.bodies.count, 2, "no text after the result: finish_answer is asked for")

        // Builder review, queue #653: a sources heading or links alone after
        // the search are not an answer; the turn asks for finish_answer.
        for reply in ["Sources", "# Sources", "Источники", "Links for verification", "[Погода](https://example.com/spb)",
                      "Источники:\n- [Погода](https://example.com/spb)"] {
            let sourceOnly = try await run("погода в спб", anthropic("claude-haiku-5-5"), [
                json(["stop_reason": "end_turn", "content": [search, result, ["type": "text", "text": reply]]]),
                json(anthropicFinal("Около −2°.")),
            ])
            XCTAssertEqual(sourceOnly.store.status, .ready, reply)
            XCTAssertEqual(sourceOnly.store.streamingText, "Около −2°.", reply)
            XCTAssertEqual(sourceOnly.bodies.count, 2, reply)
        }
        let withLink = try await run("погода в спб", anthropic("claude-haiku-5-5"), [
            json(["stop_reason": "end_turn", "content": [search, result,
                                                         ["type": "text", "text": "Около −2°, ясно ([Погода](https://example.com/spb))."]]]),
        ])
        XCTAssertEqual(withLink.store.status, .ready, withLink.store.errorMessage ?? "")
        XCTAssertEqual(withLink.bodies.count, 1, "prose with a link is an answer")

        let pending = try await run("погода в спб", anthropic("claude-haiku-5-5"), [
            json(["stop_reason": "end_turn", "content": [search, ["type": "text", "text": "Жду результатов."]]]),
            json(anthropicFinal("Около −2°.")),
        ])
        XCTAssertEqual(pending.store.streamingText, "Около −2°.")
        XCTAssertEqual(pending.bodies.count, 2, "a search without its result is not answered by text")
    }

    /// Builder review, queue #657: the builder's fixture inputs and controls.
    func testBuilderFixtureForCitationPairingAndSourceOnlyText() async throws {
        let citations: [(String, String)] = [
            (#"Forecast <cite index="1-9">contains the literal \<cite index="2-3"> token</cite>."#,
             #"Forecast contains the literal \<cite index="2-3"> token."#),
            (#"Forecast <cite index="1-9">contains the literal \<cite index="2-3">one\</cite> token</cite>."#,
             #"Forecast contains the literal \<cite index="2-3">one\</cite> token."#),
            (#"Forecast <cite index="1-9">ends with a backslash \</cite>."#, #"Forecast ends with a backslash \."#),
            (#"Forecast \\<cite index="1-9">comes from one page</cite>."#, #"Forecast \\comes from one page."#),
            (#"Syntax \\\<cite index="1-9">literal</cite>."#, #"Syntax \\\<cite index="1-9">literal</cite>."#),
            (#"Show the escaped literal \<cite index="1-9">Title\</cite>."#, #"Show the escaped literal \<cite index="1-9">Title\</cite>."#),
            (#"Show \<cite index="1-9">Title</cite> in the example."#, #"Show \<cite index="1-9">Title</cite> in the example."#),
            (#"Evidence <cite index="1-9">page</cite>; ordinary <cite class="book">title</cite>."#,
             #"Evidence page; ordinary <cite class="book">title</cite>."#),
        ]
        for (raw, expected) in citations {
            XCTAssertEqual(NativeAgentFinalAnswer.withoutCitationTags(raw), expected, raw)
        }
        let sourceOnly = [
            "Sources", "# Sources", "Источники", "Links for verification", "<https://fixture.invalid/result>",
            "Sources\n- [Evidence](https://fixture.invalid/result)",
            #"Sources: [Evidence](https://fixture.invalid/result "Evidence from the search")"#,
            "[Evidence](<https://fixture.invalid/result>)",
            "Sources\n\n[Evidence][1]\n\n[1]: https://fixture.invalid/result",
            "Sources\n\n[Evidence][evidence]\n\n[evidence]: <https://fixture.invalid/result>",
            #"<a href="https://fixture.invalid/result">Evidence</a>"#,
            "References\n- [Evidence](https://fixture.invalid/result)",
            "Источники информации\n- <https://fixture.invalid/result>",
            "**Sources:**\n- [Evidence](https://fixture.invalid/result)",
            "1. <https://fixture.invalid/result>\n2. https://fixture.invalid/extra",
            "Список литературы:\n1. [Погода](https://fixture.invalid/result)",
        ]
        for text in sourceOnly { XCTAssertFalse(NativeAgentFinalAnswer.answersAfterSearch(text), text) }
        let answers = [
            "It is raining. <https://fixture.invalid/result>",
            #"It is raining. [Evidence](https://fixture.invalid/result "Details")"#,
            "It is raining. [Evidence][1]\n\n[1]: https://fixture.invalid/result",
            "Около −2°, ясно.", "−2°", "Sources say it is −2° and clear today in the city.",
            "Ссылка не нужна, −2°", "−2°C (source: weather.com)", "Источник: Гидрометцентр, −2°", "Linked to Arctic air",
            "Resources are scarce",
        ]
        for text in answers { XCTAssertTrue(NativeAgentFinalAnswer.answersAfterSearch(text), text) }

        // On the real loop: a reference-link source list continues, prose with
        // a link is one request and keeps the source card.
        let search: [String: Any] = ["type": "server_tool_use", "id": "s1", "name": "web_search", "input": ["query": "q"]]
        let result: [String: Any] = ["type": "web_search_tool_result", "tool_use_id": "s1",
                                     "content": [["type": "web_search_result", "title": "E", "url": "https://fixture.invalid/result", "encrypted_content": "x"]]]
        let listed = try await run("погода", anthropic("claude-sonnet-5-5"), [
            json(["stop_reason": "end_turn", "content": [search, result, ["type": "text", "text": sourceOnly[8]]]]),
            json(anthropicFinal("Evidence confirms the weather.")),
        ])
        XCTAssertEqual(listed.store.streamingText, "Evidence confirms the weather.")
        XCTAssertEqual(listed.bodies.count, 2)
        let prose = try await run("погода", anthropic("claude-sonnet-5-5"), [
            json(["stop_reason": "end_turn", "content": [search, result, ["type": "text", "text": answers[0]]]]),
        ])
        XCTAssertEqual(prose.store.status, .ready, prose.store.errorMessage ?? "")
        XCTAssertEqual(prose.bodies.count, 1)
    }
}

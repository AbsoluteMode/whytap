import XCTest
@testable import Sidekey

/// Regressions from the builder's review of the provider web search (queue
/// #429): fallback evidence, the turn's search budget, continuation after any
/// provider web work, catalog decoding, one resolver and settings sync.
/// WHY: .project-docs/decisions/2026-11-22-agent-provider-web-search.md
@MainActor
extension NativeAgentWebSearchTests {
    // MARK: - Fallback only on positive evidence

    func testUnrelatedFirstRequestErrorsNeverMoveTheQueryToTavily() async throws {
        let cases: [(OpenCodeModelProvider, String, Data)] = [
            (.openRouter, "qwen/qwen3.8-27b", Data(#"{"error":{"message":"maximum context length exceeded; web search results included","metadata":{"error_type":"context_length_exceeded"}}}"#.utf8)),
            (.anthropic, "claude-opus-5-5", Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"messages: roles must alternate"}}"#.utf8)),
            (.openAI, "gpt-6.2-astra", Data(#"{"error":{"message":"Invalid value for 'input'.","type":"invalid_request_error"}}"#.utf8)),
        ]
        for (route, model, error) in cases {
            let (directory, keys, http) = try fixture()
            try keys.save("router-key", account: OpenRouterLLMKeyStore.account)
            try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
            try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
            try keys.save("tavily-key", account: TavilySearch.keychainAccount)
            StubURLProtocol.handler = { request in
                XCTAssertNotEqual(request.url?.host, "api.tavily.com", "\(route)")
                return (400, [:], error)
            }
            let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
            let events = await run(provider, "q", .init(model: model, openCodeProvider: route))
            XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, "\(route): no retry for an unrelated error")
            XCTAssertTrue(events.contains { if case .error = $0 { return true }; return false }, "\(route)")
            XCTAssertNil(finalText(events))
            XCTAssertFalse(events.contains {
                if case .error(_, let text, _) = $0 { return text.contains("roles must alternate") || text.contains("Invalid value") }
                return false
            }, "Provider text is never echoed")
        }
    }

    func testRefusalThatNamesSearchFallsBackOnAnthropicAndOpenRouterToo() async throws {
        let cases: [(OpenCodeModelProvider, String, Data)] = [
            (.anthropic, "claude-opus-5-5", Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"Web search is disabled for this organization."}}"#.utf8)),
            (.openRouter, "vendor/model", Data(#"{"error":{"message":"Tool type openrouter:web_search is not supported for this endpoint"}}"#.utf8)),
        ]
        for (route, model, error) in cases {
            let (directory, keys, http) = try fixture()
            try keys.save("router-key", account: OpenRouterLLMKeyStore.account)
            try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
            var calls = 0
            StubURLProtocol.handler = { _ in
                calls += 1
                if calls == 1 { return (400, [:], error) }
                let answer = self.final("No search.", status: "unverified")
                return route == .anthropic
                    ? self.serve(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "f", "name": "finish_answer", "input": answer]]])
                    : self.serve(["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
                        "tool_calls": [["id": "f", "type": "function", "function": ["name": "finish_answer",
                                                                                    "arguments": self.arguments(answer)]]]]]]])
            }
            let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
            let events = await run(provider, "q", .init(model: model, openCodeProvider: route))
            XCTAssertEqual(calls, 2, "\(route)")
            XCTAssertFalse(text(1).contains("web_search_20250305") || text(1).contains("openrouter:web_search"), "\(route)")
            XCTAssertTrue(text(1).contains("Web search is off"), "No Tavily key: the retry has no search")
            XCTAssertNotNil(finalText(events))
        }
    }

    // MARK: - The turn's search budget and continuation

    func testOpenAIBudgetIsSpentAcrossRequestsAndOpenPageCounts() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return self.serve(["status": "completed", "output": [
                    ["type": "web_search_call", "id": "ws_1", "status": "completed", "action": ["type": "search", "query": "q"]],
                    ["type": "web_search_call", "id": "ws_2", "status": "completed", "action": ["type": "open_page", "url": "https://x.example"]]
                ]])
            }
            return self.serve(["status": "completed", "output": [
                ["type": "function_call", "call_id": "f", "name": "finish_answer", "arguments": self.arguments(self.final("Done."))]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "gpt-6.2-astra", openCodeProvider: .openAI))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(finalText(events), "Done.")
        let second = try body(1)
        XCTAssertFalse((second["tools"] as? [[String: Any]])?.contains { $0["type"] as? String == "web_search" } == true,
                       "Two web calls spent: no more search in this turn")
        XCTAssertNil(second["max_tool_calls"])
        XCTAssertFalse((second["include"] as? [String])?.contains("web_search_call.action.sources") == true)
    }

    func testOpenAIOpenPageAloneContinuesTheTurn() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return self.serve(["status": "completed", "output": [
                    ["type": "web_search_call", "id": "ws_1", "status": "completed", "action": ["type": "open_page", "url": "https://x.example"]]]])
            }
            return self.serve(["status": "completed", "output": [
                ["type": "function_call", "call_id": "f", "name": "finish_answer", "arguments": self.arguments(self.final("Done."))]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "gpt-6.2-astra", openCodeProvider: .openAI))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(finalText(events), "Done.")
    }

    func testOpenRouterUsageCountsSearchesWithoutCitationsAndSpendsTheBudget() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("router-key", account: OpenRouterLLMKeyStore.account)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return self.serve(["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": "Looked it up."]]],
                                   "usage": ["cost": 0.02, "server_tool_use_details": ["web_search_requests": 2, "tool_calls_executed": 2]]])
            }
            return self.serve(["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
                "tool_calls": [["id": "f", "type": "function", "function": ["name": "finish_answer",
                    "arguments": self.arguments(self.final("Answer."))]]]]]], "usage": ["cost": 0.001]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "openai/gpt-6.2-astra"))
        XCTAssertEqual(calls, 2, "Searches reported in usage, without citations, still continue the turn")
        XCTAssertEqual(finalText(events), "Answer.")
        let firstTool = try XCTUnwrap((try body(0)["tools"] as? [[String: Any]])?.first { $0["type"] as? String == "openrouter:web_search" })
        XCTAssertEqual((firstTool["parameters"] as? [String: Any])?["max_uses"] as? Int, 2)
        XCTAssertFalse((try body(1)["tools"] as? [[String: Any]])?.contains { $0["type"] as? String == "openrouter:web_search" } == true,
                       "Native engines may ignore max_uses: the app stops offering search once two are spent")
        XCTAssertEqual((try body(1)["messages"] as? [[String: Any]])?.last?["role"] as? String, "user")
        XCTAssertTrue(events.contains(.toolExecuting(tool: "web_search", label: "Searching the web")))
    }

    func testAnthropicEndTurnAfterSearchContinuesWithAUserMessageAndTheRestOfTheBudget() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return self.serve(["stop_reason": "end_turn", "content": [
                    ["type": "server_tool_use", "id": "srv", "name": "web_search", "input": ["query": "q"]],
                    ["type": "web_search_tool_result", "tool_use_id": "srv", "content": [
                        ["type": "web_search_result", "url": "https://fact.example", "title": "Fact", "encrypted_content": "ENC-1"]]],
                    ["type": "text", "text": "It is cold."]
                ]])
            }
            return self.serve(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "f", "name": "finish_answer",
                                                                       "input": self.final("It is cold.")]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "claude-opus-5-5", openCodeProvider: .anthropic))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(finalText(events), "It is cold.")
        let second = try body(1)
        XCTAssertEqual((second["messages"] as? [[String: Any]])?.last?["role"] as? String, "user", "No assistant prefill after end_turn")
        XCTAssertTrue(text(1).contains("ENC-1"), "The search result is replayed")
        XCTAssertEqual((second["tools"] as? [[String: Any]])?.first { $0["type"] as? String == "web_search_20250305" }?["max_uses"] as? Int, 1,
                       "A new provider turn gets only what is left of the app's two searches")
    }

    // MARK: - Catalog decoding, one resolver, settings sync

    func testAnOddWebSearchCapabilityDoesNotCostTheThinkingFlag() throws {
        let page = try ModelCatalogFetcher.parseAnthropicPage(Data(#"""
        {"data":[{"id":"odd","capabilities":{"thinking":{"supported":true},"server_tools":{"web_search":{"supported":"yes"}}}},
                 {"id":"odd2","capabilities":{"thinking":{"supported":true},"server_tools":[1,2]}}]}
        """#.utf8))
        XCTAssertEqual(page.models.map(\.supportsReasoning), [true, true])
        XCTAssertEqual(page.models.map(\.supportsWebSearch), [nil, nil])
    }

    func testCatalogFlagWithoutTokenLimitsReachesTheTurnAndTheRowAlike() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        // No max_input_tokens: the old spec path dropped the flag.
        let snapshot = CatalogSnapshot(models: [CatalogModel(id: "claude-legacy", supportsWebSearch: false)],
                                       fetchedAt: Date(), lastRefreshFailed: false, limited: false)
        try JSONEncoder().encode([ProviderAccount.anthropic.storageID: snapshot]).write(to: file)
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(FeatureRoute(account: .anthropic, model: "claude-legacy"), for: .agent)
        let agent = AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing, catalogs: ModelCatalogStore(fileURL: file))
        let options = agent.options(for: .native)
        XCTAssertNil(options.openCodeModelSpec)
        XCTAssertEqual(options.webSearchSupport, false)
        XCTAssertEqual(NativeAgentWebSearch.resolve(options: options, tavilyConnected: true), .tavily)
        XCTAssertEqual(AgentSearchRow(options: options, tavilyConnected: true).current, .tavily)
    }

    func testSyncedChoiceAppliesAtOnceAndSyncedTavilyKeyRefreshesTheRow() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let agent = AgentSettingsStore(defaults: defaults, codexConfig: .init())
        XCTAssertEqual(agent.webSearchChoice, .auto)
        defaults.set("tavily", forKey: AgentSettingsStore.webSearchChoiceKey) // written by settings sync
        XCTAssertTrue(agent.options(for: .native).preferTavilySearch, "The next turn reads the synced choice")
        agent.reloadWebSearchChoice()
        XCTAssertEqual(agent.webSearchChoice, .tavily)
        let notified = expectation(forNotification: .whytapTavilyKeyChanged, object: nil)
        SettingsSyncLiveReload.reload(items: ["key:" + TavilySearch.keychainAccount], defaults: defaults)
        wait(for: [notified], timeout: 1)
    }
}

import XCTest
@testable import Sidekey

/// User scenarios for the Agent's web search: the provider's built-in search,
/// the Tavily fallback, no search at all, failures and source cards.
/// WHY: .project-docs/decisions/2026-11-22-agent-provider-web-search.md
@MainActor
final class NativeAgentWebSearchTests: XCTestCase {
    func fixture() throws -> (URL, ProviderKeyStore, NativeAgentHTTP) {
        StubURLProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); StubURLProtocol.reset(); try? FileManager.default.removeItem(at: directory) }
        return (directory, keys, NativeAgentHTTP(session: session))
    }

    func serve(_ object: [String: Any]) -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies[index]) as? [String: Any])
    }

    func text(_ index: Int) -> String {
        String(decoding: StubURLProtocol.capturedBodies[index], as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    func final(_ answer: String, status: String = "answered", sources: [[String: Any]] = []) -> [String: Any] {
        ["status": status, "answer": answer, "sources": sources, "actions": []]
    }

    func arguments(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func run(_ provider: NativeAgentProvider, _ prompt: String, _ options: AgentRunOptions) async -> [AgentSSEEvent] {
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: prompt, resumeSessionID: nil, options: options) { events.append(event) }
        return events
    }

    func links(_ events: [AgentSSEEvent]) -> [ActionItem] {
        events.compactMap { event -> [ActionItem]? in
            if case .blockComplete(.usefulActions(let block)) = event { return block.items }
            return nil
        }.flatMap { $0 }.filter { if case .link = $0 { return true }; return false }
    }

    func finalText(_ events: [AgentSSEEvent]) -> String? {
        events.compactMap { if case .finalAnswer(let text) = $0 { return text }; return nil }.first
    }

    // MARK: - Choosing the search

    func testResolutionDefaultsToBuiltInThenTavilyThenNone() {
        func resolve(_ provider: OpenCodeModelProvider, _ model: String, flag: Bool? = nil,
                     prefer: Bool = false, tavily: Bool) -> NativeAgentWebSearch {
            NativeAgentWebSearch.resolve(options: .init(model: model, openCodeProvider: provider, preferTavilySearch: prefer,
                                                        webSearchSupport: flag), tavilyConnected: tavily)
        }
        XCTAssertEqual(resolve(.anthropic, "claude-opus-5-5", tavily: false), .builtIn(.anthropic))
        XCTAssertEqual(resolve(.anthropic, "claude-opus-5-5", tavily: true), .builtIn(.anthropic),
                       "A Tavily key alone never replaces the provider's own search")
        XCTAssertEqual(resolve(.anthropic, "claude-opus-5-5", prefer: true, tavily: true), .tavily, "Tavily picked in Models → Search")
        XCTAssertEqual(resolve(.anthropic, "claude-opus-5-5", prefer: true, tavily: false), .builtIn(.anthropic),
                       "Tavily picked but its key removed: search keeps working")
        XCTAssertEqual(resolve(.anthropic, "claude-opus-5-5", flag: true, tavily: true), .builtIn(.anthropic))
        XCTAssertEqual(resolve(.openAI, "gpt-6.2-astra", tavily: true), .builtIn(.openAI))
        XCTAssertEqual(resolve(.openRouter, "qwen/qwen3.8-27b", tavily: true), .builtIn(.openRouter))
        XCTAssertEqual(resolve(.anthropic, "old-claude", flag: false, tavily: true), .tavily, "Catalog says no built-in search")
        XCTAssertEqual(resolve(.anthropic, "old-claude", flag: false, tavily: false), .none)
        XCTAssertEqual(resolve(.openAI, "gpt-6.2-astra", tavily: false), .builtIn(.openAI))
        XCTAssertEqual(resolve(.openAI, "gpt-4.1-nano", tavily: true), .tavily)
        XCTAssertEqual(resolve(.openAI, "gpt-4.1-nano-2025-04-14", tavily: false), .none)
        XCTAssertEqual(resolve(.openRouter, "qwen/qwen3.8-27b", tavily: false), .builtIn(.openRouter))
        XCTAssertEqual(NativeAgentWebSearch.resolve(options: .init(model: nil, openCodeProvider: .anthropic), tavilyConnected: false), .none)
    }

    func testWithBuiltInSearchTavilyIsNeverCalledEvenWithAKey() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        try keys.save("tavily-key", account: TavilySearch.keychainAccount)
        var calls = 0
        StubURLProtocol.handler = { request in
            XCTAssertNotEqual(request.url?.host, "api.tavily.com")
            calls += 1
            if calls == 1 {
                // A model that still asks for the absent Tavily function.
                return self.serve(["stop_reason": "tool_use", "content": [
                    ["type": "tool_use", "id": "t", "name": "web_search", "input": ["query": "q"]]]])
            }
            return self.serve(["stop_reason": "tool_use", "content": [
                ["type": "tool_use", "id": "f", "name": "finish_answer", "input": self.final("Answer.")]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "claude-opus-5-5", openCodeProvider: .anthropic))
        let tools = try XCTUnwrap(try body(0)["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { $0["type"] as? String == "web_search_20250305" })
        XCTAssertFalse(tools.contains { $0["input_schema"] != nil && $0["name"] as? String == "web_search" })
        XCTAssertEqual(StubURLProtocol.capturedRequests.map { $0.url?.host ?? "" }, ["api.anthropic.com", "api.anthropic.com"])
        XCTAssertTrue(text(1).contains("Use the built-in web_search tool"))
        XCTAssertEqual(finalText(events), "Answer.")
    }

    func testAnthropicCatalogStatesWebSearchSupport() throws {
        let page = try ModelCatalogFetcher.parseAnthropicPage(Data(#"""
        {"data":[
          {"id":"yes","capabilities":{"server_tools":{"web_search":{"supported":true}},"thinking":{"supported":true}}},
          {"id":"no","capabilities":{"server_tools":{"web_search":{"supported":false}}}},
          {"id":"unsaid","capabilities":{"thinking":{"supported":false}}}
        ]}
        """#.utf8))
        XCTAssertEqual(page.models.map(\.supportsWebSearch), [true, false, nil])
        XCTAssertEqual(page.models.map(\.supportsReasoning), [true, nil, false], "Reading the new flag keeps thinking")
    }

    // MARK: - The Search row in API & Models → Models

    func testSearchRowShowsWhatTheAgentSearchesWithAndOffersTheRest() {
        func row(_ provider: OpenCodeModelProvider?, _ model: String? = "m", flag: Bool? = nil, tavily: Bool,
                 _ choice: AgentWebSearchChoice = .auto) -> AgentSearchRow {
            AgentSearchRow(options: .init(model: provider == nil ? nil : model, openCodeProvider: provider ?? .openRouter,
                                          preferTavilySearch: choice == .tavily, webSearchSupport: flag), tavilyConnected: tavily)
        }
        XCTAssertEqual(row(.anthropic, tavily: false).current.label, "Anthropic · built-in")
        XCTAssertEqual(row(.openAI, "gpt-6.2-astra", tavily: false).current.label, "OpenAI · built-in")
        XCTAssertEqual(row(.openRouter, tavily: true).current.label, "OpenRouter · web")
        XCTAssertEqual(row(.anthropic, flag: false, tavily: true).current.label, "Tavily")
        XCTAssertNil(row(.anthropic, flag: false, tavily: true).builtIn, "No built-in entry for a model without it")
        let off = row(.openAI, "gpt-4.1-nano", tavily: false)
        XCTAssertEqual(off.current.label, "Off — add a Tavily key")
        XCTAssertTrue(off.needsSetup)
        XCTAssertTrue(off.current.priceNote.contains("Add a Tavily key in API keys"))
        XCTAssertEqual(row(nil, nil, tavily: false).current, NativeAgentWebSearch.none, "No Agent model, no Tavily: Off")
        XCTAssertEqual(row(nil, nil, tavily: true).current, .tavily)
        let picked = row(.anthropic, tavily: true, .tavily)
        XCTAssertEqual(picked.current, .tavily)
        XCTAssertEqual(picked.builtIn, .builtIn(.anthropic), "The built-in entry stays to switch back")
        XCTAssertEqual(row(.anthropic, tavily: false, .tavily).current, .builtIn(.anthropic))
        // Prices are named, never a zero.
        XCTAssertTrue(row(.anthropic, tavily: false).current.priceNote.contains("$10 per 1,000 searches"))
        XCTAssertTrue(row(.openRouter, tavily: false).current.priceNote.contains("Exa at about $7 per 1,000"))
        for state in [row(.anthropic, tavily: false), row(.openRouter, tavily: false), picked, off] {
            XCTAssertFalse(state.current.priceNote.contains("$0"))
        }
    }

    func testModelsScreenSearchRowFollowsTheAgentRouteTavilyKeyAndPick() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let snapshot = CatalogSnapshot(models: [CatalogModel(id: "claude-legacy", supportsWebSearch: false),
                                                CatalogModel(id: "claude-opus-5-5", supportsWebSearch: true)],
                                       fetchedAt: Date(), lastRefreshFailed: false, limited: false)
        try JSONEncoder().encode([ProviderAccount.anthropic.storageID: snapshot]).write(to: file)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let routing = AIRoutingStore(defaults: defaults)
        let catalogs = ModelCatalogStore(fileURL: file)
        let agent = AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing, catalogs: catalogs)
        routing.setRoute(FeatureRoute(account: .anthropic, model: "claude-legacy"), for: .agent)
        let vm = APIAndModelsViewModel(routing: routing, keys: keys, catalogs: catalogs, checks: ModelCheckStore(defaults: defaults),
                                       keyStatuses: KeyStatusStore(defaults: defaults), agentSettings: agent)
        XCTAssertEqual(vm.searchRow.current.label, "Off — add a Tavily key", "Catalog: this model has no search")

        try keys.save("tavily-key", account: TavilySearch.keychainAccount)
        NotificationCenter.default.post(name: .whytapTavilyKeyChanged, object: nil)
        XCTAssertEqual(vm.searchRow.current.label, "Tavily")

        routing.setRoute(FeatureRoute(account: .anthropic, model: "claude-opus-5-5"), for: .agent)
        vm.selectSearch(.auto)
        XCTAssertEqual(vm.searchRow.current.label, "Anthropic · built-in", "Built-in is the default even with a Tavily key")
        XCTAssertEqual(agent.options(for: .native).preferTavilySearch, false)

        vm.selectSearch(.tavily)
        XCTAssertEqual(vm.searchRow.current.label, "Tavily")
        XCTAssertEqual(defaults.string(forKey: "agent.native.webSearch"), "tavily")
        XCTAssertTrue(AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing, catalogs: catalogs)
            .options(for: .native).preferTavilySearch, "The pick reaches the Agent's run")
        XCTAssertTrue(ConfigBackupRegistry.entries.keys.contains("agent.native.webSearch"))
    }

    func testTavilyPickedInModelsIsUsedInsteadOfBuiltInSearch() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        try keys.save("tavily-key", account: TavilySearch.keychainAccount)
        StubURLProtocol.handler = { _ in
            self.serve(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "f", "name": "finish_answer",
                                                                "input": self.final("Answer.")]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        _ = await run(provider, "q", .init(model: "claude-opus-5-5", openCodeProvider: .anthropic, preferTavilySearch: true))
        let tools = try XCTUnwrap(try body(0)["tools"] as? [[String: Any]])
        XCTAssertFalse(tools.contains { $0["type"] as? String == "web_search_20250305" })
        XCTAssertTrue(tools.contains { $0["name"] as? String == "web_search" && $0["input_schema"] != nil })
        XCTAssertTrue((try body(0)["system"] as? String)?.contains("(Tavily)") == true)
    }

    // MARK: - Anthropic without Tavily

    func testAnthropicWithoutTavilySearchesWithItsOwnToolAndShowsCitedSources() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        var calls = 0
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.anthropic.com", "No Tavily or other host")
            calls += 1
            if calls == 1 {
                return self.serve(["stop_reason": "pause_turn", "content": [
                    ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "погода Москва сегодня"]],
                    ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [
                        ["type": "web_search_result", "url": "https://weather.example/moscow", "title": "Погода в Москве",
                         "encrypted_content": "ENCRYPTED-STATE", "page_age": "November 22, 2026"],
                        ["type": "web_search_result", "url": "https://other.example/msk", "title": "Прогноз", "encrypted_content": "E2"]
                    ]]
                ], "usage": ["input_tokens": 1000, "output_tokens": 50, "server_tool_use": ["web_search_requests": 1]]])
            }
            return self.serve(["stop_reason": "tool_use", "content": [
                ["type": "text", "text": "Сегодня в Москве −3 °C.", "citations": [
                    ["type": "web_search_result_location", "url": "https://weather.example/moscow", "title": "Погода в Москве",
                     "cited_text": "−3 °C", "encrypted_index": "IDX"]]],
                ["type": "tool_use", "id": "toolu_final", "name": "finish_answer",
                 "input": self.final("Сегодня в Москве около −3 °C, облачно.")]
            ], "usage": ["input_tokens": 3000, "output_tokens": 80]])
        }
        var usage: [AIUsageEvent] = []
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { usage.append($0) })
        let events = await run(provider, "какая погода сегодня в Москве",
                               .init(model: "claude-opus-5-5", openCodeProvider: .anthropic))

        XCTAssertEqual(calls, 2, "pause_turn continues the same turn")
        let first = try body(0)
        let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
        let server = try XCTUnwrap(tools.first { $0["type"] as? String == "web_search_20250305" })
        XCTAssertEqual(server["name"] as? String, "web_search")
        XCTAssertEqual(server["max_uses"] as? Int, 2)
        XCTAssertFalse(tools.contains { $0["name"] as? String == "web_search" && $0["input_schema"] != nil },
                       "No Tavily function beside the provider tool")
        XCTAssertTrue((first["system"] as? String)?.contains("built-in web_search tool") == true)
        // The paused content goes back verbatim, encrypted state included.
        let second = try body(1)
        let replayed = try XCTUnwrap((second["messages"] as? [[String: Any]])?.last)
        XCTAssertEqual(replayed["role"] as? String, "assistant")
        XCTAssertTrue(text(1).contains("ENCRYPTED-STATE"))
        XCTAssertEqual(((second["tools"] as? [[String: Any]])?.count), tools.count, "Same tools in the continuation")
        XCTAssertEqual((second["tools"] as? [[String: Any]])?.first { $0["type"] as? String == "web_search_20250305" }?["max_uses"] as? Int, 2,
                       "Anthropic counts max_uses across its own turn: the pause_turn continuation keeps the tool unchanged")

        XCTAssertEqual(finalText(events), "Сегодня в Москве около −3 °C, облачно.")
        XCTAssertTrue(events.contains(.toolExecuting(tool: "web_search", label: "Searching the web")))
        // The model left sources empty: the cited page comes first, then results.
        let cards = links(events)
        XCTAssertEqual(cards.first, .link(url: URL(string: "https://weather.example/moscow")!, description: "Погода в Москве", provider: nil))
        XCTAssertEqual(cards.count, 2, "Duplicates collapse")
        XCTAssertEqual(events.last, .done(sources: []))
        // $10 per 1,000 searches on top of 1,000 × $4 + 50 × $20 per million tokens.
        XCTAssertEqual(try XCTUnwrap(usage.first?.amount), 0.005 + 0.01, accuracy: 1e-12)
        XCTAssertEqual(usage.first?.basis, .estimated)
    }

    func testModelSourcesWinOverProviderCitations() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        StubURLProtocol.handler = { _ in
            self.serve(["stop_reason": "tool_use", "content": [
                ["type": "server_tool_use", "id": "srv", "name": "web_search", "input": ["query": "q"]],
                ["type": "web_search_tool_result", "tool_use_id": "srv", "content": [
                    ["type": "web_search_result", "url": "https://result.example", "title": "Result", "encrypted_content": "E"]]],
                ["type": "tool_use", "id": "final", "name": "finish_answer", "input": self.final("Answer.",
                    sources: [["title": "Chosen", "url": "https://chosen.example/page"]])]
            ]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "claude-opus-5-5", openCodeProvider: .anthropic))
        XCTAssertEqual(links(events), [.link(url: URL(string: "https://chosen.example/page")!, description: "Chosen", provider: nil)])
    }

    func testAnthropicSearchBesideAFunctionCallIsAwaitedBeforeTheAnswer() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return self.serve(["stop_reason": "tool_use", "content": [
                    ["type": "server_tool_use", "id": "srv", "name": "web_search", "input": ["query": "q"]],
                    ["type": "tool_use", "id": "early", "name": "finish_answer", "input": self.final("Guess.")]
                ]])
            }
            return self.serve(["stop_reason": "tool_use", "content": [
                ["type": "web_search_tool_result", "tool_use_id": "srv", "content": [
                    ["type": "web_search_result", "url": "https://fact.example", "title": "Fact", "encrypted_content": "E"]]],
                ["type": "tool_use", "id": "late", "name": "finish_answer", "input": self.final("Checked answer.")]
            ]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "claude-opus-5-5", openCodeProvider: .anthropic))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(finalText(events), "Checked answer.")
        let reply = try XCTUnwrap((try body(1)["messages"] as? [[String: Any]])?.last?["content"] as? [[String: Any]])
        XCTAssertEqual(reply.map { $0["tool_use_id"] as? String }, ["early"], "Only the function call gets a tool result")
    }

    // MARK: - OpenAI and OpenRouter

    func testOpenAIBuiltInSearchSendsItsToolAndUsesCitationsWhileCostStaysUnknown() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        StubURLProtocol.handler = { _ in
            self.serve(["status": "completed", "usage": ["input_tokens": 100, "output_tokens": 10], "output": [
                ["type": "web_search_call", "id": "ws_1", "status": "completed",
                 "action": ["type": "search", "query": "weather", "sources": [["type": "url", "url": "https://source.example/a"]]]],
                ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Cold.", "annotations": [
                    ["type": "url_citation", "url": "https://cited.example/b", "title": "Cited", "start_index": 0, "end_index": 4]]]]],
                ["type": "function_call", "call_id": "call_1", "name": "finish_answer", "arguments": self.arguments(self.final("It is cold."))]
            ]])
        }
        var usage: [AIUsageEvent] = []
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { usage.append($0) })
        let events = await run(provider, "weather", .init(model: "gpt-6.2-astra", openCodeProvider: .openAI))
        let first = try body(0)
        XCTAssertTrue((first["tools"] as? [[String: Any]])?.contains { $0["type"] as? String == "web_search" } == true)
        XCTAssertFalse((first["tools"] as? [[String: Any]])?.contains { $0["name"] as? String == "web_search" } == true)
        XCTAssertTrue((first["include"] as? [String])?.contains("web_search_call.action.sources") == true)
        XCTAssertEqual(first["max_tool_calls"] as? Int, 2)
        XCTAssertEqual(finalText(events), "It is cold.")
        XCTAssertEqual(links(events).map { if case .link(let url, _, _) = $0 { return url.absoluteString }; return "" },
                       ["https://cited.example/b", "https://source.example/a"])
        XCTAssertNil(usage.first?.amount, "OpenAI reports no charge: never shown as 0")
        XCTAssertEqual(usage.first?.basis, .unavailable)
    }

    func testOpenAISearchWithoutAFunctionCallContinuesTheTurn() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return self.serve(["status": "completed", "output": [
                    ["type": "web_search_call", "id": "ws_1", "status": "completed", "action": ["type": "search", "query": "q"]],
                    ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Found it."]]]
                ]])
            }
            return self.serve(["status": "completed", "output": [
                ["type": "function_call", "call_id": "c", "name": "finish_answer", "arguments": self.arguments(self.final("Done."))]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "gpt-6.2-astra", openCodeProvider: .openAI))
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(finalText(events), "Done.")
        XCTAssertEqual(try body(0)["max_tool_calls"] as? Int, 2)
        XCTAssertEqual(try body(1)["max_tool_calls"] as? Int, 1, "One search left in the turn")
        let input = try XCTUnwrap(try body(1)["input"] as? [[String: Any]])
        XCTAssertEqual(input.last?["role"] as? String, "user", "The continuation does not end on the assistant's message")
        XCTAssertTrue(input.contains { $0["type"] as? String == "web_search_call" }, "Search items are replayed")
    }

    func testOpenRouterBuiltInSearchKeepsReportedCostAndReplaysCitations() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("router-key", account: OpenRouterLLMKeyStore.account)
        StubURLProtocol.handler = { _ in
            self.serve(["choices": [["finish_reason": "tool_calls", "message": [
                "role": "assistant", "content": NSNull(),
                "annotations": [["type": "url_citation", "url_citation": ["url": "https://router.example/x", "title": "Router source",
                                                                          "content": "excerpt", "start_index": 0, "end_index": 3]]],
                "tool_calls": [["id": "f", "type": "function", "function": ["name": "finish_answer",
                                                                            "arguments": self.arguments(self.final("Answer."))]]]
            ]]], "usage": ["cost": 0.0171]])
        }
        var usage: [AIUsageEvent] = []
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { usage.append($0) })
        let events = await run(provider, "q", .init(model: "qwen/qwen3.8-27b"))
        let tools = try XCTUnwrap(try body(0)["tools"] as? [[String: Any]])
        let server = try XCTUnwrap(tools.first { $0["type"] as? String == "openrouter:web_search" })
        XCTAssertEqual((server["parameters"] as? [String: Any])?["max_uses"] as? Int, 2)
        XCTAssertEqual(links(events), [.link(url: URL(string: "https://router.example/x")!, description: "Router source", provider: nil)])
        XCTAssertEqual(try XCTUnwrap(usage.first?.amount), 0.0171, accuracy: 1e-12, "OpenRouter's usage.cost includes the search")
        XCTAssertEqual(usage.first?.basis, .reported)
    }

    // MARK: - Fallback to Tavily

    func testModelWithoutBuiltInSearchFallsBackToTavilyWithItsSources() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        try keys.save("tavily-key", account: TavilySearch.keychainAccount)
        var modelCalls = 0, searches = 0
        StubURLProtocol.handler = { request in
            if request.url?.host == "api.tavily.com" {
                searches += 1
                return self.serve(["results": [["url": "https://tavily.example/r", "title": "Tavily result", "content": "−3 °C"]]])
            }
            modelCalls += 1
            if modelCalls == 1 {
                return self.serve(["stop_reason": "tool_use", "content": [
                    ["type": "tool_use", "id": "s", "name": "web_search", "input": ["query": "погода Москва"]]]])
            }
            return self.serve(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "f", "name": "finish_answer",
                "input": self.final("−3 °C.", sources: [["title": "Tavily result", "url": "https://tavily.example/r"]])]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "погода", .init(model: "claude-legacy", openCodeProvider: .anthropic, webSearchSupport: false))
        let tools = try XCTUnwrap(try body(0)["tools"] as? [[String: Any]])
        XCTAssertFalse(tools.contains { $0["type"] as? String == "web_search_20250305" })
        XCTAssertTrue(tools.contains { $0["name"] as? String == "web_search" && $0["input_schema"] != nil })
        XCTAssertEqual(searches, 1); XCTAssertEqual(modelCalls, 2)
        XCTAssertEqual(links(events), [.link(url: URL(string: "https://tavily.example/r")!, description: "Tavily result", provider: nil)])
    }

    func testRejectedBuiltInSearchRetriesOnceWithTavily() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        try keys.save("tavily-key", account: TavilySearch.keychainAccount)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return (400, [:], Data("{\"error\":{\"message\":\"Tool 'web_search' is not supported with this model.\",\"type\":\"invalid_request_error\"}}".utf8))
            }
            return self.serve(["status": "completed", "output": [
                ["type": "function_call", "call_id": "c", "name": "finish_answer", "arguments": self.arguments(self.final("Answer."))]]])
        }
        var usage: [AIUsageEvent] = []
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { usage.append($0) })
        let events = await run(provider, "q", .init(model: "gpt-new-without-search", openCodeProvider: .openAI))
        XCTAssertEqual(calls, 2, "One retry, no more")
        let retry = try XCTUnwrap(try body(1)["tools"] as? [[String: Any]])
        XCTAssertFalse(retry.contains { $0["type"] as? String == "web_search" })
        XCTAssertTrue(retry.contains { $0["name"] as? String == "web_search" })
        XCTAssertTrue((try body(1)["instructions"] as? String)?.contains("(Tavily)") == true)
        XCTAssertNil(try body(1)["max_tool_calls"])
        XCTAssertEqual(finalText(events), "Answer.")
        XCTAssertTrue(usage.allSatisfy { $0.amount == nil }, "A rejected request is never priced as 0")
    }

    func testRejectionAfterTheFirstRequestIsNotRetried() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 {
                return self.serve(["status": "completed", "output": [
                    ["type": "function_call", "call_id": "c", "name": "list_directory", "arguments": "{\"path\":null}"]]])
            }
            return (400, [:], Data())
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "q", .init(model: "gpt-6.2-astra", allowActions: false, openCodeProvider: .openAI))
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(events.contains { if case .error = $0 { return true }; return false })
    }

    // MARK: - No search

    func testWithoutBuiltInSearchOrTavilyTheModelIsToldAndHasNoSearchTool() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        StubURLProtocol.handler = { _ in
            self.serve(["status": "completed", "output": [["type": "function_call", "call_id": "c", "name": "finish_answer",
                "arguments": self.arguments(self.final("Не могу проверить погоду: веб-поиск не подключён.", status: "unverified"))]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "какая погода сегодня в Москве", .init(model: "gpt-4.1-nano", openCodeProvider: .openAI))
        let first = try body(0)
        let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
        XCTAssertFalse(tools.contains { $0["type"] as? String == "web_search" || $0["name"] as? String == "web_search" })
        let instructions = try XCTUnwrap(first["instructions"] as? String)
        XCTAssertTrue(instructions.contains("Web search is off"))
        XCTAssertTrue(instructions.contains("answer in one line"))
        XCTAssertTrue(instructions.contains("adding a Tavily key in Settings → API & Models → API keys"))
        XCTAssertNil(first["max_tool_calls"])
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        XCTAssertTrue(finalText(events)?.hasPrefix("Couldn’t verify") == true)
        XCTAssertTrue(links(events).isEmpty)
    }

    // MARK: - Search failures

    func testProviderSearchErrorStillEndsWithAnHonestAnswerAndNoCards() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        StubURLProtocol.handler = { _ in
            self.serve(["stop_reason": "tool_use", "content": [
                ["type": "server_tool_use", "id": "srv", "name": "web_search", "input": ["query": "q"]],
                ["type": "web_search_tool_result", "tool_use_id": "srv",
                 "content": ["type": "web_search_tool_result_error", "error_code": "unavailable"]],
                ["type": "tool_use", "id": "f", "name": "finish_answer",
                 "input": self.final("Поиск сейчас недоступен, проверить не удалось.", status: "unverified")]
            ], "usage": ["input_tokens": 100, "output_tokens": 10]])
        }
        var usage: [AIUsageEvent] = []
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { usage.append($0) })
        let events = await run(provider, "q", .init(model: "claude-opus-5-5", openCodeProvider: .anthropic))
        XCTAssertTrue(finalText(events)?.contains("проверить не удалось") == true)
        XCTAssertTrue(links(events).isEmpty)
        XCTAssertEqual(events.last, .done(sources: []))
        // A failed search is not billed and the response reports no search request.
        XCTAssertEqual(try XCTUnwrap(usage.first?.amount), (100 * 4 + 10 * 20) / 1_000_000, accuracy: 1e-12)
    }

    func testTavilyTimeoutReachesTheModelAsAFailedToolAndTheTurnFinishes() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        try keys.save("tavily-key", account: TavilySearch.keychainAccount)
        var modelCalls = 0
        StubURLProtocol.handler = { request in
            if request.url?.host == "api.tavily.com" { throw URLError(.timedOut) }
            modelCalls += 1
            if modelCalls == 1 {
                return self.serve(["status": "completed", "output": [
                    ["type": "function_call", "call_id": "s", "name": "web_search", "arguments": "{\"query\":\"q\"}"]]])
            }
            return self.serve(["status": "completed", "output": [["type": "function_call", "call_id": "f", "name": "finish_answer",
                "arguments": self.arguments(self.final("Search timed out; I couldn't check.", status: "unverified"))]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        // gpt-4.1-nano has no built-in search, so this turn uses Tavily.
        let events = await run(provider, "q", .init(model: "gpt-4.1-nano", openCodeProvider: .openAI))
        XCTAssertEqual(modelCalls, 2)
        // Requests: model, Tavily (timed out), model.
        XCTAssertEqual(StubURLProtocol.capturedRequests.map { $0.url?.host ?? "" }, ["api.openai.com", "api.tavily.com", "api.openai.com"])
        let toolOutput = try XCTUnwrap((try body(2)["input"] as? [[String: Any]])?.first { $0["type"] as? String == "function_call_output" })
        XCTAssertTrue((toolOutput["output"] as? String)?.hasPrefix("Tool failed:") == true)
        XCTAssertFalse(String(describing: toolOutput).contains("tavily-key"))
        XCTAssertTrue(finalText(events)?.contains("couldn't check") == true)
    }

    // MARK: - Cost

    func testAnthropicSearchFeeOnlyWithAKnownTokenPrice() {
        let usage: [String: Any] = ["input_tokens": 0, "output_tokens": 0, "server_tool_use": ["web_search_requests": 2]]
        XCTAssertEqual(try XCTUnwrap(AnthropicUsagePrices.cost(model: "claude-sonnet-5-5", usage: usage)), 0.02, accuracy: 1e-12)
        XCTAssertNil(AnthropicUsagePrices.cost(model: "unknown-model", usage: usage), "Unknown token price: no partial total")
        XCTAssertNil(AnthropicUsagePrices.cost(model: "claude-sonnet-5-5",
                                               usage: ["input_tokens": 1, "output_tokens": 1, "server_tool_use": "malformed"]))
        XCTAssertNil(AnthropicUsagePrices.cost(model: "claude-sonnet-5-5",
            usage: ["input_tokens": 1, "output_tokens": 1, "server_tool_use": ["web_search_requests": -1]]))
    }
}

import XCTest
@testable import Sidekey

/// Groq as a built-in provider: one key, text features and Agent, its own host
/// and nothing borrowed from OpenRouter. No network, Keychain or app launch.
// WHY: .project-docs/decisions/2026-11-19-groq-provider.md
@MainActor
final class GroqProviderTests: XCTestCase {
    private func session(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) -> URLSession {
        StubURLProtocol.reset()
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); StubURLProtocol.reset() }
        return session
    }

    private func json(_ object: [String: Any], status: Int = 200) -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    private func makeKeys() -> ProviderKeyStore {
        let box = InMemoryTokenStore.Box()
        return ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
    }

    private func makeRouting() -> AIRoutingStore {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AIRoutingStore(defaults: defaults)
    }

    private func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies[index]) as? [String: Any])
    }

    private func completion(_ message: [String: Any], finish: String = "stop") -> [String: Any] {
        ["choices": [["message": message, "finish_reason": finish]],
         "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15]]
    }

    // MARK: Identity and what it serves

    func test_account_is_stored_under_its_own_name_and_key() {
        XCTAssertEqual(ProviderAccount.groq.storageID, "groq")
        XCTAssertEqual(ProviderAccount(storageID: "groq"), .groq)
        XCTAssertNil(ProviderAccount(storageID: "Groq"))
        XCTAssertEqual(ProviderAccount.groq.kind, .groq)
        XCTAssertEqual(AIProviderKind.groq.displayName, "Groq")
        let routing = makeRouting()
        let account = ProviderAccount.groq.keychainAccount(in: routing)
        XCTAssertEqual(account, "byok.groq.api_key")
        // No other provider's key lives under Groq's account.
        for other in [ProviderAccount.openRouter, .openAI, .anthropic, .soniox, .deepgram, .elevenLabs] {
            XCTAssertNotEqual(other.keychainAccount(in: routing), account)
        }
        XCTAssertTrue(ConfigBackupRegistry.credentialAccounts.contains("byok.groq.api_key"))
    }

    func test_groq_serves_text_and_agent_but_no_speech() {
        for feature in AIFeature.allCases where feature.isActive {
            let use = feature.modelUse(on: .groq)
            switch feature.mode {
            case .llm: XCTAssertEqual(use, .chat, feature.rawValue)
            case .llmWithTools: XCTAssertEqual(use, .chatWithTools, feature.rawValue)
            case .realtime, .recorded, .decision: XCTAssertNil(use, feature.rawValue)
            }
        }
        XCTAssertEqual(OpenCodeModelProvider(account: .groq), .groq)
        XCTAssertEqual(OpenCodeModelProvider.groq.account, .groq)
    }

    // MARK: Catalog

    func test_catalog_authenticates_and_offers_only_active_text_models() async throws {
        let fetcher = ModelCatalogFetcher(session: session { _ in self.json(["object": "list", "data": [
            ["id": "openai/gpt-oss-120b", "active": true, "context_window": 131_072, "max_completion_tokens": 65_536, "created": 1_754_000_000],
            ["id": "llama-3.3-70b-versatile", "active": true, "context_window": 131_072],
            ["id": "whisper-large-v3-turbo", "active": true, "context_window": 448],
            ["id": "canopylabs/orpheus-v1-english", "active": true],
            ["id": "meta-llama/llama-prompt-guard-2-86m", "active": true],
            ["id": "openai/gpt-oss-safeguard-20b", "active": true],
            ["id": "retired-model", "active": false, "context_window": 8192],
            ["id": "  ", "active": true],
            ["id": "zero-window", "context_window": 0, "max_completion_tokens": -1],
        ]]) })
        let models = try await fetcher.fetch(account: .groq, apiKey: "groq-key", server: nil)
        XCTAssertEqual(models.map(\.id), ["llama-3.3-70b-versatile", "openai/gpt-oss-120b", "zero-window"])
        XCTAssertTrue(models.allSatisfy { $0.uses == [.chat, .chatWithTools] && $0.supportsTools == true })
        XCTAssertEqual(models[1].contextLength, 131_072)
        XCTAssertEqual(models[1].maxOutputTokens, 65_536)
        XCTAssertNotNil(models[1].catalogDate)
        // Missing or nonsensical limits stay unknown instead of becoming zero.
        XCTAssertNil(models[0].maxOutputTokens)
        XCTAssertNil(models[2].contextLength)
        XCTAssertNil(models[2].maxOutputTokens)
        XCTAssertNil(models.first?.tokenPrice)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/models")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer groq-key")
    }

    func test_catalog_without_a_key_asks_nobody_and_bad_answers_are_errors() async throws {
        var fetcher = ModelCatalogFetcher(session: session { _ in self.json(["data": []]) })
        for key in [nil, ""] as [String?] {
            do {
                _ = try await fetcher.fetch(account: .groq, apiKey: key, server: nil)
                XCTFail("A missing key must not fetch")
            } catch { XCTAssertEqual(error as? CatalogFetchError, .http(401, code: nil)) }
        }
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)

        fetcher = ModelCatalogFetcher(session: session { _ in (200, [:], Data("<html>".utf8)) })
        do {
            _ = try await fetcher.fetch(account: .groq, apiKey: "k", server: nil)
            XCTFail("HTML is not a catalog")
        } catch { XCTAssertEqual(error as? CatalogFetchError, .malformed) }

        fetcher = ModelCatalogFetcher(session: session { _ in self.json(["error": ["message": "Invalid API Key"]], status: 401) })
        do {
            _ = try await fetcher.fetch(account: .groq, apiKey: "bad", server: nil)
            XCTFail("A refused key is an error")
        } catch { XCTAssertEqual(error as? CatalogFetchError, .http(401, code: nil)) }
    }

    // MARK: Key check

    func test_key_check_reads_the_free_models_list_and_names_the_outcome() async throws {
        let expected: [(Int, KeyStatus)] = [
            (200, .valid), (401, .rejected(.invalidKey)), (402, .rejected(.outOfCredit)),
            (403, .limited), (429, .unreachable), (503, .unreachable),
        ]
        for (status, outcome) in expected {
            let checker = ProviderKeyChecker(session: session { _ in self.json([:], status: status) })
            let result = await checker.check(.groq, apiKey: "  groq-key\n", server: nil, allowPaidProbe: true)
            XCTAssertEqual(result, outcome, "HTTP \(status)")
            let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer groq-key")
            // Nothing is generated to check a key, even when a paid probe is allowed.
            XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        }
        let silent = ProviderKeyChecker(session: session { _ in self.json([:]) })
        let missing = await silent.check(.groq, apiKey: "   ", server: nil, allowPaidProbe: false)
        XCTAssertEqual(missing, .rejected(.invalidKey))
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    // MARK: Text features

    func test_text_features_run_on_groq_only_with_groqs_own_key() async throws {
        let routing = makeRouting()
        let keys = makeKeys()
        try keys.save("openrouter-key", account: OpenRouterLLMKeyStore.account)
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        let llmFeatures = AIFeature.allCases.filter { $0.isActive && $0.mode == .llm }
        XCTAssertFalse(llmFeatures.isEmpty)
        for feature in llmFeatures {
            routing.setRoute(FeatureRoute(account: .groq, model: "llama-3.3-70b-versatile"), for: feature)
            // Other providers' keys never stand in for a missing Groq key.
            do {
                _ = try await DirectLLMRouteResolver(feature: feature, routing: routing, keys: keys).routeIfEnabled()
                XCTFail("\(feature) ran without a Groq key")
            } catch { XCTAssertEqual(error as? OpenRouterLLMError, .missingKey) }
        }
        try keys.save("groq-key", account: ProviderAccount.groqKeychainAccount)
        for feature in llmFeatures {
            let route = try await DirectLLMRouteResolver(feature: feature, routing: routing, keys: keys).routeIfEnabled()
            XCTAssertEqual(route?.endpoint, .groq(apiKey: "groq-key"), feature.rawValue)
            XCTAssertEqual(route?.endpoint.baseURL.absoluteString, "https://api.groq.com/openai/v1")
            XCTAssertEqual(route?.endpoint.sendsOpenRouterHeaders, false)
            XCTAssertEqual(route?.endpoint.requiresAPIKey, true)
            XCTAssertEqual(route?.model, "llama-3.3-70b-versatile")
            XCTAssertEqual(route?.usageContext?.account, .groq)
        }
    }

    func test_text_request_goes_to_groq_without_openrouter_fields() async throws {
        let client = OpenRouterLLMClient(session: session { _ in
            self.json(self.completion(["role": "assistant", "content": "Cleaned text."]))
        }, profile: .dictation)
        let text = try await client.complete(endpoint: .groq(apiKey: "groq-key"), model: "openai/gpt-oss-20b",
                                             messages: [.init(role: "user", content: "clean this")])
        XCTAssertEqual(text, "Cleaned text.")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer groq-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Title"))
        XCTAssertNil(request.value(forHTTPHeaderField: "HTTP-Referer"))
        let sent = try body(0)
        XCTAssertEqual(sent["model"] as? String, "openai/gpt-oss-20b")
        XCTAssertEqual(sent["stream"] as? Bool, false)
        // OpenRouter's routing and reasoning controls mean nothing to Groq.
        XCTAssertNil(sent["provider"])
        XCTAssertNil(sent["reasoning"])
    }

    func test_thinking_inside_the_text_is_never_returned_as_the_answer() async throws {
        XCTAssertEqual(OpenRouterLLMClient.withoutLeadingThinkBlock("<think>plan</think>\n\nAnswer."), "Answer.")
        XCTAssertEqual(OpenRouterLLMClient.withoutLeadingThinkBlock("  \n<think>a</think>B <think>kept</think>"), "B <think>kept</think>")
        XCTAssertEqual(OpenRouterLLMClient.withoutLeadingThinkBlock("<think>never finished"), "")
        // Ordinary text, including one that only mentions the tag, is untouched.
        XCTAssertEqual(OpenRouterLLMClient.withoutLeadingThinkBlock("Use <think> tags."), "Use <think> tags.")
        XCTAssertEqual(OpenRouterLLMClient.withoutLeadingThinkBlock(""), "")

        var client = OpenRouterLLMClient(session: session { _ in
            self.json(self.completion(["role": "assistant", "content": "<think>The user wants X.</think>\nDone."]))
        })
        let groq = try await client.complete(endpoint: .groq(apiKey: "k"), model: "m", messages: [.init(role: "user", content: "x")])
        XCTAssertEqual(groq, "Done.")

        // Only thinking came back: that is an empty answer, not text to paste.
        client = OpenRouterLLMClient(session: session { _ in
            self.json(self.completion(["role": "assistant", "content": "<think>only thoughts</think>  "]))
        })
        do {
            _ = try await client.complete(endpoint: .groq(apiKey: "k"), model: "m", messages: [.init(role: "user", content: "x")])
            XCTFail("Thinking alone is not an answer")
        } catch { XCTAssertEqual(error as? OpenRouterLLMError, .emptyContent) }

        // Another provider's text is passed through exactly as before.
        client = OpenRouterLLMClient(session: session { _ in
            self.json(self.completion(["role": "assistant", "content": "<think>literal</think>text"]))
        })
        let other = try await client.complete(endpoint: .custom(baseURL: URL(string: "https://llm.example.com/v1")!, apiKey: nil),
                                              model: "m", messages: [.init(role: "user", content: "x")])
        XCTAssertEqual(other, "<think>literal</think>text")
    }

    // MARK: Agent

    private func agentFixture() throws -> (URL, ProviderKeyStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, makeKeys())
    }

    private func finalCall(_ answer: String) -> [String: Any] {
        let arguments = String(decoding: try! JSONSerialization.data(withJSONObject:
            ["status": "answered", "answer": answer, "sources": [], "actions": []] as [String: Any]), as: UTF8.self)
        return completion(["role": "assistant", "content": NSNull(), "tool_calls": [["id": "final", "type": "function",
            "function": ["name": "finish_answer", "arguments": arguments]]]], finish: "tool_calls")
    }

    func test_agent_turn_runs_on_groq_with_groqs_key_and_request_shape() async throws {
        let (directory, keys) = try agentFixture()
        try keys.save("openrouter-key", account: OpenRouterLLMKeyStore.account)
        try keys.save("groq-key", account: ProviderAccount.groqKeychainAccount)
        let http = NativeAgentHTTP(session: session { _ in self.json(self.finalCall("Four.")) })
        var usage: [AIUsageEvent] = []
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { usage.append($0) })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "2+2?", resumeSessionID: nil,
            options: .init(model: "openai/gpt-oss-120b", allowActions: false, openCodeProvider: .groq,
                           openRouterProvider: "must-not-leak")) { events.append(event) }
        XCTAssertTrue(events.contains(.finalAnswer(text: "Four.")), "\(events)")
        XCTAssertEqual(events.last, .done(sources: []))
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer groq-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Title"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))

        let sent = try body(0)
        XCTAssertEqual(sent["model"] as? String, "openai/gpt-oss-120b")
        XCTAssertEqual(sent["tool_choice"] as? String, "required")
        // Groq's own limit name, kept small beside its per-minute token limits.
        XCTAssertEqual(sent["max_completion_tokens"] as? Int, NativeAgentModel.groqOutputLimit)
        XCTAssertNil(sent["max_tokens"])
        // Nothing OpenRouter-specific, including a pin left from another route.
        XCTAssertNil(sent["provider"])
        let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["content"] as? String, "2+2?")
        let functions = try XCTUnwrap(sent["tools"] as? [[String: Any]]).compactMap { $0["function"] as? [String: Any] }
        XCTAssertTrue(functions.contains { $0["name"] as? String == "finish_answer" })
        XCTAssertTrue(functions.allSatisfy { $0["strict"] == nil && $0["parameters"] != nil })

        // Groq reports tokens only: the turn is recorded without an invented price.
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage.first?.context.account, .groq)
        XCTAssertEqual(usage.first?.context.feature, .agent)
        XCTAssertNil(usage.first?.amount)
        XCTAssertEqual(usage.first?.basis, .unavailable)
    }

    func test_agent_model_limit_is_respected_when_smaller_than_groqs_cap() async throws {
        let http = NativeAgentHTTP(session: session { _ in self.json(self.completion(["role": "assistant", "content": "ok"])) })
        var model = NativeAgentModel(options: .init(model: "tiny",
                openCodeModelSpec: .init(toolCall: true, reasoning: false, contextLimit: 8192, outputLimit: 512),
                openCodeProvider: .groq),
            key: "k", system: "system", history: [], prompt: "hi", http: http, usageSink: { _ in }, diagnosticsSink: { _ in })
        _ = try await model.next(tools: [])
        let sent = try body(0)
        XCTAssertEqual(sent["max_completion_tokens"] as? Int, 512)
        XCTAssertNil(sent["tools"])
        XCTAssertNil(sent["tool_choice"])
    }

    func test_agent_tool_step_pairs_results_and_does_not_send_reasoning_back() async throws {
        var step = 0
        let http = NativeAgentHTTP(session: session { _ in
            step += 1
            if step == 1 {
                return self.json(self.completion(["role": "assistant", "content": NSNull(), "reasoning": "private chain of thought",
                    "tool_calls": [["id": "call_1", "type": "function",
                                    "function": ["name": "read_file", "arguments": ["path": "notes.txt"]]]]], finish: "tool_calls"))
            }
            return self.json(self.completion(["role": "assistant", "content": "The file says hi."]))
        })
        var model = NativeAgentModel(options: .init(model: "qwen/qwen3.8-27b", openCodeProvider: .groq),
            key: "k", system: "system", history: [], prompt: "read notes", http: http, usageSink: { _ in }, diagnosticsSink: { _ in })
        let (_, calls) = try await model.next(tools: NativeAgentTools.definitions(allowActions: true))
        XCTAssertEqual(calls.map(\.name), ["read_file"])
        XCTAssertEqual(calls.first?.arguments["path"] as? String, "notes.txt")
        model.append(results: [(calls[0], .init(text: "hi"))])
        let (text, more) = try await model.next(tools: NativeAgentTools.definitions(allowActions: true))
        XCTAssertEqual(text, "The file says hi.")
        XCTAssertTrue(more.isEmpty)

        let second = try XCTUnwrap(try body(1)["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(second.first { $0["role"] as? String == "assistant" })
        XCTAssertNil(assistant["reasoning"])
        XCTAssertNil(assistant["reasoning_content"])
        XCTAssertNil(assistant["reasoning_details"])
        let replayed = try XCTUnwrap((assistant["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(replayed["id"] as? String, "call_1")
        // Object arguments from the model go back as the JSON string the API requires.
        let arguments = try XCTUnwrap((replayed["function"] as? [String: Any])?["arguments"] as? String)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: String], ["path": "notes.txt"])
        let tool = try XCTUnwrap(second.last)
        XCTAssertEqual(tool["role"] as? String, "tool")
        XCTAssertEqual(tool["tool_call_id"] as? String, "call_1")
        XCTAssertEqual(tool["content"] as? String, "hi")
    }

    func test_agent_names_groq_limits_and_refusals_without_retrying_or_echoing() async throws {
        let secret = "SECRET-PROVIDER-TEXT"
        let cases: [(Int, String)] = [
            (413, "This request is larger than the provider allows at once. Try a shorter request or another model."),
            (429, "The service is busy or its usage limit was reached. Try again later."),
            (401, "The service refused this API key. Check Settings."),
        ]
        for (status, message) in cases {
            let (directory, keys) = try agentFixture()
            try keys.save("groq-key", account: ProviderAccount.groqKeychainAccount)
            let http = NativeAgentHTTP(session: session { _ in
                self.json(["error": ["message": secret, "type": "tokens", "code": "rate_limit_exceeded"]], status: status)
            })
            var usage: [AIUsageEvent] = []
            let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { usage.append($0) })
            var events: [AgentSSEEvent] = []
            for await event in provider.run(prompt: "question", resumeSessionID: nil,
                options: .init(model: "openai/gpt-oss-120b", allowActions: false, openCodeProvider: .groq)) { events.append(event) }
            XCTAssertTrue(events.contains(.error(code: "native_agent", message: message, retryable: true)), "HTTP \(status): \(events)")
            XCTAssertFalse("\(events)".contains(secret))
            // A refused request is not sent again by itself.
            XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, "HTTP \(status)")
            XCTAssertEqual(usage.map(\.basis), [.unavailable])
        }
    }

    func test_agent_without_a_groq_key_sends_nothing_even_with_other_keys() async throws {
        let (directory, keys) = try agentFixture()
        try keys.save("openrouter-key", account: OpenRouterLLMKeyStore.account)
        try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
        let http = NativeAgentHTTP(session: session { _ in self.json(self.finalCall("never")) })
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "question", resumeSessionID: nil,
            options: .init(model: "openai/gpt-oss-120b", allowActions: false, openCodeProvider: .groq)) { events.append(event) }
        XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
        XCTAssertFalse(events.contains(.finalAnswer(text: "never")))
        XCTAssertTrue(events.contains { if case .error = $0 { return true } else { return false } })
    }
}

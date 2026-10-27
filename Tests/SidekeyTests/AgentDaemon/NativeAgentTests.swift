import AppKit
import SwiftUI
import WhytapCaseKit
import XCTest
@testable import Sidekey

@MainActor
final class NativeAgentTests: XCTestCase {
    private func fixture() throws -> (URL, ProviderKeyStore, NativeAgentHTTP) {
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

    private func serve(_ object: [String: Any]) -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }

    private func router(_ message: [String: Any], finish: String = "stop") -> [String: Any] {
        ["choices": [["message": message, "finish_reason": finish]], "usage": ["cost": 0.001]]
    }

    private func body(_ index: Int) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies[index]) as? [String: Any])
    }

    func testSystemPromptSetsReplyLanguageOnceWithoutCardDescriptionLanguageRule() {
        let prompt = NativeAgentProvider.systemPrompt
        XCTAssertTrue(prompt.contains("Reply in the latest request’s language."))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains("descriptions in the user"))
        XCTAssertEqual(prompt.components(separatedBy: "language").count - 1, 1,
                       "Another language sentence made card descriptions come out in Russian or German")
    }

    func testFirstRequestHasToolsAndExactRouteWithoutBootstrapAndActionsStayOutOfText() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("router-secret", account: OpenRouterLLMKeyStore.account)
        try keys.save("wrong-openai-secret", account: ProviderAccount.openAIKeychainAccount)
        try Data("Prefer Russian.".utf8).write(to: directory.appendingPathComponent("AGENTS.md"))
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 { return self.serve(self.router(["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "action", "type": "function", "function": ["name": "show_actions", "arguments": "{\"items\":[{\"type\":\"path\",\"path\":\"/tmp/project\",\"description\":\"Открыть папку\"}]}"]]
            ]], finish: "tool_calls")) }
            return self.serve(self.router(["role": "assistant", "content": "Проект здесь:\n```\n/tmp/project\n``` "]))
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "Where is the project?", resumeSessionID: nil,
            options: .init(model: "vendor/exact-model", allowActions: false, openRouterProvider: "endpoint/pin")) { events.append(event) }
        XCTAssertEqual(calls, 2, "No version check, catalog fetch, MCP bootstrap or extra model request")
        let first = try body(0)
        XCTAssertEqual(first["model"] as? String, "vendor/exact-model")
        XCTAssertEqual((first["provider"] as? [String: Any])?["only"] as? [String], ["endpoint/pin"])
        let tools = try XCTUnwrap(first["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "web_search" })
        XCTAssertFalse(tools.contains { ($0["function"] as? [String: Any])?["name"] as? String == "run_command" })
        XCTAssertEqual(StubURLProtocol.capturedRequests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer router-secret")
        XCTAssertFalse(String(decoding: StubURLProtocol.capturedBodies[0], as: UTF8.self).contains("wrong-openai-secret"))
        XCTAssertTrue(events.contains { if case .blockComplete(.usefulActions(let block)) = $0 { return block.items.count == 1 }; return false })
        XCTAssertTrue(events.contains(.finalAnswer(text: "Проект здесь:\n```\n/tmp/project\n```")))
        XCTAssertEqual(events.last, .done(sources: []))
        XCTAssertNotNil(provider.lastSessionID)
        let saved = try String(contentsOf: directory.appendingPathComponent(NativeAgentConversation.fileName), encoding: .utf8)
        XCTAssertFalse(saved.contains("tool_calls")); XCTAssertFalse(saved.contains("base64"))
        XCTAssertFalse(saved.contains("Prefer Russian"), "Memory is supplied once, not duplicated into history")
    }

    func testPlainFinalLinksAndFoundFoldersEmitKeyboardActionsWithoutExtraModelCalls() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("key", account: OpenRouterLLMKeyStore.account)
        let folder = directory.appendingPathComponent("My Project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let answer = "Источник: https://example.com/source\nПапка: `\(folder.path)`"
        StubURLProtocol.handler = { _ in self.serve(self.router(["role": "assistant", "content": answer])) }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var items: [ActionItem] = []
        var final: String?
        for await event in provider.run(prompt: "Find the source and folder", resumeSessionID: nil, options: .init(model: "model", allowActions: false)) {
            if case .blockComplete(.usefulActions(let block)) = event { items = block.items }
            if case .finalAnswer(let text) = event { final = text }
        }
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1, "Artifact presentation must not need another model or tool request")
        XCTAssertEqual(final, answer)
        XCTAssertEqual(items.map(\.insertText), ["https://example.com/source", folder.path])
        let selection = UsefulLinksSelectionState(items: items)
        XCTAssertTrue(selection.selectedItemSupportsOpen)
        selection.selectNext()
        XCTAssertEqual(selection.selectedItem?.openTarget?.path, folder.path)
        XCTAssertEqual(selection.selectedItem?.insertText, folder.path)
    }

    func testFollowUpRetainsPricesAndAnswerEmittedAlongsideCards() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("key", account: OpenRouterLLMKeyStore.account)
        let prices = "256 ГБ — 8 499 AED; 512 ГБ — 9 349 AED."
        let converted = "256 ГБ — примерно $2 314; 512 ГБ — $2 546."
        let url = "https://example.com/phone"
        var calls = 0
        StubURLProtocol.handler = { _ in
            calls += 1
            if calls == 1 || calls == 3 {
                return self.serve(self.router(["role": "assistant", "content": calls == 1 ? prices : converted,
                    "tool_calls": [["id": "cards-\(calls)", "type": "function", "function": [
                        "name": "show_actions", "arguments": "{\"items\":[{\"type\":\"link\",\"url\":\"\(url)\",\"description\":\"Phone prices\"}]}"
                    ]]]], finish: "tool_calls"))
            }
            return self.serve(self.router(["role": "assistant", "content": ""]))
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let options = AgentRunOptions(model: "vendor/exact", allowActions: false, openRouterProvider: "endpoint/pin")
        let first = AskResponseStore()
        await first.consume(provider.run(prompt: "Сколько стоит телефон в Дубае?", resumeSessionID: nil, options: options))
        XCTAssertEqual(first.streamingText, prices)
        XCTAssertEqual(first.blocks.count, 1)
        let session = try XCTUnwrap(provider.lastSessionID)
        let second = AskResponseStore()
        await second.consume(provider.run(prompt: "А сколько это в долларах?", resumeSessionID: session, options: options))
        XCTAssertEqual(second.streamingText, converted)
        XCTAssertEqual(provider.lastSessionID, session)
        let request = try body(2)
        let messages = try XCTUnwrap(request["messages"] as? [[String: Any]])
        let priorAnswer = try XCTUnwrap(messages.first { $0["role"] as? String == "assistant" }?["content"] as? String)
        XCTAssertTrue(priorAnswer.contains(prices))
        XCTAssertTrue(priorAnswer.contains(url), "A follow-up may refer to the returned card, not only its prose")
        XCTAssertEqual(messages.last?["content"] as? String, "А сколько это в долларах?")
        XCTAssertEqual(calls, 4, "Preserving a card's accompanying answer needs no extra model call")
        let saved = NativeAgentConversation.load(directory: directory, resumeID: session,
            route: "openrouter/vendor/exact/endpoint/pin")
        XCTAssertEqual(saved.pairs.count, 2)
        XCTAssertTrue(saved.pairs.last?.assistant.contains(converted) == true)
    }

    func testOpenAIResponsesRetainsReasoningAndCallIDAndReturnsImage() async throws {
        let (_, _, http) = try fixture()
        var count = 0
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/responses")
            count += 1
            return self.serve(count == 1 ? ["status": "completed", "output": [
                ["type": "reasoning", "id": "r1", "summary": [], "encrypted_content": "opaque"],
                ["type": "function_call", "call_id": "fc1", "name": "capture_screen", "arguments": "{}"]
            ]] : ["status": "completed", "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Visible fixture."]]]]])
        }
        var model = NativeAgentModel(options: .init(model: "exact-openai", openCodeProvider: .openAI), key: "own-openai-key", system: "system",
                                     history: [], prompt: "Read the screen", http: http, usageSink: { _ in })
        let (_, calls) = try await model.next(tools: NativeAgentTools.definitions(allowActions: true))
        model.append(results: [(calls[0], .init(text: "Captured", image: "synthetic-pixels"))])
        let (answer, _) = try await model.next(tools: NativeAgentTools.definitions(allowActions: true))
        XCTAssertEqual(answer, "Visible fixture.")
        let next = try body(1)
        XCTAssertEqual(next["store"] as? Bool, false)
        XCTAssertEqual(next["include"] as? [String], ["reasoning.encrypted_content"])
        let input = try XCTUnwrap(next["input"] as? [[String: Any]])
        XCTAssertTrue(input.contains { $0["encrypted_content"] as? String == "opaque" })
        XCTAssertTrue(input.contains { $0["type"] as? String == "function_call_output" && $0["call_id"] as? String == "fc1" })
        XCTAssertTrue(String(decoding: StubURLProtocol.capturedBodies[1], as: UTF8.self).replacingOccurrences(of: "\\/", with: "/").contains("data:image/jpeg;base64,synthetic-pixels"))
        XCTAssertEqual(StubURLProtocol.capturedRequests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer own-openai-key")
    }

    func testCardAnswerSurvivesEmptyFinalAcrossAllNativeProviders() async throws {
        for route: OpenCodeModelProvider in [.openRouter, .openAI, .anthropic] {
            let (directory, keys, http) = try fixture()
            let account: String
            switch route {
            case .openRouter: account = OpenRouterLLMKeyStore.account
            case .openAI: account = ProviderAccount.openAIKeychainAccount
            case .anthropic: account = ProviderAccount.anthropicKeychainAccount
            }
            try keys.save("key", account: account)
            var step = 0
            StubURLProtocol.handler = { _ in
                step += 1
                let text = step == 1 ? "The price is about $2,314." : ""
                let args: [String: Any] = ["items": [["type": "link", "url": "https://example.com/phone", "description": "Phone"]]]
                switch route {
                case .openRouter:
                    var message: [String: Any] = ["role": "assistant", "content": text]
                    if step == 1 { message["tool_calls"] = [["id": "card", "type": "function", "function": ["name": "show_actions",
                        "arguments": String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]] }
                    return self.serve(self.router(message, finish: step == 1 ? "tool_calls" : "stop"))
                case .openAI:
                    var output: [[String: Any]] = [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]
                    if step == 1 { output.append(["type": "function_call", "call_id": "card", "name": "show_actions",
                        "arguments": String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)]) }
                    return self.serve(["status": "completed", "output": output])
                case .anthropic:
                    var content: [[String: Any]] = [["type": "text", "text": text]]
                    if step == 1 { content.append(["type": "tool_use", "id": "card", "name": "show_actions", "input": args]) }
                    return self.serve(["stop_reason": step == 1 ? "tool_use" : "end_turn", "content": content])
                }
            }
            let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
            var events: [AgentSSEEvent] = []
            for await event in provider.run(prompt: "And in dollars?", resumeSessionID: nil,
                options: .init(model: "exact", allowActions: false, openCodeProvider: route)) { events.append(event) }
            XCTAssertTrue(events.contains(.finalAnswer(text: "The price is about $2,314.")), "\(route)")
            XCTAssertEqual(events.last, .done(sources: []))
            XCTAssertEqual(step, 2)
        }
    }

    func testCanonicalFinalAnswerOverridesTextBesideCards() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("key", account: OpenRouterLLMKeyStore.account)
        var step = 0
        StubURLProtocol.handler = { _ in
            step += 1
            if step == 1 { return self.serve(self.router(["role": "assistant", "content": "Earlier price.", "tool_calls": [
                ["id": "card", "type": "function", "function": ["name": "show_actions", "arguments": "{\"items\":[{\"type\":\"link\",\"url\":\"https://example.com\",\"description\":\"Source\"}]}"]]
            ]], finish: "tool_calls")) }
            return self.serve(self.router(["role": "assistant", "content": "Corrected final price."]))
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "price", resumeSessionID: nil, options: .init(model: "model")) { events.append(event) }
        XCTAssertTrue(events.contains(.finalAnswer(text: "Corrected final price.")))
        XCTAssertFalse(events.contains(.finalAnswer(text: "Earlier price.")))
    }

    func testNarrationBeforeEvidenceToolDoesNotBecomeSuccessfulAnswer() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("key", account: OpenRouterLLMKeyStore.account)
        var step = 0
        StubURLProtocol.handler = { _ in
            step += 1
            if step == 1 { return self.serve(self.router(["role": "assistant", "content": "I'll check the price now.", "tool_calls": [
                ["id": "read", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"missing.txt\"}"]]
            ]], finish: "tool_calls")) }
            return self.serve(self.router(["role": "assistant", "content": ""]))
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "price", resumeSessionID: nil, options: .init(model: "model")) { events.append(event) }
        XCTAssertTrue(events.contains { if case .error = $0 { return true }; return false })
        XCTAssertFalse(events.contains(.done(sources: [])))
        XCTAssertNil(provider.lastSessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(NativeAgentConversation.fileName).path))
    }

    func testCardAnswerPartsAccumulateButLaterEvidenceInvalidatesThem() async throws {
        for continuesWithEvidence in [false, true] {
            let (directory, keys, http) = try fixture()
            try keys.save("key", account: OpenRouterLLMKeyStore.account)
            var step = 0
            StubURLProtocol.handler = { _ in
                step += 1
                if step <= 2 {
                    return self.serve(self.router(["role": "assistant", "content": step == 1 ? "First price." : "Second price.", "tool_calls": [
                        ["id": "card-\(step)", "type": "function", "function": ["name": "show_actions", "arguments": "{\"items\":[{\"type\":\"path\",\"path\":\"/tmp/price\"}]}"]]
                    ]], finish: "tool_calls"))
                }
                if step == 3, continuesWithEvidence {
                    return self.serve(self.router(["role": "assistant", "content": "Checking a newer price.", "tool_calls": [
                        ["id": "read", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"missing.txt\"}"]]
                    ]], finish: "tool_calls"))
                }
                return self.serve(self.router(["role": "assistant", "content": ""]))
            }
            let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
            var final: String?
            for await event in provider.run(prompt: "price", resumeSessionID: nil, options: .init(model: "model")) {
                if case .finalAnswer(let text) = event { final = text }
            }
            XCTAssertEqual(final, continuesWithEvidence ? "" : "First price.\n\nSecond price.")
        }
    }

    func testAnthropicToolResultPreservesThinkingSignatureAndImage() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "anthropic-key")
            return self.serve(["stop_reason": "tool_use", "content": [
                ["type": "thinking", "thinking": "reasoning", "signature": "signed"],
                ["type": "tool_use", "id": "tool1", "name": "capture_screen", "input": [:]]
            ]])
        }
        var model = NativeAgentModel(options: .init(model: "exact-anthropic", openCodeProvider: .anthropic), key: "anthropic-key", system: "system", history: [], prompt: "screen", http: http, usageSink: { _ in })
        let (_, calls) = try await model.next(tools: NativeAgentTools.definitions(allowActions: false))
        model.append(results: [(calls[0], .init(text: "Captured", image: "pixels", mimeType: "image/png"))])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: model.messages), as: UTF8.self)
        XCTAssertTrue(encoded.contains("signed")); XCTAssertTrue(encoded.contains("tool_use_id")); XCTAssertTrue(encoded.replacingOccurrences(of: "\\/", with: "/").contains("image/png"))
        XCTAssertEqual((model.messages.last?["content"] as? [[String: Any]])?.first?["tool_use_id"] as? String, "tool1")
    }

    func testAnthropicTurnRecordsTokenEstimateWhileOpenAIStaysUnpriced() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { request in
            if request.url?.host == "api.anthropic.com" {
                return self.serve(["stop_reason": "end_turn", "content": [["type": "text", "text": "done"]],
                                   "usage": ["input_tokens": 2000, "output_tokens": 100, "cache_read_input_tokens": 5000]])
            }
            return self.serve(["status": "completed", "usage": ["input_tokens": 2000, "output_tokens": 100],
                               "output": [["type": "message", "content": [["type": "output_text", "text": "done"]]]]])
        }
        var recorded: [AIUsageEvent] = []
        var anthropic = NativeAgentModel(options: .init(model: "claude-opus-5-5", openCodeProvider: .anthropic), key: "key", system: "system",
                                         history: [], prompt: "hi", http: http, usageSink: { recorded.append($0) })
        _ = try await anthropic.next(tools: [])
        var openAI = NativeAgentModel(options: .init(model: "gpt-model", openCodeProvider: .openAI), key: "key", system: "system",
                                      history: [], prompt: "hi", http: http, usageSink: { recorded.append($0) })
        _ = try await openAI.next(tools: [])
        XCTAssertEqual(recorded.map(\.context.account), [.anthropic, .openAI])
        // 2,000 × $4 + 5,000 × $0.20 + 100 × $20 per million tokens.
        XCTAssertEqual(try XCTUnwrap(recorded[0].amount), 0.011, accuracy: 1e-12)
        XCTAssertEqual(recorded[0].basis, .estimated)
        XCTAssertNil(recorded[1].amount)
        XCTAssertEqual(recorded[1].basis, .unavailable)
    }

    func testOpenRouterPreservesNativeReasoningAndToolPairing() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { _ in self.serve(self.router(["role": "assistant", "content": NSNull(),
            "reasoning_details": [["type": "reasoning.encrypted", "data": "opaque-state"]],
            "tool_calls": [["id": "id1", "type": "function", "function": ["name": "read_file", "arguments": "{\"path\":\"file\"}"]]]], finish: "tool_calls")) }
        var model = NativeAgentModel(options: .init(model: "vendor/model"), key: "key", system: "system", history: [], prompt: "read", http: http, usageSink: { _ in })
        let (_, calls) = try await model.next(tools: NativeAgentTools.definitions(allowActions: true))
        model.append(results: [(calls[0], .init(text: "result"))])
        XCTAssertEqual(model.messages.last?["tool_call_id"] as? String, "id1")
        XCTAssertNotNil(model.messages[1]["reasoning_details"])
    }

    func testOpenRouterContinuationUsesCanonicalCallsAndOneReasoningRepresentation() async throws {
        for objectArguments in [false, true] {
            let (_, _, http) = try fixture()
            let originalArguments = "{ \"query\" : \"weather\" }\n"
            let details: [[String: Any]] = [
                ["type": "reasoning.encrypted", "data": "opaque-one", "id": "r1", "format": "unknown"],
                ["type": "reasoning.encrypted", "data": "opaque-two", "id": "r2", "format": "unknown"]
            ]
            var step = 0
            StubURLProtocol.handler = { _ in
                step += 1
                if step == 1 { return self.serve(self.router(["role": "assistant", "content": NSNull(),
                    "refusal": NSNull(), "annotations": [], "response_only": "omit-me",
                    "reasoning": "duplicate-thoughts", "reasoning_content": "another-duplicate", "reasoning_details": details,
                    "tool_calls": [["index": 0, "id": "call-exact", "type": "function", "function": [
                        "name": "web_search", "arguments": objectArguments ? ["query": "weather"] as Any : originalArguments as Any]]]
                ], finish: "tool_calls")) }
                return self.serve(self.router(["role": "assistant", "content": "Answer."]))
            }
            var model = NativeAgentModel(options: .init(model: "qwen/qwen3.8-27b", openRouterProvider: "cerebras/fp16"),
                key: "key", system: "system", history: [], prompt: "weather", http: http, usageSink: { _ in })
            let tools = NativeAgentTools.definitions(allowActions: false)
            let (_, calls) = try await model.next(tools: tools)
            model.append(results: [(calls[0], .init(text: "Synthetic search result"))])
            _ = try await model.next(tools: tools)
            let first = try body(0), second = try body(1)
            XCTAssertEqual(second["model"] as? String, first["model"] as? String)
            XCTAssertEqual(second["provider"] as? NSDictionary, first["provider"] as? NSDictionary)
            XCTAssertEqual(second["tools"] as? NSArray, first["tools"] as? NSArray)
            let messages = try XCTUnwrap(second["messages"] as? [[String: Any]])
            let assistant = messages[2]
            XCTAssertEqual(Set(assistant.keys), ["role", "content", "tool_calls", "reasoning_details"])
            XCTAssertEqual(assistant["reasoning_details"] as? NSArray, details as NSArray)
            let wire = try XCTUnwrap((assistant["tool_calls"] as? [[String: Any]])?.first)
            XCTAssertNil(wire["index"])
            XCTAssertEqual(wire["id"] as? String, "call-exact")
            let function = try XCTUnwrap(wire["function"] as? [String: Any])
            let arguments = try XCTUnwrap(function["arguments"] as? String)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? NSDictionary, ["query": "weather"] as NSDictionary)
            if !objectArguments { XCTAssertEqual(arguments, originalArguments, "Preserve an already valid argument string value exactly") }
            XCTAssertEqual(messages[3]["role"] as? String, "tool")
            XCTAssertEqual(messages[3]["tool_call_id"] as? String, "call-exact")
        }
    }

    func testOpenRouterPlainReasoningAliasIsRetainedWithoutDetails() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { _ in self.serve(self.router(["role": "assistant", "content": "Answer", "reasoning_content": "plain-thinking"])) }
        var model = NativeAgentModel(options: .init(model: "model"), key: "key", system: "system", history: [], prompt: "question", http: http, usageSink: { _ in })
        _ = try await model.next(tools: [])
        XCTAssertEqual(model.messages.last?["reasoning"] as? String, "plain-thinking")
        XCTAssertNil(model.messages.last?["reasoning_content"])
    }

    func testOpenRouterErrorCategoriesNeverEchoMessagesOrUnknownMetadata() async throws {
        for category in ["invalid_prompt", "context_length_exceeded", "SYNTHETIC_PRIVATE_CONTENT"] {
            let (_, _, http) = try fixture()
            StubURLProtocol.handler = { _ in (400, [:], try! JSONSerialization.data(withJSONObject: ["error": [
                "message": "SYNTHETIC_PRIVATE_CONTENT", "metadata": ["error_type": category,
                    "provider_code": "SYNTHETIC_PRIVATE_CONTENT", "flagged_input": "SYNTHETIC_PRIVATE_CONTENT"]]])) }
            do {
                _ = try await http.json(URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!))
                XCTFail("Expected error")
            } catch {
                let text = error.localizedDescription
                XCTAssertFalse(text.contains("SYNTHETIC_PRIVATE_CONTENT"))
                if category == "invalid_prompt" { XCTAssertTrue(text.contains("invalid_prompt")) }
                else if category == "context_length_exceeded" { XCTAssertTrue(text.contains("context limit")) }
                else { XCTAssertEqual(text, "The service returned HTTP 400. Try again.") }
            }
        }
    }

    func testErrorBodyLimitDoesNotExposeRawContent() async throws {
        for oversized in [false, true] {
            let (_, _, http) = try fixture()
            StubURLProtocol.handler = { _ in (400, [:], try! JSONSerialization.data(withJSONObject: ["error": [
                "message": String(repeating: "SYNTHETIC_PRIVATE_CONTENT", count: oversized ? 2000 : 1),
                "metadata": ["error_type": "invalid_request", "provider_code": "SYNTHETIC_PRIVATE_CONTENT"]]])) }
            do {
                _ = try await http.json(URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!))
                XCTFail("Expected error")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_PRIVATE_CONTENT"))
                if oversized { XCTAssertEqual(error.localizedDescription, "The service returned HTTP 400. Try again.") }
                else { XCTAssertTrue(error.localizedDescription.contains("invalid_request")) }
            }
        }
    }

    func testOpenRouterHTTP200ErrorsAreRejectedAfterRecordingReportedCost() async throws {
        for insideChoice in [false, true] {
            let (_, _, http) = try fixture()
            let providerError: [String: Any] = ["code": 400, "message": "SYNTHETIC_PRIVATE_CONTENT", "metadata": ["error_type": "invalid_request"]]
            StubURLProtocol.handler = { _ in
                var response: [String: Any] = ["usage": ["cost": 0.007]]
                if insideChoice { response["choices"] = [["finish_reason": "error", "error": providerError, "message": ["role": "assistant", "content": "Partial output"]]] }
                else { response["error"] = providerError }
                return self.serve(response)
            }
            var usage: [AIUsageEvent] = []
            var model = NativeAgentModel(options: .init(model: "model"), key: "key", system: "system", history: [], prompt: "question", http: http, usageSink: { usage.append($0) })
            do { _ = try await model.next(tools: []); XCTFail("Expected provider error") }
            catch { XCTAssertTrue(error.localizedDescription.contains("invalid_request")); XCTAssertFalse(error.localizedDescription.contains("SYNTHETIC_PRIVATE_CONTENT")) }
            XCTAssertEqual(usage.count, 1)
            XCTAssertEqual(try XCTUnwrap(usage.first?.amount), 0.007, accuracy: 0.000000001)
            XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
            XCTAssertEqual(model.messages.count, 1, "A partial/error response must not enter the assistant history")
        }
    }

    func testWebSearchContinuationErrorIsNotRetriedOrPersisted() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("key", account: OpenRouterLLMKeyStore.account)
        try keys.save("search-key", account: TavilySearch.keychainAccount)
        var modelCalls = 0, searchCalls = 0
        StubURLProtocol.handler = { request in
            if request.url?.host == "api.tavily.com" {
                searchCalls += 1
                return self.serve(["results": [["url": "https://example.com", "title": "Fixture", "content": "Search result"]]])
            }
            modelCalls += 1
            if modelCalls == 1 { return self.serve(self.router(["role": "assistant", "content": NSNull(), "reasoning": "plain-thinking", "tool_calls": [
                ["id": "search", "type": "function", "function": ["name": "web_search", "arguments": "{\"query\":\"weather\"}"]]
            ]], finish: "tool_calls")) }
            return (400, [:], try! JSONSerialization.data(withJSONObject: ["error": ["message": "SYNTHETIC_PRIVATE_CONTENT", "metadata": ["error_type": "invalid_prompt"]]]))
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "weather", resumeSessionID: nil,
            options: .init(model: "qwen/qwen3.8-27b", openRouterProvider: "cerebras/fp16")) { events.append(event) }
        XCTAssertEqual(modelCalls, 2)
        XCTAssertEqual(searchCalls, 1)
        XCTAssertTrue(events.contains { if case .error(_, let text, _) = $0 { return text.contains("invalid_prompt") && !text.contains("SYNTHETIC_PRIVATE_CONTENT") }; return false })
        XCTAssertFalse(events.contains(.done(sources: [])))
        XCTAssertNil(provider.lastSessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(NativeAgentConversation.fileName).path))
    }

    func testDisabledActionsAreEnforcedEvenWhenModelRequestsHiddenTool() async throws {
        let (directory, keys, _) = try fixture()
        let tools = NativeAgentTools(directory: directory, allowActions: false, keys: keys)
        let result = await tools.execute(.init(id: "1", name: "write_file", arguments: ["path": "forbidden.txt", "content": "bad"]))
        XCTAssertTrue(result.text.contains("unavailable"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden.txt").path))
        let command = await tools.execute(.init(id: "2", name: "run_command", arguments: ["command": "touch forbidden.txt"]))
        XCTAssertTrue(command.text.contains("unavailable"))
    }

    func testTavilySendsOnlyQueryWithItsOwnKeyAndBoundsResults() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.tavily.com/search")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tavily-secret")
            return self.serve(["results": (0..<8).map { ["url": "https://example.com/\($0)", "title": "Title", "content": String(repeating: "a", count: 5000)] }])
        }
        let result = try await TavilySearch(http: http).search(query: "current weather", key: "tavily-secret")
        let sent = try body(0)
        XCTAssertEqual(sent["query"] as? String, "current weather")
        XCTAssertEqual(sent["search_depth"] as? String, "basic")
        XCTAssertEqual(sent["include_raw_content"] as? Bool, false)
        XCTAssertNil(sent["messages"]); XCTAssertNil(sent["api_key"])
        let results = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])?["results"] as? [[String: String]])
        XCTAssertEqual(results.count, 5); XCTAssertEqual(results[0]["content"]?.count, 3000)
    }

    func testTavilyValidatesWithoutPaidSearchAndFailedReplacementPreservesKey() async throws {
        let (_, keys, http) = try fixture()
        try keys.save("old-key", account: TavilySearch.keychainAccount)
        let settings = TavilySettings(keys: keys, search: .init(http: http))
        settings.draftKey = "bad-key"
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/usage")
            return (401, [:], Data("private provider response".utf8))
        }
        await settings.save()
        XCTAssertEqual(keys.read(account: TavilySearch.keychainAccount), "old-key")
        XCTAssertTrue(settings.configured)
        XCTAssertTrue(settings.messageIsError)
        XCTAssertTrue(settings.message?.contains("Check the key and connection") == true)
        settings.draftKey = "retry-key"
        XCTAssertNil(settings.message, "Editing the replacement clears its old validation error")
        XCTAssertFalse(settings.messageIsError)
        await settings.save()
        XCTAssertNotNil(settings.message)
        settings.clearDraft()
        XCTAssertTrue(settings.draftKey.isEmpty)
        XCTAssertNil(settings.message, "Leaving Settings must clear the notice with its draft")
        XCTAssertEqual(keys.read(account: TavilySearch.keychainAccount), "old-key")
        StubURLProtocol.handler = { _ in self.serve(["key": ["usage": 1]]) }
        settings.draftKey = "new-key"
        await settings.save()
        XCTAssertEqual(keys.read(account: TavilySearch.keychainAccount), "new-key")
        XCTAssertTrue(settings.draftKey.isEmpty)
        XCTAssertFalse(settings.messageIsError)
    }

    func testMissingKeyAndSearchKeyAreReportedWithoutNetwork() async throws {
        let (directory, keys, http) = try fixture()
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var events: [AgentSSEEvent] = []
        for await event in provider.run(prompt: "hi", resumeSessionID: nil, options: .init(model: "model")) { events.append(event) }
        XCTAssertTrue(events.contains { if case .error = $0 { return true }; return false })
        let tools = NativeAgentTools(directory: directory, allowActions: true, keys: keys, tavily: .init(http: http))
        let result = await tools.execute(.init(id: "1", name: "web_search", arguments: ["query": "news"]))
        XCTAssertTrue(result.text.contains("Connect Tavily")); XCTAssertTrue(StubURLProtocol.capturedRequests.isEmpty)
    }

    func testHTTPFailuresDoNotEchoProviderBodiesAndOversizedResponsesFail() async throws {
        let (_, _, http) = try fixture()
        StubURLProtocol.handler = { _ in (403, [:], Data("secret-request-content".utf8)) }
        let request = URLRequest(url: URL(string: "https://example.com")!)
        do { _ = try await http.json(request); XCTFail("Expected failure") }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret-request-content")) }
        StubURLProtocol.handler = { _ in (200, [:], Data(repeating: 65, count: 200)) }
        do { _ = try await http.json(request, limit: 100); XCTFail("Expected bounded response") }
        catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
    }

    func testConversationExpiresAndNeverCrossesProviderOrModel() throws {
        let (directory, _, _) = try fixture()
        let now = Date()
        var conversation = NativeAgentConversation.load(directory: directory, resumeID: nil, route: "route1", now: now)
        for i in 0..<12 { try conversation.append(user: "ask \(i)", assistant: "answer", directory: directory, now: now) }
        XCTAssertEqual(conversation.pairs.count, 6)
        XCTAssertEqual(NativeAgentConversation.load(directory: directory, resumeID: conversation.id, route: "route1", now: now).pairs.count, 6)
        XCTAssertTrue(NativeAgentConversation.load(directory: directory, resumeID: conversation.id, route: "route2", now: now).pairs.isEmpty)
        XCTAssertTrue(NativeAgentConversation.load(directory: directory, resumeID: conversation.id, route: "route1", now: now.addingTimeInterval(901)).pairs.isEmpty)
        XCTAssertTrue(NativeAgentConversation.load(directory: directory, resumeID: nil, route: "route1", now: now).pairs.isEmpty)
    }

    func testOversizedTurnRetainsBoundedLatestQuestionAndAnswer() throws {
        let (directory, _, _) = try fixture()
        var conversation = NativeAgentConversation.load(directory: directory, resumeID: nil, route: "route")
        try conversation.append(user: "Older topic", assistant: "Older answer", directory: directory)
        let question = "User request:\nА сколько это в долларах?"
        let user = "Selected text:\n" + String(repeating: "evidence ", count: 3000) + "\n" + question
        let answer = "256 ГБ: 8 499 AED\n" + String(repeating: "detail ", count: 3000) + "\n512 ГБ: 9 349 AED"
        try conversation.append(user: user, assistant: answer, directory: directory)
        let restored = NativeAgentConversation.load(directory: directory, resumeID: conversation.id, route: "route")
        XCTAssertEqual(restored.pairs.count, 2, "Shorten before eviction so earlier small exchanges can remain")
        let pair = try XCTUnwrap(restored.pairs.last)
        XCTAssertLessThanOrEqual(pair.user.count + pair.assistant.count, NativeAgentConversation.maximumCharacters)
        XCTAssertTrue(pair.user.hasPrefix("Selected text:"))
        XCTAssertTrue(pair.user.hasSuffix(question))
        XCTAssertTrue(pair.assistant.hasPrefix("256 ГБ: 8 499 AED"))
        XCTAssertTrue(pair.assistant.hasSuffix("512 ГБ: 9 349 AED"))
        XCTAssertFalse(pair.user.contains(String(repeating: "evidence ", count: 3000)))
        XCTAssertTrue(NativeAgentConversation.load(directory: directory, resumeID: restored.id, route: "different").pairs.isEmpty)
        try conversation.append(user: "А 512 ГБ?", assistant: "Примерно $2 546.", directory: directory)
        let continued = NativeAgentConversation.load(directory: directory, resumeID: conversation.id, route: "route")
        XCTAssertEqual(continued.pairs.count, 3)
        XCTAssertTrue(continued.pairs.contains { $0.assistant.hasPrefix("256 ГБ: 8 499 AED") })
        XCTAssertLessThanOrEqual(continued.pairs.reduce(0) { $0 + $1.user.count + $1.assistant.count }, NativeAgentConversation.maximumCharacters)
    }

    func testCopyCardPayloadStaysOutOfSupplementaryConversationMemory() async throws {
        for finalText in ["", "Here is the example."] {
            let (directory, keys, http) = try fixture()
            try keys.save("key", account: OpenRouterLLMKeyStore.account)
            var step = 0
            StubURLProtocol.handler = { _ in
                step += 1
                if step == 1 { return self.serve(self.router(["role": "assistant", "content": NSNull(), "tool_calls": [
                    ["id": "copy", "type": "function", "function": ["name": "show_actions", "arguments": "{\"items\":[{\"type\":\"copy\",\"text\":\"SYNTHETIC_COPY_PAYLOAD\",\"description\":\"Code example\"},{\"type\":\"copy\",\"text\":\"ANOTHER_COPY_PAYLOAD\"}]}"]]
                ]], finish: "tool_calls")) }
                return self.serve(self.router(["role": "assistant", "content": finalText]))
            }
            let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
            var items: [ActionItem] = []
            for await event in provider.run(prompt: "Prepare a copyable example", resumeSessionID: nil, options: .init(model: "model")) {
                if case .blockComplete(.usefulActions(let block)) = event { items = block.items }
            }
            XCTAssertEqual(items.first?.insertText, "SYNTHETIC_COPY_PAYLOAD")
            let saved = try String(contentsOf: directory.appendingPathComponent(NativeAgentConversation.fileName), encoding: .utf8)
            XCTAssertFalse(saved.contains("SYNTHETIC_COPY_PAYLOAD"))
            XCTAssertFalse(saved.contains("ANOTHER_COPY_PAYLOAD"))
            XCTAssertTrue(saved.contains("Code example"))
            XCTAssertTrue(saved.contains("Copyable text"))
        }
    }

    func testShellUsesWorkspaceAndCapsOutput() async throws {
        let (directory, _, _) = try fixture()
        let result = await NativeAgentCommand().run(command: "pwd; /usr/bin/yes x | /usr/bin/head -c 40000", directory: directory, helper: nil)
        XCTAssertTrue(result.contains(directory.path)); XCTAssertTrue(result.contains("Output shortened"))
        XCTAssertLessThan(result.utf8.count, 33_000)
        XCTAssertTrue(CaseBuiltInAgentProcesses.shared.pids.isEmpty)
    }

    func testShellTimeoutKillsStubbornProcessGroupAndReleasesCaseIdentity() async throws {
        let (directory, _, _) = try fixture()
        let start = ContinuousClock.now
        let result = await NativeAgentCommand().run(command: "trap '' TERM; while :; do :; done", directory: directory, helper: nil, timeout: .milliseconds(100))
        XCTAssertTrue(result.contains("stopped")); XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        XCTAssertTrue(CaseBuiltInAgentProcesses.shared.pids.isEmpty)
    }

    func testShellCancellationStopsBeforeLateWrite() async throws {
        let (directory, _, _) = try fixture()
        let task = Task { await NativeAgentCommand().run(command: "sleep 1; touch late-file", directory: directory, helper: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.contains("stopped"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("late-file").path))
    }

    func testCancellationKillsStubbornDescendantAfterShellExits() async throws {
        let (directory, _, _) = try fixture()
        let task = Task { await NativeAgentCommand().run(
            command: "/bin/sh -c 'trap \"\" TERM; echo $$ > stubborn-pid; while :; do :; done' & wait",
            directory: directory, helper: nil) }
        let pidFile = directory.appendingPathComponent("stubborn-pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        task.cancel()
        _ = await task.value
        // A reparented killed child may briefly remain as a zombie, so check
        // that it cannot keep running by observing no continued CPU activity.
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "Cancellation must stop descendants even when their parent exits first")
    }


    private func detachedCommandFixture(_ directory: URL) throws -> (URL, URL) {
        let source = directory.appendingPathComponent("detached.c")
        let binary = directory.appendingPathComponent("detached-job").resolvingSymlinksInPath()
        let ready = directory.appendingPathComponent("detached-pid")
        try Data(#"""
        #include <unistd.h>
        #include <stdio.h>
        #include <stdlib.h>
        int main(int argc, char **argv) {
            pid_t child = fork();
            if (child < 0) return 2;
            if (child > 0) {
                for (int i=0; i<200 && access(argv[1], F_OK)!=0; i++) usleep(5000);
                if (argc > 2) usleep(500000);
                return 0;
            }
            if (setsid() < 0) _exit(3);
            FILE *file = fopen(argv[1], "w");
            if (!file) _exit(4);
            fprintf(file, "%d", getpid()); fclose(file);
            sleep(3);
            _exit(0);
        }
        """#.utf8).write(to: source)
        let compiler = Process()
        let errors = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [source.path, "-o", binary.path]
        compiler.standardError = errors
        try compiler.run(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        return (binary, ready)
    }

    private func cleanDetachedFixture(_ binary: URL, ready: URL) {
        guard let raw = try? String(contentsOf: ready, encoding: .utf8), let pid = Int32(raw),
              let process = CaseSystemProcessInspector().info(pid: pid),
              URL(fileURLWithPath: process.executablePath).resolvingSymlinksInPath() == binary else { return }
        kill(pid, SIGKILL)
    }

    func testDetachedOutputCannotKeepCommandWaitingAfterLeaderExit() async throws {
        let (directory, _, _) = try fixture()
        let (binary, ready) = try detachedCommandFixture(directory)
        defer { cleanDetachedFixture(binary, ready: ready) }
        let started = ContinuousClock.now
        let result = await NativeAgentCommand().run(command: "printf 'before\\n'; '\(binary.path)' '\(ready.path)'; printf 'leader-done\\n'", directory: directory, helper: nil, timeout: .milliseconds(250))
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertTrue(result.hasPrefix("before\nleader-done\n"), "Preserve output even while a detached process holds the pipe open: \(result)")
        XCTAssertNotNil(result.range(of: "Detached child processes may still be running", options: .caseInsensitive), result)
        XCTAssertFalse(result.contains("[Exit 0]"), "An inherited open pipe is not a clean successful completion")
        XCTAssertTrue(CaseBuiltInAgentProcesses.shared.pids.isEmpty)
    }

    func testCancellationFinishesDespiteDetachedOutput() async throws {
        let (directory, _, _) = try fixture()
        let (binary, ready) = try detachedCommandFixture(directory)
        defer { cleanDetachedFixture(binary, ready: ready) }
        let command = "'\(binary.path)' '\(ready.path)' hold-parent"
        let task = Task { await NativeAgentCommand().run(command: command, directory: directory, helper: nil) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let started = ContinuousClock.now
        task.cancel()
        let result = await task.value
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertTrue(result.contains("stopped waiting"))
        XCTAssertTrue(result.contains("Detached"))
    }

    func testCommandsDoNotInheritUnrelatedAppFileDescriptors() async throws {
        let (directory, _, _) = try fixture()
        let file = directory.appendingPathComponent("owned-descriptor")
        try Data("fixture".utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_SETFD, 0)
        let command = "if [ -e /dev/fd/\(handle.fileDescriptor) ]; then printf inherited; else printf closed; fi"
        let result = await NativeAgentCommand().run(command: command, directory: directory, helper: nil)
        XCTAssertTrue(result.hasPrefix("closed"), result)
    }

    func testTerminatedShellIsNotReportedAsSuccessfulExit() async throws {
        let (directory, _, _) = try fixture()
        let result = await NativeAgentCommand().run(command: "kill -KILL $$", directory: directory, helper: nil)
        XCTAssertTrue(result.contains("Terminated by signal 9"))
        XCTAssertFalse(result.contains("[Exit 0]"))
    }

    func testMultipleActionCallsAccumulateAndActionOnlyHistoryHasContent() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("key", account: OpenRouterLLMKeyStore.account)
        var step = 0
        StubURLProtocol.handler = { _ in
            step += 1
            if step == 1 {
                let calls = ["/tmp/first", "/tmp/second"].enumerated().map { index, path -> [String: Any] in
                    let args = String(decoding: try! JSONSerialization.data(withJSONObject: ["items": [["type": "path", "path": path]]]), as: UTF8.self)
                    return ["id": "call\(index)", "type": "function", "function": ["name": "show_actions", "arguments": args]]
                }
                return self.serve(self.router(["role": "assistant", "content": NSNull(), "tool_calls": calls], finish: "tool_calls"))
            }
            return self.serve(self.router(["role": "assistant", "content": ""]))
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        var actionCount = 0
        for await event in provider.run(prompt: "return both folders", resumeSessionID: nil, options: .init(model: "model")) {
            if case .blockComplete(.usefulActions(let block)) = event { actionCount = block.items.count }
        }
        XCTAssertEqual(actionCount, 2)
        let history = NativeAgentConversation.load(directory: directory, resumeID: provider.lastSessionID, route: "openrouter/model/")
        XCTAssertEqual(history.pairs.last?.assistant, "- /tmp/first\n- /tmp/second")
        var model = NativeAgentModel(options: .init(model: "model", openCodeProvider: .anthropic), key: "key", system: "system", history: history.pairs, prompt: "continue", http: http, usageSink: { _ in })
        model.append(results: [(.init(id: "read", name: "read_file", arguments: [:]), .init(text: ""))])
        let result = try XCTUnwrap((model.messages.last?["content"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(result.first?["text"] as? String, "[Empty tool result]")
    }

    func testNativeMigrationPreservesDisconnectedStateAndModelPreferences() throws {
        let suite = "NativeMigration-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AgentProviderStore(defaults: defaults).activeProvider)
        defaults.set("opencode", forKey: "agent.activeProvider")
        defaults.set("vendor/model", forKey: "agent.opencode.model")
        XCTAssertEqual(AgentProviderStore(defaults: defaults).activeProvider, .native)
        XCTAssertEqual(defaults.string(forKey: "agent.activeProvider"), "opencode", "Keep the rollback app’s persisted provider ID")
        let connected = AgentProviderStore(defaults: defaults)
        connected.markConnected(.native)
        XCTAssertEqual(defaults.string(forKey: "agent.preferredProvider"), "opencode")
        XCTAssertEqual(AgentProviderStore(defaults: defaults).preferredProvider, .native)
        XCTAssertEqual(defaults.string(forKey: "agent.opencode.model"), "vendor/model")
        AgentProviderStore(defaults: defaults).disconnect()
        XCTAssertNil(AgentProviderStore(defaults: defaults).activeProvider)
    }
    func testSyntheticScreenshotIsReturnedAsMediaAndNeverWritten() async throws {
        let (directory, keys, _) = try fixture()
        var captures = 0
        let tools = NativeAgentTools(directory: directory, allowActions: false, keys: keys, capture: { _ in
            captures += 1
            return .success(.object(["image": .string("synthetic-base64"), "mimeType": .string("image/jpeg")]))
        }, helper: nil)
        let result = await tools.execute(.init(id: "s1", name: "capture_screen", arguments: [:]))
        XCTAssertEqual(captures, 1); XCTAssertEqual(result.image, "synthetic-base64")
        XCTAssertFalse(result.text.contains("synthetic-base64"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testReadAndSearchStayBoundedAndWritingEmptyContentIsSupported() async throws {
        let (directory, keys, _) = try fixture()
        let file = directory.appendingPathComponent("sample.txt")
        try Data(String(repeating: "a", count: 40_000).utf8).write(to: file)
        let tools = NativeAgentTools(directory: directory, allowActions: true, keys: keys, helper: nil)
        let result = await tools.execute(.init(id: "r", name: "read_file", arguments: ["path": "sample.txt"]))
        XCTAssertTrue(result.text.contains("continue at byte offset 32000")); XCTAssertLessThan(result.text.count, 32_100)
        let found = await tools.execute(.init(id: "f", name: "search_files", arguments: ["path": directory.path, "query": "sample"]))
        XCTAssertTrue(found.text.contains(file.path))
        let written = await tools.execute(.init(id: "w", name: "write_file", arguments: ["path": "sample.txt", "content": ""]))
        XCTAssertTrue(written.text.contains("Saved")); XCTAssertEqual(try Data(contentsOf: file).count, 0)
        let invalid = await tools.execute(.init(id: "x", name: "read_file", arguments: ["path": "/dev/zero"]))
        XCTAssertTrue(invalid.text.contains("regular text file"))
    }

    func testOffscreenAgentsSettings() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_NATIVE_AGENT_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_NATIVE_AGENT_RENDER_DIR for native Settings review images")
        }
        let (directory, _, _) = try fixture()
        let suite = "AgentRender-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let routing = AIRoutingStore(defaults: defaults)
        routing.setRoute(.init(account: .openRouter, model: "vendor/lightweight-model"), for: .agent)
        let settings = AgentSettingsStore(defaults: defaults, codexConfig: .init(), routing: routing)
        let store = AgentProviderStore(defaults: defaults)
        store.markConnected(.native)
        let model = AgentModeViewModel(store: store, probe: { _ in .connected(sessionID: nil) }, notify: { _ in })
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for connected in [false, true] {
            if connected { store.markConnected(.native) } else { store.disconnect() }
            for dark in [false, true] {
                for width in [560.0, 760.0] {
                    let view = AgentModeView(viewModel: model, settings: settings, store: store, agentEnabled: { true },
                                             onAgentToggle: { _ in }, openAPIAndModels: { _ in })
                        .background(MacSettingsTheme.bgContent)
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let size = NSSize(width: width, height: 940)
                    host.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: size.height),
                                          styleMask: .borderless, backing: .buffered, defer: true)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "agents-\(connected ? "connected" : "disconnected")-\(dark ? "dark" : "light")-\(Int(width)).png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name))
                    XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
                    window.close()
                    window.contentView = nil
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("AGENTS.md").path))
    }

}

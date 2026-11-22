import XCTest
@testable import Sidekey

/// The Agent on OpenAI. The live checks are paid (a few cents) and skipped unless
/// `WHYTAP_LIVE_OPENAI_KEY` holds an OpenAI key and `WHYTAP_LIVE_OPENAI_MODEL`
/// optionally names the model (default gpt-6.2-sol). The key stays in memory.
/// WHY: .project-docs/decisions/2026-11-22-openai-agent-probe-responses.md
@MainActor
extension NativeAgentWebSearchTests {
    private var liveKey: String? {
        ProcessInfo.processInfo.environment["WHYTAP_LIVE_OPENAI_KEY"].flatMap { $0.isEmpty ? nil : $0 }
    }
    private var liveModel: String { ProcessInfo.processInfo.environment["WHYTAP_LIVE_OPENAI_MODEL"] ?? "gpt-6.2-sol" }

    func testLiveOpenAIAgentProbePassesWhereChatCompletionsRefusesTools() async throws {
        try XCTSkipUnless(liveKey != nil, "Set WHYTAP_LIVE_OPENAI_KEY for this paid check")
        let key = try XCTUnwrap(liveKey)
        let route = ResolvedRoute(feature: .agent, account: .openAI, model: liveModel, apiKey: key, server: nil)
        let outcome = await ModelProbe(timeout: .seconds(60)).probe(route, use: .chatWithTools, catalog: nil)
        XCTAssertEqual(outcome, .passed, "\(liveModel): \(outcome)")
    }

    func testLiveOpenAIAgentAnswersWithBuiltInSearchAndSources() async throws {
        try XCTSkipUnless(liveKey != nil, "Set WHYTAP_LIVE_OPENAI_KEY for this paid check")
        let key = try XCTUnwrap(liveKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        try keys.save(key, account: ProviderAccount.openAIKeychainAccount)
        var usage: [AIUsageEvent] = []
        let provider = NativeAgentProvider(keys: keys, http: NativeAgentHTTP(), workspace: { directory },
                                           usageSink: { usage.append($0) })
        let events = await run(provider, "Какая погода сегодня в Москве? Ответь одной фразой.",
                               .init(model: liveModel, openCodeProvider: .openAI))
        let errors = events.compactMap { if case .error(let code, let message, _) = $0 { return "\(code): \(message)" }; return nil }
        XCTAssertEqual(errors, [])
        XCTAssertNotNil(finalText(events))
        XCTAssertTrue(events.contains { if case .toolExecuting("web_search", _) = $0 { return true }; return false },
                      "OpenAI's built-in search ran")
        XCTAssertFalse(finalText(events)?.unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) } ?? true,
                       "No internal citation marks in the answer")
        XCTAssertTrue(usage.allSatisfy { $0.amount == nil }, "OpenAI reports no cost; unknown is never 0")
        print("live answer:", finalText(events) ?? "-", "links:", links(events).count)
    }

    func testOpenAICitationMarksNeverReachTheAnswer() async throws {
        let (directory, keys, http) = try fixture()
        try keys.save("openai-key", account: ProviderAccount.openAIKeychainAccount)
        let marked = "Сейчас в Москве +1 °C и идёт небольшой снег \u{E200}cite\u{E202}turn138346forecast0\u{E201}."
        StubURLProtocol.handler = { _ in
            self.serve(["status": "completed", "output": [
                ["type": "web_search_call", "status": "completed", "action": ["type": "search", "query": "погода Москва",
                                                                             "sources": [["type": "api", "name": "oai-weather"]]]],
                ["type": "function_call", "call_id": "c", "name": "finish_answer", "arguments": self.arguments(self.final(marked))]]])
        }
        let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
        let events = await run(provider, "какая погода сегодня в Москве", .init(model: "gpt-6.2-sol", openCodeProvider: .openAI))
        XCTAssertEqual(finalText(events), "Сейчас в Москве +1 °C и идёт небольшой снег.")
        XCTAssertEqual(links(events), [], "An API source without a URL is no link card")
        XCTAssertEqual(NativeAgentFinalAnswer.withoutProviderCitationMarks("Plain text."), "Plain text.")
        XCTAssertEqual(NativeAgentFinalAnswer.withoutProviderCitationMarks("A \u{E200}cite\u{E202}turn0search0\u{E202}turn0news2\u{E201} and \u{E203}b."),
                       "A and \u{E203}b.", "Several references in one mark; other private glyphs stay")
    }

    /// The Search row names the Agent model it follows, so an Agent that kept
    /// Anthropic while the LLM row moved to OpenAI explains itself.
    func testSearchRowNamesTheAgentModelItFollows() {
        let anthropic = AgentSearchRow(options: .init(model: "claude-opus-5-5", openCodeProvider: .anthropic), tavilyConnected: false)
        XCTAssertEqual(anthropic.current.label, "Anthropic · built-in")
        XCTAssertEqual(anthropic.agentLine, "Follows the Agent model: Anthropic · claude-opus-5-5.")
        let sol = AgentSearchRow(options: .init(model: "gpt-6.2-sol", openCodeProvider: .openAI), tavilyConnected: false)
        XCTAssertEqual(sol.current.label, "OpenAI · built-in")
        XCTAssertEqual(sol.agentLine, "Follows the Agent model: OpenAI · gpt-6.2-sol.")
        XCTAssertNil(AgentSearchRow(options: .init(), tavilyConnected: false).agentLine)
    }

    // MARK: - Builder #447: only the exact OpenAI citation markup is removed

    private func finalAnswer(_ answer: String, insert: String = "", copy: String? = nil) throws -> NativeAgentFinalAnswer {
        let actions = copy.map { [["type": "copy", "text": $0, "description": "Fixture"]] } ?? []
        return try NativeAgentFinalAnswer(arguments: [
            "status": "answered", "answer": answer, "insert_text": insert, "sources": [[String: Any]](), "actions": actions,
        ])
    }

    private func copyText(_ item: ActionItem?) -> String? {
        guard case let .copy(text, _) = item else { return nil }
        return text
    }

    func testOnlyOpenAICitationMarkupIsRemovedEverywhereElseTextStaysLiteral() throws {
        let mark = "\u{E200}cite\u{E202}turn0search0\u{E201}"
        XCTAssertEqual(try finalAnswer("Verified \(mark).").answer, "Verified.")
        let glyphs = "Private glyphs: \u{E000}\u{F8FF}."
        XCTAssertEqual(try finalAnswer(glyphs).answer, glyphs)
        let literalSpan = "Line 1 \u{E200}literal text\nline 2\u{E201} remains."
        XCTAssertEqual(try finalAnswer(literalSpan).answer, literalSpan)
        XCTAssertEqual(try finalAnswer("Text \u{E200} literal words, then cite \(mark).").answer, "Text \u{E200} literal words, then cite.")
        let punctuation = "A \u{E234} B\n\nDo not join : spacing."
        XCTAssertEqual(try finalAnswer(punctuation).answer, punctuation)

        let action = try finalAnswer("There is a result.", insert: "Paste \(mark).", copy: "Copy \(mark).")
        XCTAssertEqual(copyText(action.insert), "Paste.", "Insert payload")
        XCTAssertEqual(copyText(action.actions.items.last), "Copy.", "Copy payload")
        let literalInsert = try finalAnswer("Here.", insert: "printf '%s' '\u{E234}' \u{E200}x\u{E201}")
        XCTAssertEqual(copyText(literalInsert.insert), "printf '%s' '\u{E234}' \u{E200}x\u{E201}", "Text the user asked for stays literal")

        let path = "/tmp/fixture/part-\u{E234}.txt"
        let pathFinal = try finalAnswer("Open `\(path)`.")
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: pathFinal.visibleText, existing: pathFinal.actions)?.items.first?.insertText, path)
        let command = "printf '%s' '\u{E234}'"
        let commandFinal = try finalAnswer("Run this:\n\n```sh\n\(command)\n```")
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: commandFinal.visibleText, existing: commandFinal.actions)?.items.first?.insertText, command)
        let rawLink = "https://example.test/part-\u{E234}"
        let linkFinal = try finalAnswer("Open [the fixture](\(rawLink)).")
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: linkFinal.visibleText, existing: linkFinal.actions)?.items.first?.insertText,
                       URL(string: rawLink)?.absoluteString)
    }

    // MARK: - Builder #448: literal data keeps the same bytes; other providers untouched

    func testCitationBytesInLiteralDataStayAndACitationOnlyCopyCardIsDropped() throws {
        let mark = "\u{E200}cite\u{E202}turn0search0\u{E201}"
        let literalCommand = "printf '%s' 'raw\(mark)'"
        let literalPayload = try finalAnswer("Here is the exact text.", insert: literalCommand, copy: literalCommand)
        XCTAssertEqual(copyText(literalPayload.insert), literalCommand, "explicit Insert")
        XCTAssertTrue(literalPayload.actions.items.contains { copyText($0) == literalCommand }, "explicit Copy")
        let codeFinal = try finalAnswer("Run this:\n\n```sh\n\(literalCommand)\n```")
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: codeFinal.visibleText, existing: codeFinal.actions)?.items.first?.insertText,
                       literalCommand, "shell fence")
        let fencedProse = try finalAnswer("Example:\n\n```text\nSee \(mark).\n```")
        XCTAssertTrue(fencedProse.answer.contains(mark), "nothing inside a code fence is changed")
        let literalPath = "/tmp/fixture/part-\(mark).txt"
        let pathFinal = try finalAnswer("Open `\(literalPath)`.")
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: pathFinal.visibleText, existing: pathFinal.actions)?.items.first?.insertText,
                       literalPath, "file name")
        let literalLink = "https://example.test/part-\(mark)"
        let linkFinal = try finalAnswer("Open [the fixture](\(literalLink)).")
        XCTAssertEqual(NativeAgentAnswerArtifacts.collect(from: linkFinal.visibleText, existing: linkFinal.actions)?.items.first?.insertText,
                       URL(string: literalLink)?.absoluteString, "URL")
        let privateSequence = "Literal \u{E200}cite\u{E202}project-name\u{E201} stays."
        XCTAssertEqual(try finalAnswer(privateSequence).answer, privateSequence, "not an OpenAI reference")

        let citationOnly = try finalAnswer("Useful verified answer.", copy: mark)
        XCTAssertEqual(citationOnly.answer, "Useful verified answer.")
        XCTAssertFalse(citationOnly.actions.items.contains { copyText($0) != nil }, "the empty copy card is dropped")
        XCTAssertThrowsError(try finalAnswer("Answer.", copy: "   "), "a genuinely empty card is still invalid")

        // Other providers' output is never cleaned.
        let anthropic = try NativeAgentFinalAnswer(arguments: [
            "status": "answered", "answer": "Verified \(mark).", "insert_text": "", "sources": [[String: Any]](), "actions": [[String: Any]](),
        ], openAICitations: false)
        XCTAssertEqual(anthropic.answer, "Verified \(mark).")
    }

    func testOnlyOpenAIRoutesCleanCitationMarks() async throws {
        let mark = "\u{E200}cite\u{E202}turn0search0\u{E201}"
        for (route, model, cleaned) in [(OpenCodeModelProvider.anthropic, "claude-opus-5-5", false),
                                        (.openRouter, "openai/gpt-6.2-sol", true), (.openRouter, "vendor/model", false)] {
            let (directory, keys, http) = try fixture()
            try keys.save("router-key", account: OpenRouterLLMKeyStore.account)
            try keys.save("anthropic-key", account: ProviderAccount.anthropicKeychainAccount)
            let answer = final("Verified \(mark).")
            StubURLProtocol.handler = { _ in
                route == .anthropic
                    ? self.serve(["stop_reason": "tool_use", "content": [["type": "tool_use", "id": "f", "name": "finish_answer", "input": answer]]])
                    : self.serve(["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
                        "tool_calls": [["id": "f", "type": "function", "function": ["name": "finish_answer", "arguments": self.arguments(answer)]]]]]]])
            }
            let provider = NativeAgentProvider(keys: keys, http: http, workspace: { directory }, usageSink: { _ in })
            let events = await run(provider, "q", .init(model: model, openCodeProvider: route))
            XCTAssertEqual(finalText(events), cleaned ? "Verified." : "Verified \(mark).", "\(route) \(model)")
        }
    }
}

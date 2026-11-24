import XCTest
@testable import Sidekey

/// Drop Smart on the direct Anthropic and OpenAI routes asks for the least
/// reasoning the chosen model accepts. Each test dictates through the real
/// `PostProcessor` and client against a stubbed provider.
/// WHY: .project-docs/decisions/2026-11-24-smart-minimal-reasoning.md
@MainActor
final class SmartMinimalReasoningTests: XCTestCase {
    private var session: URLSession!
    private var routing: AIRoutingStore!
    private var keys: ProviderKeyStore!
    private var checks: ModelCheckStore!
    private var refusals: SmartReasoningRefusals!
    /// Every request body the provider received, in order.
    private var bodies: [[String: Any]] = []
    private var urls: [String] = []

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let box = InMemoryTokenStore.Box()
        routing = AIRoutingStore(defaults: defaults)
        keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        checks = ModelCheckStore(defaults: defaults)
        refusals = SmartReasoningRefusals()
        bodies = []
        urls = []
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    private static let anthropicReply = #"{"content":[{"type":"text","text":"Скинь мне, пожалуйста, ссылку на документ."}],"stop_reason":"end_turn","usage":{"output_tokens":14,"output_tokens_details":{"thinking_tokens":0}}}"#
    private static let openAIReply = #"{"usage":{"completion_tokens":14,"completion_tokens_details":{"reasoning_tokens":0}},"choices":[{"message":{"content":"Скинь мне, пожалуйста, ссылку на документ."}}]}"#
    private static let dictation = "Ну, э-э, короче, скинь мне, пожалуйста, ссылку на документ."
    private static let cleaned = "Скинь мне, пожалуйста, ссылку на документ."

    private func route(_ account: ProviderAccount, _ model: String) throws {
        if let keychain = account.keychainAccount(in: routing) { try keys.save("test-key", account: keychain) }
        routing.setRoute(FeatureRoute(account: account, model: model), for: .dropSmartCleanup)
    }

    private func smart(profile: OpenRouterLLMClient.Profile = .smart) -> PostProcessor {
        PostProcessor(
            llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys),
            openRouterClient: OpenRouterLLMClient(session: session, profile: profile,
                                                  reasoningRefusals: refusals, usageSink: { _ in }),
            checks: checks
        )
    }

    /// The stub records each request and answers with `reply(body, index)`.
    private func provider(_ reply: @escaping ([String: Any], Int) throws -> (Int, String)) {
        StubURLProtocol.handler = { [unowned self] request in
            let raw = StubURLProtocol.capturedBodies.last ?? Data()
            let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
            bodies.append(json)
            urls.append(request.url?.absoluteString ?? "")
            let (status, body) = try reply(json, bodies.count - 1)
            return (status, [:], Data(body.utf8))
        }
    }

    private func dictate(_ processor: PostProcessor, _ text: String = SmartMinimalReasoningTests.dictation) async throws -> PostProcessor.Output {
        try await processor.processOutput(text, targetApp: "Telegram", language: "ru", transcriptionMode: "smart")
    }

    // MARK: Anthropic

    /// The maintainer's own route: Smart on Claude Sonnet 5.5 through Anthropic.
    func testSmartOnSonnet55AsksLowEffortWithoutUpFrontThinking() async throws {
        try route(.anthropic, "claude-sonnet-5-5")
        provider { _, _ in (200, Self.anthropicReply) }

        let output = try await dictate(smart())

        XCTAssertEqual(output.text, Self.cleaned)
        XCTAssertTrue(output.usedEditor)
        XCTAssertEqual(urls, ["https://api.anthropic.com/v1/messages"])
        let body = try XCTUnwrap(bodies.first)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5", "The chosen model is never replaced")
        XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"])
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "between_tools"],
                       "Sonnet 5.5 refuses `disabled`; `between_tools` takes no other field")
        XCTAssertEqual(body["system"] as? String, PostProcessor.systemPrompt, "The editor prompt is unchanged")
        XCTAssertEqual(body["max_tokens"] as? Int, 8192)
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["reasoning_effort"])
    }

    /// Fable cannot turn thinking off: low effort only, and the reply's
    /// thinking block is never pasted. The pass verdict still means "insert
    /// the dictation as it is".
    func testSmartOnFableAsksLowEffortOnlyAndKeepsThePassVerdict() async throws {
        try route(.anthropic, "claude-fable-5-2")
        provider { _, _ in
            (200, #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"<WHYTAP_PASS>"}],"stop_reason":"end_turn"}"#)
        }

        let output = try await dictate(smart(), "Давай созвонимся завтра после обеда.")

        XCTAssertEqual(output.text, "Давай созвонимся завтра после обеда.")
        XCTAssertFalse(output.usedEditor)
        let body = try XCTUnwrap(bodies.first)
        XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"])
        XCTAssertNil(body["thinking"], "Thinking is always on: any explicit setting but adaptive is refused")
    }

    func testAnthropicFieldsFollowWhatEachModelAccepts() {
        typealias Fields = SmartDirectReasoning.Anthropic
        let expected: [(String, Fields?)] = [
            ("claude-sonnet-5-5", Fields(effort: "low", thinking: "between_tools")),
            ("claude-sonnet-5-5-20261001", Fields(effort: "low", thinking: "between_tools")),
            ("claude-haiku-5-5", Fields(effort: "low", thinking: "disabled")),
            ("claude-sonnet-5", Fields(effort: "low", thinking: "disabled")),
            ("claude-sonnet-5-20260601", Fields(effort: "low", thinking: "disabled")),
            // Thinking cannot be turned off.
            ("claude-fable-5-2", Fields(effort: "low", thinking: nil)),
            ("claude-mythos-5-2", Fields(effort: "low", thinking: nil)),
            ("claude-opus-5-5", Fields(effort: "low", thinking: nil)),
            // Disabled thinking may leak thinking tags into the text.
            ("claude-opus-5", Fields(effort: "low", thinking: nil)),
            // No thinking unless asked.
            ("claude-opus-4-8", Fields(effort: "low", thinking: nil)),
            ("claude-sonnet-4-6", Fields(effort: "low", thinking: nil)),
            ("claude-opus-4-5-20251101", Fields(effort: "low", thinking: nil)),
            // Effort is refused; they do not think unless asked.
            ("claude-sonnet-4-5", nil),
            ("claude-haiku-4-5-20251001", nil),
            ("some-future-model", nil),
        ]
        for (model, fields) in expected {
            XCTAssertEqual(SmartDirectReasoning.anthropic(model: model), fields, model)
        }
    }

    /// A model without the parameter is sent exactly what it got before.
    func testSmartOnAnOlderClaudeSendsNoReasoningField() async throws {
        try route(.anthropic, "claude-haiku-4-5")
        provider { _, _ in (200, Self.anthropicReply) }

        let output = try await dictate(smart())

        XCTAssertEqual(output.text, Self.cleaned)
        let body = try XCTUnwrap(bodies.first)
        XCTAssertEqual(Set(body.keys), ["model", "max_tokens", "system", "messages"])
    }

    // MARK: OpenAI

    func testSmartOnOpenAISendsTheLowestEffortTheModelAccepts() async throws {
        for (model, effort) in [("gpt-5.5", "none"), ("gpt-6-luna", "none"), ("gpt-5.4-mini-2026-03-17", "none"),
                                ("gpt-5-mini", "minimal"), ("gpt-5-2025-08-07", "minimal"),
                                ("gpt-6.2-sol", "low"), ("o3", "low"), ("gpt-6.3-nova", "low")] {
            bodies = []; urls = []
            try route(.openAI, model)
            provider { _, _ in (200, Self.openAIReply) }

            let output = try await dictate(smart())

            XCTAssertEqual(output.text, Self.cleaned, model)
            XCTAssertEqual(urls, ["https://api.openai.com/v1/chat/completions"], model)
            let body = try XCTUnwrap(bodies.first)
            XCTAssertEqual(body["model"] as? String, model)
            XCTAssertEqual(body["reasoning_effort"] as? String, effort, model)
            XCTAssertNil(body["reasoning"], "OpenRouter's field never goes to OpenAI")
            XCTAssertNil(body["temperature"])
            XCTAssertNil(body["provider"])
            XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], PostProcessor.systemPrompt)
        }
    }

    /// GPT-4.1 and GPT-4o refuse the argument, chat snapshots and pro models
    /// may too, and a generation nobody has checked is unknown: none of them
    /// is sent it.
    func testSmartOnOpenAIModelsWithoutReasoningSendsNoField() async throws {
        for model in ["gpt-4.1", "gpt-4o-mini", "gpt-5-chat-latest", "gpt-5.5-pro", "o1-mini", "gpt-7-nova"] {
            bodies = []
            try route(.openAI, model)
            provider { _, _ in (200, Self.openAIReply) }

            let output = try await dictate(smart())

            XCTAssertEqual(output.text, Self.cleaned, model)
            XCTAssertEqual(bodies.count, 1, model)
            XCTAssertEqual(Set(bodies[0].keys), ["model", "messages", "stream"], model)
        }
    }

    // MARK: A model that refuses the field

    /// The table says a model takes the field and the provider says otherwise
    /// (a changed model, a stale table): the dictation still comes out
    /// cleaned, and later dictations are sent without the field at once.
    func testOpenAIRefusingTheFieldIsAskedAgainWithoutItAndRemembered() async throws {
        try route(.openAI, "gpt-5.5")
        provider { body, _ in
            body["reasoning_effort"] == nil
                ? (200, Self.openAIReply)
                : (400, #"{"error":{"message":"Unsupported value: 'reasoning_effort' does not support 'none' with this model."}}"#)
        }
        let processor = smart()

        let first = try await dictate(processor)
        XCTAssertEqual(first.text, Self.cleaned)
        XCTAssertEqual(bodies.map { $0["reasoning_effort"] as? String }, ["none", nil])
        XCTAssertEqual(bodies[1]["model"] as? String, "gpt-5.5", "The retry keeps the chosen model")
        XCTAssertNil(checks.refusedModel(for: .dropSmartCleanup), "The model works: no refusal badge")
        XCTAssertTrue(refusals.contains(.openAI, model: "gpt-5.5"))

        let second = try await dictate(processor)
        XCTAssertEqual(second.text, Self.cleaned)
        XCTAssertEqual(bodies.count, 3, "One request, without the field")
        XCTAssertNil(bodies[2]["reasoning_effort"])
    }

    func testAnthropicRefusingTheFieldsIsAskedAgainWithoutThemAndRemembered() async throws {
        try route(.anthropic, "claude-sonnet-5-5")
        provider { body, _ in
            body["thinking"] == nil && body["output_config"] == nil
                ? (200, Self.anthropicReply)
                : (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"\"thinking.type.between_tools\" is not supported for this model."}}"#)
        }
        let processor = smart()

        let first = try await dictate(processor)
        XCTAssertEqual(first.text, Self.cleaned)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(Set(bodies[1].keys), ["model", "max_tokens", "system", "messages"])

        _ = try await dictate(processor)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertNil(bodies[2]["thinking"])
        XCTAssertNil(bodies[2]["output_config"])
    }

    /// A proxy between the Mac and the provider answers the repeat with its
    /// own HTTP 200 page (or an empty reply): the dictation fails, and that
    /// proves nothing about the field. The next dictation still asks for
    /// minimal reasoning.
    func testAnInvalidAnswerToTheRepeatDoesNotMarkTheModel() async throws {
        let cases: [(ProviderAccount, String, OpenAICompatibleLLMEndpoint.TextAPI, String, String)] = [
            (.anthropic, "claude-sonnet-5-5", .anthropic, "thinking", Self.anthropicReply),
            (.openAI, "gpt-5.5", .openAI, "reasoning_effort", Self.openAIReply),
        ]
        let invalid = ["<html><body>502 Bad Gateway</body></html>",
                       #"{"content":[],"stop_reason":"end_turn","choices":[{"message":{"content":""}}]}"#]
        for (account, model, api, field, goodReply) in cases {
            for page in invalid {
                bodies = []
                try route(account, model)
                provider { body, _ in body[field] == nil ? (200, page) : (400, #"{"error":{"message":"refused"}}"#) }
                let processor = smart()
                do {
                    _ = try await dictate(processor)
                    XCTFail("Expected the invalid answer to fail the dictation")
                } catch let error as OpenRouterLLMError {
                    XCTAssertFalse(error.isModelRefusal, "\(model): \(error)")
                }
                XCTAssertEqual(bodies.count, 2, model)
                XCTAssertFalse(refusals.contains(api, model: model), "\(model): \(page.prefix(12))")

                bodies = []
                provider { _, _ in (200, goodReply) }
                let output = try await dictate(processor)
                XCTAssertEqual(output.text, Self.cleaned)
                XCTAssertEqual(bodies.count, 1)
                XCTAssertNotNil(bodies[0][field], "\(model) is still asked for minimal reasoning")
            }
        }
    }

    // MARK: Provider failures

    /// A request the provider rejects for another reason (too long an input)
    /// fails as before: one more attempt without the fields, then the error.
    func testAnthropicRejectingTheInputStillFailsAsBefore() async throws {
        try route(.anthropic, "claude-sonnet-5-5")
        provider { _, _ in (400, #"{"type":"error","error":{"type":"invalid_request_error","message":"prompt is too long"}}"#) }

        do {
            _ = try await dictate(smart())
            XCTFail("Expected the rejected input to reach the caller")
        } catch let error as OpenRouterLLMError {
            XCTAssertEqual(error, .inputRejected)
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNil(checks.refusedModel(for: .dropSmartCleanup))

        // The input was the problem, not the fields: the next dictation
        // still asks for minimal reasoning.
        XCTAssertFalse(refusals.contains(.anthropic, model: "claude-sonnet-5-5"))
        bodies = []
        provider { _, _ in (200, Self.anthropicReply) }
        _ = try await dictate(smart())
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies[0]["thinking"] as? [String: String], ["type": "between_tools"])
    }

    /// An outage, a bad key or a rate limit is not retried and changes nothing
    /// about what the next dictation sends.
    func testProviderOutageKeyAndRateLimitAreNotRetried() async throws {
        for (account, model, field) in [(ProviderAccount.anthropic, "claude-sonnet-5-5", "thinking"),
                                        (.openAI, "gpt-5.5", "reasoning_effort")] {
            for status in [401, 429, 500, 529] {
                bodies = []
                try route(account, model)
                provider { _, _ in (status, #"{"error":{"message":"unavailable"}}"#) }
                do {
                    _ = try await dictate(smart())
                    XCTFail("Expected HTTP \(status) to reach the caller")
                } catch let error as OpenRouterLLMError {
                    guard case .unexpectedStatus(let code, _) = error else { return XCTFail("\(error)") }
                    XCTAssertEqual(code, status)
                }
                XCTAssertEqual(bodies.count, 1, "\(model) HTTP \(status)")
                XCTAssertNotNil(bodies[0][field], "The next dictation still asks for minimal reasoning")
                XCTAssertFalse(refusals.contains(account == .anthropic ? .anthropic : .openAI, model: model))
            }
        }
    }

    func testAConnectionFailureReachesTheCallerAfterOneRequest() async throws {
        try route(.openAI, "gpt-5.5")
        StubURLProtocol.handler = { [unowned self] _ in
            bodies.append([:])
            throw URLError(.timedOut)
        }
        do {
            _ = try await dictate(smart())
            XCTFail("Expected the timeout to reach the caller")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(bodies.count, 1)
    }

    /// OpenAI refuses the model itself: the field is dropped, the model is
    /// still refused, and the row gets its refusal badge as before.
    func testOpenAIRefusingTheModelItselfIsStillRecordedAsARefusal() async throws {
        try route(.openAI, "gpt-5.5")
        provider { _, _ in (400, #"{"error":{"message":"The model does not exist or you do not have access to it."}}"#) }
        do {
            _ = try await dictate(smart())
            XCTFail("Expected the refusal to reach the caller")
        } catch let error as OpenRouterLLMError {
            XCTAssertTrue(error.isModelRefusal)
        }
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(checks.refusedModel(for: .dropSmartCleanup), "gpt-5.5")
        XCTAssertFalse(refusals.contains(.openAI, model: "gpt-5.5"), "The field was not the reason")
    }

    // MARK: Stored timing lines

    func testOnlyPublicCatalogNamesBecomeALoggedModel() {
        let anthropic = ["claude-sonnet-5-5": "claude-sonnet-5-5", "claude-haiku-4-5-20251001": "claude-haiku-4-5",
                         "claude-opus-4-5-20251101": "claude-opus-4-5", "claude-sonnet-5-20260601": "claude-sonnet-5",
                         "claude-opus-5-latest": "claude-opus-5", "Claude-Fable-5-2": "claude-fable-5-2"]
        for (saved, logged) in anthropic { XCTAssertEqual(CleanupDiagnosticModel.anthropic(saved), logged, saved) }
        let openAI = ["gpt-5.5": "gpt-5.5", "gpt-4o-mini": "gpt-4o-mini", "gpt-5.4-mini-2026-03-17": "gpt-5.4-mini",
                      "gpt-6.2-sol": "gpt-6.2-sol", "gpt-5-2025-08-07": "gpt-5", "o3": "o3"]
        for (saved, logged) in openAI { XCTAssertEqual(CleanupDiagnosticModel.openAI(saved), logged, saved) }
        // What is logged is always one of the fixed names, never saved text.
        for name in ["acme-private-claude", "claude-sonnet-5-5 for Ivan", "claude-acme-5", "my-claude-sonnet-5-5",
                     "claude-opus-5-acme", "claude-opus-99-12345678", "claude-sonnet-5-5-1234567", "claude-sonnet-5-5\n",
                     "ft:gpt-5.1:acme-corp:ivan-notes:abc123", "gpt-acme", "gpt-5.5-acme-internal", "gpt-99x-pro-1234-56-78",
                     "gpt-5.5-2026-0317", "gpt-5.5\n", "", "o3-acme"] {
            XCTAssertEqual(CleanupDiagnosticModel.anthropic(name), "other", name)
            XCTAssertEqual(CleanupDiagnosticModel.openAI(name), "other", name)
        }
        XCTAssertEqual(CleanupDiagnosticModel.openRouter("google/gemini-3.8-flash", listed: true), "google/gemini-3.8-flash")
        XCTAssertEqual(CleanupDiagnosticModel.openRouter("acme/private-alias", listed: false), "other")
        // Only OpenRouter's own generation IDs are a request ID.
        XCTAssertEqual(OpenRouterLLMClient.openRouterRequestID("gen-1763980000-AbC123"), "gen-1763980000-AbC123")
        for id in ["acme-secret", "gen-acme secret", "gen-" + String(repeating: "a", count: 90), nil] {
            XCTAssertEqual(OpenRouterLLMClient.openRouterRequestID(id), "unavailable")
        }
    }

    /// Every field of the lines the system log now keeps, captured where
    /// the client hands them to the log. A saved model name the catalogs do
    /// not know (a private alias, a fine-tuned model, a name on a user's own
    /// server) and a foreign reply ID never appear in them, on a successful
    /// and on a failed request, on direct Anthropic, direct OpenAI and
    /// OpenRouter; a catalog name appears as its fixed family name.
    func testStoredTimingLinesCarryNoUnverifiedModelName() async throws {
        let secret = "acme-secret-\(UUID().uuidString.prefix(8).lowercased())"
        let server = routing.addServer(name: "Local", baseURL: "http://127.0.0.1:11434/v1")
        let routes: [(ProviderAccount, String, String, String)] = [
            (.anthropic, secret, "anthropic", "other"),
            (.openAI, secret, "openai", "other"),
            (.openAI, "ft:gpt-5.1:\(secret):notes:abc", "openai", "other"),
            (.openRouter, "\(secret)/model", "openrouter", "other"),
            (.server(server.id), secret, "custom", "custom"),
            (.anthropic, "claude-sonnet-5-5-20261001", "anthropic", "claude-sonnet-5-5"),
            (.openAI, "gpt-5.5", "openai", "gpt-5.5"),
            (.openRouter, "google/gemini-3.8-flash", "openrouter", "google/gemini-3.8-flash"),
        ]
        for (account, model, provider, logged) in routes {
            for status in [200, 500] {
                var lines: [CleanupDiagnostics] = []
                try route(account, model)
                self.provider { [unowned self] body, _ in
                    if urls.last?.hasSuffix("/models") == true {
                        return (200, #"{"data":[{"id":"google/gemini-3.8-flash"}]}"#)
                    }
                    if status != 200 { return (status, #"{"error":{"message":"\#(secret)"}}"#) }
                    // The reply's own ID is not OpenRouter's: it is not logged either.
                    return (200, body["max_tokens"] == nil
                        ? Self.openAIReply.replacingOccurrences(of: #"{"usage""#, with: #"{"id":"\#(secret)","usage""#)
                        : Self.anthropicReply)
                }
                let client = OpenRouterLLMClient(session: session, profile: .smart, reasoningRefusals: refusals,
                                                 usageSink: { _ in }, diagnostics: { lines.append($0) })
                let processor = PostProcessor(
                    llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys),
                    openRouterClient: client, checks: checks)
                _ = try? await dictate(processor)

                let label = "\(provider) \(model.replacingOccurrences(of: secret, with: "<name>")) HTTP \(status)"
                XCTAssertEqual(lines.count, 1, "\(label): every request, successful or failed, leaves one line")
                guard let line = lines.first else { continue }
                XCTAssertEqual(line.provider, provider, label)
                XCTAssertEqual(line.model, logged, label)
                XCTAssertEqual(line.status, status, label)
                XCTAssertEqual(line.requestID, "unavailable", label)
                XCTAssertGreaterThanOrEqual(line.llmMs, 0, label)
                XCTAssertEqual(line.outputTokens, status == 200 ? 14 : -1, label)
                XCTAssertEqual(line.reasoningTokens, status == 200 ? 0 : -1, label)
                // Every text field of the line, whatever it is called.
                let text = Mirror(reflecting: line).children.compactMap { $0.value as? String }
                XCTAssertEqual(text.count, 4, "provider, model, request ID, effort")
                XCTAssertFalse(text.contains { $0.contains(secret) || $0.contains("20261001") }, label)
            }
        }
    }

    /// What the dictation's line says on the maintainer's route, and after a
    /// refused field: the setting that was answered, one line for both requests.
    func testTheTimingLineNamesTheSettingThatWasAnswered() async throws {
        var lines: [CleanupDiagnostics] = []
        func processor() -> PostProcessor {
            PostProcessor(
                llmRoute: DirectLLMRouteResolver(feature: .dropSmartCleanup, routing: routing, keys: keys),
                openRouterClient: OpenRouterLLMClient(session: session, profile: .smart, reasoningRefusals: refusals,
                                                      usageSink: { _ in }, diagnostics: { lines.append($0) }),
                checks: checks)
        }
        try route(.anthropic, "claude-sonnet-5-5")
        provider { _, _ in (200, Self.anthropicReply) }
        _ = try await dictate(processor())
        XCTAssertEqual(lines.map(\.effort), ["low+between_tools"])
        XCTAssertEqual(lines.map(\.effortRefused), [false])

        try route(.openAI, "gpt-5.5")
        provider { body, _ in body["reasoning_effort"] == nil ? (200, Self.openAIReply) : (400, "{}") }
        _ = try await dictate(processor())
        XCTAssertEqual(lines.map(\.effort), ["low+between_tools", "default"])
        XCTAssertEqual(lines.map(\.effortRefused), [false, true])
        XCTAssertEqual(lines.last?.status, 200)

        // Translation and meetings: a line for translation, none for meetings.
        lines = []
        for profile in [OpenRouterLLMClient.Profile.dictation, .standard] {
            let client = OpenRouterLLMClient(session: session, profile: profile, reasoningRefusals: refusals,
                                             usageSink: { _ in }, diagnostics: { lines.append($0) })
            _ = try await client.complete(endpoint: .openAI(apiKey: "key"), model: "gpt-4.1",
                                          messages: [.init(role: "user", content: "example")])
        }
        XCTAssertEqual(lines.map(\.effort), ["default"])
    }

    // MARK: Routes that must not change

    /// OpenRouter keeps its own policy: the catalog's lowest effort, throughput
    /// sorting, and none of the direct fields.
    func testSmartThroughOpenRouterIsUnchanged() async throws {
        try route(.openRouter, "google/gemini-3.8-flash")
        provider { [unowned self] _, _ in
            if urls.last?.hasSuffix("/models") == true {
                return (200, #"{"data":[{"id":"google/gemini-3.8-flash","reasoning":{"mandatory":true,"supported_efforts":["high","medium","low"]}}]}"#)
            }
            return (200, Self.openAIReply)
        }

        let output = try await dictate(smart())

        XCTAssertEqual(output.text, Self.cleaned)
        XCTAssertEqual(urls, ["https://openrouter.ai/api/v1/models", "https://openrouter.ai/api/v1/chat/completions"])
        let body = try XCTUnwrap(bodies.last)
        XCTAssertEqual(body["reasoning"] as? [String: String], ["effort": "low"])
        XCTAssertEqual(body["provider"] as? [String: String], ["sort": "throughput"])
        XCTAssertEqual(body["temperature"] as? Double, 0.1)
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertNil(body["output_config"])
        XCTAssertNil(body["thinking"])
    }

    /// A user's own server may run anything, a Claude or GPT name included:
    /// it never gets a reasoning field.
    func testSmartOnAUsersOwnServerSendsNoReasoningField() async throws {
        let server = routing.addServer(name: "Local", baseURL: "http://127.0.0.1:11434/v1")
        routing.setRoute(FeatureRoute(account: .server(server.id), model: "gpt-5.5"), for: .dropSmartCleanup)
        provider { _, _ in (200, Self.openAIReply) }

        let output = try await dictate(smart())

        XCTAssertEqual(output.text, Self.cleaned)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(Set(bodies[0].keys), ["model", "messages", "stream", "temperature"])
    }

    /// Translation shares the dictation profile and meetings use the standard
    /// one: neither is given the direct fields.
    func testTranslationAndMeetingProfilesAreUnchangedOnDirectRoutes() async throws {
        for profile in [OpenRouterLLMClient.Profile.dictation, .standard] {
            let client = OpenRouterLLMClient(session: session, profile: profile, reasoningRefusals: refusals, usageSink: { _ in })
            bodies = []
            provider { body, _ in (200, body["max_tokens"] == nil ? Self.openAIReply : Self.anthropicReply) }

            _ = try await client.complete(endpoint: .anthropic(apiKey: "key"), model: "claude-sonnet-5-5",
                                          messages: [.init(role: "user", content: "example")])
            _ = try await client.complete(endpoint: .openAI(apiKey: "key"), model: "gpt-5.5",
                                          messages: [.init(role: "user", content: "example")])

            XCTAssertEqual(Set(bodies[0].keys), ["model", "max_tokens", "messages"])
            XCTAssertEqual(Set(bodies[1].keys), ["model", "messages", "stream"])
        }
    }
}

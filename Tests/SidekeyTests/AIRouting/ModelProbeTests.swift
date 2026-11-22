import XCTest
@testable import Sidekey

final class ModelProbeTests: XCTestCase {
    // MARK: Fakes

    private final class FakeUpstream: BYOKUpstreamSession, @unchecked Sendable {
        let events: AsyncStream<BYOKStreamEvent>
        private let continuation: AsyncStream<BYOKStreamEvent>.Continuation
        private let onEnd: BYOKStreamEvent?
        private let lock = NSLock()
        private var frames: [Data] = []

        init(onEnd: BYOKStreamEvent?) {
            var cont: AsyncStream<BYOKStreamEvent>.Continuation!
            events = AsyncStream { cont = $0 }
            continuation = cont
            self.onEnd = onEnd
        }

        var audio: [Data] {
            lock.lock(); defer { lock.unlock() }
            return frames
        }

        private func append(_ pcm: Data) {
            lock.lock(); frames.append(pcm); lock.unlock()
        }

        func sendAudio(_ pcm: Data) async { append(pcm) }

        func endInput() async {
            if let onEnd { continuation.yield(onEnd) }
        }

        func close() async { continuation.finish() }
    }

    private final class FakeAdapter: BYOKTranscriptionAdapter, @unchecked Sendable {
        let upstream: FakeUpstream
        private let openError: Error?
        private let lock = NSLock()
        private var languages: [String?] = []

        init(upstream: FakeUpstream, openError: Error? = nil) {
            self.upstream = upstream
            self.openError = openError
        }

        var openedLanguages: [String?] {
            lock.lock(); defer { lock.unlock() }
            return languages
        }

        private func record(_ language: String?) {
            lock.lock(); languages.append(language); lock.unlock()
        }

        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
            record(language)
            if let openError { throw openError }
            return upstream
        }
    }

    // MARK: Helpers

    private func route(
        _ account: ProviderAccount, model: String = "the-model", key: String? = "the-key",
        feature: AIFeature = .dropFast, server: ServerEndpoint? = nil
    ) -> ResolvedRoute {
        ResolvedRoute(feature: feature, account: account, model: model, apiKey: key, server: server)
    }

    private func server(_ baseURL: String = "https://llm.example.com/v1") -> ServerEndpoint {
        ServerEndpoint(id: UUID(), name: "Local", baseURL: baseURL, keyAccount: "byok.server.test.api_key")
    }

    private func realtimeProbe(_ adapter: FakeAdapter, timeout: Duration = .seconds(5)) -> ModelProbe {
        ModelProbe(makeRealtimeAdapter: { _ in adapter }, timeout: timeout)
    }

    private func httpProbe(
        handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)
    ) -> ModelProbe {
        StubURLProtocol.reset()
        addTeardownBlock { StubURLProtocol.reset() }
        StubURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return ModelProbe(session: session)
    }

    private static let okBody = Data(#"{"choices":[{"message":{"content":"OK"}}]}"#.utf8)

    private func jsonBody(at index: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(StubURLProtocol.capturedBodies[safe: index])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Real-time

    func test_realtime_probe_sends_one_second_of_silence_only() async {
        let adapter = FakeAdapter(upstream: FakeUpstream(onEnd: .done("")))
        let outcome = await realtimeProbe(adapter).probe(route(.deepgram), use: .realtimeSTT, catalog: nil)
        XCTAssertEqual(outcome, .passed)
        let audio = adapter.upstream.audio
        XCTAssertEqual(audio.reduce(0) { $0 + $1.count }, 32_000)
        XCTAssertTrue(audio.allSatisfy { $0.count == 3_200 })
        XCTAssertTrue(audio.allSatisfy { $0.allSatisfy { $0 == 0 } })
        XCTAssertEqual(ModelProbe.silence.count, 32_000)
        XCTAssertEqual(adapter.openedLanguages, ["en"])
    }

    func test_realtime_probe_passes_on_done() async {
        let adapter = FakeAdapter(upstream: FakeUpstream(onEnd: .done("")))
        let outcome = await realtimeProbe(adapter).probe(route(.soniox), use: .realtimeSTT, catalog: nil)
        XCTAssertEqual(outcome, .passed)
    }

    func test_realtime_probe_fails_with_the_provider_reason() async {
        let adapter = FakeAdapter(upstream: FakeUpstream(onEnd: .error("model_not_available")))
        let outcome = await realtimeProbe(adapter).probe(route(.deepgram), use: .realtimeSTT, catalog: nil)
        XCTAssertEqual(outcome, .failed(reason: "Provider refused: model_not_available"))
    }

    /// A timeout can be a slow network as well as an unknown dialect: it is
    /// never kept as a failure (final review I1).
    func test_realtime_probe_timeout_is_inconclusive() async {
        let adapter = FakeAdapter(upstream: FakeUpstream(onEnd: nil))
        let probe = realtimeProbe(adapter, timeout: .milliseconds(50))
        let outcome = await probe.probe(route(.server(UUID()), key: nil, server: server()), use: .realtimeSTT, catalog: nil)
        XCTAssertEqual(outcome, .inconclusive(reason: "No answer from the server (its realtime dialect may differ)"))

        let hostedAdapter = FakeAdapter(upstream: FakeUpstream(onEnd: nil))
        let hosted = await realtimeProbe(hostedAdapter, timeout: .milliseconds(50))
            .probe(route(.elevenLabs), use: .realtimeSTT, catalog: nil)
        XCTAssertEqual(hosted, .inconclusive(reason: "No answer from the provider"))
    }

    /// A dropped socket, a handshake refusal or a broken end-of-stream send
    /// says nothing certain about the model (final review I1).
    func test_realtime_transport_errors_are_inconclusive() async {
        for code in ["transport", BYOKStreamErrorCode.endOfStreamSendFailed] {
            let adapter = FakeAdapter(upstream: FakeUpstream(onEnd: .error(code)))
            let outcome = await realtimeProbe(adapter).probe(route(.soniox), use: .realtimeSTT, catalog: nil)
            XCTAssertEqual(outcome, .inconclusive(reason: "No connection"), code)
        }
    }

    func test_realtime_probe_offline_at_open_is_inconclusive() async {
        let adapter = FakeAdapter(upstream: FakeUpstream(onEnd: nil), openError: URLError(.notConnectedToInternet))
        let outcome = await realtimeProbe(adapter).probe(route(.deepgram), use: .realtimeSTT, catalog: nil)
        XCTAssertEqual(outcome, .inconclusive(reason: "No connection"))
    }

    func test_soniox_probe_handshake_carries_the_key_in_the_header() {
        let request = SonioxBYOKAdapter.handshakeRequest(apiKey: "sx")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sx")
        XCTAssertEqual(request.url?.absoluteString, "wss://stt-rt.soniox.com/transcribe-websocket")
    }

    func test_header_authenticated_adapter_never_builds_for_a_missing_hosted_key() {
        XCTAssertThrowsError(try ModelProbe.headerAuthenticatedAdapter(route(.soniox, key: nil)))
        XCTAssertNoThrow(try ModelProbe.headerAuthenticatedAdapter(route(.soniox)))
    }

    // MARK: Chat

    func test_openai_probe_uses_its_own_endpoint_with_modern_output_limit() async throws {
        let probe = httpProbe { _ in (200, [:], Self.okBody) }
        let outcome = await probe.probe(route(.openAI, feature: .translation), use: .chat, catalog: nil)
        XCTAssertEqual(outcome, .passed)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer the-key")
        let body = try jsonBody(at: 0)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 512)
        XCTAssertNil(body["max_tokens"])
        XCTAssertNil(body["provider"])
        XCTAssertNil(body["reasoning"])
    }

    func test_chat_probe_body() async throws {
        let probe = httpProbe { _ in (200, [:], Self.okBody) }
        let catalog = CatalogModel(id: "vendor/model", reasoning: OpenRouterReasoningCapabilities(mandatory: false, supportedEfforts: nil))
        let outcome = await probe.probe(route(.openRouter, model: "vendor/model", feature: .dropSmartCleanup), use: .chat, catalog: catalog)
        XCTAssertEqual(outcome, .passed)

        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer the-key")
        let body = try jsonBody(at: 0)
        XCTAssertEqual(body["model"] as? String, "vendor/model")
        XCTAssertEqual(body["max_tokens"] as? Int, 16)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["provider"] as? [String: Any])?["require_parameters"] as? Bool, true)
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "user", "content": "Reply with OK."]])
        XCTAssertNil(body["tools"])
    }

    func test_keyless_server_chat_probe_sends_no_authorization_and_no_provider() async throws {
        let probe = httpProbe { _ in (200, [:], Self.okBody) }
        let outcome = await probe.probe(
            route(.server(UUID()), key: nil, feature: .dropSmartCleanup, server: server("https://llm.example.com/v1")),
            use: .chat, catalog: nil)
        XCTAssertEqual(outcome, .passed)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://llm.example.com/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try jsonBody(at: 0)
        XCTAssertNil(body["provider"])
        XCTAssertNil(body["reasoning"])
        XCTAssertEqual(body["max_tokens"] as? Int, 16)
    }

    func test_agent_probe_offers_one_fake_tool() async throws {
        let probe = httpProbe { _ in (200, [:], Self.okBody) }
        let outcome = await probe.probe(route(.openRouter, feature: .agent), use: .chatWithTools, catalog: nil)
        XCTAssertEqual(outcome, .passed)
        let body = try jsonBody(at: 0)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "whytap_probe")
        XCTAssertEqual(function["description"] as? String, "Probe tool. Do not call.")
    }

    /// Anthropic's own Messages API: one fake tool, no `tool_choice` (forced
    /// tool use is a 400 on current models), and a 200 cut off at `max_tokens`
    /// still passes.
    func test_anthropic_agent_probe_offers_one_fake_tool_without_tool_choice() async throws {
        let cutOff = Data(#"{"type":"message","content":[],"stop_reason":"max_tokens"}"#.utf8)
        let probe = httpProbe { _ in (200, [:], cutOff) }
        let outcome = await probe.probe(
            route(.anthropic, model: "claude-sonnet-5-5", key: "sk-ant", feature: .agent),
            use: .chatWithTools, catalog: nil)
        XCTAssertEqual(outcome, .passed)

        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))

        let body = try jsonBody(at: 0)
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16)
        XCTAssertNil(body["tool_choice"])
        XCTAssertNil(body["stream"])
        XCTAssertEqual(body["messages"] as? [[String: String]], [["role": "user", "content": "Reply with OK."]])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "whytap_probe")
        XCTAssertEqual(tools[0]["description"] as? String, "Probe tool. Do not call.")
        let schema = try XCTUnwrap(tools[0]["input_schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual((schema["properties"] as? [String: Any])?.isEmpty, true)

        let refusal = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"model: claude-nope not found"}}"#.utf8)
        let table: [(Int, Data, ProbeOutcome)] = [
            (400, refusal, .failed(reason: "Provider refused: model: claude-nope not found")),
            (404, refusal, .failed(reason: "Provider refused: model: claude-nope not found")),
            (401, Data(), .inconclusive(reason: "Key problem")),
            (402, Data(), .inconclusive(reason: "Key problem")),
            (403, Data(), .inconclusive(reason: "Key problem")),
            (429, Data(), .inconclusive(reason: "No answer from the provider")),
            (529, Data(), .inconclusive(reason: "No answer from the provider")),
        ]
        for (status, data, expected) in table {
            let probe = httpProbe { _ in (status, [:], data) }
            let result = await probe.probe(route(.anthropic, key: "sk-ant", feature: .agent), use: .chatWithTools, catalog: nil)
            XCTAssertEqual(result, expected, "anthropic \(status)")
        }
    }

    /// OpenAI tool use is checked the way the Agent runs it: the Responses API
    /// with one function tool. Newer reasoning models (gpt-6.2-sol) refuse
    /// function tools on Chat Completions, which the Agent never uses.
    func test_openai_agent_probe_uses_the_responses_api() async throws {
        let refusalOnChat = Data(#"{"error":{"message":"Function tools with reasoning_effort are not supported for gpt-6.2-sol in /v1/chat/completions. To use function tools, use /v1/responses.","type":"invalid_request_error"}}"#.utf8)
        let probe = httpProbe { request in
            if request.url?.path == "/v1/chat/completions" { return (400, [:], refusalOnChat) }
            return (200, [:], Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"OK"}]}]}"#.utf8))
        }
        let outcome = await probe.probe(route(.openAI, model: "gpt-6.2-sol", key: "sk-openai", feature: .agent),
                                        use: .chatWithTools, catalog: nil)
        XCTAssertEqual(outcome, .passed)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.capturedRequests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai")
        let body = try jsonBody(at: 0)
        XCTAssertEqual(body["model"] as? String, "gpt-6.2-sol")
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 512)
        XCTAssertNil(body["reasoning"], "No reasoning_effort: the Agent sends none either")
        XCTAssertNil(body["messages"])
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        XCTAssertEqual(tools[0]["name"] as? String, "whytap_probe")

        let refusal = Data(#"{"error":{"message":"The model `gpt-nope` does not exist.","type":"invalid_request_error"}}"#.utf8)
        let table: [(Int, Data, ProbeOutcome)] = [
            (200, Data(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#.utf8), .passed),
            (200, Data(#"{"status":"failed","error":{"message":"server error"}}"#.utf8), .failed(reason: "Provider refused: server error")),
            (200, Data("not json".utf8), .inconclusive(reason: "Unexpected answer")),
            (400, refusal, .failed(reason: "Provider refused: The model `gpt-nope` does not exist.")),
            (404, refusal, .failed(reason: "Provider refused: The model `gpt-nope` does not exist.")),
            (401, Data(), .inconclusive(reason: "Key problem")),
            (429, Data(), .inconclusive(reason: "No answer from the provider")),
        ]
        for (status, data, expected) in table {
            let probe = httpProbe { _ in (status, [:], data) }
            let result = await probe.probe(route(.openAI, key: "sk-openai", feature: .agent), use: .chatWithTools, catalog: nil)
            XCTAssertEqual(result, expected, "openai responses \(status)")
        }
        let noKey = await httpProbe { _ in (200, [:], Data()) }
            .probe(route(.openAI, key: nil, feature: .agent), use: .chatWithTools, catalog: nil)
        XCTAssertEqual(noKey, .inconclusive(reason: "Key problem"))
    }

    /// Plain text on OpenAI stays on Chat Completions, as the text features call it.
    func test_openai_text_probe_stays_on_chat_completions() async throws {
        let probe = httpProbe { _ in (200, [:], Self.okBody) }
        let outcome = await probe.probe(route(.openAI, model: "gpt-6.2-sol", feature: .dropSmartCleanup), use: .chat, catalog: nil)
        XCTAssertEqual(outcome, .passed)
        XCTAssertEqual(StubURLProtocol.capturedRequests.first?.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertNil(try jsonBody(at: 0)["tools"])
    }

    /// A failure stored by the old Chat Completions check is not shown again.
    func test_openai_tool_use_checks_have_a_new_adapter_version() {
        XCTAssertEqual(ModelRegistry.adapterVersion(.openAI, .chatWithTools), 2)
        XCTAssertEqual(ModelRegistry.adapterVersion(.openAI, .chat), 1)
        XCTAssertEqual(ModelRegistry.adapterVersion(.anthropic, .chatWithTools), 1)
        XCTAssertEqual(ModelRegistry.adapterVersion(.openRouter, .chatWithTools), 1)
    }

    func test_max_tokens_rejection_retries_once_with_512() async throws {
        var calls = 0
        let probe = httpProbe { _ in
            calls += 1
            if calls == 1 {
                return (400, [:], Data(#"{"error":{"message":"max_tokens is too small for this model"}}"#.utf8))
            }
            return (200, [:], Self.okBody)
        }
        let outcome = await probe.probe(route(.openRouter, feature: .dropSmartCleanup), use: .chat, catalog: nil)
        XCTAssertEqual(outcome, .passed)
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(try jsonBody(at: 0)["max_tokens"] as? Int, 16)
        XCTAssertEqual(try jsonBody(at: 1)["max_tokens"] as? Int, 512)
    }

    func test_chat_probe_status_table() async {
        let table: [(Int, String, ProbeOutcome)] = [
            (404, #"{"error":{"message":"No endpoints found for model"}}"#, .failed(reason: "Provider refused: No endpoints found for model")),
            (422, "", .failed(reason: "Provider refused: HTTP 422")),
            (401, "{}", .inconclusive(reason: "Key problem")),
            (402, "{}", .inconclusive(reason: "Key problem")),
            (503, "{}", .inconclusive(reason: "No answer from the provider")),
        ]
        for (code, body, expected) in table {
            let probe = httpProbe { _ in (code, [:], Data(body.utf8)) }
            let outcome = await probe.probe(route(.openRouter, feature: .dropSmartCleanup), use: .chat, catalog: nil)
            XCTAssertEqual(outcome, expected, "HTTP \(code)")
        }
    }

    @MainActor
    func test_offline_probe_is_inconclusive_and_not_stored() async throws {
        let probe = httpProbe { _ in throw URLError(.notConnectedToInternet) }
        let outcome = await probe.probe(route(.openRouter, feature: .dropSmartCleanup), use: .chat, catalog: nil)
        XCTAssertEqual(outcome, .inconclusive(reason: "No connection"))

        let suite = "ModelProbeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let key = ModelCheckKey(account: "openRouter", model: "the-model", use: .chat)
        let store = ModelCheckStore(defaults: defaults)
        store.store(outcome, for: key, adapterVersion: 1, at: Date())
        XCTAssertNil(store.record(for: key))
    }

    // MARK: Async STT

    func test_async_probe_maps_the_provider_answer() async {
        let refused = httpProbe { _ in (400, [:], Data("{}".utf8)) }
        let refusedOutcome = await refused.probe(route(.soniox, feature: .meetings), use: .asyncSTT, catalog: nil)
        XCTAssertEqual(refusedOutcome, .failed(reason: "Provider refused the model (HTTP 400)"))

        let down = httpProbe { _ in (500, [:], Data("{}".utf8)) }
        let downOutcome = await down.probe(route(.soniox, feature: .meetings), use: .asyncSTT, catalog: nil)
        guard case .inconclusive = downOutcome else { return XCTFail("expected inconclusive, got \(downOutcome)") }
    }

    /// Meetings on ElevenLabs and Deepgram check the picked model on the
    /// provider's own pre-recorded endpoint, with that model.
    // WHY: .project-docs/decisions/2026-11-21-recorded-meeting-models.md
    func test_async_probe_checks_elevenlabs_and_deepgram_on_their_recorded_endpoints() async {
        var paths: [String] = []
        let probe = httpProbe { request in
            paths.append(request.url?.path ?? "")
            if request.url?.host == "api.elevenlabs.io" { return (200, [:], Data(#"{"text":""}"#.utf8)) }
            return (200, [:], Data(#"{"results":{"channels":[{"alternatives":[{"transcript":""}]}]}}"#.utf8))
        }
        let eleven = await probe.probe(route(.elevenLabs, feature: .meetings), use: .asyncSTT, catalog: nil)
        let deepgram = await probe.probe(route(.deepgram, feature: .meetings), use: .asyncSTT, catalog: nil)
        XCTAssertEqual(eleven, .passed)
        XCTAssertEqual(deepgram, .passed)
        XCTAssertEqual(paths, ["/v1/speech-to-text", "/v1/listen"])
        let sent = zip(StubURLProtocol.capturedRequests, StubURLProtocol.capturedBodies).map {
            ($0.url?.query ?? "") + String(decoding: $1, as: UTF8.self)
        }
        XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(sent.allSatisfy { $0.contains("the-model") }, "the picked model is the one checked")

        let refused = httpProbe { _ in (401, [:], Data(#"{"detail":{"status":"invalid_api_key"}}"#.utf8)) }
        let keyOutcome = await refused.probe(route(.elevenLabs, feature: .meetings), use: .asyncSTT, catalog: nil)
        XCTAssertEqual(keyOutcome, .inconclusive(reason: "Key problem"), "a key problem is no verdict on the model")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

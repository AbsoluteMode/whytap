import XCTest
@testable import Sidekey

@MainActor
final class OpenAIRealtimeAdapterTests: XCTestCase {
    func testOpenSendsTranscriptionConfigWithModelLanguagePrompt() async throws {
        let stub = StubWebSocketTransport()
        let adapter = OpenAIRealtimeAdapter(model: "gpt-4o-transcribe") { stub }
        _ = try await adapter.open(language: "ru", terms: ["Whytap"])
        // First frame is the session config (text/JSON).
        // StubWebSocketTransport stores sent frames in `stub.sent` as [Sent]
        // where Sent is .text(String) or .data(Data).
        guard case .text(let json)? = stub.sent.first else { return XCTFail("no config frame") }
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let session = obj["session"] as! [String: Any]
        let input = (session["audio"] as! [String: Any])["input"] as! [String: Any]
        let format = input["format"] as! [String: Any]
        let tx = input["transcription"] as! [String: Any]
        // OpenAI Realtime GA transcription shape.
        XCTAssertEqual(obj["type"] as? String, "session.update")
        XCTAssertEqual(session["type"] as? String, "transcription")
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual(format["rate"] as? Int, 24_000)
        XCTAssertEqual(tx["model"] as? String, "gpt-4o-transcribe")
        XCTAssertEqual(tx["language"] as? String, "ru")
        XCTAssertEqual(tx["prompt"] as? String, "Whytap")
    }

    func testSendAudioAppendsBase64AndCommitOnEnd() async throws {
        let stub = StubWebSocketTransport()
        let adapter = OpenAIRealtimeAdapter(model: "m") { stub }
        let session = try await adapter.open(language: nil, terms: [])
        await session.sendAudio(Data([0x01, 0x02]))
        await session.endInput()
        // After config: append(base64) then commit.
        // StubWebSocketTransport.sent stores sent frames as [Sent].
        let texts = stub.sent.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
        XCTAssertTrue(texts.contains { $0.contains("input_audio_buffer.append") && $0.contains("\"audio\"") })
        XCTAssertTrue(texts.contains { $0.contains("input_audio_buffer.commit") })
        await session.close()
    }

    func testUpsample16kTo24kProduces3to2Ratio() {
        // 4 input samples (8 bytes) → 6 output samples (12 bytes) at 24/16 = 3/2.
        let input = Data([0, 0, 0x10, 0x27, 0, 0, 0xF0, 0xD8])
        XCTAssertEqual(OpenAIRealtimeSession.upsample16kTo24k(input).count, 12)
    }

    func testEventsNormalizedDeltaThenCompleted() async throws {
        let stub = StubWebSocketTransport()
        let adapter = OpenAIRealtimeAdapter(model: "m") { stub }
        let session = try await adapter.open(language: nil, terms: [])
        // StubWebSocketTransport delivers inbound frames via deliverText(_:).
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.delta","delta":"he"}"#)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hello"}"#)
        var got: [BYOKStreamEvent] = []
        for await ev in session.events {
            got.append(ev)
            if case .done = ev { break }
        }
        XCTAssertTrue(got.contains(.partial("he")))
        XCTAssertEqual(got.last, .done("hello"))
        await session.close()
    }

    // The upgrade request: a user's own server may run without a key, and a
    // bare "Bearer " header is something a gateway can reject.
    func test_handshake_has_no_authorization_without_key() {
        let url = URL(string: "wss://gpu.local:8000/v1/realtime?intent=transcription")!

        let request = OpenAIRealtimeAdapter.handshakeRequest(url: url, apiKey: "")

        XCTAssertEqual(request.url, url)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_handshake_sends_bearer_with_key() {
        let url = URL(string: "wss://gpu.local:8000/v1/realtime?intent=transcription")!

        let request = OpenAIRealtimeAdapter.handshakeRequest(url: url, apiKey: "sk-test")

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        // GA Realtime API: the beta header would select the retired beta shape.
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Beta"))
    }

    // MARK: - OpenAI speech (api.openai.com)
    // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md

    private func events(_ session: BYOKUpstreamSession) async -> [BYOKStreamEvent] {
        var got: [BYOKStreamEvent] = []
        for await ev in session.events {
            got.append(ev)
            if case .done = ev { break }
            if case .error = ev { break }
        }
        return got
    }

    private func config(_ stub: StubWebSocketTransport) throws -> (tx: [String: Any], input: [String: Any]) {
        guard case .text(let json)? = stub.sent.first else { throw XCTSkip("no config frame") }
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let input = (((obj["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any])
        return (input["transcription"] as! [String: Any], input)
    }

    private var partials: (([BYOKStreamEvent]) -> [String]) {
        { $0.compactMap { if case .partial(let p) = $0 { return p } else { return nil } } }
    }

    func test_live_model_streams_within_one_turn_with_languages_and_keywords() async throws {
        let stub = StubWebSocketTransport()
        let adapter = OpenAIRealtimeAdapter(model: "gpt-live-transcribe", dialect: .openAI) { stub }
        let session = try await adapter.open(language: "ru", terms: ["Whytap", "Soniox<x>", "  "])

        let (tx, input) = try config(stub)
        XCTAssertEqual(tx["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(tx["languages"] as? [String], ["ru"])
        XCTAssertNil(tx["language"], "never both")
        XCTAssertEqual(tx["keywords"] as? [String], ["Whytap", "Sonioxx"])
        XCTAssertNil(tx["prompt"])
        XCTAssertTrue(input["turn_detection"] is NSNull, "push-to-talk: the take's end is the commit")

        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i1","delta":"При"}"#)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i1","delta":"вет, ми"}"#)
        await session.endInput()
        stub.deliverText(#"{"type":"input_audio_buffer.committed","item_id":"i1","previous_item_id":null}"#)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"Привет, мир."}"#)
        let got = await events(session)

        XCTAssertTrue(partials(got).contains("При"))
        XCTAssertTrue(partials(got).contains("Привет, ми"), "deltas add up to the turn's text")
        XCTAssertTrue(got.contains(.final("Привет, мир.")))
        XCTAssertEqual(got.last, .done("Привет, мир."))
        await session.close()
    }

    func test_realtime_whisper_sends_no_prompt() async throws {
        let stub = StubWebSocketTransport()
        _ = try await OpenAIRealtimeAdapter(model: "gpt-realtime-whisper", dialect: .openAI) { stub }
            .open(language: "en", terms: ["Whytap"])
        let (tx, input) = try config(stub)
        XCTAssertEqual(tx["language"] as? String, "en")
        XCTAssertNil(tx["prompt"])
        XCTAssertNil(tx["keywords"])
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func test_turn_based_model_uses_server_vad_and_orders_finals_by_commit() async throws {
        let stub = StubWebSocketTransport()
        let adapter = OpenAIRealtimeAdapter(model: "gpt-4o-mini-transcribe", dialect: .openAI) { stub }
        let session = try await adapter.open(language: "en", terms: ["Whytap"])

        let (tx, input) = try config(stub)
        XCTAssertEqual(tx["language"] as? String, "en")
        XCTAssertEqual(tx["prompt"] as? String, "Whytap")
        XCTAssertEqual((input["turn_detection"] as? [String: Any])?["type"] as? String, "server_vad")

        // Two phrases; the second one's completion arrives first.
        stub.deliverText(#"{"type":"input_audio_buffer.committed","item_id":"a","previous_item_id":null}"#)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"a","delta":"One"}"#)
        stub.deliverText(#"{"type":"input_audio_buffer.committed","item_id":"b","previous_item_id":"a"}"#)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"two."}"#)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"One,"}"#)
        await session.endInput()
        // Server VAD already committed everything: the final commit finds an
        // empty buffer. That says nothing is left, not that the take failed.
        stub.deliverText(#"{"type":"error","error":{"type":"invalid_request_error","code":"input_audio_buffer_commit_empty"}}"#)
        let got = await events(session)

        let finals = got.compactMap { if case .final(let f) = $0 { return f } else { return nil } }
        XCTAssertEqual(finals, ["One,", "two."], "commit order, not completion order")
        XCTAssertTrue(partials(got).contains("One two."), "a completed later phrase waits behind the open one")
        XCTAssertEqual(got.last, .done("One, two."))
        let texts = stub.sent.compactMap { if case .text(let t) = $0 { return t } else { return nil } }
        XCTAssertTrue(texts.contains { $0.contains("input_audio_buffer.commit") })
        await session.close()
    }

    func test_turn_based_model_waits_for_the_last_phrase_after_the_take_ends() async throws {
        let stub = StubWebSocketTransport()
        let session = try await OpenAIRealtimeAdapter(model: "gpt-transcribe", dialect: .openAI) { stub }
            .open(language: nil, terms: [])
        await session.endInput()
        stub.deliverText(#"{"type":"input_audio_buffer.committed","item_id":"z","previous_item_id":null}"#)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"z","transcript":"Last words."}"#)
        let got = await events(session)
        XCTAssertEqual(got.last, .done("Last words."))
        await session.close()
    }

    func test_silence_is_an_empty_take_not_a_failure() async throws {
        // Push-to-talk: the commit of a silent take completes with no text.
        let live = StubWebSocketTransport()
        let liveSession = try await OpenAIRealtimeAdapter(model: "gpt-live-transcribe", dialect: .openAI) { live }
            .open(language: nil, terms: [])
        await liveSession.sendAudio(Data(count: 3_200))
        await liveSession.endInput()
        live.deliverText(#"{"type":"input_audio_buffer.committed","item_id":"s"}"#)
        live.deliverText(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"s","transcript":""}"#)
        let liveEvents = await events(liveSession)
        XCTAssertEqual(liveEvents.last, .done(""))
        XCTAssertFalse(liveEvents.contains { if case .final = $0 { return true } else { return false } })
        await liveSession.close()

        // Server VAD heard no speech: nothing was committed, the final commit
        // is refused as empty.
        let vad = StubWebSocketTransport()
        let vadSession = try await OpenAIRealtimeAdapter(model: "gpt-4o-transcribe", dialect: .openAI) { vad }
            .open(language: nil, terms: [])
        await vadSession.endInput()
        vad.deliverText(#"{"type":"error","error":{"type":"invalid_request_error","code":"input_audio_buffer_commit_empty"}}"#)
        let vadEvents = await events(vadSession)
        XCTAssertEqual(vadEvents.last, .done(""))
        await vadSession.close()
    }

    func test_dropped_socket_is_a_transport_error() async throws {
        let stub = StubWebSocketTransport()
        let session = try await OpenAIRealtimeAdapter(model: "gpt-live-transcribe", dialect: .openAI) { stub }
            .open(language: nil, terms: [])
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i","delta":"half"}"#)
        stub.deliver(.failure(URLError(.networkConnectionLost)))
        let got = await events(session)
        XCTAssertEqual(got.last, .error("transport"))
        XCTAssertTrue(DirectProviderStreamingSession.isTransportClass("transport"))
        await session.close()
    }

    // A refused key, no credit or a rate limit stays a refusal even after the
    // take's end (never mistaken for the empty final commit). Drop recovers
    // it through the batch rung, which names the reason.
    func test_account_refusals_fail_the_take_as_provider_refused() async throws {
        for code in ["insufficient_quota", "rate_limit_exceeded", "invalid_api_key"] {
            let stub = StubWebSocketTransport()
            let session = try await OpenAIRealtimeAdapter(model: "gpt-4o-transcribe", dialect: .openAI) { stub }
                .open(language: nil, terms: [])
            await session.endInput()
            stub.deliverText(#"{"type":"error","error":{"type":"x","code":"\#(code)"}}"#)
            let got = await events(session)
            XCTAssertEqual(got.last, .error(BYOKStreamErrorCode.providerRefused), code)
            await session.close()
        }
        XCTAssertTrue(DirectProviderStreamingSession.isTransportClass(BYOKStreamErrorCode.providerRefused))
    }

    func test_failed_turn_fails_the_take() async throws {
        let stub = StubWebSocketTransport()
        let session = try await OpenAIRealtimeAdapter(model: "gpt-live-transcribe", dialect: .openAI) { stub }
            .open(language: nil, terms: [])
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.failed","item_id":"i","error":{"code":"x"}}"#)
        let got = await events(session)
        XCTAssertEqual(got.last, .error(BYOKStreamErrorCode.providerRefused))
        await session.close()
    }

    // A pong repeats the current partial: progress for the stall detector,
    // no change for the island.
    func test_ping_heartbeat_repeats_the_current_partial() async throws {
        let stub = StubWebSocketTransport()
        let session = try await OpenAIRealtimeAdapter(model: "gpt-live-transcribe", dialect: .openAI,
                                                      pingInterval: .milliseconds(5)) { stub }
            .open(language: nil, terms: [])
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i","delta":"Hi"}"#)
        var seen = 0
        for await ev in session.events {
            if ev == .partial("Hi") { seen += 1 }
            if seen >= 3 { break }
        }
        XCTAssertGreaterThanOrEqual(seen, 3)
        await session.close()
    }

    // The production URL of an OpenAI route is OpenAI's; a server's comes only
    // from its own base URL, and a broken one fails before any socket.
    func test_openai_host_is_explicit_and_servers_never_reach_it() throws {
        XCTAssertEqual(BYOKRealtimeURL.openAIHosted.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
        XCTAssertNil(BYOKRealtimeURL.openAIRealtime(baseURL: nil))
        XCTAssertNil(BYOKRealtimeURL.openAIRealtime(baseURL: "http://my host:8000"))
        XCTAssertEqual(BYOKRealtimeURL.openAIRealtime(baseURL: "https://gpu.local:8000")?.host, "gpu.local")

        let server = ServerEndpoint(id: UUID(), name: "S", baseURL: "http://my host:8000", keyAccount: "k")
        let route = ResolvedRoute(feature: .dropFast, account: .server(server.id), model: "gpt-live-transcribe",
                                  apiKey: "k", server: server)
        XCTAssertThrowsError(try RealtimeAdapterFactory.make(route)) { error in
            XCTAssertEqual(error as? FeatureRouteError, .invalidBaseURL(.dropFast))
        }
        // A server keeps the plain shape even when it names an OpenAI model.
        let config = OpenAIRealtimeAdapter.sessionUpdate(model: "gpt-live-transcribe", dialect: .server,
                                                         language: "ru", terms: ["Whytap"])
        let input = (((config["session"] as! [String: Any])["audio"] as! [String: Any])["input"] as! [String: Any])
        let tx = input["transcription"] as! [String: Any]
        XCTAssertEqual(tx["language"] as? String, "ru")
        XCTAssertEqual(tx["prompt"] as? String, "Whytap")
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    func test_openai_route_needs_the_shared_key() {
        let keyless = ResolvedRoute(feature: .dropFast, account: .openAI, model: "gpt-live-transcribe",
                                    apiKey: nil, server: nil)
        XCTAssertThrowsError(try RealtimeAdapterFactory.make(keyless)) { error in
            XCTAssertEqual(error as? FeatureRouteError, .missingKey(.dropFast))
        }
        let keyed = ResolvedRoute(feature: .dropFast, account: .openAI, model: "gpt-live-transcribe",
                                  apiKey: "oa", server: nil)
        XCTAssertTrue((try? RealtimeAdapterFactory.make(keyed)) is OpenAIRealtimeAdapter)
    }

    // A Drop take on OpenAI whose session is refused mid-recording (no credit)
    // keeps its own audio and resolves `.degraded`: the batch rung then names
    // the refusal or delivers the text.
    func test_drop_take_refused_mid_recording_keeps_its_audio_for_the_batch_rung() async {
        let captured = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let engine = CapturingStubAudioSource(captured: captured)
        let stub = StubWebSocketTransport()
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: OpenAIRealtimeAdapter(model: "gpt-live-transcribe", dialect: .openAI) { stub },
            language: nil, terms: [], resilient: true
        )
        var live: [String] = []
        session.onTranscriptUpdate = { live.append($0) }
        let run = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(nanoseconds: 40_000_000)
        stub.deliverText(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i","delta":"Hello"}"#)
        try? await Task.sleep(nanoseconds: 30_000_000)
        stub.deliverText(#"{"type":"error","error":{"type":"insufficient_quota","code":"insufficient_quota"}}"#)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(engine.didStop, "capture continues after the refusal")

        await session.stop()
        let result = await run.value
        XCTAssertEqual(result, .degraded)
        XCTAssertEqual(session.capturedAudioPCM16(), captured)
        XCTAssertEqual(live, ["Hello"], "the island showed the live words")
    }
}

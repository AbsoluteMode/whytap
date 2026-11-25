import Foundation
@testable import Sidekey
import XCTest

/// Soniox live translation for Subtitles: one WebSocket carries the original
/// and its translation; a broken or refused socket is named; the start waits
/// for Soniox's first answer so nothing is captured on a refused key.
final class SonioxRealtimeTranslateAdapterTests: XCTestCase {
    private func json(_ sent: StubWebSocketTransport.Sent) -> [String: Any]? {
        guard case .text(let text) = sent else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private func open(_ transport: StubWebSocketTransport, source: String? = "en",
                      deadline: Duration = .seconds(30)) async throws -> SpeechTranslationSession {
        var adapter = SonioxRealtimeTranslateAdapter(transport: { transport })
        adapter.startDeadline = deadline
        return try await adapter.open(source: source, target: "ru")
    }

    private func events(_ session: SpeechTranslationSession) async -> [SpeechTranslationEvent] {
        var events: [SpeechTranslationEvent] = []
        for await event in session.events { events.append(event) }
        return events
    }

    /// Soniox's first answer to the config, before any audio.
    private static let ready = #"{"tokens":[],"final_audio_proc_ms":0,"total_audio_proc_ms":0}"#

    func testTheConfigAsksForOneWayTranslationOfTwentyFourKilohertzAudio() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        XCTAssertTrue(transport.resumed)
        let config = try XCTUnwrap(json(transport.sent[0]))
        XCTAssertEqual(config["model"] as? String, "stt-rt-v6")
        XCTAssertEqual(config["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(config["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(config["num_channels"] as? Int, 1)
        XCTAssertEqual(config["enable_endpoint_detection"] as? Bool, true)
        XCTAssertEqual(config["language_hints"] as? [String], ["en"])
        XCTAssertNil(config["api_key"], "the key goes in the Authorization header")
        let translation = try XCTUnwrap(config["translation"] as? [String: Any])
        XCTAssertEqual(translation["type"] as? String, "one_way")
        XCTAssertEqual(translation["target_language"] as? String, "ru")
        XCTAssertEqual(session.providerName, "Soniox")
        await session.close()
        let detect = SonioxRealtimeTranslateSession.config(source: nil, target: "de", reference: "r")
        XCTAssertNil(detect["language_hints"], "Detect leaves the spoken language to Soniox")
    }

    /// The scenario Maxim tests: the original word by word and its
    /// translation in one stream. Only final tokens are passed on; a
    /// translation is placed at the end of the original it translates.
    func testTheOriginalAndItsTranslationArriveInOneStream() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        transport.deliverText(#"""
        {"tokens":[{"text":"Hel","is_final":false,"translation_status":"original","start_ms":100,"end_ms":300}]}
        """#)
        transport.deliverText(#"""
        {"tokens":[
          {"text":"Hello","is_final":true,"translation_status":"original","start_ms":100,"end_ms":400},
          {"text":" world.","is_final":true,"translation_status":"original","start_ms":420,"end_ms":900},
          {"text":"<end>","is_final":true}
        ]}
        """#)
        transport.deliverText(#"""
        {"tokens":[
          {"text":"Привет,","is_final":true,"translation_status":"translation"},
          {"text":" мир.","is_final":true,"translation_status":"translation"},
          {"text":" Next","is_final":false,"translation_status":"original","start_ms":1200,"end_ms":1400}
        ]}
        """#)
        transport.deliverText(#"""
        {"tokens":[{"text":" Next one.","is_final":true,"translation_status":"original","start_ms":1200,"end_ms":1800}]}
        """#)
        await session.endInput()
        transport.deliverText(#"""
        {"tokens":[{"text":" Следующий.","is_final":true,"translation_status":"translation"}],"finished":true}
        """#)
        let received = await events(session)
        XCTAssertEqual(received, [
            .source("Hello", elapsedMs: 400),
            .source(" world.", elapsedMs: 900),
            .translation("Привет,", elapsedMs: 900),
            .translation(" мир.", elapsedMs: 900),
            .source(" Next one.", elapsedMs: 1_800),
            .translation(" Следующий.", elapsedMs: 1_800),
            .closed,
        ])
        XCTAssertTrue(transport.cancelled, "the socket is released after finished")
    }

    /// Speech already in the target language has nothing to translate: it is
    /// its own subtitle.
    func testSpeechInTheTargetLanguageIsItsOwnTranslation() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        transport.deliverText(#"{"tokens":[{"text":"Да.","is_final":true,"translation_status":"none","end_ms":700}]}"#)
        await session.endInput()
        transport.deliverText(#"{"tokens":[],"finished":true}"#)
        let received = await events(session)
        XCTAssertEqual(received, [.source("Да.", elapsedMs: 700), .translation("Да.", elapsedMs: 700), .closed])
    }

    /// Binary frames of 100 ms; the end of audio is an empty text frame (an
    /// empty binary frame made Soniox time out with 408 in the live probe).
    func testAudioGoesOutInHundredMillisecondBinaryFramesThenAnEmptyTextFrame() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        let pcm = Data((0..<12_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        await session.sendAudio(pcm)
        var frames = transport.sent.dropFirst().compactMap { sent -> Data? in
            if case .data(let data) = sent { return data } else { return nil }
        }
        XCTAssertEqual(frames.map(\.count), [4_800, 4_800], "2.5 frames: the half waits")
        await session.endInput()
        frames = transport.sent.dropFirst().compactMap { sent -> Data? in
            if case .data(let data) = sent { return data } else { return nil }
        }
        XCTAssertEqual(frames.map(\.count), [4_800, 4_800, 2_400])
        XCTAssertEqual(frames.reduce(Data(), +), pcm)
        XCTAssertEqual(transport.sent.last, .text(""))
        XCTAssertEqual(session.acceptedAudioSeconds(), 0.25, accuracy: 0.001)
        await session.sendAudio(pcm)
        XCTAssertEqual(transport.sent.last, .text(""), "nothing is sent after the end of audio")
        await session.close()
    }

    func testARefusedKeyFailsTheStart() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"error_code":401,"error_message":"Invalid API key."}"#)
        do { _ = try await open(transport); XCTFail("expected a refused key") } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .refusedKey)
        }
        XCTAssertTrue(transport.cancelled)
        let handshake = StubWebSocketTransport()
        handshake.responseStatusCode = 401
        handshake.deliver(.failure(URLError(.badServerResponse)))
        do { _ = try await open(handshake); XCTFail("expected a refused key") } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .refusedKey)
        }
    }

    func testStartErrorsAreNamed() async throws {
        let language = StubWebSocketTransport()
        language.deliverText(#"{"error_code":400,"error_message":"Invalid language in translation.target_language"}"#)
        do { _ = try await open(language); XCTFail() } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .unsupportedLanguage)
        }
        XCTAssertEqual(SonioxRealtimeTranslateSession.failure(code: 402, starting: true), .noCredit)
        XCTAssertEqual(SonioxRealtimeTranslateSession.failure(code: 429, starting: false), .busy)
        XCTAssertEqual(SonioxRealtimeTranslateSession.failure(code: 408, starting: false), .connectionLost)
        XCTAssertEqual(SonioxRealtimeTranslateSession.failure(code: 400, starting: false), .provider,
                       "mid-session a 400 is not the language")
        XCTAssertEqual(SonioxRealtimeTranslateSession.failure(code: 500, starting: false), .provider)
    }

    func testNoAnswerAtStartTimesOut() async throws {
        let transport = StubWebSocketTransport()
        let started = Date()
        do { _ = try await open(transport, deadline: .milliseconds(200)); XCTFail() } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .connectionLost)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(transport.cancelled)
    }

    /// The pairs already received stay; the stream says the connection ended.
    func testADroppedSocketMidSessionIsAConnectionLoss() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        transport.deliverText(#"{"tokens":[{"text":"Hi.","is_final":true,"translation_status":"original","end_ms":500}]}"#)
        transport.deliver(.failure(URLError(.networkConnectionLost)))
        let received = await events(session)
        XCTAssertEqual(received, [.source("Hi.", elapsedMs: 500), .failed(.connectionLost)])
    }

    func testAnErrorMidSessionEndsItNamed() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        transport.deliverText(#"{"error_code":402,"error_message":"Organization balance exhausted."}"#)
        let received = await events(session)
        XCTAssertEqual(received, [.failed(.noCredit)])
        XCTAssertTrue(transport.cancelled)
    }

    /// After the end of audio only `finished` is a clean ending: a socket lost
    /// before it may have dropped the last translation.
    func testASocketLostAfterTheEndOfAudioIsNotACleanEnding() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        await session.endInput()
        transport.deliver(.failure(URLError(.networkConnectionLost)))
        let received = await events(session)
        XCTAssertEqual(received, [.failed(.connectionLost)])
    }

    func testAFailedEndOfAudioIsAConnectionLoss() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        transport.sendError = URLError(.networkConnectionLost)
        await session.endInput()
        let received = await events(session)
        XCTAssertEqual(received, [.failed(.connectionLost)])
    }

    func testTheAppsOwnCloseEndsQuietly() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        await session.close()
        let received = await events(session)
        XCTAssertEqual(received, [.closed])
        XCTAssertEqual(transport.cancelReason, "client closed")
    }

    // MARK: Builder review #566

    /// Finding 1: Stop or a new session while Soniox has not answered closes
    /// the socket at once, not at the start deadline, and starts nothing.
    func testCancellingWhileWaitingForSonioxClosesTheSocketAtOnce() async throws {
        let transport = StubWebSocketTransport()
        var adapter = SonioxRealtimeTranslateAdapter(transport: { transport })
        adapter.startDeadline = .seconds(30)
        let opening = Task { try await adapter.open(source: "en", target: "ru") }
        for _ in 0..<400 where transport.sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(transport.sent.count, 1, "the config was sent")
        let cancelledAt = Date()
        opening.cancel()
        do { _ = try await opening.value; XCTFail("a cancelled open returns no session") } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.5)
        XCTAssertTrue(transport.cancelled, "the socket is closed")
        // A late answer changes nothing.
        transport.deliverText(Self.ready)
    }

    func testCancellingWhileTheConfigIsStillSendingClosesTheSocket() async throws {
        let transport = HangingSendTransport()
        var adapter = SonioxRealtimeTranslateAdapter(transport: { transport })
        adapter.startDeadline = .seconds(30)
        let opening = Task { try await adapter.open(source: nil, target: "ru") }
        for _ in 0..<400 where !transport.sending { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(transport.sending)
        let cancelledAt = Date()
        opening.cancel()
        do { _ = try await opening.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 0.5)
        XCTAssertTrue(transport.cancelled)
    }

    /// Review #572, finding 1: an open cancelled before it begins never
    /// starts the socket or sends the config.
    func testAnAlreadyCancelledOpenNeverConnects() async throws {
        let transport = StubWebSocketTransport()
        let adapter = SonioxRealtimeTranslateAdapter(transport: { transport })
        let opening = Task { () async throws -> SpeechTranslationSession in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await adapter.open(source: "en", target: "ru")
        }
        do { _ = try await opening.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(transport.resumed)
        XCTAssertTrue(transport.sent.isEmpty)

        // The session itself, started in a task already cancelled.
        let direct = StubWebSocketTransport()
        let session = SonioxRealtimeTranslateSession(transport: direct)
        let start = Task { () async throws in
            withUnsafeCurrentTask { $0?.cancel() }
            try await session.start(source: "en", target: "ru", deadline: .seconds(30))
        }
        do { try await start.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertTrue(direct.sent.isEmpty, "no config is sent")
        XCTAssertTrue(direct.cancelled)
        var events: [SpeechTranslationEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.closed])
    }

    /// Review #572, finding 2: one policy in-band and at the handshake; an
    /// unfamiliar error type falls back to its status.
    func testOneErrorPolicyForTypesStatusesAndHandshakes() async throws {
        typealias S = SonioxRealtimeTranslateSession
        XCTAssertEqual(S.failure(code: 401, type: "brand_new_type", starting: true), .refusedKey)
        XCTAssertEqual(S.failure(code: 402, type: "brand_new_type", starting: false), .noCredit)
        XCTAssertEqual(S.failure(code: 429, type: "brand_new_type", starting: false), .busy)
        XCTAssertEqual(S.failure(code: 400, type: "brand_new_type", message: "Invalid language hint.", starting: true),
                       .unsupportedLanguage)
        for (status, expected) in [(401, SpeechTranslationFailure.refusedKey), (403, .permissionDenied),
                                   (402, .noCredit), (429, .busy), (503, .connectionLost)] {
            let inBand = StubWebSocketTransport()
            inBand.deliverText(#"{"tokens":[],"error_code":\#(status),"error_message":"x"}"#)
            do { _ = try await open(inBand); XCTFail() } catch let failure as SpeechTranslationFailure {
                XCTAssertEqual(failure, expected, "in-band \(status)")
            }
            let handshake = StubWebSocketTransport()
            handshake.responseStatusCode = status
            handshake.deliver(.failure(URLError(.badServerResponse)))
            do { _ = try await open(handshake); XCTFail() } catch let failure as SpeechTranslationFailure {
                XCTAssertEqual(failure, expected, "handshake \(status)")
            }
        }
        let lost = StubWebSocketTransport()
        lost.deliver(.failure(URLError(.networkConnectionLost)))
        do { _ = try await open(lost); XCTFail() } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .connectionLost, "no status: the connection was lost")
        }
    }

    /// Review #572, finding 3: logs name only documented error types.
    func testLogsNameOnlyDocumentedErrorTypes() {
        typealias S = SonioxRealtimeTranslateSession
        XCTAssertEqual(S.loggable("unauthenticated"), "unauthenticated")
        XCTAssertEqual(S.loggable("model_not_available"), "model_not_available")
        XCTAssertEqual(S.loggable("hello_from_the_transcript"), "other")
        XCTAssertEqual(S.loggable("Invalid language hint."), "other")
        XCTAssertEqual(S.loggable(nil), "none")
    }

    /// Finding 2: only a transcription response opens the session. A control
    /// frame does not, so a refused key after it still fails the open; a
    /// `finished` before any response is a failed open.
    func testOnlyATranscriptionResponseOpensTheSession() async throws {
        let refused = StubWebSocketTransport()
        refused.deliverText(#"{"type":"pong","id":1}"#)
        refused.deliverText(#"{"type":"reconnect","reconnect_token":"t","reconnect_url":"wss://x"}"#)
        refused.deliverText(#"{"tokens":[],"error_code":401,"error_type":"unauthenticated","error_message":"Invalid API key."}"#)
        do { _ = try await open(refused); XCTFail("a refused key after a control frame fails the open") }
        catch let failure as SpeechTranslationFailure { XCTAssertEqual(failure, .refusedKey) }
        XCTAssertTrue(refused.cancelled)

        let finished = StubWebSocketTransport()
        finished.deliverText(#"{"tokens":[],"final_audio_proc_ms":0,"total_audio_proc_ms":0,"finished":true}"#)
        do { _ = try await open(finished); XCTFail("finished before starting is no session") }
        catch let failure as SpeechTranslationFailure { XCTAssertEqual(failure, .provider) }
        XCTAssertTrue(finished.cancelled)

        let ready = StubWebSocketTransport()
        ready.deliverText(#"{"type":"pong","id":1}"#)
        ready.deliverText(Self.ready)
        let session = try await open(ready)
        await session.close()
    }

    /// Finding 3: the documented `error_type` decides the message; a 400 is
    /// a language only when Soniox's request error says so.
    func testErrorTypesAreNamedByTheirDocumentedCategory() async throws {
        typealias S = SonioxRealtimeTranslateSession
        XCTAssertEqual(S.failure(code: 400, type: "model_not_available",
                                 message: "The requested model is not available.", starting: true), .modelUnavailable)
        XCTAssertEqual(S.failure(code: 400, type: "invalid_request",
                                 message: "Invalid language in translation.target_language", starting: true),
                       .unsupportedLanguage)
        XCTAssertEqual(S.failure(code: 400, type: "invalid_request", message: "Start request is malformed.", starting: true),
                       .provider)
        XCTAssertEqual(S.failure(code: 400, type: "invalid_request", message: "Invalid language hint.", starting: false),
                       .provider, "mid-session a request error is not the chosen language")
        XCTAssertEqual(S.failure(code: 401, type: "unauthenticated", starting: true), .refusedKey)
        XCTAssertEqual(S.failure(code: 403, type: "temp_api_key_session_expired", starting: false), .refusedKey)
        XCTAssertEqual(S.failure(code: 403, type: "permission_denied", starting: true), .permissionDenied)
        for type in ["organization_balance_exhausted", "organization_monthly_budget_exhausted",
                     "project_monthly_budget_exhausted"] {
            XCTAssertEqual(S.failure(code: 402, type: type, starting: false), .noCredit)
        }
        XCTAssertEqual(S.failure(code: 429, type: "max_concurrent_connections_reached", starting: true), .busy)
        XCTAssertEqual(S.failure(code: 503, type: "service_unavailable", starting: false), .connectionLost)
        XCTAssertEqual(S.failure(code: 413, type: "max_duration_reached", starting: false), .provider)
        XCTAssertEqual(S.failure(code: 500, type: "internal_error", starting: false), .provider)
        // Without a type, the status.
        XCTAssertEqual(S.failure(code: 400, starting: true), .provider)
        XCTAssertEqual(S.failure(code: 403, starting: true), .permissionDenied)

        let model = StubWebSocketTransport()
        model.deliverText(#"{"tokens":[],"error_code":400,"error_type":"model_not_available","error_message":"The requested model is not available."}"#)
        do { _ = try await open(model); XCTFail() } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .modelUnavailable)
        }
        XCTAssertEqual(TranslationIssue.speechTranslation(.modelUnavailable, target: "ru", provider: "Soniox").message,
                       "Soniox live translation is not available for this key's project or region. Check your Soniox project.")
        XCTAssertEqual(TranslationIssue.speechTranslation(.permissionDenied, target: "ru", provider: "Soniox").feature,
                       .subtitlesAudio)
        XCTAssertEqual(TranslationIssue.speechTranslation(.connectionLost, target: "ru", provider: "Soniox").message,
                       "The Soniox connection ended. Check your network and start again.")
    }

    /// Finding 4: Costs records a Soniox session under the reference sent in
    /// the config, so the usage log's exact charge replaces the estimate.
    func testCostsCarryTheSessionsSonioxReference() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(Self.ready)
        let session = try await open(transport)
        let config = try XCTUnwrap(json(transport.sent[0]))
        let reference = try XCTUnwrap(config["client_reference_id"] as? String)
        XCTAssertEqual(session.usageReference, reference)
        var recorded: [AIUsageEvent] = []
        let metered = AIUsageMeteredSpeechTranslation(
            session: session, context: AIUsageContext(feature: .subtitlesAudio, account: .soniox, model: "stt-rt-v6"))
        metered.record = { recorded.append($0) }
        await metered.sendAudio(Data(count: 4_800))
        await metered.close()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.id, "soniox:\(reference)")
        XCTAssertEqual(recorded.first?.basis, .estimated, "the estimate stays until the charge is known")
        XCTAssertEqual(recorded.first.flatMap(SonioxUsagePrices.reference)?.value, reference)
        // OpenAI sessions have no such reference.
        let openAI = AIUsageMeteredSpeechTranslation(
            session: FakeSpeechTranslation(),
            context: AIUsageContext(feature: .subtitlesAudio, account: .openAI, model: "gpt-realtime-translate"))
        var other: [AIUsageEvent] = []
        openAI.record = { other.append($0) }
        await openAI.sendAudio(Data(count: 4_800))
        await openAI.close()
        XCTAssertFalse(other.first?.id.hasPrefix("soniox:") ?? true)
    }
}

/// The Subtitles model on a real Soniox session over a stub socket: pairs
/// form from the one stream, and a broken socket keeps them and names it.
@MainActor
final class SonioxSubtitlesModelTests: XCTestCase {
    private func wait(_ condition: @autoclosure () -> Bool, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    private func makeModel(_ transport: StubWebSocketTransport, audio: FixtureSubtitleAudio) -> LiveSubtitleModel {
        let model = LiveSubtitleModel(
            flushInterval: .milliseconds(5), connectionTimeout: .seconds(5),
            makeAudio: { audio },
            openTranslator: { source, target in
                try await SonioxRealtimeTranslateAdapter(transport: { transport }).open(source: source, target: target)
            }
        )
        model.sourceCode = "en"
        model.targetCode = "ru"
        return model
    }

    private static func sentence(_ text: String, end: Int, translation: String) -> [String] {
        [
            #"{"tokens":[{"text":"\#(text)","is_final":true,"translation_status":"original","end_ms":\#(end)},{"text":"<end>","is_final":true}]}"#,
            #"{"tokens":[{"text":"\#(translation)","is_final":true,"translation_status":"translation"}]}"#,
        ]
    }

    func testSonioxSentencesBecomePairsAndStopWaitsForFinished() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"tokens":[]}"#)
        let audio = FixtureSubtitleAudio()
        let model = makeModel(transport, audio: audio)
        model.start()
        try await wait(model.phase == .listening)
        audio.pair.continuation.yield([Float](repeating: 0.1, count: 4_800))
        try await wait(transport.sent.contains { if case .data = $0 { return true } else { return false } })
        for line in Self.sentence("Welcome back everyone.", end: 1_400, translation: "С возвращением, все.")
            + Self.sentence(" Today we talk about rivers.", end: 3_900, translation: " Сегодня поговорим о реках.") {
            transport.deliverText(line)
        }
        try await wait(model.lines.count >= 1 && model.liveTranslation.contains("рек"))
        model.stop()
        try await wait(transport.sent.last == .text(""))
        transport.deliverText(#"{"tokens":[],"finished":true}"#)
        try await wait(model.phase == .idle)
        XCTAssertNil(model.issue)
        XCTAssertEqual(model.lines.map(\.source), ["Welcome back everyone.", "Today we talk about rivers."])
        XCTAssertEqual(model.lines.map(\.translation), ["С возвращением, все.", "Сегодня поговорим о реках."])
        XCTAssertEqual(audio.finished, 1)
    }

    func testABrokenSonioxSocketKeepsThePairsAndSaysSo() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"tokens":[]}"#)
        let audio = FixtureSubtitleAudio()
        let model = makeModel(transport, audio: audio)
        model.start()
        try await wait(model.phase == .listening)
        for line in Self.sentence("First.", end: 900, translation: "Первое.")
            + Self.sentence(" Second.", end: 2_000, translation: " Второе.") {
            transport.deliverText(line)
        }
        try await wait(model.lines.count >= 1)
        transport.deliver(.failure(URLError(.networkConnectionLost)))
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.message, "The Soniox connection ended. Check your network and start again.")
        XCTAssertGreaterThanOrEqual(model.lines.count, 1, "finished pairs stay on screen")
        XCTAssertEqual(model.lines.first?.translation, "Первое.")
    }

    func testARefusedSonioxKeyNamesSonioxAndCapturesNothing() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"error_code":401,"error_message":"Invalid API key."}"#)
        let audio = FixtureSubtitleAudio()
        let model = LiveSubtitleModel(
            flushInterval: .milliseconds(5), connectionTimeout: .seconds(5),
            makeAudio: { audio },
            openTranslator: { source, target in
                do {
                    return try await SonioxRealtimeTranslateAdapter(transport: { transport }).open(source: source, target: target)
                } catch let failure as SpeechTranslationFailure {
                    throw SubtitleAudioTranslate.EngineFailure(failure: failure, provider: "Soniox")
                }
            }
        )
        model.start()
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.message, "Soniox refused the API key. Check it in Keys & models.")
        XCTAssertEqual(audio.started, 0, "system audio is never captured")
    }
}

/// A socket whose sends never complete until it is cancelled.
final class HangingSendTransport: StreamingTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var sendWaiters: [CheckedContinuation<Void, Error>] = []
    private var receiveWaiters: [CheckedContinuation<Result<StreamingFrame, Error>, Never>] = []
    private var _sending = false
    private var _cancelled = false
    var sending: Bool { lock.withLock { _sending } }
    var cancelled: Bool { lock.withLock { _cancelled } }
    var responseStatusCode: Int? { nil }
    func resume() {}

    func cancel(reason: String?) {
        let (sends, receives) = lock.withLock { () -> ([CheckedContinuation<Void, Error>], [CheckedContinuation<Result<StreamingFrame, Error>, Never>]) in
            _cancelled = true
            defer { sendWaiters = []; receiveWaiters = [] }
            return (sendWaiters, receiveWaiters)
        }
        sends.forEach { $0.resume(throwing: StreamingSessionError.transportCancelled) }
        receives.forEach { $0.resume(returning: .failure(StreamingSessionError.transportCancelled)) }
    }

    func send(_ frame: StreamingFrame) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let cancelled = lock.withLock { () -> Bool in
                _sending = true
                if _cancelled { return true }
                sendWaiters.append(continuation)
                return false
            }
            if cancelled { continuation.resume(throwing: StreamingSessionError.transportCancelled) }
        }
    }

    func receive() async -> Result<StreamingFrame, Error> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<StreamingFrame, Error>, Never>) in
            let cancelled = lock.withLock { () -> Bool in
                if _cancelled { return true }
                receiveWaiters.append(continuation)
                return false
            }
            if cancelled { continuation.resume(returning: .failure(StreamingSessionError.transportCancelled)) }
        }
    }
}

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
        XCTAssertEqual(model.issue?.message, "The translation connection ended. Check your network and start again.")
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

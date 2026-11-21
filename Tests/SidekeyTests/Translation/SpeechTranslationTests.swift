import Foundation
@testable import Sidekey
import XCTest

/// A speech-translation session driven by the test: it yields what the test
/// sends and closes on `endInput` like the provider's session.close.
final class FakeSpeechTranslation: SpeechTranslationSession, @unchecked Sendable {
    let pair = AsyncStream.makeStream(of: SpeechTranslationEvent.self)
    var events: AsyncStream<SpeechTranslationEvent> { pair.stream }
    private let lock = NSLock()
    private var bytes = 0
    private var ends = 0
    private var closes = 0
    /// When false, `endInput` never answers (a provider that hangs on close).
    var closesOnEndInput = true
    var sentBytes: Int { lock.withLock { bytes } }
    var endInputCount: Int { lock.withLock { ends } }
    var closeCount: Int { lock.withLock { closes } }

    func sendAudio(_ pcm: Data) async { lock.withLock { bytes += pcm.count } }
    func endInput() async {
        lock.withLock { ends += 1 }
        guard closesOnEndInput else { return }
        pair.continuation.yield(.closed)
        pair.continuation.finish()
    }
    func close() async {
        lock.withLock { closes += 1 }
        pair.continuation.finish()
    }
    func acceptedAudioSeconds() -> Double { Double(sentBytes) / 32_000 }

    func yieldRecorded(until millis: Int = .max) {
        for event in OpenAITranslateRecordedSession.events where event.at <= millis {
            switch event.stream {
            case .source: pair.continuation.yield(.source(event.text, elapsedMs: event.elapsed))
            case .translation: pair.continuation.yield(.translation(event.text, elapsedMs: event.elapsed))
            }
        }
    }
}

private struct UnusedTranslator: TextTranslating {
    func translate(_ text: String, target: TranslationTarget) async throws -> String {
        XCTFail("The Subtitles LLM must not be used with a speech translator")
        return text
    }
}

@MainActor
final class SpeechTranslationModelTests: XCTestCase {
    private func makeModel(
        translator: @escaping () async throws -> SpeechTranslationSession?,
        audio: FixtureSubtitleAudio = FixtureSubtitleAudio(),
        llmUsed: (() -> Void)? = nil
    ) -> LiveSubtitleModel {
        let model = LiveSubtitleModel(
            flushInterval: .milliseconds(5), connectionTimeout: .seconds(5),
            makeAudio: { audio },
            open: { _ in XCTFail("No speech-to-text session with a speech translator"); return FixtureSubtitleUpstream() },
            makeService: { llmUsed?(); return UnusedTranslator() },
            openTranslator: { _, _ in try await translator() }
        )
        model.sourceCode = "en"
        model.targetCode = "ru"
        return model
    }

    private func wait(_ condition: @autoclosure () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    func testRecordedSessionBecomesPairsAndStopWaitsForTheProviderClose() async throws {
        let session = FakeSpeechTranslation()
        let audio = FixtureSubtitleAudio()
        var llmUsed = false
        let model = makeModel(translator: { session }, audio: audio, llmUsed: { llmUsed = true })
        model.start()
        try await wait(model.phase == .listening)
        audio.pair.continuation.yield([0.1, 0.2, -0.1])
        try await wait(session.sentBytes > 0)
        session.yieldRecorded()
        try await wait(model.lines.count >= 7)
        XCTAssertFalse(model.liveTranslation.isEmpty || model.live.isEmpty, "the last sentence is still live")
        model.stop()
        try await wait(model.phase == .idle)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.issue)
        XCTAssertEqual(session.endInputCount, 1)
        XCTAssertEqual(model.lines.count, 8)
        XCTAssertEqual(model.lines.first?.source, "Welcome back everyone.")
        XCTAssertEqual(model.lines.first?.translation, "Добро пожаловать обратно, всем.")
        XCTAssertEqual(model.lines.map(\.ordinal), Array(0..<8))
        XCTAssertTrue(model.lines.allSatisfy { $0.translation != nil && !$0.failed })
        XCTAssertEqual(model.live, ""); XCTAssertEqual(model.liveTranslation, "")
        XCTAssertFalse(llmUsed)
        XCTAssertEqual(audio.finished, 1)
    }

    func testAConnectionDropShowsTheErrorAndKeepsThePairs() async throws {
        let session = FakeSpeechTranslation()
        let model = makeModel(translator: { session })
        model.start()
        try await wait(model.phase == .listening)
        session.yieldRecorded(until: 9_000)
        try await wait(model.lines.count >= 2)
        session.pair.continuation.yield(.failed(.connectionLost))
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.phase, .failed)
        XCTAssertEqual(model.issue?.message, "The translation connection ended. Check your network and start again.")
        XCTAssertEqual(model.lines.count, 2, "finished pairs stay on screen")
        XCTAssertGreaterThanOrEqual(session.closeCount, 1)
    }

    func testASocketThatEndsWithoutClosingIsAnErrorNotAHang() async throws {
        let session = FakeSpeechTranslation()
        let model = makeModel(translator: { session })
        model.start()
        try await wait(model.phase == .listening)
        session.pair.continuation.finish()
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.message, "The translation connection ended. Check your network and start again.")
    }

    func testARefusedKeyStopsBeforeAudioWithAKeyMessage() async throws {
        let audio = FixtureSubtitleAudio()
        let model = makeModel(translator: { throw SpeechTranslationFailure.refusedKey }, audio: audio)
        model.start()
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue, TranslationIssue(message: "OpenAI refused the API key. Check it in API & Models.",
                                                     feature: .subtitlesAudio))
        XCTAssertEqual(audio.started, 0, "system audio is never captured")
    }

    func testAnEmptyBalanceMidSessionNamesIt() async throws {
        let session = FakeSpeechTranslation()
        let model = makeModel(translator: { session })
        model.start()
        try await wait(model.phase == .listening)
        session.pair.continuation.yield(.failed(.noCredit))
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.feature, .subtitlesAudio)
        XCTAssertEqual(model.issue?.message,
                       "Your OpenAI account is out of credit. Add credit or choose another Subtitles audio model.")
    }

    func testAnUnsupportedTargetLanguageIsNamed() async throws {
        let model = makeModel(translator: { throw SpeechTranslationFailure.unsupportedLanguage })
        model.targetCode = "kk"
        model.start()
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.message, "OpenAI live translation does not support Kazakh. Choose another target language.")
    }

    func testAProviderThatNeverClosesIsBoundedByTheStopWatchdog() async throws {
        let session = FakeSpeechTranslation()
        session.closesOnEndInput = false
        let model = makeModel(translator: { session })
        model.start()
        try await wait(model.phase == .listening)
        session.yieldRecorded(until: 6_000)
        try await wait(!model.lines.isEmpty)
        model.stop()
        XCTAssertEqual(model.phase, .finishing)
        try await wait(model.phase == .failed, seconds: 12)
        XCTAssertEqual(model.issue?.message, "The speech provider did not finish in time. The completed subtitles are still here.")
        XCTAssertFalse(model.lines.isEmpty)
    }

    func testALongLiveOriginalShowsItsNewestWholeWords() {
        let heard = String(repeating: "word ", count: 30) + "last words here"
        let row = SubtitleCaption.rows(lines: [], live: heard).first
        XCTAssertEqual(row?.source.hasPrefix("…word"), true)
        XCTAssertEqual(row?.source.hasSuffix("last words here"), true)
        XCTAssertLessThanOrEqual(row?.source.count ?? 0, SubtitleCaption.liveSourceLimit + 1)
    }

    func testATranslationWithoutAnOriginalStillShows() async throws {
        let session = FakeSpeechTranslation()
        let model = makeModel(translator: { session })
        model.start()
        try await wait(model.phase == .listening)
        session.pair.continuation.yield(.translation("Привет.", elapsedMs: 600))
        session.pair.continuation.yield(.translation(" Как ", elapsedMs: 900))
        try await wait(!model.lines.isEmpty)
        let rows = SubtitleCaption.rows(lines: model.lines, live: model.live, liveTranslation: model.liveTranslation)
        XCTAssertEqual(rows.first?.source, "")
        XCTAssertEqual(rows.first?.translation, .text("Привет."))
        XCTAssertEqual(rows.last?.translation, .live("Как"))
        await model.cancel().value
    }
}

final class OpenAIRealtimeTranslateAdapterTests: XCTestCase {
    private func json(_ sent: StubWebSocketTransport.Sent) -> [String: Any]? {
        guard case .text(let text) = sent else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }

    private func open(_ transport: StubWebSocketTransport, deadline: Duration = .seconds(2)) async throws
        -> SpeechTranslationSession {
        var adapter = OpenAIRealtimeTranslateAdapter(transport: { transport })
        adapter.startDeadline = deadline
        return try await adapter.open(target: "ru")
    }

    func testStartAsksForTheTargetAndTheInputTranscript() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"type":"session.created","session":{"type":"translation"}}"#)
        transport.deliverText(#"{"type":"session.updated","session":{"type":"translation"}}"#)
        let session = try await open(transport)
        let update = try XCTUnwrap(json(transport.sent[0]))
        XCTAssertEqual(update["type"] as? String, "session.update")
        let audio = (update["session"] as? [String: Any])?["audio"] as? [String: Any]
        XCTAssertEqual((audio?["output"] as? [String: Any])?["language"] as? String, "ru")
        XCTAssertEqual(((audio?["input"] as? [String: Any])?["transcription"] as? [String: Any])?["model"] as? String,
                       "gpt-realtime-whisper")
        await session.close()
    }

    func testAudioIsUpsampledToTwoHundredMillisecondFramesAndCloseFlushes() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"type":"session.updated"}"#)
        let session = try await open(transport)
        // 9,600 bytes = 300 ms at 16 kHz -> 14,400 bytes at 24 kHz: one 200 ms frame, the rest waits.
        await session.sendAudio(Data(count: 9_600))
        var appends = transport.sent.compactMap(json).filter { $0["type"] as? String == "session.input_audio_buffer.append" }
        XCTAssertEqual(appends.count, 1)
        XCTAssertEqual(Data(base64Encoded: appends[0]["audio"] as? String ?? "")?.count, 9_600)
        await session.endInput()
        let sent = transport.sent.compactMap(json)
        appends = sent.filter { $0["type"] as? String == "session.input_audio_buffer.append" }
        XCTAssertEqual(appends.count, 2, "the rest is flushed before close")
        XCTAssertEqual(Data(base64Encoded: appends[1]["audio"] as? String ?? "")?.count, 4_800)
        XCTAssertEqual(sent.last?["type"] as? String, "session.close")
        XCTAssertEqual(session.acceptedAudioSeconds(), 0.3, accuracy: 0.001)
        transport.deliverText(#"{"type":"session.input_transcript.delta","delta":" Hello","elapsed_ms":200}"#)
        transport.deliverText(#"{"type":"session.output_transcript.delta","delta":"Привет","elapsed_ms":400}"#)
        transport.deliverText(#"{"type":"session.closed"}"#)
        var events: [SpeechTranslationEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.source(" Hello", elapsedMs: 200), .translation("Привет", elapsedMs: 400), .closed])
    }

    func testARefusedHandshakeIsARefusedKey() async throws {
        let transport = StubWebSocketTransport()
        transport.responseStatusCode = 401
        transport.deliver(.failure(URLError(.badServerResponse)))
        do {
            _ = try await open(transport)
            XCTFail("expected a refused key")
        } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .refusedKey)
        }
        XCTAssertTrue(transport.cancelled)
    }

    func testQuotaAndLanguageErrorsAtStartAreNamed() async throws {
        let quota = StubWebSocketTransport()
        quota.deliverText(#"{"type":"error","error":{"type":"insufficient_quota","code":"insufficient_quota","message":"x"}}"#)
        do { _ = try await open(quota); XCTFail() } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .noCredit)
        }
        let language = StubWebSocketTransport()
        language.deliverText(#"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_value","param":"session.audio.output.language","message":"x"}}"#)
        do { _ = try await open(language); XCTFail() } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .unsupportedLanguage)
        }
    }

    func testARecoverableErrorDoesNotEndTheSession() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"type":"session.updated"}"#)
        let session = try await open(transport)
        transport.deliverText(#"{"type":"error","error":{"type":"invalid_request_error","code":"invalid_event","message":"x"}}"#)
        transport.deliverText(#"{"type":"session.output_transcript.delta","delta":"Да","elapsed_ms":200}"#)
        var iterator = session.events.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .translation("Да", elapsedMs: 200))
        await session.close()
    }

    func testADroppedSocketMidSessionIsAConnectionLoss() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"type":"session.updated"}"#)
        let session = try await open(transport)
        transport.deliver(.failure(URLError(.networkConnectionLost)))
        var events: [SpeechTranslationEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.failed(.connectionLost)])
    }

    func testNoAnswerAtStartTimesOut() async throws {
        let transport = StubWebSocketTransport()
        let started = Date()
        do { _ = try await open(transport, deadline: .milliseconds(200)); XCTFail() } catch let failure as SpeechTranslationFailure {
            XCTAssertEqual(failure, .connectionLost)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}

final class SpeechTranslationRoutingTests: XCTestCase {
    func testOnlySubtitlesAudioOffersOpenAISpeechTranslation() {
        XCTAssertEqual(AIFeature.subtitlesAudio.modelUse(on: .openAI), .speechTranslation)
        for feature in AIFeature.activeCases where feature != .subtitlesAudio {
            XCTAssertNotEqual(feature.modelUse(on: .openAI), .speechTranslation, feature.rawValue)
        }
        XCTAssertNil(AIFeature.dropFast.modelUse(on: .openAI))
        XCTAssertEqual(ModelRegistry.recommended(for: .subtitlesAudio, kind: .openAI), "gpt-realtime-translate")
        XCTAssertTrue(ModelRegistry.isVerified("gpt-realtime-translate", kind: .openAI, use: .speechTranslation))
    }

    func testTheOpenAICatalogListsTranslationOnlyForSpeechTranslation() throws {
        let body = #"{"data":[{"id":"gpt-realtime-translate","created":1777950216},{"id":"gpt-realtime-2"},{"id":"gpt-6"}]}"#
        let models = try ModelCatalogFetcher.parseOpenAI(Data(body.utf8))
        XCTAssertEqual(models.first { $0.id == "gpt-realtime-translate" }?.uses, [.speechTranslation])
        XCTAssertNil(models.first { $0.id == "gpt-realtime-2" })
        XCTAssertEqual(models.first { $0.id == "gpt-6" }?.uses?.contains(.speechTranslation), false)
    }

    func testCostsEstimateAnHourAtThreeDollarsSix() {
        let context = AIUsageContext(feature: .subtitlesAudio, account: .openAI, model: "gpt-realtime-translate")
        let event = AIUsageEvent.speech(context, seconds: 3_600)
        XCTAssertEqual(event.amount ?? 0, 3.06, accuracy: 0.0001)
        XCTAssertEqual(event.basis, .estimated)
    }
}

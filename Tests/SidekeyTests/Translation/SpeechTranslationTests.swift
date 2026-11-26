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

    func yieldRecorded(from first: Int = .min, until millis: Int = .max) {
        for event in OpenAITranslateRecordedSession.events where event.at > first && event.at <= millis {
            switch event.stream {
            case .source: pair.continuation.yield(.source(event.text, elapsedMs: event.elapsed))
            case .translation: pair.continuation.yield(.translation(event.text, elapsedMs: event.elapsed))
            }
        }
    }
}

@MainActor
final class SpeechTranslationModelTests: XCTestCase {
    private func makeModel(
        translator: @escaping () async throws -> SpeechTranslationSession,
        audio: FixtureSubtitleAudio = FixtureSubtitleAudio(),
        stopDeadline: Duration = .seconds(10)
    ) -> LiveSubtitleModel {
        let model = LiveSubtitleModel(
            flushInterval: .milliseconds(5), connectionTimeout: .seconds(5), stopDeadline: stopDeadline,
            makeAudio: { audio },
            openTranslator: { _, _ in try await translator() }
        )
        model.sourceCode = "en"
        model.targetCode = "ru"
        return model
    }

    /// Returns as soon as the condition holds. The deadline only matters on a loaded
    /// Mac (the build queue saw load 317 on 14 cores), so it is generous.
    // WHY: .project-docs/decisions/2026-11-26-test-suite-speed.md
    /// A deadline that runs out fails the test: a wait that silently timed out
    /// used to cost the whole deadline and then pass.
    private func wait(_ condition: @autoclosure () -> Bool, seconds: Double = 30,
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "condition never became true", file: file, line: line)
    }

    func testRecordedSessionBecomesPairsAndStopWaitsForTheProviderClose() async throws {
        let session = FakeSpeechTranslation()
        let audio = FixtureSubtitleAudio()
        let model = makeModel(translator: { session }, audio: audio)
        model.start()
        try await wait(model.phase == .listening)
        audio.pair.continuation.yield([0.1, 0.2, -0.1])
        try await wait(session.sentBytes > 0)
        session.yieldRecorded()
        // The recording's last sentence arrives after the seventh pair is closed.
        try await wait(model.lines.count >= 7 && !model.live.isEmpty && !model.liveTranslation.isEmpty)
        XCTAssertEqual(model.lines.count, 7)
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
        XCTAssertEqual(model.issue?.message, "The OpenAI connection ended. Check your network and start again.")
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
        XCTAssertEqual(model.issue?.message, "The OpenAI connection ended. Check your network and start again.")
    }

    func testARefusedKeyStopsBeforeAudioWithAKeyMessage() async throws {
        let audio = FixtureSubtitleAudio()
        let model = makeModel(translator: { throw SpeechTranslationFailure.refusedKey }, audio: audio)
        model.start()
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue, TranslationIssue(message: "OpenAI refused the API key. Check it in Keys & models.",
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
                       "Your OpenAI account is out of credit. Add credit to use Subtitles.")
    }

    func testAnUnsupportedTargetLanguageIsNamed() async throws {
        let model = makeModel(translator: { throw SpeechTranslationFailure.unsupportedLanguage })
        model.targetCode = "kk"
        model.start()
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.message, "OpenAI live translation does not support Kazakh. Choose another target language.")
    }

    /// Stop shows a stopped session at once: the recorded provider took 5.7 s
    /// from session.close to session.closed, and the overlay used to show a
    /// spinner all that time. The last translation still settles after it,
    /// and Start right away drops that tail and begins a new session.
    func testStopShowsAStoppedSessionAtOnceAndTheTailSettlesAfter() async throws {
        let first = FakeSpeechTranslation()
        first.closesOnEndInput = false // a provider still finishing
        let second = FakeSpeechTranslation()
        var sessions = [first, second]
        let model = makeModel(translator: { sessions.removeFirst() })
        model.start()
        try await wait(model.phase == .listening)
        first.pair.continuation.yield(.source(" Thank you all.", elapsedMs: 600))
        first.pair.continuation.yield(.source(" See", elapsedMs: 1_400))
        first.pair.continuation.yield(.translation("Спасибо всем", elapsedMs: 1_000))
        try await wait(model.liveTranslation == "Спасибо")

        model.stop()
        // Same run loop turn: no longer running, the stopped box and Start.
        XCTAssertFalse(model.phase.isRunning)
        XCTAssertEqual(model.sessionAction, .start, "Start shows in place of Stop at once")
        XCTAssertNil(SubtitleCaption.status(hasRows: false, phase: model.phase, issue: nil))

        // The tail arrives after Stop and settles in place.
        try await wait(first.endInputCount == 1)
        first.pair.continuation.yield(.translation(".", elapsedMs: 1_200))
        first.pair.continuation.yield(.closed)
        first.pair.continuation.finish()
        try await wait(model.phase == .idle)
        XCTAssertEqual(model.lines.map(\.translation), ["Спасибо всем."])

        // Start during a slow finish drops it and starts again at once.
        let slow = FakeSpeechTranslation()
        slow.closesOnEndInput = false
        sessions = [slow, second]
        model.start()
        try await wait(model.phase == .listening)
        model.stop()
        XCTAssertFalse(model.phase.isRunning)
        model.start()
        // Wait for the new session itself: its capture (the shared fixture,
        // already ended) finishes at once, so `listening` can last less than
        // one poll, and waiting for it used to run out the whole deadline.
        try await wait(sessions.isEmpty)
        XCTAssertEqual(slow.closeCount, 1, "the old session is closed")
        XCTAssertTrue(sessions.isEmpty, "a new session was opened")
        XCTAssertTrue(model.lines.isEmpty)
        model.cancel()
    }

    /// Start during Stop's tail, then closing the overlay before the old
    /// session is released: the queued Start never opens a session or capture.
    func testClosingWhileAStartWaitsForTheOldSessionStartsNothing() async throws {
        let first = FakeSpeechTranslation()
        first.closesOnEndInput = false
        var opened = 0
        let audio = FixtureSubtitleAudio()
        let model = makeModel(translator: { opened += 1; return opened == 1 ? first : FakeSpeechTranslation() }, audio: audio)
        model.start()
        try await wait(model.phase == .listening)
        model.stop()
        XCTAssertNotNil(model.start(), "Start queues behind the finishing session")
        await model.cancel().value // the overlay closes before the cleanup ends
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(opened, 1, "no second provider session")
        XCTAssertFalse(model.phase.isRunning)
        XCTAssertFalse(model.phase.isActive)
    }

    func testAProviderThatNeverClosesIsBoundedByTheStopWatchdog() async throws {
        let session = FakeSpeechTranslation()
        session.closesOnEndInput = false
        // The product waits 10 s; the rule under test is the same at 200 ms.
        let model = makeModel(translator: { session }, stopDeadline: .milliseconds(200))
        model.start()
        try await wait(model.phase == .listening)
        session.yieldRecorded(until: 6_000)
        try await wait(!model.lines.isEmpty)
        model.stop()
        XCTAssertEqual(model.phase, .finishing)
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.message, "The speech provider did not finish in time. The completed subtitles are still here.")
        XCTAssertFalse(model.lines.isEmpty)
    }

    func testAConnectionLostAfterStopKeepsTheTranslatedTailAndSaysSo() async throws {
        let session = FakeSpeechTranslation()
        session.closesOnEndInput = false
        let model = makeModel(translator: { session })
        model.start()
        try await wait(model.phase == .listening)
        session.pair.continuation.yield(.source(" Thank you all", elapsedMs: 600))
        session.pair.continuation.yield(.translation("Спасибо всем", elapsedMs: 1_000))
        session.pair.continuation.yield(.translation(" и до вст", elapsedMs: 1_200))
        try await wait(model.liveTranslation == "Спасибо всем и до")
        model.stop()
        try await wait(session.endInputCount == 1)
        session.pair.continuation.yield(.failed(.connectionLost))
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.message, "The OpenAI connection ended. Check your network and start again.")
        XCTAssertEqual(model.lines.map(\.source), ["Thank you all"])
        XCTAssertEqual(model.lines.map(\.translation), ["Спасибо всем и до"], "kept in whole words")
    }

    func testAStreamThatEndsAfterStopWithoutClosingIsNotComplete() async throws {
        let session = FakeSpeechTranslation()
        session.closesOnEndInput = false
        let model = makeModel(translator: { session })
        model.start()
        try await wait(model.phase == .listening)
        session.pair.continuation.yield(.translation("Привет.", elapsedMs: 600))
        model.stop()
        try await wait(session.endInputCount == 1)
        session.pair.continuation.finish()
        try await wait(model.phase == .failed)
        XCTAssertEqual(model.issue?.message, "The OpenAI connection ended. Check your network and start again.")
        XCTAssertEqual(model.lines.map(\.translation), ["Привет."])
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

    /// The start deadline is long unless a test is about it: a handshake answered at
    /// once must not lose to the timer on a loaded Mac.
    private func open(_ transport: StubWebSocketTransport, deadline: Duration = .seconds(30)) async throws
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

    /// The capture is already 24 kHz: its bytes go out unchanged, in 200 ms
    /// frames, the rest flushed at close.
    func testTwentyFourKilohertzAudioGoesOutUnchangedInTwoHundredMillisecondFrames() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"type":"session.updated"}"#)
        let session = try await open(transport)
        // 14,400 bytes = 300 ms at 24 kHz: one 200 ms frame, the rest waits.
        let pcm = Data((0..<14_400).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        await session.sendAudio(pcm)
        var appends = transport.sent.compactMap(json).filter { $0["type"] as? String == "session.input_audio_buffer.append" }
        XCTAssertEqual(appends.count, 1)
        XCTAssertEqual(Data(base64Encoded: appends[0]["audio"] as? String ?? ""), pcm.prefix(9_600))
        await session.endInput()
        let sent = transport.sent.compactMap(json)
        appends = sent.filter { $0["type"] as? String == "session.input_audio_buffer.append" }
        XCTAssertEqual(appends.count, 2, "the rest is flushed before close")
        XCTAssertEqual(Data(base64Encoded: appends[1]["audio"] as? String ?? ""), pcm.suffix(4_800))
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

    /// Stop sends session.close; only session.closed is a clean ending. A
    /// socket lost before it may have dropped the last translation.
    /// (Regressions found by the integration builder, ticket #360.)
    func testNetworkLossAfterSessionCloseRequestIsNotCleanCompletion() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"type":"session.updated"}"#)
        let session = try await open(transport)
        await session.endInput()
        transport.deliver(.failure(URLError(.networkConnectionLost)))
        var events: [SpeechTranslationEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.failed(.connectionLost)])
        await session.close()
    }

    func testSessionCloseSendFailureIsNotCleanCompletion() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"type":"session.updated"}"#)
        let session = try await open(transport)
        transport.sendError = URLError(.networkConnectionLost)
        await session.endInput()
        var events: [SpeechTranslationEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.failed(.connectionLost)])
        await session.close()
    }

    func testTheAppsOwnCloseEndsQuietly() async throws {
        let transport = StubWebSocketTransport()
        transport.deliverText(#"{"type":"session.updated"}"#)
        let session = try await open(transport)
        await session.close()
        var events: [SpeechTranslationEvent] = []
        for await event in session.events { events.append(event) }
        XCTAssertEqual(events, [.closed])
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
    /// It is the Audio translate slot's fixed model, never a picked route
    /// (`SubtitleAudioTranslateTests`); the registry still knows it.
    func testTheTranslateModelStaysKnownButIsNoPickerModel() {
        XCTAssertNil(AIFeature.subtitlesAudio.modelUse(on: .openAI))
        // OpenAI serves Drop's live speech again, but never with the translate
        // model: it is no speech-to-text model.
        // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
        XCTAssertEqual(AIFeature.dropFast.modelUse(on: .openAI), .realtimeSTT)
        XCTAssertFalse(ModelRegistry.isVerified("gpt-realtime-translate", kind: .openAI, use: .realtimeSTT))
        XCTAssertEqual(SubtitleAudioTranslate.model, "gpt-realtime-translate")
        XCTAssertTrue(ModelRegistry.isVerified("gpt-realtime-translate", kind: .openAI, use: .speechTranslation))
    }

    func testTheOpenAICatalogListsTranslationOnlyForSpeechTranslation() throws {
        let body = #"{"data":[{"id":"gpt-realtime-translate","created":1777950216},{"id":"gpt-realtime-2"},{"id":"gpt-6"}]}"#
        let models = try ModelCatalogFetcher.parseOpenAI(Data(body.utf8))
        XCTAssertEqual(models.first { $0.id == "gpt-realtime-translate" }?.uses, [.speechTranslation])
        XCTAssertNil(models.first { $0.id == "gpt-realtime-2" })
        XCTAssertEqual(models.first { $0.id == "gpt-6" }?.uses?.contains(.speechTranslation), false)
    }

    // OpenAI speech: published per-minute prices, an unknown model unpriced.
    // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
    func testOpenAISpeechCostsAreEstimatedPerMinute() {
        for (model, hour) in [("gpt-live-transcribe", 1.02), ("gpt-transcribe", 0.27), ("gpt-4o-mini-transcribe", 0.18)] {
            let event = AIUsageEvent.speech(AIUsageContext(feature: .dropFast, account: .openAI, model: model), seconds: 3_600)
            XCTAssertEqual(event.amount ?? -1, hour, accuracy: 0.0001, model)
            XCTAssertEqual(event.basis, .estimated)
        }
        let unknown = AIUsageEvent.speech(AIUsageContext(feature: .dropFast, account: .openAI, model: "gpt-9-transcribe"), seconds: 60)
        XCTAssertNil(unknown.amount)
        XCTAssertEqual(unknown.basis, .unavailable)
    }

    func testOpenAISpeechModelsAreClassified() throws {
        let body = #"{"data":[{"id":"gpt-live-transcribe"},{"id":"gpt-realtime-whisper"},{"id":"gpt-transcribe"},{"id":"whisper-1"},{"id":"gpt-4o-transcribe-diarize"},{"id":"gpt-4o-mini-transcribe-2025-12-15"}]}"#
        let models = try ModelCatalogFetcher.parseOpenAI(Data(body.utf8))
        // Two OpenAI speech models: live and recorded. The rest are left out.
        // WHY: .project-docs/decisions/2026-11-22-openai-speech-provider.md
        XCTAssertEqual(models.first { $0.id == "gpt-live-transcribe" }?.uses, [.realtimeSTT])
        XCTAssertEqual(models.first { $0.id == "gpt-transcribe" }?.uses, [.asyncSTT])
        for retired in ["gpt-realtime-whisper", "whisper-1", "gpt-4o-mini-transcribe-2025-12-15"] {
            XCTAssertNil(models.first { $0.id == retired }, retired)
        }
        XCTAssertNil(models.first { $0.id == "gpt-4o-transcribe-diarize" }, "no realtime speaker labels")
    }

    func testCostsEstimateAnHourAtThreeDollarsSix() {
        let context = AIUsageContext(feature: .subtitlesAudio, account: .openAI, model: "gpt-realtime-translate")
        let event = AIUsageEvent.speech(context, seconds: 3_600)
        XCTAssertEqual(event.amount ?? 0, 3.06, accuracy: 0.0001)
        XCTAssertEqual(event.basis, .estimated)
    }
}

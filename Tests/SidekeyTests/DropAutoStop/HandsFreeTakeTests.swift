import XCTest
@testable import Sidekey

/// An auto-stop Drop take has no key release. The quiet rule alone ends it:
/// the provider's commits are live text, never the end of the take.
@MainActor
final class HandsFreeTakeTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - ElevenLabs: the provider never ends a take

    /// Scribe commits a segment at its ~36 s cap in the middle of a sentence,
    /// so its commit is never the end of a take, auto-stop or not.
    func testEveryTakeAsksForAManualCommit() {
        let url = query(ElevenLabsRealtimeURL.make(model: "scribe_v3_live", language: "ru", terms: ["Whytap"]))
        XCTAssertEqual(url["commit_strategy"], "manual")
        XCTAssertNil(url["vad_silence_threshold_secs"])
        XCTAssertEqual(url["model_id"], "scribe_v3_live")
        XCTAssertEqual(url["language_code"], "ru")
        XCTAssertEqual(url["no_verbatim"], "true")
    }

    func testProviderCommitsNeverEndATakeBeforeItsStop() async throws {
        let stub = StubWebSocketTransport()
        let adapter = ElevenLabsBYOKAdapter(model: "scribe_v3_live") { _, _ in stub }
        let session = try await adapter.open(language: nil, terms: [])
        var events = session.events.makeAsyncIterator()
        stub.deliverText(#"{"message_type":"committed_transcript","text":"первая часть"}"#)
        let first = await events.next()
        XCTAssertEqual(first, .final("первая часть"))
        stub.deliverText(#"{"message_type":"partial_transcript","text":"вторая"}"#)
        let next = await events.next()
        XCTAssertEqual(next, .partial("вторая"))  // not .done: the take goes on
        await session.close()
    }

    // MARK: - A dictation longer than one provider segment

    /// The reported failure: with auto-stop on, a take was cut and pasted at
    /// ~36 s of continuous speech. A segment commit is live text like any
    /// other; only quiet ends the take, and the stop delivers every segment.
    func testASegmentCommitMidSpeechKeepsAnAutoStopTakeRunning() async {
        let upstream = DirectProviderStreamingSessionTests.FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: DirectProviderStreamingSessionTests.FakeAudio(),
            adapter: PlainAdapter(session: upstream), language: nil, terms: []
        )
        var updates: [String] = []
        var clock: TimeInterval = 0
        var rule = DropAutoStopRule(now: 0, quietAfterSpeech: 1.5)
        session.onTranscriptUpdate = {
            updates.append($0)
            rule.transcriptChanged($0, now: clock)
        }
        let finished = Finished()
        let run = Task<StreamingSessionResult, Never> {
            let result = await session.run()
            await finished.set()
            return result
        }
        try? await Task.sleep(for: .milliseconds(30))

        clock = 35
        upstream.cont.yield(.partial("первая часть"))
        clock = 36
        upstream.cont.yield(.final("первая часть"))
        for _ in 0..<100 where updates.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        clock = 37
        upstream.cont.yield(.partial("вторая"))
        for _ in 0..<100 where updates.count < 3 { try? await Task.sleep(for: .milliseconds(10)) }

        XCTAssertEqual(updates.last, "первая часть вторая")
        let endedEarly = await finished.value
        XCTAssertFalse(endedEarly, "the provider's segment commit must not end the take")
        XCTAssertEqual(rule.decision(now: 38), .keepListening)
        XCTAssertEqual(rule.decision(now: 39), .finish)

        await session.stop()
        upstream.cont.yield(.done("первая часть вторая часть"))
        let result = await run.value
        XCTAssertEqual(result, .transcript("первая часть вторая часть"))
    }

    private actor Finished {
        private(set) var value = false
        func set() { value = true }
    }

    // MARK: - What the auto-stop rule can see and recover

    private struct PlainAdapter: BYOKTranscriptionAdapter {
        let session: DirectProviderStreamingSessionTests.FakeSession
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession { session }
    }

    /// Deepgram-style upstream: words arrive only as finals. The live
    /// transcript must still move, or the end rule would see silence.
    func testFinalOnlySpeechReachesTheLiveTranscriptAndEndsTheTakeNormally() async {
        let upstream = DirectProviderStreamingSessionTests.FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: DirectProviderStreamingSessionTests.FakeAudio(),
            adapter: PlainAdapter(session: upstream), language: nil, terms: []
        )
        var updates: [String] = []
        var endpointer = DropAutoStopRule(now: 0)
        session.onTranscriptUpdate = {
            updates.append($0)
            endpointer.transcriptChanged($0, now: 1)
        }
        let run = Task { await session.run() }
        try? await Task.sleep(for: .milliseconds(30))
        upstream.cont.yield(.final("напиши письмо"))
        upstream.cont.yield(.final("Ярославу"))
        for _ in 0..<100 where updates.count < 2 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(updates, ["напиши письмо", "напиши письмо Ярославу"])
        // Words were seen: quiet ends the take, the no-speech window does not.
        XCTAssertEqual(endpointer.decision(now: 2.9), .keepListening)
        XCTAssertEqual(endpointer.decision(now: 3), .finish)

        await session.stop()
        upstream.cont.yield(.done("напиши письмо Ярославу"))
        let result = await run.value
        XCTAssertEqual(result, .transcript("напиши письмо Ярославу"))
    }

    /// The connection drops before any word. The end rule stops the take
    /// (never cancels), so the session resolves `.degraded` and the retained
    /// audio goes to batch recovery, exactly as after a key release.
    func testTransportLossBeforeTheFirstWordIsRecoveredByTheStop() async {
        let retained = Data([0x01, 0x02, 0x03, 0x04])
        let audio = CapturingStubAudioSource(captured: retained)
        let upstream = DirectProviderStreamingSessionDegradedTests.DrivableUpstream()
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: DirectProviderStreamingSessionDegradedTests.DrivableAdapter(session: upstream),
            language: nil, terms: [], resilient: true
        )
        var endpointer = DropAutoStopRule(now: 0)
        session.onTranscriptUpdate = { endpointer.transcriptChanged($0, now: 1) }
        let run = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(for: .milliseconds(40))
        upstream.emit(.error("transport"))
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(audio.didStop, "capture goes on after the connection drops")

        // No word ever arrived: the rule stops the take, it does not cancel it.
        XCTAssertEqual(endpointer.decision(now: DropAutoStopRule.noSpeechTimeout - 0.1), .keepListening)
        XCTAssertEqual(endpointer.decision(now: DropAutoStopRule.noSpeechTimeout), .finish)
        await session.stop()
        let result = await run.value
        XCTAssertEqual(result, .degraded)
        XCTAssertEqual(session.capturedAudioPCM16(), retained)
    }
}

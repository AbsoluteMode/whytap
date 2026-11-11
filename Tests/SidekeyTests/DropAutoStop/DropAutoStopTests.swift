import XCTest
@testable import Sidekey

/// Drop "stop automatically": one press starts the take, and it ends when
/// the speaker has finished.
@MainActor
final class DropAutoStopTests: XCTestCase {
    // MARK: - When the take ends

    func testTakeStopsWhenTheTranscriptGoesQuietAfterSpeech() {
        var rule = DropAutoStopRule(now: 100)
        XCTAssertEqual(rule.decision(now: 101), .keepListening)
        rule.transcriptChanged("привет", now: 102)
        rule.transcriptChanged("привет как дела", now: 103)
        XCTAssertEqual(rule.decision(now: 104.9), .keepListening)
        XCTAssertEqual(rule.decision(now: 105), .finish)
    }

    func testRepeatedIdenticalPartialsDoNotKeepTheTakeOpen() {
        var rule = DropAutoStopRule(now: 0)
        rule.transcriptChanged("готово", now: 1)
        rule.transcriptChanged(" готово ", now: 2.5)
        XCTAssertEqual(rule.decision(now: 3), .finish)
    }

    /// Pressed and said nothing: an ordinary stop after the no-speech window
    /// (silence pastes nothing; a dropped connection is still recovered).
    func testPressWithoutSpeechStopsAfterTheNoSpeechWindow() {
        var rule = DropAutoStopRule(now: 0)
        rule.transcriptChanged("   ", now: 3)
        XCTAssertEqual(rule.decision(now: 4.9), .keepListening)
        XCTAssertEqual(rule.decision(now: 5), .finish)
        XCTAssertLessThan(DropAutoStopRule.noSpeechTimeout, DirectProviderStreamingSession.defaultStallSeconds)
    }

    func testSpeechStartingLateCountsFromItsLastWord() {
        var rule = DropAutoStopRule(now: 0)
        rule.transcriptChanged("да", now: 4.5)
        XCTAssertEqual(rule.decision(now: 6), .keepListening)
        XCTAssertEqual(rule.decision(now: 6.5), .finish)
    }

    /// A deliberate long dictation is never cut by the rule while words keep
    /// coming: only the hotkey's own cap applies.
    func testLongDictationWithoutPausesIsNotCut() {
        var rule = DropAutoStopRule(now: 0)
        for second in 1...300 {
            rule.transcriptChanged("слово \(second)", now: TimeInterval(second))
            XCTAssertEqual(rule.decision(now: TimeInterval(second) + 0.9), .keepListening)
        }
    }

    func testCalibratedTimingsApplyAndBadValuesFallBack() {
        var quick = DropAutoStopRule(now: 0, quietAfterSpeech: 0.8)
        quick.transcriptChanged("готово", now: 1)
        XCTAssertEqual(quick.decision(now: 1.7), .keepListening)
        XCTAssertEqual(quick.decision(now: 1.8), .finish)

        let suite = "drop-autostop-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DropAutoStopTuning.quietSeconds(defaults), 2)
        XCTAssertEqual(DropAutoStopTuning.providerSilenceSeconds(defaults), 1.5)
        defaults.set(1.2, forKey: DropAutoStopTuning.quietSecondsKey)
        defaults.set(0.9, forKey: DropAutoStopTuning.providerSilenceSecondsKey)
        XCTAssertEqual(DropAutoStopTuning.quietSeconds(defaults), 1.2)
        XCTAssertEqual(DropAutoStopTuning.providerSilenceSeconds(defaults), 0.9)
        for bad in [0.0, -1, 99, Double.nan] {
            defaults.set(bad, forKey: DropAutoStopTuning.quietSecondsKey)
            defaults.set(bad, forKey: DropAutoStopTuning.providerSilenceSecondsKey)
            XCTAssertEqual(DropAutoStopTuning.quietSeconds(defaults), 2)
            XCTAssertEqual(DropAutoStopTuning.providerSilenceSeconds(defaults), 1.5)
        }
        defaults.set("fast", forKey: DropAutoStopTuning.quietSecondsKey)
        XCTAssertEqual(DropAutoStopTuning.quietSeconds(defaults), 2)
    }

    // MARK: - Words that arrive before the watcher's first poll

    /// The first final lands before the 200 ms poll ever ran. It must count
    /// as speech: the take ends on the quiet path, not the no-speech one.
    func testWordsBeforeTheFirstPollAreSpeechNotSilence() {
        let watch = DropAutoStopWatch(quietSeconds: { 2 })
        // Callback first, exactly as the streaming session delivers it.
        watch.transcriptChanged("напиши письмо", now: 10.05)
        // The watcher wakes for the first time afterwards.
        XCTAssertEqual(watch.decision(now: 10.2), .keepListening)
        XCTAssertEqual(watch.decision(now: 12.0), .keepListening)
        XCTAssertEqual(watch.decision(now: 12.1), .finish, "2 s after the words, not 5 s after start")
    }

    func testRecordingStartSetsTheClockOnceAndLaterEventsDoNotMoveIt() {
        let watch = DropAutoStopWatch(quietSeconds: { 2 })
        watch.recordingBegan(now: 100)
        watch.recordingBegan(now: 103)          // a later poll must not restart it
        XCTAssertEqual(watch.decision(now: 104.9), .keepListening)
        XCTAssertEqual(watch.decision(now: 105), .finish, "no speech 5 s after the first start")
    }

    func testPollBeforeAnyWordStartsTheClockAndResetForgetsTheTake() {
        let watch = DropAutoStopWatch(quietSeconds: { 2 })
        XCTAssertEqual(watch.decision(now: 50), .keepListening)   // first poll, no words yet
        watch.transcriptChanged("да", now: 51)
        XCTAssertEqual(watch.decision(now: 53), .finish)

        watch.reset()
        // The next take starts clean: the old words and clock are gone.
        XCTAssertEqual(watch.decision(now: 200), .keepListening)
        XCTAssertEqual(watch.decision(now: 204.9), .keepListening)
        XCTAssertEqual(watch.decision(now: 205), .finish)
    }

    private struct FinalOnlyAdapter: BYOKTranscriptionAdapter {
        let session: DirectProviderStreamingSessionTests.FakeSession
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession { session }
    }

    /// The wiring with a fake upstream: the session's callback feeds the
    /// watch before any poll, and the take then stops as speech.
    func testFinalDeliveredBeforeTheWatcherWakesEndsTheTakeAsSpeech() async {
        let upstream = DirectProviderStreamingSessionTests.FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: DirectProviderStreamingSessionTests.FakeAudio(),
            adapter: FinalOnlyAdapter(session: upstream), language: nil, terms: []
        )
        let watch = DropAutoStopWatch(quietSeconds: { 2 })
        var clock: TimeInterval = 0
        var delivered = 0
        session.onTranscriptUpdate = {
            delivered += 1
            watch.transcriptChanged($0, now: clock)
        }
        let run = Task { await session.run() }
        try? await Task.sleep(for: .milliseconds(30))
        clock = 0.05
        upstream.cont.yield(.final("напиши письмо Ярославу"))
        for _ in 0..<100 where delivered == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(delivered, 1)

        // First poll at 200 ms, then the quiet path at 2 s after the words.
        XCTAssertEqual(watch.decision(now: 0.2), .keepListening)
        XCTAssertEqual(watch.decision(now: 2.0), .keepListening)
        XCTAssertEqual(watch.decision(now: 2.1), .finish)

        await session.stop()
        upstream.cont.yield(.done("напиши письмо Ярославу"))
        let result = await run.value
        XCTAssertEqual(result, .transcript("напиши письмо Ярославу"))
    }

    // MARK: - Which press starts such a take

    func testOnlyAToggleStartWithTheSettingOnBecomesAnAutoStopTake() {
        let live = FeatureRoute(account: .elevenLabs, model: "scribe_v3_live")
        func starts(
            enabled: Bool = true, gesture: HotkeyGesture = .tap,
            route: DropFlowRoute = .startStreamingSession, speech: FeatureRoute? = live
        ) -> Bool {
            AppDelegate.dropPressStartsAutoStopTake(
                enabled: enabled, gesture: gesture, route: route, speechRoute: speech
            )
        }
        XCTAssertTrue(starts())
        XCTAssertTrue(starts(route: .discardFailedTakeAndStart))
        XCTAssertTrue(starts(speech: FeatureRoute(account: .soniox, model: "stt-rt-v5")))
        XCTAssertTrue(starts(speech: nil), "an unset route explains itself at the start")

        XCTAssertFalse(starts(enabled: false))
        XCTAssertFalse(starts(gesture: .hold), "a hold ends on release")
        // The second press of a toggle is a stop, never a new auto-stop take.
        for route in [DropFlowRoute.stopStreamingSession, .stopRecordingAndTranscribe, .recordPendingStop, .noop] {
            XCTAssertFalse(starts(route: route), "\(route)")
        }
        // No words before a commit: nothing could show the speaker finished.
        XCTAssertFalse(starts(speech: FeatureRoute(account: .server(UUID()), model: "whisper")))
    }

    func testSettingIsOffUntilTheUserTurnsItOnAndPersists() {
        let suite = "drop-autostop-prefs-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = DropAutoStopPreferences(defaults: defaults)
        XCTAssertFalse(preferences.isEnabled)
        preferences.isEnabled = true
        XCTAssertTrue(DropAutoStopPreferences(defaults: defaults).isEnabled)
    }
}

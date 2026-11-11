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

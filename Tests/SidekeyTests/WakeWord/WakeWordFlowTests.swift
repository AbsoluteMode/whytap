import XCTest
@testable import Sidekey

@MainActor
final class WakeWordFlowTests: XCTestCase {
    // MARK: - End of a hands-free take

    func testTakeFinishesWhenTheTranscriptGoesQuietAfterSpeech() {
        var endpointer = WakeTakeEndpointer(now: 100)
        XCTAssertEqual(endpointer.decision(now: 101), .keepListening)
        endpointer.transcriptChanged("привет", now: 102)
        endpointer.transcriptChanged("привет как дела", now: 103)
        XCTAssertEqual(endpointer.decision(now: 104.9), .keepListening)
        XCTAssertEqual(endpointer.decision(now: 105), .finish)
    }

    func testCalibratedQuietTimeEndsTheTakeSoonerAndBadValuesFallBack() {
        var quick = WakeTakeEndpointer(now: 0, quietAfterSpeech: 0.8)
        quick.transcriptChanged("готово", now: 1)
        XCTAssertEqual(quick.decision(now: 1.7), .keepListening)
        XCTAssertEqual(quick.decision(now: 1.8), .finish)

        let suite = "wakeword-tuning-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WakeWordTuning.quietSeconds(defaults), 2)
        XCTAssertEqual(WakeWordTuning.providerSilenceSeconds(defaults), 1.5)
        defaults.set(1.2, forKey: WakeWordTuning.quietSecondsKey)
        defaults.set(0.9, forKey: WakeWordTuning.providerSilenceSecondsKey)
        XCTAssertEqual(WakeWordTuning.quietSeconds(defaults), 1.2)
        XCTAssertEqual(WakeWordTuning.providerSilenceSeconds(defaults), 0.9)
        for bad in [0.0, -1, 99, Double.nan] {
            defaults.set(bad, forKey: WakeWordTuning.quietSecondsKey)
            defaults.set(bad, forKey: WakeWordTuning.providerSilenceSecondsKey)
            XCTAssertEqual(WakeWordTuning.quietSeconds(defaults), 2)
            XCTAssertEqual(WakeWordTuning.providerSilenceSeconds(defaults), 1.5)
        }
        defaults.set("fast", forKey: WakeWordTuning.quietSecondsKey)
        XCTAssertEqual(WakeWordTuning.quietSeconds(defaults), 2)
    }

    func testRepeatedIdenticalPartialsDoNotKeepTheTakeOpen() {
        var endpointer = WakeTakeEndpointer(now: 0)
        endpointer.transcriptChanged("готово", now: 1)
        endpointer.transcriptChanged(" готово ", now: 2.5)
        XCTAssertEqual(endpointer.decision(now: 3), .finish)
    }

    func testFalseTriggerWithoutSpeechIsCancelledNotPasted() {
        var endpointer = WakeTakeEndpointer(now: 0)
        endpointer.transcriptChanged("   ", now: 3)
        XCTAssertEqual(endpointer.decision(now: 4.9), .keepListening)
        XCTAssertEqual(endpointer.decision(now: 5), .cancel)
    }

    func testSpeechStartingLateStillCountsFromItsLastWord() {
        var endpointer = WakeTakeEndpointer(now: 0)
        endpointer.transcriptChanged("да", now: 4.5)
        XCTAssertEqual(endpointer.decision(now: 6), .keepListening)
        XCTAssertEqual(endpointer.decision(now: 6.5), .finish)
    }

    /// A false trigger next to a TV: the transcript never goes quiet, so only
    /// the cap ends the take, long before the hotkey's 10-minute limit.
    func testNeverEndingSpeechIsCutAtTheCapAndDelivered() {
        var endpointer = WakeTakeEndpointer(now: 0)
        for second in 1...59 {
            endpointer.transcriptChanged("слово \(second)", now: TimeInterval(second))
            XCTAssertEqual(endpointer.decision(now: TimeInterval(second) + 0.5), .keepListening)
        }
        endpointer.transcriptChanged("ещё", now: 59.9)
        XCTAssertEqual(endpointer.decision(now: 60), .finish)
        XCTAssertLessThan(WakeTakeEndpointer.noSpeechTimeout, DirectProviderStreamingSession.defaultStallSeconds)
    }

    func testWakeWordStaysOffRoutesThatCannotShowTheSpeakerFinished() {
        XCTAssertTrue(AppDelegate.wakeWordCanEndTake(on: FeatureRoute(account: .elevenLabs, model: "scribe_v3_live")))
        XCTAssertTrue(AppDelegate.wakeWordCanEndTake(on: FeatureRoute(account: .soniox, model: "stt-rt-v5")))
        XCTAssertTrue(AppDelegate.wakeWordCanEndTake(on: nil))
        XCTAssertFalse(AppDelegate.wakeWordCanEndTake(on: FeatureRoute(account: .server(UUID()), model: "whisper")))
    }

    // MARK: - When the microphone may stay open

    func testListensOnlyWhenEnabledAwakeAndNothingElseCaptures() {
        func listen(
            enabled: Bool = true, asleep: Bool = false, phase: AppPhase = .idle,
            agent: AgentPhase = .idle, meeting: Bool = false, screenshot: Bool = false
        ) -> Bool {
            AppDelegate.wakeWordShouldListen(
                enabled: enabled, asleep: asleep, phase: phase, agentPhase: agent,
                meetingRecording: meeting, screenshotActive: screenshot
            )
        }
        XCTAssertTrue(listen())
        XCTAssertFalse(listen(enabled: false))
        XCTAssertFalse(listen(asleep: true))
        XCTAssertFalse(listen(meeting: true))
        XCTAssertFalse(listen(screenshot: true))
        for phase in [AppPhase.recording, .transcribing, .verifying, .inserting, .finishing, .deliveryFailed] {
            XCTAssertFalse(listen(phase: phase), "\(phase)")
        }
        for agent in [AgentPhase.textInputActive, .voiceRecording, .transcribing, .executing] {
            XCTAssertFalse(listen(agent: agent), "\(agent)")
        }
    }

    // MARK: - Pause for the builder's meeting gate

    func testPauseReleasesListeningAndEndsByItself() {
        var clock = Date(timeIntervalSince1970: 1_000)
        var notifications = 0
        let pause = WakeWordPause(now: { clock }, notify: { notifications += 1 })
        XCTAssertFalse(pause.isPaused)
        pause.setPaused(true)
        XCTAssertTrue(pause.isPaused)
        XCTAssertEqual(notifications, 1)
        clock += WakeWordPause.duration - 1
        XCTAssertTrue(pause.isPaused)
        clock += 1
        XCTAssertFalse(pause.isPaused, "a builder that never resumes cannot leave the wake word off")
        pause.setPaused(true)
        pause.setPaused(false)
        XCTAssertFalse(pause.isPaused)
        XCTAssertEqual(notifications, 3)
    }

    // MARK: - Where a wake word may start a take

    func testOnlyPositiveEvidenceOfAnEditableFieldCounts() {
        func editable(_ role: String?, _ subrole: String? = nil, value: Bool = false, selected: Bool = false) -> Bool {
            PasteTargetValidator.isPositivelyEditable(
                role: role, subrole: subrole, valueSettable: value, selectedTextSettable: selected
            )
        }
        // Focused editable fields.
        XCTAssertTrue(editable("AXTextField"))
        XCTAssertTrue(editable("AXTextArea"))
        XCTAssertTrue(editable("AXComboBox"))
        XCTAssertTrue(editable("AXGroup", "AXContentEditableElement"))
        XCTAssertTrue(editable("AXGroup", value: true))
        XCTAssertTrue(editable("AXWebArea", selected: true))
        // Focus that is not a text field.
        XCTAssertFalse(editable("AXButton"))
        XCTAssertFalse(editable("AXWebArea"))
        XCTAssertFalse(editable("AXWebArea", value: true))
        XCTAssertFalse(editable("AXWindow"))
        // Unknown focus: no role at all, whatever else is claimed.
        XCTAssertFalse(editable(nil, value: true, selected: true))
        XCTAssertFalse(editable("", "AXSearchField", value: true))
    }

    func testProcessWithoutAnyFocusNeverStartsAWakeWordTake() throws {
        // No such process: the permissive hint rule says yes, the strict one no.
        XCTAssertTrue(PasteTargetValidator.appHasFocusedTextInput(pid: .max))
        XCTAssertFalse(PasteTargetValidator.appHasFocusedTextInput(pid: .max, requiringEvidence: true))

        // A live process with no windows and no editable focus.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        XCTAssertFalse(PasteTargetValidator.appHasFocusedTextInput(
            pid: child.processIdentifier, requiringEvidence: true
        ))
        XCTAssertFalse(PasteTargetValidator.appHasFocusedTextInput(
            pid: child.processIdentifier, bundleIdentifier: "com.apple.finder", requiringEvidence: true
        ))
    }

    // MARK: - Microphone choice

    func testBluetoothDefaultInputFallsBackToBuiltInAndNeverOpensBluetooth() {
        for wired in [AudioTransportKind.builtin, .usb] {
            XCTAssertEqual(WakeWordMicOperator.chooseDevice(defaultInput: 7, defaultTransport: wired, builtIn: 3), 7)
        }
        // Bluetooth, Continuity and unidentified inputs are never held open.
        for wireless in [AudioTransportKind.bluetooth, .other, nil] {
            XCTAssertEqual(WakeWordMicOperator.chooseDevice(defaultInput: 7, defaultTransport: wireless, builtIn: 3), 3)
            XCTAssertNil(WakeWordMicOperator.chooseDevice(defaultInput: 7, defaultTransport: wireless, builtIn: nil))
        }
    }

    // MARK: - Preferences

    private func preferences() -> WakeWordPreferences {
        let suite = "wakeword-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return WakeWordPreferences(defaults: defaults)
    }

    func testWakeWordIsOffUntilTheUserTurnsItOn() {
        let preferences = preferences()
        XCTAssertFalse(preferences.isEnabled)
        XCTAssertEqual(preferences.phrases, ["WHY TAP", "WHY TAB"])
    }

    func testPhrasesKeepOnlyWhatTheModelCanSpellAndNeverBecomeEmpty() {
        let preferences = preferences()
        preferences.phrasesText = "wait up, вайтап; Wait  UP\nright up, tap 2"
        XCTAssertEqual(preferences.phrases, ["WAIT UP", "RIGHT UP"])
        XCTAssertEqual(preferences.phrasesText, "wait up, right up")
        XCTAssertEqual(WakeWordPreferences.rejectedEntries(in: "wait up, вайтап, tap 2, "), ["вайтап", "tap 2"])

        preferences.phrasesText = "привет"
        XCTAssertEqual(preferences.phrases, ["WHY TAP", "WHY TAB"])

        preferences.phrases = (1...20).map { "word " + String(repeating: "a", count: $0) }
        XCTAssertEqual(preferences.phrases.count, WakeWordPreferences.maximumPhrases)
    }

    func testChangesAreAnnouncedOnce() {
        let preferences = preferences()
        var count = 0
        let token = NotificationCenter.default.addObserver(
            forName: WakeWordPreferences.didChangeNotification, object: nil, queue: nil
        ) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        preferences.isEnabled = true
        preferences.isEnabled = true
        preferences.phrasesText = "wait up"
        preferences.phrasesText = "Wait Up"
        XCTAssertEqual(count, 2)
    }

    // MARK: - Listener

    private final class ScriptedSpotter: WakeWordSpotting {
        func accept(_ samples: [Float]) -> [String] { samples.first == 1 ? ["WHY TAP"] : [] }
    }

    /// Like the real microphone source: `stop()` does not finish the stream.
    private final class OpenEndedMic: MicSourcing, @unchecked Sendable {
        let samples: AsyncStream<[Float]>
        private let continuation: AsyncStream<[Float]>.Continuation
        init() { (samples, continuation) = AsyncStream<[Float]>.makeStream() }
        func start() async throws {}
        func stop() async {}
        func speak(_ value: Float) { continuation.yield([value]) }
    }

    private final class Holder: @unchecked Sendable {
        weak var spotter: ScriptedSpotter?
    }

    func testStoppingReleasesTheModelEvenThoughTheMicStreamNeverFinishes() async {
        let mic = OpenEndedMic()
        let holder = Holder()
        let listener = WakeWordListener(
            makeSpotter: { _ in
                let spotter = ScriptedSpotter()
                holder.spotter = spotter
                return spotter
            },
            makeMic: { mic }
        )
        var heard = 0
        listener.onWake = { _ in heard += 1 }
        listener.update(listenWith: .init(phrases: ["WHY TAP"], threshold: 0.1))
        await settle { listener.isListening }
        XCTAssertNotNil(holder.spotter)

        listener.update(listenWith: nil)
        await settle { holder.spotter == nil }
        XCTAssertNil(holder.spotter, "the reader task must end on stop, releasing the spotter")
        mic.speak(1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(heard, 0)
    }

    func testDeniedMicrophoneOrUnusableModelIsNotRetried() async {
        var builds = 0
        let mic = FakeMic()
        mic.failStart = true
        let listener = WakeWordListener(
            makeSpotter: { _ in ScriptedSpotter() },
            makeMic: { builds += 1; return mic }
        )
        listener.update(listenWith: .init(phrases: ["WHY TAP"], threshold: 0.1))
        await settle { mic.stops >= 1 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(builds, 1)
        XCTAssertFalse(listener.isListening)
        listener.update(listenWith: nil)
    }

    private final class FakeMic: MicSourcing, @unchecked Sendable {
        let samples: AsyncStream<[Float]>
        private let continuation: AsyncStream<[Float]>.Continuation
        private(set) var starts = 0
        private(set) var stops = 0
        var failStart = false

        init() { (samples, continuation) = AsyncStream<[Float]>.makeStream() }
        func start() async throws {
            starts += 1
            if failStart { throw MicCaptureError.permissionDenied }
        }
        func stop() async {
            stops += 1
            continuation.finish()
        }
        func speak(_ value: Float) { continuation.yield([value]) }
    }

    private func settle(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testListenerReportsThePhraseOnceThenRearmsAndReleasesTheMicWhenToldTo() async {
        let mic = FakeMic()
        var clock: TimeInterval = 0
        let listener = WakeWordListener(
            makeSpotter: { _ in ScriptedSpotter() }, makeMic: { mic }, now: { clock }
        )
        var heard: [String] = []
        listener.onWake = { heard.append($0) }
        let configuration = WakeWordListener.Configuration(phrases: ["WHY TAP"], threshold: 0.1)

        listener.update(listenWith: configuration)
        await settle { listener.isListening }
        XCTAssertTrue(listener.isListening)

        mic.speak(0)
        mic.speak(1)
        mic.speak(1)  // the phrase's echo inside the re-arm window
        await settle { heard.count >= 1 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(heard, ["WHY TAP"])

        clock = 3
        mic.speak(1)
        await settle { heard.count >= 2 }
        XCTAssertEqual(heard.count, 2)

        listener.update(listenWith: configuration)  // unchanged: no restart
        XCTAssertEqual(mic.starts, 1)

        listener.update(listenWith: nil)
        XCTAssertFalse(listener.isListening)
        await settle { mic.stops >= 1 }
        XCTAssertGreaterThanOrEqual(mic.stops, 1)
        mic.speak(1)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(heard.count, 2)
    }

    func testListenerStaysOffWhenTheMicrophoneOrModelIsUnavailable() async {
        let mic = FakeMic()
        mic.failStart = true
        let denied = WakeWordListener(makeSpotter: { _ in ScriptedSpotter() }, makeMic: { mic })
        denied.update(listenWith: .init(phrases: ["WHY TAP"], threshold: 0.1))
        await settle { mic.stops >= 1 }
        XCTAssertFalse(denied.isListening)

        let silentMic = FakeMic()
        let noModel = WakeWordListener(
            makeSpotter: { _ in throw WakeWordSpotter.Failure.modelMissing }, makeMic: { silentMic }
        )
        noModel.update(listenWith: .init(phrases: ["WHY TAP"], threshold: 0.1))
        await settle { silentMic.stops >= 1 }
        XCTAssertFalse(noModel.isListening)
        XCTAssertEqual(silentMic.starts, 0)
        denied.update(listenWith: nil)
        noModel.update(listenWith: nil)
    }
}

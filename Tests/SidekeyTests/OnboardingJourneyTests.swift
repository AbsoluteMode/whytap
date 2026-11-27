import XCTest
@testable import Sidekey

/// The way through the onboarding as a person meets it: which steps they see
/// for what they already had and what they choose, Back, the progress bar and
/// the automatic move after a success.
@MainActor
final class OnboardingJourneyTests: XCTestCase {
    private func steps(_ start: OnboardingStart = .cleanMac, _ progress: OnboardingProgress = .init()) -> [OnboardingStep] {
        OnboardingJourney.steps(start: start, progress: progress)
    }

    // MARK: - Which steps

    func testACleanMacBeforeAnyChoiceSeesEveryStepButTheConditionalOnes() {
        XCTAssertEqual(steps(), [.language, .source, .speechKey, .llmKey, .keyboard, .microphone,
                                 .screenRecording, .toolbox, .thanks])
    }

    func testOnThisMacSkipsTheSpeechKeyAndBringsTryDrop() {
        let local = steps(.cleanMac, OnboardingProgress(source: .onThisMac, speechExpected: true))
        XCTAssertFalse(local.contains(.speechKey))
        XCTAssertTrue(local.contains(.llmKey), "a language model stays an option with local speech")
        XCTAssertTrue(local.contains(.tryDrop))
    }

    func testYourKeyKeepsTheSpeechKeyStep() {
        let api = steps(.cleanMac, OnboardingProgress(source: .yourKey))
        XCTAssertEqual(Array(api.prefix(4)), [.language, .source, .speechKey, .llmKey])
    }

    func testWithoutLocalSpeechThereIsNoSourceChoice() {
        var intel = OnboardingStart.cleanMac
        intel.onDeviceSupported = false
        XCTAssertEqual(Array(steps(intel).prefix(2)), [.language, .speechKey])
    }

    /// No web-search key step since 2026-11-27: the Agent runs on the user's
    /// own Claude Code or Codex, and a self-hosted language model goes on to
    /// the keyboard step like any other.
    func testASelfHostedLanguageModelHasNoExtraStep() {
        let selfHosted = steps(.cleanMac, OnboardingProgress(source: .yourKey))
        XCTAssertEqual(selfHosted[selfHosted.firstIndex(of: .llmKey)! + 1], .keyboard)
    }

    func testInputMonitoringOnlyWhenTheShortcutAsksForIt() {
        XCTAssertFalse(steps().contains(.inputMonitoring))
        let needed = steps(.cleanMac, OnboardingProgress(needsInputMonitoring: true))
        XCTAssertEqual(needed[needed.firstIndex(of: .microphone)! + 1], .inputMonitoring)
    }

    func testEverythingDoneBeforeShowsOnlyTheTour() {
        let done = OnboardingStart(speechReady: true, llmReady: true, languageChosen: true,
                                   keyboardGranted: true, microphoneGranted: true, screenRecordingGranted: true)
        XCTAssertEqual(steps(done), [.tryDrop, .toolbox, .thanks])
    }

    func testTryDropNeedsSpeechOnTheWay() {
        XCTAssertFalse(steps(.cleanMac, OnboardingProgress(source: .yourKey)).contains(.tryDrop))
        XCTAssertTrue(steps(.cleanMac, OnboardingProgress(source: .yourKey, speechExpected: true)).contains(.tryDrop))
    }

    // MARK: - Next and Back

    func testNextAndBackWalkTheSameList() {
        let way = steps(.cleanMac, OnboardingProgress(source: .yourKey, speechExpected: true))
        var forward: [OnboardingStep] = [way[0]]
        while let next = OnboardingJourney.next(after: forward.last!, in: way) { forward.append(next) }
        XCTAssertEqual(forward, way)
        var backward: [OnboardingStep] = [way.last!]
        while let previous = OnboardingJourney.previous(before: backward.last!, in: way) { backward.append(previous) }
        XCTAssertEqual(backward, way.reversed())
        XCTAssertNil(OnboardingJourney.previous(before: way[0], in: way), "the first step has no Back")
    }

    func testAStepAChoiceRemovedContinuesFromItsPlace() {
        // On the speech key step the person goes Back and picks On this Mac:
        // the speech key step leaves the way.
        let local = steps(.cleanMac, OnboardingProgress(source: .onThisMac, speechExpected: true))
        XCTAssertEqual(OnboardingJourney.next(after: .speechKey, in: local), .llmKey)
        XCTAssertEqual(OnboardingJourney.previous(before: .speechKey, in: local), .source)
    }

    // MARK: - Progress bar

    func testTheBarRunsFromEmptyToFull() {
        let way = steps()
        XCTAssertEqual(OnboardingJourney.fraction(at: way.first!, in: way), 0)
        XCTAssertEqual(OnboardingJourney.fraction(at: way.last!, in: way), 1)
        let values = way.map { OnboardingJourney.fraction(at: $0, in: way) }
        XCTAssertEqual(values, values.sorted(), "the bar never goes back while moving forward")
    }

    // MARK: - Segments

    func testSegmentsAreHonestAboutWhatWasDoneSkippedOrUnnecessary() {
        var start = OnboardingStart.cleanMac
        start.keyboardGranted = true
        let progress = OnboardingProgress(source: .onThisMac, speechExpected: true)
        let segments = OnboardingJourney.segments(start: start, progress: progress, current: .microphone,
                                                  done: [.language, .source])
        func state(_ step: OnboardingStep) -> OnboardingSegmentState? { segments.first { $0.step == step }?.state }
        XCTAssertEqual(segments.count, 10, "Input Monitoring and search are not segments unless needed; whytap.ai is part of the last step")
        XCTAssertEqual(state(.source), .completed)
        XCTAssertEqual(state(.speechKey), .bypassed, "On this Mac made the key unnecessary")
        XCTAssertEqual(state(.llmKey), .bypassed, "skipped, never a false done")
        XCTAssertEqual(state(.language), .completed)
        XCTAssertEqual(state(.keyboard), .completed, "granted before the window opened")
        XCTAssertEqual(state(.microphone), .current)
    }

    func testEveryStepHasADwellButTheLast() {
        XCTAssertEqual(OnboardingStep.source.dwell, 0.62)
        XCTAssertEqual(OnboardingStep.speechKey.dwell, 1.15, "the padlock opens and settles before the move")
        XCTAssertEqual(OnboardingStep.llmKey.dwell, 1.15, "the language model key has the same padlock")
        XCTAssertEqual(OnboardingStep.tryDrop.dwell, 1.35)
        for step in [OnboardingStep.toolbox, .thanks] {
            XCTAssertNil(step.dwell, "\(step) waits for Continue: no timer")
        }
    }

    // MARK: - Dwell latch

    func testTheDwellMovesOnOnceUnlessHeld() async throws {
        let gate = Gate()
        let dwell = OnboardingDwellController(wait: { _ in await gate.wait() }, reduceMotion: { false })
        var moves = 0
        dwell.schedule(0.78, next: "Language") { moves += 1 }
        XCTAssertEqual(dwell.state, .counting(next: "Language", progress: 0))
        try await waitUntil { gate.count > 0 }
        gate.open()
        try await waitUntil { moves == 1 }
        XCTAssertEqual(dwell.state, .idle)
    }

    func testHoldingStopsTheMoveUntilThePointerLeaves() async throws {
        let gate = Gate()
        let dwell = OnboardingDwellController(wait: { _ in await gate.wait() }, reduceMotion: { false })
        var moves = 0
        dwell.schedule(0.78, next: "Language") { moves += 1 }
        try await waitUntil { gate.count > 0 }
        dwell.latch()
        XCTAssertTrue(dwell.isLatched)
        gate.open()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(moves, 0, "held: no move however long")
        dwell.resume()
        try await waitUntil { gate.count > 0 }
        gate.open()
        try await waitUntil { moves == 1 }
    }

    func testReturnGoesOnAtOnceAndReviewNeverMovesByItself() async throws {
        let dwell = OnboardingDwellController(wait: { _ in }, reduceMotion: { false })
        var moves = 0
        dwell.review(next: "Language") { moves += 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(moves, 0)
        XCTAssertEqual(dwell.state, .reviewing(next: "Language"))
        dwell.commitNow()
        XCTAssertEqual(moves, 1)
        dwell.commitNow()
        XCTAssertEqual(moves, 1, "nothing pending after the move")
    }

    func testCancelledDwellNeverMoves() async throws {
        let gate = Gate()
        let dwell = OnboardingDwellController(wait: { _ in await gate.wait() }, reduceMotion: { false })
        var moves = 0
        dwell.schedule(0.78, next: "Language") { moves += 1 }
        try await waitUntil { gate.count > 0 }
        dwell.cancel() // Back
        gate.open()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(moves, 0)
    }

    func testOptionalAndInformationalSteps() {
        XCTAssertEqual(OnboardingStep.allCases.filter(\.isOptional), [.llmKey, .screenRecording, .tryDrop])
        XCTAssertEqual(OnboardingStep.allCases.filter(\.isInformational), [.toolbox, .thanks])
    }

    // MARK: - Helpers

    @MainActor
    private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }
        func wait() async { await withCheckedContinuation { waiting.append($0) } }
        func open() { let all = waiting; waiting = []; all.forEach { $0.resume() } }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(condition(), "Condition never became true", file: file, line: line)
    }
}

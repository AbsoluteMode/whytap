import XCTest
@testable import Sidekey

/// The way through the onboarding as a person meets it: which steps they see
/// for what they already had and what they choose, Back, the progress bar and
/// the automatic move after a success.
final class OnboardingJourneyTests: XCTestCase {
    private func steps(_ start: OnboardingStart = .cleanMac, _ progress: OnboardingProgress = .init()) -> [OnboardingStep] {
        OnboardingJourney.steps(start: start, progress: progress)
    }

    // MARK: - Which steps

    func testACleanMacBeforeAnyChoiceSeesEveryStepButTheConditionalOnes() {
        XCTAssertEqual(steps(), [.source, .speechKey, .llmKey, .language, .keyboard, .microphone,
                                 .screenRecording, .hotkeys, .toolbox, .help, .thanks])
    }

    func testOnThisMacSkipsTheSpeechKeyAndBringsTryDrop() {
        let local = steps(.cleanMac, OnboardingProgress(source: .onThisMac, speechExpected: true))
        XCTAssertFalse(local.contains(.speechKey))
        XCTAssertTrue(local.contains(.llmKey), "a language model stays an option with local speech")
        XCTAssertTrue(local.contains(.tryDrop))
    }

    func testYourKeyKeepsTheSpeechKeyStep() {
        let api = steps(.cleanMac, OnboardingProgress(source: .yourKey))
        XCTAssertEqual(Array(api.prefix(3)), [.source, .speechKey, .llmKey])
    }

    func testWithoutLocalSpeechThereIsNoSourceChoice() {
        var intel = OnboardingStart.cleanMac
        intel.onDeviceSupported = false
        XCTAssertEqual(steps(intel).first, .speechKey)
    }

    func testSearchAppearsOnlyWithALanguageModel() {
        XCTAssertFalse(steps().contains(.search))
        let withLLM = steps(.cleanMac, OnboardingProgress(source: .yourKey, hasLanguageModel: true))
        XCTAssertEqual(withLLM[withLLM.firstIndex(of: .llmKey)! + 1], .search)
        var ready = OnboardingStart.cleanMac
        ready.llmReady = true
        XCTAssertTrue(steps(ready).contains(.search), "an LLM set before the onboarding offers search too")
        ready.searchReady = true
        XCTAssertFalse(steps(ready).contains(.search))
    }

    func testInputMonitoringOnlyWhenTheShortcutAsksForIt() {
        XCTAssertFalse(steps().contains(.inputMonitoring))
        let needed = steps(.cleanMac, OnboardingProgress(needsInputMonitoring: true))
        XCTAssertEqual(needed[needed.firstIndex(of: .microphone)! + 1], .inputMonitoring)
    }

    func testEverythingDoneBeforeShowsOnlyTheTour() {
        let done = OnboardingStart(speechReady: true, llmReady: true, searchReady: true, languageChosen: true,
                                   keyboardGranted: true, microphoneGranted: true, screenRecordingGranted: true)
        XCTAssertEqual(steps(done), [.tryDrop, .hotkeys, .toolbox, .help, .thanks])
    }

    func testTryDropNeedsSpeechOnTheWay() {
        XCTAssertFalse(steps(.cleanMac, OnboardingProgress(source: .yourKey)).contains(.tryDrop))
        XCTAssertTrue(steps(.cleanMac, OnboardingProgress(source: .yourKey, speechExpected: true)).contains(.tryDrop))
    }

    // MARK: - Next and Back

    func testNextAndBackWalkTheSameList() {
        let way = steps(.cleanMac, OnboardingProgress(source: .yourKey, hasLanguageModel: true, speechExpected: true))
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

    // MARK: - Moving on by itself

    func testASuccessMovesOnOnceAfterTheBeat() {
        var advance = OnboardingAutoAdvance()
        XCTAssertTrue(advance.succeeded(.keyboard, current: .keyboard))
        XCTAssertFalse(advance.succeeded(.keyboard, current: .keyboard), "a second report schedules nothing more")
        XCTAssertTrue(advance.fire(current: .keyboard))
        XCTAssertFalse(advance.fire(current: .keyboard))
    }

    func testBackDuringTheBeatCancelsTheMove() {
        var advance = OnboardingAutoAdvance()
        XCTAssertTrue(advance.succeeded(.microphone, current: .microphone))
        advance.cancel() // Back
        XCTAssertFalse(advance.fire(current: .keyboard))
    }

    func testASuccessOfAnotherStepOrAnInformationalStepDoesNotMove() {
        var advance = OnboardingAutoAdvance()
        XCTAssertFalse(advance.succeeded(.microphone, current: .keyboard),
                       "a permission granted in System Settings while another step is shown")
        XCTAssertFalse(advance.succeeded(.hotkeys, current: .hotkeys))
    }

    func testOptionalAndInformationalSteps() {
        XCTAssertEqual(OnboardingStep.allCases.filter(\.isOptional), [.llmKey, .search, .screenRecording, .tryDrop])
        XCTAssertEqual(OnboardingStep.allCases.filter(\.isInformational), [.hotkeys, .toolbox, .help, .thanks])
    }
}

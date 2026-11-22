import XCTest
@testable import Sidekey

/// The standalone onboarding preview walks every step with its own fakes:
/// keys in memory, offline checks ("bad" keys refused), pretend permissions
/// and a Simulate Drop button, all in its own defaults suite. No window shows.
/// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingPreviewTests: XCTestCase {
    private func eventually(_ condition: @MainActor () -> Bool, timeout: Double = 6,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Condition never became true", file: file, line: line)
    }

    func testThePreviewWalksEveryStepWithoutTheSystem() async throws {
        let suite = "OnboardingPreviewTests-\(UUID().uuidString)"
        let session = OnboardingPreviewSession(suiteName: suite)
        defer { session.clear() }
        let model = session.model
        XCTAssertTrue(model.isPreview)
        XCTAssertEqual(model.step, .source, "it starts at the first step")

        model.chooseYourKey()
        model.next()
        XCTAssertEqual(model.step, .speechKey)
        await model.useSpeechKey("bad-key", provider: .deepgram)
        XCTAssertEqual(model.outcome(.speechKey), .failed("Key not accepted"), "a key containing bad is refused")
        await model.useSpeechKey("sk-preview", provider: .elevenLabs)
        XCTAssertTrue(model.outcome(.speechKey).isDone)
        XCTAssertEqual(AIRoutingStore(defaults: UserDefaults(suiteName: suite)!).route(for: .dropFast)?.account, .elevenLabs,
                       "routes go to the preview's own suite")

        model.next()
        XCTAssertEqual(model.step, .llmKey)
        await model.useLLMKey("sk-ant", provider: .anthropic)
        XCTAssertTrue(model.outcome(.llmKey).isDone)
        model.next()
        XCTAssertEqual(model.step, .search)
        await model.useSearchKey("tvly-bad")
        XCTAssertFalse(model.outcome(.search).isDone, "the stubbed Tavily check refuses it")
        await model.useSearchKey("tvly-preview")
        XCTAssertTrue(model.outcome(.search).isDone, "the stubbed Tavily check passes without a network request")

        model.next()
        XCTAssertEqual(model.step, .language)
        model.setLanguage(nil)
        model.next()
        XCTAssertEqual(model.step, .keyboard)
        model.requestKeyboard()
        try await eventually { model.outcome(.keyboard).isDone }
        model.next()
        XCTAssertEqual(model.step, .microphone)
        model.requestMicrophone()
        try await eventually { model.outcome(.microphone).isDone }
        model.next()
        XCTAssertEqual(model.step, .screenRecording)
        model.requestScreenRecording()
        try await eventually { model.outcome(.screenRecording).isDone }
        model.next()
        XCTAssertEqual(model.step, .tryDrop)
        model.noteDictated()
        XCTAssertTrue(model.outcome(.tryDrop).isDone)
        for expected in [OnboardingStep.hotkeys, .toolbox, .help, .thanks] {
            model.next()
            XCTAssertEqual(model.step, expected)
        }
        model.back()
        XCTAssertEqual(model.step, .help, "Back works in the preview too")

        var finished = false
        model.onFinish = { finished = true }
        model.next()
        model.finish()
        XCTAssertTrue(finished)
    }

    func testThePreviewOnThisMacDownloadsOnATimer() async throws {
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
        defer { session.clear() }
        let model = session.model
        model.chooseOnThisMac()
        try await eventually { model.onDevice.status == .ready }
        try await eventually { model.outcome(.source) == .done("Speech on this Mac") }
    }
}

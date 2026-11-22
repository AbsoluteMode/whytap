import XCTest
@testable import Sidekey

/// The standalone onboarding preview walks every step with its own fakes:
/// keys in memory, offline checks (keys containing "bad" refused), pretend permissions
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
        try await eventually { model.step == .speechKey }
        await model.useSpeechKey("bad-key-0123456789abcdef", provider: .deepgram)
        XCTAssertEqual(model.keyProblems[.speechKey], .refused, "a key containing bad is refused")
        await model.useSpeechKey("sk-preview-0123456789abcdef", provider: .elevenLabs)
        XCTAssertTrue(model.outcome(.speechKey).isDone)
        XCTAssertEqual(AIRoutingStore(defaults: UserDefaults(suiteName: suite)!).route(for: .dropFast)?.account, .elevenLabs,
                       "routes go to the preview's own suite")

        model.next()
        XCTAssertEqual(model.step, .llmKey)
        await model.useLLMKey("sk-ant-0123456789abcdef", provider: .anthropic)
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

    func testEachKeyProblemIsNamedWithoutBlame() async throws {
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        let cases: [(String, OnboardingKeyProblem)] = [
            ("short-key", .format),
            ("key with spaces 0123456789", .format),
            ("bad-0123456789abcdef", .refused),
            ("credit-0123456789abcdef", .noCredit),
            ("noaccess-0123456789abcdef", .noSpeechAccess),
            ("offline-0123456789abcdef", .unreachable),
        ]
        for (key, expected) in cases {
            await model.useSpeechKey(key, provider: .deepgram)
            XCTAssertEqual(model.keyProblems[.speechKey], expected, key)
            XCTAssertEqual(model.outcome(.speechKey), .failed(expected.message(provider: "Deepgram")), key)
            XCTAssertFalse(model.keySaved(.deepgram), "a refused key is not saved: \(key)")
        }
        XCTAssertTrue(OnboardingKeyProblem.unreachable.offersRetry)
        XCTAssertFalse(OnboardingKeyProblem.refused.offersRetry)
        await model.useSpeechKey("good-0123456789abcdef", provider: .deepgram)
        XCTAssertNil(model.keyProblems[.speechKey], "a working key clears the problem")
        XCTAssertTrue(model.outcome(.speechKey).isDone)
    }

    func testOnlyRealKeyPrefixesPickTheProviderAndTheMiddleIsMasked() {
        let speech = [AIProviderKind.soniox, .deepgram, .elevenLabs].compactMap(OnboardingSpeechKeyProvider.of)
        XCTAssertEqual(OnboardingSpeechKeyProvider.detect("sk_0123456789abcdef", among: speech)?.provider.kind, .elevenLabs)
        XCTAssertNil(OnboardingSpeechKeyProvider.detect("0123456789abcdef0123", among: speech),
                     "Soniox and Deepgram keys have no prefix: the chosen tab decides")
        XCTAssertNil(OnboardingSpeechKeyProvider.detect("sk-proj-0123456789", among: speech), "OpenAI is not offered yet")
        let withOpenAI = speech + [OnboardingSpeechKeyProvider.of(.openAI)!]
        XCTAssertEqual(OnboardingSpeechKeyProvider.detect("sk-proj-0123456789", among: withOpenAI)?.provider.kind, .openAI)
        XCTAssertNil(OnboardingSpeechKeyProvider.detect("sk-ant-0123456789", among: withOpenAI), "an Anthropic key is not speech")

        let masked = OnboardingKeyMask.masked("sk_0123456789abcdefWXYZ", prefix: 3)
        XCTAssertTrue(masked.hasPrefix("sk_"))
        XCTAssertTrue(masked.hasSuffix("WXYZ"))
        XCTAssertFalse(masked.contains("0123"), "the middle is hidden")
    }
}

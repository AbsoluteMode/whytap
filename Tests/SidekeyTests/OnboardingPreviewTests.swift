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

    /// The owner saw a random string highlighted as OpenAI with "check it
    /// with OpenAI": only a key's own format names its provider.
    func testOnlyAKeysOwnFormatNamesItsProvider() throws {
        let speech = [AIProviderKind.soniox, .deepgram, .elevenLabs].compactMap(OnboardingKeyProvider.of)
        let elevenLabs = "sk_" + String(repeating: "0a", count: 24)
        XCTAssertEqual(OnboardingKeyProvider.detect(elevenLabs, among: speech)?.kind, .elevenLabs)
        XCTAssertEqual(OnboardingKeyProvider.detect(String(repeating: "0f", count: 20), among: speech)?.kind, .deepgram,
                       "Deepgram keys are 40 hexadecimal characters")
        for random in ["adsfdsfasdfasfafa", "adsfdsfasdfasfafaqwerty", "0123456789abcdef0123", "sk_short", "фываолдж0123456789abcdef"] {
            XCTAssertNil(OnboardingKeyProvider.detect(random, among: speech), "\(random) names nobody")
        }
        XCTAssertNil(OnboardingKeyProvider.detect("sk-proj-0123456789abcdef", among: speech), "OpenAI is not offered here")
        let withOpenAI = speech + [OnboardingKeyProvider.of(.openAI)!]
        XCTAssertEqual(OnboardingKeyProvider.detect("sk-proj-0123456789abcdef", among: withOpenAI)?.kind, .openAI)
        XCTAssertNil(OnboardingKeyProvider.detect("adsfdsfasdfasfafaqwerty", among: withOpenAI), "no guess at OpenAI")
        XCTAssertNil(OnboardingKeyProvider.detect("sk-ant-api03-0123456789abcdef", among: withOpenAI), "an Anthropic key is not speech")
        XCTAssertNil(OnboardingKeyProvider.detect("sk-or-v1-0123456789abcdef", among: withOpenAI), "an OpenRouter key is not speech")

        let llm = OnboardingJourneyModel.llmProviders.compactMap(OnboardingKeyProvider.of)
        XCTAssertEqual(OnboardingKeyProvider.detect("sk-ant-api03-0123456789abcdef", among: llm)?.kind, .anthropic)
        XCTAssertEqual(OnboardingKeyProvider.detect("sk-or-v1-0123456789abcdef", among: llm)?.kind, .openRouter)
        XCTAssertEqual(OnboardingKeyProvider.detect("sk-proj-0123456789abcdef", among: llm)?.kind, .openAI)
        XCTAssertNil(OnboardingKeyProvider.detect(elevenLabs, among: llm), "a speech key is not a language model")
        XCTAssertNil(OnboardingKeyProvider.detect("sk-ant-0123", among: llm), "too short to be a key")
    }

    /// Key-like input is closed like a secure field from the first character;
    /// anything else shows as typed and is named as a format problem.
    func testKeyLikeInputIsClosedFromTheFirstCharacterAndTypingKeepsTheCaret() async throws {
        for typed in ["фывааф", "фыва", "key with spaces 0123456789", "фываолдж0123456789abcdef", "key.with.dots"] {
            XCTAssertNil(OnboardingKeyMask.masked(typed), "\(typed) shows as typed")
        }
        XCTAssertEqual(OnboardingKeyMask.masked("adsfdsfasdfasfafa"), String(repeating: "•", count: 17))
        XCTAssertEqual(OnboardingKeyMask.masked("a"), "•", "closed from the first character")
        XCTAssertNil(OnboardingKeyMask.masked(""))
        // Typing a key by hand: closed at every length, one dot per character,
        // so the caret stays where the typed character is.
        let key = "sk_live0123456789abcdefWXYZ"
        for length in 1...key.count {
            let typed = String(key.prefix(length))
            let masked = try XCTUnwrap(OnboardingKeyMask.masked(typed))
            XCTAssertEqual(masked.count, typed.count, "same length, so the caret stays at \(length)")
            XCTAssertTrue(masked.allSatisfy { $0 == "•" }, "no character of the key shows at \(length)")
        }

        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        await model.useSpeechKey("фывааф", provider: .soniox)
        XCTAssertEqual(model.keyProblems[.speechKey], .format, "a typed word is a calm format problem, no request")
        XCTAssertEqual(model.outcome(.speechKey), .failed(OnboardingKeyProblem.format.message(provider: "Soniox")))
    }

    /// Return on a key that names nobody (no format, no picked mark) is a
    /// format problem; editing the key clears it; an accepted key stays.
    func testAKeyThatNamesNoProviderIsAFormatProblemUntilEdited() async throws {
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.rejectUnrecognizedKey(on: .speechKey)
        XCTAssertEqual(model.keyProblems[.speechKey], .unrecognized)
        XCTAssertEqual(model.outcome(.speechKey), .failed(OnboardingKeyProblem.unrecognized.message(provider: "")))
        XCTAssertFalse(OnboardingKeyProblem.unrecognized.offersRetry)
        model.keyEdited(on: .speechKey)
        XCTAssertNil(model.keyProblems[.speechKey], "a changed key is a new attempt")
        XCTAssertEqual(model.outcome(.speechKey), .idle)
        await model.useSpeechKey("good-0123456789abcdef", provider: .soniox)
        model.keyEdited(on: .speechKey)
        XCTAssertTrue(model.outcome(.speechKey).isDone, "typing never undoes an accepted key")
    }

    /// "Use your own server →" opens the server form in the preview's window;
    /// Back or Cancel returns to the same step, Save returns with it done.
    func testOwnServerOpensTheFormAndComesBack() async throws {
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.useOwnServer(.speech)
        XCTAssertEqual(model.serverForm, .speech)
        model.back()
        XCTAssertNil(model.serverForm, "Back closes the form first")
        XCTAssertEqual(model.step, .speechKey, "and stays on the key step")
        XCTAssertEqual(model.outcome(.speechKey), .idle, "nothing was saved")

        model.useOwnServer(.speech)
        var server = OnboardingServerDraft()
        server.address = "localhost:11434/v1"
        XCTAssertFalse(server.canSave, "a server needs a model")
        server.add("qwen3:8b", use: .llm)
        server.add("whisper-large-v3", use: .transcription)
        server.add("whisper-large-v3", use: .transcription)
        XCTAssertEqual(server.models.count, 2, "one model per use")
        XCTAssertEqual(server.name, "Ollama", "the name comes from the address")
        model.saveServer(server)
        XCTAssertNil(model.serverForm)
        XCTAssertEqual(model.outcome(.speechKey), .done("Ollama · whisper-large-v3"), "the speech model, not the LLM")
    }

    func testAServerIsNamedByItsAddress() {
        func name(_ address: String) -> String? { OnboardingServerDraft.url(from: address).map(OnboardingServerDraft.name(for:)) }
        XCTAssertEqual(name("http://localhost:1234/v1"), "LM Studio")
        XCTAssertEqual(name("http://127.0.0.1:8000/v1"), "127.0.0.1:8000")
        XCTAssertEqual(name("https://www.llm.example.com/v1"), "llm.example.com")
        XCTAssertEqual(name("gpu-box.local:8080"), "gpu-box.local:8080")
        XCTAssertNil(name("ftp://example.com"))
        XCTAssertNil(name("not an address"))
        XCTAssertNil(name(""))
    }
}

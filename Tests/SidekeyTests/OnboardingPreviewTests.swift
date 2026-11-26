import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import Sidekey
@testable import OnboardingPreviewKit

/// The standalone onboarding preview walks every step with its own fakes:
/// keys in memory, offline checks (keys containing "bad" refused), pretend permissions
/// and the Drop shortcut held in its window, all in its own defaults suite. No window shows.
/// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingPreviewTests: XCTestCase {
    /// The preview's fakes wait so a person can watch each state (a key check
    /// 0.7 s, System Settings 1.6 s, ...). The tests run every one of those
    /// delays and every dwell at a tenth: the same order of events, a tenth of
    /// the wall time. The dwell is still waited at once, independently of the
    /// animation's frame rate, which can be throttled in an unattended test process.
    // WHY: .project-docs/decisions/2026-11-26-test-suite-speed.md
    static let pace = 0.1

    private func makeSession(suiteName: String = "OnboardingPreviewTests-\(UUID().uuidString)",
                             skipLanguage: Bool = true) -> OnboardingPreviewSession {
        let session = OnboardingPreviewSession(suiteName: suiteName, dwellWait: { seconds in
            try? await Task.sleep(for: .seconds(seconds * Self.pace))
        }, pace: Self.pace)
        if skipLanguage, session.model.step == .language { session.model.skip() }
        return session
    }

    /// Returns as soon as the condition holds; the deadline only matters on a loaded Mac.
    private func eventually(_ condition: @MainActor () -> Bool, timeout: Double = 30,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Condition never became true", file: file, line: line)
    }

    // Builder review #503: the preview's system audio ask is simulated like
    // every permission there; no Core Audio tap starts.
    func testThePreviewAsksForSystemAudioWithoutHardware() async throws {
        let session = makeSession()
        defer { session.clear() }
        XCTAssertFalse(session.askedSystemAudio)
        session.model.askSystemAudio()
        try await eventually { session.askedSystemAudio }
    }

    func testThePreviewWalksEveryStepWithoutTheSystem() async throws {
        let suite = "OnboardingPreviewTests-\(UUID().uuidString)"
        let session = makeSession(suiteName: suite, skipLanguage: false)
        defer { session.clear() }
        let model = session.model
        XCTAssertTrue(model.isPreview)
        XCTAssertEqual(model.step, .language)
        model.setLanguage(nil)
        try await eventually { model.step == .source }

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
        XCTAssertEqual(model.step, .keyboard, "Anthropic searches the web itself: no Tavily step")
        model.back()
        XCTAssertEqual(model.step, .llmKey)
        model.useOwnServer(.languageModel)
        await model.saveServer(OnboardingServerDraft(address: "localhost:1234/v1", model: "qwen3"), on: .languageModel)
        XCTAssertTrue(model.outcome(.llmKey).isDone)
        model.next()
        XCTAssertEqual(model.step, .search, "a server's model has no known search")
        await model.useSearchKey("tvly-bad-0123456789abcdef")
        XCTAssertEqual(model.keyProblems[.search], .refused, "the stubbed Tavily check refuses it")
        await model.useSearchKey("tvly-preview-0123456789abcdef")
        XCTAssertTrue(model.outcome(.search).isDone, "the stubbed Tavily check passes without a network request")

        model.next()
        // Each access step: Allow, back without the switch (Not on yet),
        // Allow again, allowed (REV 57).
        for step in [OnboardingStep.keyboard, .microphone, .screenRecording] {
            XCTAssertEqual(model.step, step)
            XCTAssertEqual(model.accessState(step), .rest)
            model.requestAccess(step)
            XCTAssertEqual(model.accessState(step), .waiting)
            try await eventually { model.accessState(step) == .notOn }
            model.requestAccess(step)
            XCTAssertEqual(model.accessState(step), .waiting, "Allow again waits for System Settings again")
            try await eventually { model.outcome(step).isDone }
            XCTAssertEqual(model.accessState(step), .granted)
            if step != .screenRecording { model.next() }
        }
        model.next()
        XCTAssertEqual(model.step, .tryDrop)
        // A take that brings nothing says so calmly; the next take clears it
        // (REV 58). The preview drives Drop's phases by hand.
        let voice = model.voice
        voice.phaseChanged(.recording)
        XCTAssertTrue(voice.recording)
        voice.phaseChanged(.idle)
        try await eventually { model.outcome(.tryDrop) == .failed(OnboardingJourneyModel.noSpeech) }
        voice.phaseChanged(.recording)
        XCTAssertEqual(model.outcome(.tryDrop), .idle, "a new take clears the line")
        voice.phaseChanged(.transcribing)
        voice.phaseChanged(.inserting)
        voice.phaseChanged(.idle)
        try await eventually { model.outcome(.tryDrop).failureText?.contains("another field") == true }
        voice.phaseChanged(.recording)
        voice.phaseChanged(.deliveryFailed)
        try await eventually { model.outcome(.tryDrop).failureText?.contains("couldn’t finish") == true }
        voice.phaseChanged(.recording)
        voice.phaseChanged(.inserting)
        model.noteDictated()
        voice.phaseChanged(.idle)
        XCTAssertTrue(model.outcome(.tryDrop).isDone)
        XCTAssertNotNil(model.tryDropSeconds, "the take's time from the press")
        for expected in [OnboardingStep.toolbox, .thanks] {
            model.next()
            XCTAssertEqual(model.step, expected)
        }
        model.back()
        XCTAssertEqual(model.step, .toolbox, "Back works in the preview too")

        var finished = false
        model.onFinish = { finished = true }
        model.next()
        model.finish()
        XCTAssertTrue(finished)
    }

    func testThePreviewOnThisMacDownloadsOnATimer() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.chooseOnThisMac()
        try await eventually { model.onDevice.status == .ready }
        try await eventually { model.outcome(.source) == .done("Speech on this Mac") }
    }

    func testEachKeyProblemIsNamedWithoutBlame() async throws {
        let session = makeSession()
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
        XCTAssertEqual(OnboardingKeyProvider.detect(elevenLabs, among: speech)?.kind, .provider(.elevenLabs))
        XCTAssertEqual(OnboardingKeyProvider.detect(String(repeating: "0f", count: 20), among: speech)?.kind, .provider(.deepgram),
                       "Deepgram keys are 40 hexadecimal characters")
        for random in ["adsfdsfasdfasfafa", "adsfdsfasdfasfafaqwerty", "0123456789abcdef0123", "sk_short", "фываолдж0123456789abcdef"] {
            XCTAssertNil(OnboardingKeyProvider.detect(random, among: speech), "\(random) names nobody")
        }
        XCTAssertNil(OnboardingKeyProvider.detect("sk-proj-0123456789abcdef", among: speech), "OpenAI is not offered here")
        let withOpenAI = speech + [OnboardingKeyProvider.of(.openAI)!]
        XCTAssertEqual(OnboardingKeyProvider.detect("sk-proj-0123456789abcdef", among: withOpenAI)?.kind, .provider(.openAI))
        XCTAssertNil(OnboardingKeyProvider.detect("adsfdsfasdfasfafaqwerty", among: withOpenAI), "no guess at OpenAI")
        XCTAssertNil(OnboardingKeyProvider.detect("sk-ant-api03-0123456789abcdef", among: withOpenAI), "an Anthropic key is not speech")
        XCTAssertNil(OnboardingKeyProvider.detect("sk-or-v1-0123456789abcdef", among: withOpenAI), "an OpenRouter key is not speech")

        let llm = OnboardingJourneyModel.llmProviders.compactMap(OnboardingKeyProvider.of)
        XCTAssertEqual(OnboardingKeyProvider.detect("sk-ant-api03-0123456789abcdef", among: llm)?.kind, .provider(.anthropic))
        XCTAssertEqual(OnboardingKeyProvider.detect("sk-or-v1-0123456789abcdef", among: llm)?.kind, .provider(.openRouter))
        XCTAssertEqual(OnboardingKeyProvider.detect("sk-proj-0123456789abcdef", among: llm)?.kind, .provider(.openAI))
        XCTAssertNil(OnboardingKeyProvider.detect(elevenLabs, among: llm), "a speech key is not a language model")
        XCTAssertNil(OnboardingKeyProvider.detect("sk-ant-0123", among: llm), "too short to be a key")

        let search = [OnboardingKeyProvider.tavily]
        XCTAssertEqual(OnboardingKeyProvider.detect("tvly-dev-0123456789abcdef", among: search)?.kind, .tavily)
        XCTAssertNil(OnboardingKeyProvider.detect("sk-ant-api03-0123456789abcdef", among: search), "only Tavily's own format")
        XCTAssertNil(OnboardingKeyProvider.detect("tvly-dev-0123456789abcdef", among: llm), "a Tavily key is not a language model")
    }

    /// The owner typed in the Russian layout and saw
    /// "-2390234(№\");%)№(%;\"()№131" in clear: the field is a secure field,
    /// every input is dots from the first character, a wrong format is only
    /// the error text on Return.
    func testEveryInputIsClosedLikeASecureFieldAndTypingKeepsTheCaret() async throws {
        let russianLayout = "-2390234(№\");%)№(%;\"()№131"
        for typed in [russianLayout, "фывааф", "ЙЦУКЕН", "key with spaces 0123456789", "фываолдж0123456789abcdef",
                      "key.with.dots", "!@#$%^&*()", "adsfdsfasdfasfafa", "a", "№"] {
            let masked = try XCTUnwrap(OnboardingKeyMask.masked(typed), typed)
            XCTAssertEqual(masked, String(repeating: "•", count: typed.count), "\(typed) is dots only")
            XCTAssertNil(OnboardingKeyProvider.detect(typed, among: [.soniox, .deepgram, .elevenLabs, .openAI]
                .compactMap(OnboardingKeyProvider.of)), "\(typed) names no provider")
        }
        XCTAssertNil(OnboardingKeyMask.masked(""))
        // The dots have the same advance as the typed characters, so the
        // field's caret stays over the right dot.
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        XCTAssertEqual(width(russianLayout), width(OnboardingKeyMask.masked(russianLayout)!), accuracy: 0.5)
        XCTAssertEqual(width("фывааф"), width(OnboardingKeyMask.masked("фывааф")!), accuracy: 0.5)
        // Typing by hand, one character at a time: dots at every length.
        for text in ["sk_live0123456789abcdefWXYZ", russianLayout] {
            for length in 1...text.count {
                let typed = String(text.prefix(length))
                let masked = try XCTUnwrap(OnboardingKeyMask.masked(typed))
                XCTAssertEqual(masked.count, typed.count, "same length, so the caret stays at \(length)")
                XCTAssertTrue(masked.allSatisfy { $0 == "•" }, "no character shows at \(length)")
            }
        }

        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        for typed in ["фывааф", russianLayout] {
            await model.useSpeechKey(typed, provider: .soniox)
            XCTAssertEqual(model.keyProblems[.speechKey], .format, "\(typed): a calm format problem, no request")
            XCTAssertEqual(model.outcome(.speechKey), .failed(OnboardingKeyProblem.format.message(provider: "Soniox")))
            XCTAssertFalse(model.keySaved(.soniox))
        }
    }

    /// Return on a key that names nobody (no format, no picked mark) is a
    /// format problem; editing the key clears it; an accepted key stays.
    func testAKeyThatNamesNoProviderIsAFormatProblemUntilEdited() async throws {
        let session = makeSession()
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

    /// "Use your own server →" turns the key field into the server's fields
    /// on the same step; Back returns to the key field, Save is the step done.
    func testOwnServerChangesTheStepAndComesBack() async throws {
        let suite = "OnboardingPreviewTests-\(UUID().uuidString)"
        let session = makeSession(suiteName: suite)
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.useOwnServer(.speech)
        XCTAssertTrue(model.showsServerForm(.speech))
        model.back()
        XCTAssertFalse(model.showsServerForm(.speech), "Back returns to the key field first")
        XCTAssertEqual(model.step, .speechKey, "and stays on the key step")
        XCTAssertEqual(model.outcome(.speechKey), .idle, "nothing was saved")

        model.useOwnServer(.speech)
        var server = OnboardingServerDraft(address: "localhost:11434/v1", key: "local-key")
        XCTAssertFalse(server.canSave, "a server needs a model")
        XCTAssertEqual(server.name, "Ollama", "the name comes from the address")
        server.model = "whisper-large-v3"
        await model.saveServer(server, on: .speech)
        XCTAssertEqual(model.outcome(.speechKey), .done("Ollama · whisper-large-v3"))
        XCTAssertEqual(model.step, .speechKey, "the fields stay until the step moves on")
        XCTAssertTrue(model.showsServerForm(.speech), "no return to the key field before the move")
        func routes() -> AIRoutingStore { AIRoutingStore(defaults: UserDefaults(suiteName: suite)!) }
        XCTAssertEqual(routes().route(for: .dropFast)?.model, "whisper-large-v3", "the speech step adds a transcription model")

        // The language model step offers the same server filled in; only
        // the LLM is new, and the server is not added twice.
        try await eventually { model.step == .llmKey }
        XCTAssertEqual(model.serverPrefill(for: .languageModel),
                       OnboardingServerDraft(address: "http://localhost:11434/v1", key: "local-key"))
        XCTAssertNil(model.serverPrefill(for: .speech), "nothing added on the LLM step yet")
        model.useOwnServer(.languageModel)
        var llm = try XCTUnwrap(model.serverPrefill(for: .languageModel))
        llm.model = "qwen3:8b"
        await model.saveServer(llm, on: .languageModel)
        XCTAssertEqual(model.outcome(.llmKey), .done("Ollama · qwen3:8b"))
        XCTAssertEqual(routes().state.servers.count, 1, "one server, two models")
        XCTAssertEqual(routes().state.servers.first?.models?.map(\.kind).sorted { $0.rawValue < $1.rawValue }, [.llm, .transcription])
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

    // MARK: - The model, after a key is accepted

    /// The owner asked what the preselected "gpt-5.6 dinosaur" was (a fixed
    /// name in the preview's catalog), then for "Sonnet / Sol, the current
    /// one" as the recommendation: the step starts on the newest Sol from the
    /// provider's catalog, marked Recommended, and lets the person pick another.
    func testTheLanguageModelStepStartsOnTheRecommendedModelAndWaitsForTheChoice() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        await model.useSpeechKey("good-0123456789abcdef", provider: .soniox)
        try await eventually { model.step == .llmKey }

        model.llmProvider = .openAI
        await model.useLLMKey("sk-proj-good-0123456789abcdef", provider: .openAI)
        XCTAssertEqual(model.outcome(.llmKey), .done("gpt-6.2-sol"), "the newest Sol, not the newest voice model")
        XCTAssertEqual(model.currentModel(.llmKey), "gpt-6.2-sol")
        XCTAssertEqual(model.recommendedModel(.llmKey), "gpt-6.2-sol")
        let ids = model.modelChoices(.llmKey).map(\.id)
        XCTAssertEqual(ids.first, "gpt-6.2-sol", "the recommended model is first")
        XCTAssertTrue(ids.contains("gpt-6.2-astra"))
        XCTAssertFalse(ids.contains("gpt-live-1.1"), "a voice model is not a text choice")
        XCTAssertFalse(ids.contains("gpt-5.5-2026-04-23"), "dated snapshots are left out")
        XCTAssertFalse(ids.contains { $0.contains("transcribe") || $0.contains("whisper") })
        XCTAssertLessThanOrEqual(ids.count, OnboardingModelPick.listLimit)
        XCTAssertEqual(model.modelChoices(.llmKey).first { $0.id == "gpt-6.2-astra" }?.price, "$8 / $40 per 1M")

        // No automatic move: the step waits for a pick or Next. 400 ms is
        // several times the longest dwell at the tests' pace.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.step, .llmKey, "with a choice of models the step waits")
        await model.chooseModel("gpt-6.2-astra", on: .llmKey)
        XCTAssertEqual(model.outcome(.llmKey), .done("gpt-6.2-astra"))
        XCTAssertEqual(model.currentModel(.llmKey), "gpt-6.2-astra", "the shared LLM row runs the person's pick")
        XCTAssertEqual(model.recommendedModel(.llmKey), "gpt-6.2-sol", "the recommendation stays marked")
        try await eventually { model.step != .llmKey }
    }

    /// OpenRouter: the recommended model is Anthropic's current Sonnet,
    /// first in the list and set, and the step waits for a pick or Next.
    func testOpenRouterRecommendsTheCurrentSonnetAndWaits() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.next()
        XCTAssertEqual(model.step, .llmKey)
        model.llmProvider = .openRouter
        await model.useLLMKey("sk-or-v1-good-0123456789abcdef", provider: .openRouter)
        XCTAssertEqual(model.recommendedModel(.llmKey), "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(model.outcome(.llmKey), .done("anthropic/claude-sonnet-5.5"))
        let choices = model.modelChoices(.llmKey)
        XCTAssertEqual(choices.first?.id, "anthropic/claude-sonnet-5.5", "\(choices.map(\.id))")
        XCTAssertGreaterThan(choices.count, 1)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.step, .llmKey, "no automatic move with a choice of models")
        model.next()
        XCTAssertNotEqual(model.step, .llmKey)
        XCTAssertEqual(model.currentModel(.llmKey), "anthropic/claude-sonnet-5.5", "Next keeps the recommended model")
    }

    /// The owner read "claude-son…" and asked how to read it: the list and
    /// the button show a readable name, never cut, with the ID beside it.
    func testModelsHaveReadableNames() {
        let names = [
            "claude-sonnet-5-5": "Claude Sonnet 5.5", "anthropic/claude-sonnet-5.5": "Claude Sonnet 5.5",
            "claude-fable-5-2": "Claude Fable 5.2", "claude-haiku-5-5": "Claude Haiku 5.5",
            "gpt-6.2-sol": "GPT-6.2 Sol", "gpt-6-luna": "GPT-6 Luna", "openai/gpt-6.2-astra": "GPT-6.2 Astra",
            "gpt-live-transcribe": "GPT Live Transcribe", "google/gemini-3.8-pro": "Gemini 3.8 Pro",
            "deepseek/deepseek-v4": "DeepSeek V4", "qwen3:8b": "Qwen3:8b",
        ]
        for (id, name) in names { XCTAssertEqual(OnboardingModelPick.readableName(id), name, id) }
    }

    /// "Choose model" until the person picks one, the recommended one
    /// included; then the button names the pick. A new key asks again.
    func testThePickedModelIsNamedOnItsButton() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.next()
        model.llmProvider = .anthropic
        await model.useLLMKey("sk-ant-good-0123456789abcdef", provider: .anthropic)
        XCTAssertFalse(model.pickedModels.contains(.llmKey), "nothing picked yet: Choose model")
        XCTAssertNil(model.checkedModel(.llmKey), "no checkmark before a pick, the recommended one only tagged")
        XCTAssertEqual(model.currentModel(.llmKey), "claude-sonnet-5-5", "Next keeps the recommended model")
        model.modelMenu(open: true)
        model.modelMenu(open: false)
        XCTAssertNil(model.checkedModel(.llmKey), "closing the list without a pick changes nothing")
        await model.chooseModel("claude-sonnet-5-5", on: .llmKey)
        XCTAssertTrue(model.pickedModels.contains(.llmKey), "picking the recommended model counts")
        XCTAssertEqual(model.checkedModel(.llmKey), "claude-sonnet-5-5", "the checkmark after the choice")
        XCTAssertEqual(model.currentModel(.llmKey), "claude-sonnet-5-5")
        model.back()
        model.next()
        await model.useLLMKey("sk-ant-good-0123456789abcdef", provider: .anthropic)
        XCTAssertFalse(model.pickedModels.contains(.llmKey), "a new key asks again")
    }

    func testAnthropicStartsOnTheCurrentSonnetWithItsPrice() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.llmProvider = .anthropic
        await model.useLLMKey("sk-ant-good-0123456789abcdef", provider: .anthropic)
        XCTAssertEqual(model.outcome(.llmKey), .done("claude-sonnet-5-5"))
        XCTAssertEqual(model.recommendedModel(.llmKey), "claude-sonnet-5-5")
        let choices = model.modelChoices(.llmKey)
        XCTAssertEqual(choices.first { $0.id == "claude-sonnet-5-5" }?.price, "$2 / $10 per 1M")
        XCTAssertTrue(choices.contains { $0.id == "claude-fable-5-2" }, "the person can pick the flagship")
        XCTAssertFalse(choices.contains { $0.id == "claude-opus-4-5-20251101" })
    }

    /// The owner on the speech step with OpenAI and "Choose model": "no model
    /// choice, we have only one model there" (REV 54). An accepted speech key
    /// sets the one model Settings -> Speech uses for the provider and the
    /// step moves on by itself; no list, no pick, no wait.
    func testTheSpeechStepHasNoModelChoice() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.speechProvider = .openAI
        await model.useSpeechKey("sk-proj-good-0123456789abcdef", provider: .openAI)
        XCTAssertTrue(model.outcome(.speechKey).isDone)
        XCTAssertTrue(model.modelChoices(.speechKey).isEmpty, "no Choose model on the speech step")
        XCTAssertTrue(model.modelCatalog(.speechKey).isEmpty, "and no search")
        XCTAssertEqual(model.currentModel(.speechKey), ModelRegistry.openAILiveModel, "the model Settings uses")
        await model.chooseModel("gpt-transcribe", on: .speechKey)
        XCTAssertEqual(model.currentModel(.speechKey), ModelRegistry.openAILiveModel, "a pick never reaches speech")
        try await eventually { model.step == .llmKey }
        for provider in [AIProviderKind.soniox, .deepgram, .elevenLabs] {
            XCTAssertTrue(model.modelChoices(.speechKey, provider: provider).isEmpty, "\(provider)")
        }
    }

    func testTheFlagshipRuleAndTheListedModels() {
        let day: TimeInterval = 86_400
        let now = Date()
        func choice(_ id: String, _ days: Double, _ out: Double? = nil) -> OnboardingModelChoice {
            OnboardingModelChoice(id: id, price: nil, date: now.addingTimeInterval(-days * day), outputPerMillion: out)
        }
        // Prices known: the newest generation's priciest.
        XCTAssertEqual(OnboardingModelPick.flagship([choice("a-sol", 3, 10), choice("a-astra", 5, 40),
                                                     choice("a-old-astra", 80, 50)])?.id, "a-astra")
        // No prices: the newest; small tiers never the default.
        XCTAssertEqual(OnboardingModelPick.flagship([choice("x-mini", 1), choice("x-large", 9)])?.id, "x-large")
        XCTAssertEqual(OnboardingModelPick.flagship([choice("only-mini", 1)])?.id, "only-mini")
        XCTAssertNil(OnboardingModelPick.flagship([]))
        XCTAssertFalse(OnboardingModelPick.isListed("gpt-5.5-2026-04-23", speech: false))
        XCTAssertFalse(OnboardingModelPick.isListed("claude-opus-4-5-20251101", speech: false))
        XCTAssertFalse(OnboardingModelPick.isListed("gpt-live-1.1", speech: false))
        XCTAssertTrue(OnboardingModelPick.isListed("gpt-live-transcribe", speech: true))
        XCTAssertEqual(OnboardingModelPick.shortPrice("$1.25 in / $10 out per 1M tokens"), "$1.25 / $10 per 1M")
        XCTAssertEqual(OnboardingModelPick.outputPrice("$1.25 in / $10 out per 1M tokens"), 10)
        XCTAssertEqual(OnboardingModelPick.outputPrice("$0.1 in / $1,200 out per 1M tokens"), 1_200)
        XCTAssertNil(OnboardingModelPick.outputPrice("Free"))
        XCTAssertEqual(OnboardingModelPick.minutePrice(0.017), "0.017")
        XCTAssertEqual(OnboardingModelPick.minutePrice(0.0045), "0.0045")
        // The recommendation is the family's newest, not a fixed ID.
        let anthropic = [choice("claude-fable-5-2", 12, 40), choice("claude-sonnet-5-5", 55, 10),
                         choice("claude-sonnet-5", 140, 10), choice("claude-sonnet-6-20270101", 1, 10)]
        XCTAssertEqual(OnboardingModelPick.recommended(anthropic, provider: .anthropic)?.id, "claude-sonnet-5-5",
                       "a dated snapshot is not the recommendation")
        let openAI = [choice("gpt-6.2-astra", 21, 40), choice("gpt-6.2-sol", 18, 10), choice("gpt-6.1-sol", 54, 10),
                      choice("gpt-6.2-sol-pro", 2, 10)]
        XCTAssertEqual(OnboardingModelPick.recommended(openAI, provider: .openAI)?.id, "gpt-6.2-sol")
        XCTAssertEqual(OnboardingModelPick.recommended([choice("gpt-6.2-astra", 21, 40)], provider: .openAI)?.id,
                       "gpt-6.2-astra", "without a Sol the newest flagship stands in")
        XCTAssertEqual(OnboardingModelPick.recommended([choice("anthropic/claude-sonnet-5.5", 55, 10),
                                                        choice("anthropic/claude-fable-5.2", 12, 40)], provider: .openRouter)?.id,
                       "anthropic/claude-sonnet-5.5")
        // OpenRouter: each major author's flagship, Anthropic first.
        let router = OnboardingModelPick.listed([choice("openai/gpt-6.2-astra", 3, 40), choice("openai/gpt-6.2-sol", 3, 10),
                                                 choice("anthropic/claude-fable-5.2", 12, 40), choice("anthropic/claude-haiku-5.5", 40, 0.5),
                                                 choice("some/unknown", 1, 99)], speech: false, router: true)
        XCTAssertEqual(router.map(\.id), ["anthropic/claude-fable-5.2", "openai/gpt-6.2-astra"])
    }

    // MARK: - Switching marks on a key step (REV 46)

    /// The owner asked what happens when a person enters one key and then
    /// switches: "accepted" belongs to the provider or server that answered,
    /// another mark shows its own state, and the route moves only after a
    /// new check succeeds.
    private func llmRoute(_ model: OnboardingJourneyModel) -> ProviderAccount? { model.models.sharedRow(.llm)?.choice?.account }
    private func speechRoute(_ model: OnboardingJourneyModel) -> ProviderAccount? { model.models.sharedRow(.speech)?.choice?.account }
    private func account(_ kind: AIProviderKind) -> ProviderAccount? { APIAndModelsViewModel.builtInAccount(for: kind) }

    private func atLanguageModelStep() async throws -> (OnboardingPreviewSession, OnboardingJourneyModel) {
        let session = makeSession()
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.next()
        XCTAssertEqual(model.step, .llmKey)
        return (session, model)
    }

    func testLanguageModelKeyThenAnotherProviderThenBack() async throws {
        let (session, model) = try await atLanguageModelStep()
        defer { session.clear() }
        model.llmProvider = .anthropic
        await model.useLLMKey("sk-ant-good-0123456789abcdef", provider: .anthropic)
        XCTAssertEqual(llmRoute(model), account(.anthropic))

        model.llmProvider = .openAI
        model.routeShown(on: .llmKey)
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.openAI)), .idle, "OpenAI never borrows Anthropic's answer")
        XCTAssertFalse(model.keySaved(.openAI), "an empty field: no OpenAI key")
        XCTAssertTrue(model.outcome(.llmKey).isDone, "the step still holds Anthropic for Next")
        XCTAssertEqual(llmRoute(model), account(.anthropic), "a click is not a switch")

        // A pick in a list never reaches a provider whose key was not checked here.
        await model.chooseModel("gpt-6.2-sol", on: .llmKey)
        XCTAssertEqual(llmRoute(model), account(.anthropic))
        XCTAssertEqual(model.accepted[.llmKey]?.route, .provider(.anthropic))
        XCTAssertNil(model.checkedModel(.llmKey))
        XCTAssertNil(model.llmModel, "the pick is not remembered for Anthropic's next check either")
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.openAI)), .idle, "no attempt was made for OpenAI")

        // A refused OpenAI key is OpenAI's: Anthropic stays accepted.
        await model.useLLMKey("sk-proj-bad-0123456789abcdef", provider: .openAI)
        guard case .failed = model.outcome(.llmKey, for: .provider(.openAI)) else { return XCTFail("OpenAI's refusal") }
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.anthropic)), .done("claude-sonnet-5-5"))
        XCTAssertEqual(llmRoute(model), account(.anthropic))

        model.llmProvider = .anthropic
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.anthropic)), .done("claude-sonnet-5-5"),
                       "back on Anthropic: accepted again, no key asked")

        // A checked OpenAI key moves the route; Anthropic's key stays saved.
        model.llmProvider = .openAI
        await model.useLLMKey("sk-proj-good-0123456789abcdef", provider: .openAI)
        XCTAssertEqual(llmRoute(model), account(.openAI))
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.openAI)), .done("gpt-6.2-sol"))
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.anthropic)), .idle)
        XCTAssertTrue(model.keySaved(.anthropic), "the field offers \"Saved Anthropic key · press Return\"")
    }

    func testLanguageModelServerThenProvider() async throws {
        let (session, model) = try await atLanguageModelStep()
        defer { session.clear() }
        model.useOwnServer(.languageModel)
        let server = OnboardingServerDraft(address: "dsfadfdas", model: "dafdasfdasf")
        await model.saveServer(server, on: .languageModel)
        XCTAssertEqual(model.accepted[.llmKey]?.route, .server)
        XCTAssertTrue(model.steps.contains(.search))
        let serverAccount = llmRoute(model)

        // The owner's screenshot: Anthropic after the server.
        model.closeServerForm(.languageModel)
        model.llmProvider = .anthropic
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.anthropic)), .idle,
                       "no \"Anthropic · dsfadfdas · dafdasfdasf\": the server's line is the server's")
        XCTAssertEqual(llmRoute(model), serverAccount, "the server still runs the LLM")
        XCTAssertTrue(model.steps.contains(.search), "the Tavily step goes only after a provider's key")
        XCTAssertEqual(model.outcome(.llmKey, for: .server), .done("dsfadfdas · dafdasfdasf"))

        model.useOwnServer(.languageModel)
        XCTAssertEqual(model.acceptedServerDraft(.languageModel), server, "the fields come back as accepted")
        model.closeServerForm(.languageModel)

        await model.useLLMKey("sk-ant-good-0123456789abcdef", provider: .anthropic)
        XCTAssertEqual(llmRoute(model), account(.anthropic))
        XCTAssertFalse(model.steps.contains(.search))
        XCTAssertEqual(model.outcome(.llmKey, for: .server), .idle)
    }

    func testLanguageModelProviderThenServer() async throws {
        let (session, model) = try await atLanguageModelStep()
        defer { session.clear() }
        await model.useLLMKey("sk-ant-good-0123456789abcdef", provider: .anthropic)
        model.useOwnServer(.languageModel)
        XCTAssertEqual(model.outcome(.llmKey, for: .server), .idle, "the server's fields are open, not \"added\"")
        XCTAssertNil(model.acceptedServerDraft(.languageModel))

        await model.saveServer(OnboardingServerDraft(address: "localhost:11434/v1", model: "bad-model"), on: .languageModel)
        guard case .failed = model.outcome(.llmKey, for: .server) else { return XCTFail("the server's own failure") }
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.anthropic)), .done("claude-sonnet-5-5"))
        XCTAssertEqual(llmRoute(model), account(.anthropic))
        XCTAssertFalse(model.steps.contains(.search))

        await model.saveServer(OnboardingServerDraft(address: "localhost:11434/v1", model: "qwen3:8b"), on: .languageModel)
        XCTAssertEqual(model.accepted[.llmKey]?.route, .server)
        XCTAssertNotEqual(llmRoute(model), account(.anthropic))
        XCTAssertTrue(model.steps.contains(.search))
        XCTAssertEqual(model.outcome(.llmKey, for: .provider(.anthropic)), .idle)
    }

    func testSpeechKeyThenAnotherProviderThenBack() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.speechProvider = .soniox
        await model.useSpeechKey("good-0123456789abcdef", provider: .soniox)
        let soniox = try XCTUnwrap(model.accepted[.speechKey])
        XCTAssertEqual(soniox.route, .provider(.soniox))
        XCTAssertEqual(speechRoute(model), account(.soniox))

        model.speechProvider = .deepgram
        model.routeShown(on: .speechKey)
        XCTAssertEqual(model.outcome(.speechKey, for: .provider(.deepgram)), .idle)
        XCTAssertEqual(speechRoute(model), account(.soniox))
        let deepgramModel = try XCTUnwrap(model.recommendedModel(.speechKey, provider: .deepgram))
        await model.chooseModel(deepgramModel, on: .speechKey)
        XCTAssertEqual(speechRoute(model), account(.soniox), "no Deepgram pick without its key")
        XCTAssertEqual(model.outcome(.speechKey, for: .provider(.deepgram)), .idle, "no attempt was made for Deepgram")

        await model.useSpeechKey("bad-0123456789abcdef", provider: .deepgram)
        guard case .failed = model.outcome(.speechKey, for: .provider(.deepgram)) else { return XCTFail("Deepgram's refusal") }
        XCTAssertEqual(model.outcome(.speechKey, for: .provider(.soniox)), .done(soniox.text))

        model.speechProvider = .soniox
        XCTAssertEqual(model.outcome(.speechKey, for: .provider(.soniox)), .done(soniox.text), "accepted again")
        XCTAssertEqual(speechRoute(model), account(.soniox))
    }

    func testSpeechServerAndProviderSwitches() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        // Provider, then the server.
        await model.useSpeechKey("good-0123456789abcdef", provider: .soniox)
        model.useOwnServer(.speech)
        XCTAssertEqual(model.outcome(.speechKey, for: .server), .idle, "the fields stay open to a server")
        await model.saveServer(OnboardingServerDraft(address: "localhost:8000/v1", model: "whisper-large-v3-turbo"), on: .speech)
        XCTAssertEqual(model.accepted[.speechKey]?.route, .server)
        XCTAssertNotEqual(speechRoute(model), account(.soniox))
        // The server, then a provider.
        model.closeServerForm(.speech)
        model.speechProvider = .soniox
        XCTAssertEqual(model.outcome(.speechKey, for: .provider(.soniox)), .idle, "Soniox does not show the server's line")
        XCTAssertTrue(model.keySaved(.soniox), "\"Saved Soniox key · press Return\"")
        await model.useSpeechKey("", provider: .soniox)
        XCTAssertEqual(speechRoute(model), account(.soniox), "Return on the saved key moves the route back")
        XCTAssertEqual(model.outcome(.speechKey, for: .server), .idle)
    }

    // MARK: - Search in "Choose model" (REV 52)

    func testModelSearchFindsByNameAndID() {
        let catalog = ["anthropic/claude-sonnet-5.5", "anthropic/claude-fable-5.2", "openai/gpt-6.2-sol",
                       "openai/gpt-6.2-astra", "google/gemini-3.8-pro", "deepseek/deepseek-v4"].map {
            OnboardingModelChoice(id: $0)
        }
        XCTAssertEqual(OnboardingModelSearch.matches("sonnet", in: catalog).map(\.id), ["anthropic/claude-sonnet-5.5"])
        XCTAssertEqual(Set(OnboardingModelSearch.matches("GPT 6.2", in: catalog).map(\.id)),
                       ["openai/gpt-6.2-sol", "openai/gpt-6.2-astra"], "words in any order, case and dashes ignored")
        XCTAssertEqual(OnboardingModelSearch.matches("claude-fable", in: catalog).map(\.id), ["anthropic/claude-fable-5.2"], "by ID")
        XCTAssertEqual(OnboardingModelSearch.matches("Gemini 3.8 Pro", in: catalog).map(\.id), ["google/gemini-3.8-pro"], "by readable name")
        XCTAssertTrue(OnboardingModelSearch.matches("  ", in: catalog).isEmpty)
        XCTAssertTrue(OnboardingModelSearch.matches("llama", in: catalog).isEmpty)
        XCTAssertFalse(OnboardingModelSearch.offersSearch(Array(repeating: catalog[0], count: 10)), "ten or fewer: no search")
        XCTAssertTrue(OnboardingModelSearch.offersSearch(Array(repeating: catalog[0], count: 11)))
    }

    /// OpenRouter's catalog is large: the search covers all of it while the
    /// list stays the selection; a pick from the search sets that model.
    func testOpenRouterSearchesItsWholeCatalog() async throws {
        let (session, model) = try await atLanguageModelStep()
        defer { session.clear() }
        model.llmProvider = .openRouter
        await model.useLLMKey("sk-or-v1-good-0123456789abcdef", provider: .openRouter)
        let catalog = model.modelCatalog(.llmKey)
        let listed = model.modelChoices(.llmKey)
        XCTAssertTrue(OnboardingModelSearch.offersSearch(catalog), "\(catalog.count) models")
        XCTAssertGreaterThan(catalog.count, listed.count)
        XCTAssertTrue(listed.allSatisfy { choice in catalog.contains { $0.id == choice.id } })
        if let output = ProcessInfo.processInfo.environment["WHYTAP_ONBOARDING_RENDER_DIR"] {
            // Offscreen review images of the list, closed field and searching.
            for (name, query) in [("model-search-openrouter", ""), ("model-search-openrouter-gemini", "gemini"),
                                  ("model-search-openrouter-sol", "sol"), ("model-search-openrouter-none", "llama")] {
                let list = OnboardingModelList(choices: listed, catalog: catalog, selected: nil,
                                               recommended: model.recommendedModel(.llmKey), query: query) { _ in }
                let host = NSHostingView(rootView: list)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
            }
        }
        let unlisted = try XCTUnwrap(catalog.first { choice in !listed.contains { $0.id == choice.id } })
        let found = OnboardingModelSearch.matches(unlisted.id, in: catalog)
        XCTAssertEqual(found.first?.id, unlisted.id)
        await model.chooseModel(unlisted.id, on: .llmKey)
        XCTAssertEqual(model.currentModel(.llmKey), unlisted.id, "a model found by search is set like any pick")
        XCTAssertEqual(model.checkedModel(.llmKey), unlisted.id)
    }

    /// Typing in "Choose model" keeps the panel's form (Maxim: "sol" made the
    /// field narrower, indented the results and resized the panel): one
    /// width with and without a query, results in the rows' own grid, a
    /// height that follows the rows, and one calm row when nothing matches.
    func testSearchingKeepsTheModelPanelsShape() async throws {
        let (session, model) = try await atLanguageModelStep()
        defer { session.clear() }
        model.llmProvider = .openRouter
        await model.useLLMKey("sk-or-v1-good-0123456789abcdef", provider: .openRouter)
        let catalog = model.modelCatalog(.llmKey)
        let listed = model.modelChoices(.llmKey)
        let recommended = model.recommendedModel(.llmKey)
        XCTAssertEqual(OnboardingModelSearch.matches("sol", in: catalog).count, 2, "the case Maxim saw")
        func size(_ query: String) -> CGSize {
            let list = OnboardingModelList(choices: listed, catalog: catalog, selected: nil,
                                           recommended: recommended, query: query) { _ in }
            return NSHostingView(rootView: list).fittingSize
        }
        let idle = size(""), sol = size("sol"), none = size("llama"), many = size("a")
        let width = OnboardingModelList.panelWidth(choices: listed, catalog: catalog, recommended: recommended)
        for (query, got) in [("", idle), ("sol", sol), ("llama", none), ("a", many)] {
            XCTAssertEqual(got.width, width, accuracy: 0.5, "the same width for “\(query)”")
        }
        XCTAssertGreaterThanOrEqual(width, OnboardingModelList.minWidth)
        XCTAssertLessThanOrEqual(width, OnboardingModelList.maxWidth)
        let field: CGFloat = 32 + 4 + 1
        XCTAssertEqual(sol.height, 12 + field + 2 * 40 + 1, accuracy: 0.5, "two results, two rows")
        XCTAssertEqual(none.height, 12 + field + 40, accuracy: 0.5, "no result: one row")
        XCTAssertEqual(many.height, 12 + field + OnboardingModelList.resultsHeight, accuracy: 0.5, "many results scroll")
        // Names never cut: each row's name and ID fit at their natural width.
        let inner = width - 12 - 16 - 12 - 8
        for choice in listed + catalog {
            let name = NSHostingView(rootView: Text(OnboardingModelPick.readableName(choice.id))
                .font(OnboardingTheme.sans(13, weight: .medium))).fittingSize.width
            let price = choice.price.map { NSHostingView(rootView: Text($0).font(OnboardingTheme.sans(11.5))).fittingSize.width + 32 } ?? 24
            let tag: CGFloat = choice.id == recommended ? 90 : 0
            XCTAssertLessThanOrEqual(name + tag + price, inner + 0.5, "\(choice.id) fits")
        }
        XCTAssertEqual(OnboardingModelList.listHeight(rows: 0, typed: true), 40)
        XCTAssertEqual(OnboardingModelList.listHeight(rows: 3, typed: false), 122)
    }

    /// REV 56: in the app "Choose model" lists the provider's real catalog
    /// (the `APIAndModelsViewModel` that Settings -> Models uses, its
    /// `ModelCatalog` and prices); the preview's fake catalogs, key checks and
    /// permissions live in OnboardingPreviewKit, which the app does not link.
    func testThePreviewsFakesNeverReachTheApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let app = root.appendingPathComponent("Sources/Sidekey")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for fake in ["OnboardingPreviewProviders", "OnboardingPreviewSession", "OnboardingPreviewURLProtocol", "OnboardingPreviewDrop",
                         "OnboardingPreviewTokenStore"] {
                XCTAssertFalse(text.contains(fake), "\(file.lastPathComponent) names \(fake)")
            }
        }
        let delegate = try String(contentsOf: app.appendingPathComponent("AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(delegate.contains("let model = OnboardingJourneyModel(resumeDefaults: .standard)"),
                      "the app's onboarding builds on the default APIAndModelsViewModel, the Settings catalog")
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let appTarget = try XCTUnwrap(manifest.range(of: #"name: "SidekeyApp",\s*dependencies: \["Sidekey"\]"#,
                                                      options: .regularExpression), "the app links Sidekey only")
        XCTAssertFalse(manifest[appTarget].contains("OnboardingPreviewKit"))
    }

    /// The access steps' states come from the system's answer only (REV 57):
    /// a return with the switch off says Not on yet, a step reached again
    /// starts at Allow, macOS's own microphone dialog is never taken for a
    /// refusal, and Open System Settings opens that step's pane.
    func testAccessStepsFollowTheSystemsAnswer() async throws {
        let suite = "OnboardingPreviewTests-\(UUID().uuidString)"
        let session = makeSession(suiteName: suite)
        defer { session.clear() }
        let model = session.model
        model.showPermissions()
        XCTAssertEqual(model.step, .keyboard)
        XCTAssertEqual(model.accessState(.keyboard), .rest)

        // Coming back before anything was asked changes nothing.
        model.recheckPermissions()
        XCTAssertEqual(model.accessState(.keyboard), .rest)

        model.requestAccess(.keyboard)
        XCTAssertEqual(model.accessState(.keyboard), .waiting)
        model.recheckPermissions()
        XCTAssertEqual(model.accessState(.keyboard), .notOn, "back from System Settings with the switch off")
        XCTAssertFalse(model.outcome(.keyboard).isDone)

        // Another step and back: Allow again, not a leftover wait or line.
        model.next()
        XCTAssertEqual(model.step, .microphone)
        model.back()
        XCTAssertEqual(model.step, .keyboard)
        XCTAssertEqual(model.accessState(.keyboard), .rest)

        // The quiet link opens the pane, and the system's grant moves it on.
        model.requestAccess(.keyboard)
        model.openSystemSettings(for: .keyboard)
        try await eventually { model.accessState(.keyboard) == .granted }
        // A grant is never undone by a later return from System Settings.
        model.recheckPermissions()
        XCTAssertEqual(model.accessState(.keyboard), .granted)

        // While macOS's microphone dialog is open (not determined yet), a
        // return to the app is no refusal.
        model.next()
        XCTAssertEqual(model.step, .microphone)
        model.requestAccess(.microphone)
        model.recheckPermissions()
        XCTAssertEqual(model.accessState(.microphone), .waiting)
        // Don't Allow in that dialog: Not on yet.
        try await eventually { model.accessState(.microphone) == .notOn }
    }

    /// Each access step has its own words and figure; only Screen Recording
    /// is optional, and its pane is named where to turn Whytap on.
    func testAccessKindsMatchTheirSteps() {
        for kind in OnboardingAccessKind.allCases {
            XCTAssertEqual(OnboardingAccessKind(step: kind.step), kind)
            XCTAssertEqual(kind.isOptional, kind.step.isOptional)
            XCTAssertFalse(kind.notOnLine.isEmpty)
        }
        let override = PermissionsHelper.usesProtectionOverridePane
        defer { PermissionsHelper.usesProtectionOverridePane = override }
        PermissionsHelper.usesProtectionOverridePane = false
        XCTAssertEqual(OnboardingAccessKind.keyboard.pane, "Accessibility")
        XCTAssertEqual(OnboardingAccessKind.keyboard.notOnLine, "Whytap isn’t on in Accessibility yet.")
        XCTAssertFalse(OnboardingAccessKind.keyboard.addsByHand)
        // macOS 27.3: the Accessibility link lands on System & App Protection
        // Override, which lists no Whytap until the person adds it with +, so
        // the step never names or opens it.
        PermissionsHelper.usesProtectionOverridePane = true
        XCTAssertTrue(OnboardingAccessKind.keyboard.addsByHand)
        XCTAssertTrue(OnboardingAccessKind.screenRecording.addsByHand)
        XCTAssertFalse(OnboardingAccessKind.microphone.addsByHand)
        XCTAssertEqual(OnboardingAccessKind.keyboard.notOnLine, "Keyboard control isn’t on yet.")
        // The other panes keep their names and their switches.
        XCTAssertEqual(OnboardingAccessKind.microphone.pane, "Microphone")
        XCTAssertEqual(OnboardingAccessKind.screenRecording.grantedLine, "Ready for Shot and the Agent.")
        XCTAssertNil(OnboardingAccessKind(step: .language))
        XCTAssertTrue(OnboardingJourneyView.isWireframe(.screenRecording))
        // The ⌘ is closed strokes: four sides and four 270-degree loops whose
        // ends meet the sides.
        let legend = OnboardingAccessFigures.Keyboard.legend
        XCTAssertEqual(legend.count, 8)
        for loop in legend.suffix(4) {
            let first = loop[0], last = loop[loop.count - 1]
            let touches: (OnboardingWireSolid.Vec3) -> Bool = { p in
                legend.prefix(4).contains { side in
                    let a = side[0], b = side[1]
                    let onX = abs(a.x - b.x) < 1e-9 && abs(p.x - a.x) < 1e-6
                    let onZ = abs(a.z - b.z) < 1e-9 && abs(p.z - a.z) < 1e-6
                    return (onX && abs(abs(p.z) - abs(a.z)) < 1e-6) || (onZ && abs(abs(p.x) - abs(a.x)) < 1e-6)
                }
            }
            XCTAssertTrue(touches(first) && touches(last), "each loop starts and ends on a side's end")
        }
    }

    /// Try Drop's wire key carries the legend of the person's Drop key.
    func testTryDropsKeyShowsTheDropKeysLegend() {
        XCTAssertEqual(OnboardingFinaleFigures.legend(for: .holdSpace), .none)
        XCTAssertEqual(OnboardingFinaleFigures.legend(for: .modifier(.rightCommand)), .command)
        XCTAssertEqual(OnboardingFinaleFigures.legend(for: .modifier(.rightOption)), .option)
    }

    /// Try Drop says which key to hold once, in the field's header: the
    /// field says only where the text appears, and a take that brought
    /// nothing says so inside the field, not on a line under it (REV 63).
    func testTryDropSaysTheKeyOnce() {
        XCTAssertEqual(OnboardingTryDropStage.placeholder, "Your text will appear here")
        let quiet = OnboardingTryDropStage.emptyText(.waiting)
        XCTAssertEqual(quiet.text, OnboardingTryDropStage.placeholder)
        XCTAssertFalse(quiet.failed)
        XCTAssertEqual(OnboardingTryDropStage.emptyText(.recording).text, OnboardingTryDropStage.placeholder)
        let failed = OnboardingTryDropStage.emptyText(.failed(OnboardingJourneyModel.noSpeech))
        XCTAssertEqual(failed.text, "No speech heard — try again.")
        XCTAssertTrue(failed.failed)
    }

    // MARK: - The preview's Drop on Try Drop

    private final class Takes { var texts: [String] = []; var erased: [Int] = [] }

    private func previewDrop(_ shortcut: HotkeyShortcut = .holdSpace, gesture: HotkeyGesture = .hold)
        -> (OnboardingPreviewDrop, OnboardingVoiceSignal, Takes, () -> Void) {
        let drop = OnboardingPreviewDrop()
        drop.transcribing = 0.01
        drop.threshold = 0.05
        var clock = Date()
        drop.now = { clock }
        let takes = Takes()
        drop.isEditable = { true }
        drop.eraseLeaked = { takes.erased.append($0) }
        let voice = OnboardingVoiceSignal(appState: nil)
        drop.attach(shortcut: shortcut, gesture: gesture, voice: voice) { takes.texts.append($0) }
        return (drop, voice, takes, { clock = clock.addingTimeInterval(1.5) })
    }

    private func key(_ type: NSEvent.EventType, _ code: UInt16, _ characters: String = " ",
                     flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: isRepeat,
                         keyCode: code)!
    }

    /// Held Space behaves as Drop's own Space hold in the app (the same
    /// SpaceHoldDetector and swallow rule): the first space prints, the hold
    /// past the threshold erases what printed and records, its auto-repeats
    /// and its release are swallowed, and letting go drops the text.
    func testThePreviewHoldsSpaceLikeDrop() async throws {
        let (drop, voice, takes, later) = previewDrop()
        defer { drop.detach() }
        XCTAssertNotNil(drop.handle(key(.keyDown, 0, "a")), "other keys still type")
        XCTAssertNotNil(drop.handle(key(.keyDown, 49)), "the first space prints, as in the app")
        XCTAssertNotNil(drop.handle(key(.keyDown, 49, isRepeat: true)), "before the threshold it is still typing")
        try await eventually { voice.recording }
        XCTAssertEqual(takes.erased, [2], "the two spaces that printed are erased when the hold is confirmed")
        XCTAssertNil(drop.handle(key(.keyDown, 49, isRepeat: true)), "repeats while recording never reach the field")
        later()
        XCTAssertNil(drop.handle(key(.keyUp, 49)), "the release is Drop's too")
        XCTAssertFalse(voice.recording, "letting go ends the take")
        try await eventually { !voice.working }
        XCTAssertEqual(takes.texts, [OnboardingPreviewDrop.text])
    }

    /// A short Space tap is just a space, as with Drop in the app.
    func testAQuickSpaceTapIsJustASpace() async throws {
        let (drop, voice, takes, _) = previewDrop()
        defer { drop.detach() }
        XCTAssertNotNil(drop.handle(key(.keyDown, 49)))
        XCTAssertNotNil(drop.handle(key(.keyUp, 49)))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(voice.recording)
        XCTAssertEqual(takes.erased, [], "nothing to erase")
        XCTAssertEqual(takes.texts, [])
    }

    /// Outside a text field a hold records nothing, as Drop's check decides.
    func testAHoldOutsideATextFieldDoesNothing() async throws {
        let (drop, voice, _, _) = previewDrop()
        defer { drop.detach() }
        drop.isEditable = { false }
        _ = drop.handle(key(.keyDown, 49))
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(voice.recording)
        XCTAssertNotNil(drop.handle(key(.keyUp, 49)))
    }

    private func recording(_ drop: OnboardingPreviewDrop, _ voice: OnboardingVoiceSignal) async throws {
        _ = drop.handle(key(.keyDown, 49))
        try await eventually { voice.recording }
    }

    /// A key released while the window is not in front never arrives: the
    /// take ends when the window or the app loses focus.
    func testLosingFocusEndsTheTake() async throws {
        for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            let (drop, voice, _, later) = previewDrop()
            try await recording(drop, voice)
            later()
            NotificationCenter.default.post(name: name, object: nil)
            XCTAssertFalse(voice.recording, "\(name.rawValue) ends the take")
            try await eventually { !voice.working }
            XCTAssertNotNil(drop.handle(key(.keyUp, 49)), "the late release is ordinary again")
            drop.detach()
        }
    }

    func testATakeEndsByItselfAfterItsLongestLength() async throws {
        let (drop, voice, _, _) = previewDrop()
        defer { drop.detach() }
        drop.longestTake = 0.15
        try await recording(drop, voice)
        try await eventually({ !voice.recording })
        try await eventually { !voice.working }
    }

    /// Continue, Skip or Back mid-take: the take is dropped and nothing
    /// arrives afterwards.
    func testLeavingTryDropEndsTheTake() async throws {
        let (drop, voice, takes, later) = previewDrop()
        try await recording(drop, voice)
        later()
        drop.detach()
        XCTAssertFalse(voice.recording)
        XCTAssertFalse(voice.working)
        XCTAssertNotNil(drop.handle(key(.keyDown, 49)), "nothing listens once the step is gone")
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(takes.texts, [])
    }

    /// A tap shortcut (a combo here) starts with one press and ends with the
    /// next; a combo needs its modifiers.
    func testATapShortcutTogglesTheTake() async throws {
        let combo = HotkeyTapCombo(keyCode: 2, modifiers: UInt32(cmdKey | shiftKey), keyTitle: "D")
        let (drop, voice, takes, later) = previewDrop(.combo(combo), gesture: .tap)
        defer { drop.detach() }
        XCTAssertNotNil(drop.handle(key(.keyDown, 2, "d")), "without its modifiers it is just a letter")
        XCTAssertFalse(voice.recording)
        XCTAssertNil(drop.handle(key(.keyDown, 2, "d", flags: [.command, .shift])))
        XCTAssertNil(drop.handle(key(.keyUp, 2, "d", flags: [.command, .shift])))
        XCTAssertTrue(voice.recording, "a tap shortcut keeps recording after the key comes up")
        later()
        _ = drop.handle(key(.keyDown, 2, "d", flags: [.command, .shift]))
        XCTAssertFalse(voice.recording)
        try await eventually { !voice.working }
        XCTAssertEqual(takes.texts, [OnboardingPreviewDrop.text])
    }

    /// End to end, in a real window: once Try Drop is on screen the preview
    /// listens, Space sent through the app (with the field holding the
    /// keyboard) records instead of typing, and letting go drops the text
    /// into the field; once the step is gone nothing listens.
    func testSpaceInThePreviewWindowDictatesIntoTheField() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        let drop = try XCTUnwrap(model.dropStandIn as? OnboardingPreviewDrop)
        drop.transcribing = 0.01
        drop.shortestTake = 0
        drop.threshold = 0.05
        let configuration = model.hotkeys.configuration
        let stage = OnboardingTryDropStage(model: model, shortcut: configuration.dropVoiceShortcut,
                                           gesture: configuration.normalizedDropGesture)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: stage)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await eventually { drop.isListening }
        let field = try XCTUnwrap(Self.textView(in: host))
        window.makeFirstResponder(field)
        // This window is never key in a test; Drop's check looks at the field.
        drop.isEditable = { field.isEditable }
        drop.eraseLeaked = { count in for _ in 0..<count { field.deleteBackward(nil) } }
        func send(_ type: NSEvent.EventType, isRepeat: Bool = false) {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: " ",
                                         charactersIgnoringModifiers: " ", isARepeat: isRepeat, keyCode: 49)!
            NSApp.sendEvent(event)
        }
        // A short tap is a space, as with Drop in the app: the monitor lets
        // it through to the field (a test window is never key, so the passed
        // event is handed to the field the way AppKit would).
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: " ",
                                         charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
            if let passed = drop.handle(event), type == .keyDown { field.keyDown(with: passed) }
        }
        XCTAssertEqual(field.string, " ")
        field.string = ""
        // A hold: the space that printed is erased, repeats never print.
        send(.keyDown)
        try await eventually { model.voice.recording }
        XCTAssertEqual(field.string, "", "the printed space is erased when the hold is confirmed")
        for _ in 0..<5 { send(.keyDown, isRepeat: true) }
        XCTAssertEqual(field.string, "", "no spaces while held")
        send(.keyUp)
        XCTAssertFalse(model.voice.recording, "letting go ends it")
        try await eventually { field.string == OnboardingPreviewDrop.text }
        try await eventually { model.outcome(.tryDrop).isDone }
        window.contentView = nil
        window.close()
        try await eventually { !drop.isListening }
    }

    /// The same in the whole onboarding window: Try Drop reached by walking
    /// the steps (with their transitions), then Space held and released.
    func testSpaceInTheWholeWindowNeverTypesIntoTryDrop() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        let drop = try XCTUnwrap(model.dropStandIn as? OnboardingPreviewDrop)
        drop.transcribing = 0.01
        drop.shortestTake = 0
        drop.threshold = 0.05
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: OnboardingJourneyView(model: model))
        window.contentView = host
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        await model.useSpeechKey("sk-preview-0123456789abcdef", provider: .elevenLabs)
        var guardSteps = 0
        while model.step != .tryDrop, guardSteps < 30 {
            model.next(); guardSteps += 1
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        XCTAssertEqual(model.step, .tryDrop)
        try await Task.sleep(nanoseconds: 900_000_000)  // the step's glide ends
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(drop.isListening, "Try Drop listens once it has arrived")
        let field = try XCTUnwrap(Self.textView(in: host))
        window.makeFirstResponder(field)
        drop.isEditable = { field.isEditable }
        drop.eraseLeaked = { count in for _ in 0..<count { field.deleteBackward(nil) } }
        func send(_ type: NSEvent.EventType, isRepeat: Bool = false) {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: " ",
                                         charactersIgnoringModifiers: " ", isARepeat: isRepeat, keyCode: 49)!
            NSApp.sendEvent(event)
        }
        send(.keyDown)
        try await eventually { model.voice.recording }
        for _ in 0..<5 { send(.keyDown, isRepeat: true) }
        XCTAssertEqual(field.string, "", "no spaces while held")
        send(.keyUp)
        try await eventually { field.string == OnboardingPreviewDrop.text }
        window.contentView = nil
        window.close()
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        for sub in view.subviews { if let found = textView(in: sub) { return found } }
        return nil
    }

    /// From any Try Drop state, Skip and Back leave the step, a take running
    /// included; the preview has its Drop stand-in and the app has none.
    func testTryDropCanAlwaysBeLeft() async throws {
        let session = makeSession()
        defer { session.clear() }
        let model = session.model
        XCTAssertTrue(model.dropStandIn is OnboardingPreviewDrop)
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        await model.useSpeechKey("sk-preview-0123456789abcdef", provider: .elevenLabs)
        var guardSteps = 0
        while model.step != .tryDrop, guardSteps < 30 { model.next(); guardSteps += 1 }
        XCTAssertEqual(model.step, .tryDrop)
        let index = try XCTUnwrap(model.steps.firstIndex(of: .tryDrop))
        let before = model.steps[index - 1]
        model.voice.phaseChanged(.recording)
        model.next()
        XCTAssertEqual(model.step, .toolbox, "Skip while recording; Shortcuts is gone (REV 64)")
        model.back()
        XCTAssertEqual(model.step, .tryDrop)
        model.voice.phaseChanged(.recording)
        model.back()
        XCTAssertEqual(model.step, before, "Back while recording")
        model.voice.phaseChanged(.idle)
    }

    /// The last step's list holds real questions for the Ask agent, each
    /// short enough for one line and under Ask's 300-character limit; a
    /// click opens whytap.ai with the question in the link, which the page
    /// asks on load (REV 66).
    func testTheLastStepAsksRealQuestionsOnWhytapAI() throws {
        let questions = OnboardingQuestionList.questions
        XCTAssertGreaterThanOrEqual(questions.count, 16, "REV 69: a bigger pool")
        XCTAssertEqual(Set(questions).count, questions.count)
        for question in questions {
            XCTAssertLessThanOrEqual(question.count, 52, "one line: \(question)")
            XCTAssertTrue(question.hasSuffix("?"))
        }
        let url = OnboardingQuestionList.link(for: "Can I run Whytap fully local with Ollama?")
        XCTAssertEqual(url.host, "whytap.ai")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query, [URLQueryItem(name: "q", value: "Can I run Whytap fully local with Ollama?")])
        // REV 69: the whole list drifts from the bottom up, four rows in
        // view, the loop closing without a seam; the pointer holds it.
        let list = OnboardingQuestionList.self
        XCTAssertEqual(list.visible(at: 0, inFull: true), [0, 1, 2, 3], "four rows in full at rest, none dimmed")
        XCTAssertEqual(list.visible(at: list.step, inFull: true), [1, 2, 3, 4])
        XCTAssertEqual(list.visible(at: list.step / 2), [0, 1, 2, 3, 4], "the next rises in as the top one leaves")
        XCTAssertEqual(list.visible(at: list.step / 2, inFull: true), [1, 2, 3])
        XCTAssertEqual(list.offset(list.round, wholeRows: false), 0, accuracy: 0.001, "the loop closes")
        XCTAssertEqual(list.visible(at: list.round - list.step, inFull: true), [questions.count - 1, 0, 1, 2],
                       "the last row leads back to the first")
        XCTAssertEqual(list.offset(list.step * 1.6, wholeRows: true), list.step, "Reduce Motion: whole rows")
        var seen = Set<Int>()
        var travel: CGFloat = 0
        while travel < list.round { seen.formUnion(list.visible(at: list.offset(travel, wholeRows: false))); travel += 3 }
        XCTAssertEqual(seen.count, questions.count, "every question comes round")
        let drift = OnboardingQuestionDrift()
        _ = drift.advance(to: 0, paused: false, still: false)
        var time = 0.0
        for _ in 0..<60 { time += 1.0 / 60; _ = drift.advance(to: time, paused: false, still: false) }
        XCTAssertEqual(drift.travel, list.speed, accuracy: 0.5, "a slow drift: \(list.speed) pt a second")
        let held = drift.travel
        for _ in 0..<60 { time += 1.0 / 60; _ = drift.advance(to: time, paused: true, still: false) }
        XCTAssertEqual(drift.travel, held, "the pointer on the list holds it")
        time += 30
        _ = drift.advance(to: time, paused: false, still: false)
        XCTAssertLessThanOrEqual(drift.travel - held, list.speed * 0.6 + 0.001, "a long gap does not jump ahead")
        let quiet = OnboardingQuestionDrift()
        for step in 0..<60 { _ = quiet.advance(to: Double(step) / 60, paused: false, still: true) }
        XCTAssertEqual(quiet.travel, 0, "offscreen renders hold still")
    }

    /// The ring shows the whole Toolbox catalog Settings lists (every tool
    /// but Settings, a tool not out yet included), and the card names the
    /// tool under the pointer or says what Toolbox is.
    func testToolboxShowsTheWholeCatalog() {
        let tools = OnboardingToolboxStage.tools
        XCTAssertEqual(tools, HoverTool.allCases.filter { $0 != .settings })
        XCTAssertGreaterThan(tools.count, 6, "the whole catalog, not six tools")
        XCTAssertTrue(tools.contains(.calendar))
        XCTAssertFalse(tools.contains(.settings))
        XCTAssertEqual(OnboardingToolboxStage.card(for: nil).title, "Your quick tools")
        let shot = OnboardingToolboxStage.card(for: .screenshot)
        XCTAssertEqual(shot.title, "Shot")
        XCTAssertEqual(shot.text, HoverToolRegistry.info(for: .screenshot).description)
        if HoverTool.calendar.isComingSoon {
            XCTAssertEqual(OnboardingToolboxStage.card(for: .calendar).text, CalendarAvailability.message)
        }
        // The whole catalog fits the ring at every point of its turn: tiles
        // never touch each other, never cover the card, never leave the area.
        let sizes: [CGSize] = [CGSize(width: 520, height: 186), CGSize(width: 520, height: 210)]
        let tile = Double(OnboardingToolboxStage.tile)
        let card = OnboardingToolboxStage.cardSize
        for size in sizes {
            XCTAssertEqual(Double(OnboardingToolboxStage.spots(tools.count, in: size)[0].x), Double(size.width) / 2,
                           accuracy: 0.5, "the first tile starts at the top")
            for step in 0..<40 {
                let turn = Double(step) / 40 / Double(tools.count)
                let spots: [CGPoint] = OnboardingToolboxStage.spots(tools.count, in: size, turn: turn)
                XCTAssertEqual(spots.count, tools.count)
                XCTAssertGreaterThan(Self.closestTiles(spots, in: size), 0, "tiles touch at \(size), turn \(turn)")
                for spot in spots {
                    let half = Double(OnboardingToolboxStage.tileScale(spot, in: size)) * tile / 2
                    let x = Double(spot.x), y = Double(spot.y)
                    XCTAssertGreaterThanOrEqual(x - half, 0); XCTAssertLessThanOrEqual(x + half, Double(size.width))
                    XCTAssertGreaterThanOrEqual(y - half, 0); XCTAssertLessThanOrEqual(y + half, Double(size.height))
                    let dx = abs(x - Double(size.width) / 2) - Double(card.width) / 2
                    let dy = abs(y - Double(size.height) / 2) - Double(card.height) / 2
                    XCTAssertGreaterThan(max(dx, dy), half + 4, "a tile covers the card at \(size), turn \(turn)")
                }
            }
        }
    }

    /// The ring turns slowly on its own, holds while a tile is pointed at and
    /// stands still under Reduce Motion.
    func testTheToolboxRingTurnsLikeACarousel() {
        let carousel = OnboardingCarousel()
        _ = carousel.advance(to: 100, paused: false, still: false)
        let moving = carousel.advance(to: 100.04, paused: false, still: false)
        XCTAssertGreaterThan(moving, 0)
        XCTAssertEqual(carousel.advance(to: 100.08, paused: true, still: false), moving, "a pointed tile stops it")
        XCTAssertGreaterThan(carousel.advance(to: 100.12, paused: false, still: false), moving, "and it goes on")
        let held = carousel.turn
        XCTAssertEqual(carousel.advance(to: 100.16, paused: false, still: true), held, "Reduce Motion stands still")
        var turn = 0.0
        for frame in 0..<(60 * 80) { turn = carousel.advance(to: 200 + Double(frame) / 60, paused: false, still: false) }
        XCTAssertLessThan(turn, 1, "it wraps around")
    }

    /// The smallest clearance between two tiles at their tilted sizes.
    private static func closestTiles(_ spots: [CGPoint], in size: CGSize) -> Double {
        var closest = Double.infinity
        let tile = Double(OnboardingToolboxStage.tile)
        for i in spots.indices {
            for j in spots.indices where j > i {
                let dx: Double = Double(abs(spots[i].x - spots[j].x))
                let dy: Double = Double(abs(spots[i].y - spots[j].y))
                let si: Double = Double(OnboardingToolboxStage.tileScale(spots[i], in: size))
                let sj: Double = Double(OnboardingToolboxStage.tileScale(spots[j], in: size))
                closest = min(closest, max(dx, dy) - (si + sj) / 2 * tile)
            }
        }
        return closest
    }
}

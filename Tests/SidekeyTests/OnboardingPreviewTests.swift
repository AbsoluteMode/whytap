import AppKit
import SwiftUI
import XCTest
@testable import Sidekey
@testable import OnboardingPreviewKit

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
        XCTAssertEqual(model.step, .language, "Anthropic searches the web itself: no Tavily step")
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
        XCTAssertEqual(model.step, .language)
        model.setLanguage(nil)
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
        for expected in [OnboardingStep.hotkeys, .toolbox, .thanks] {
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

        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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

    /// "Use your own server →" turns the key field into the server's fields
    /// on the same step; Back returns to the key field, Save is the step done.
    func testOwnServerChangesTheStepAndComesBack() async throws {
        let suite = "OnboardingPreviewTests-\(UUID().uuidString)"
        let session = OnboardingPreviewSession(suiteName: suite)
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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

        // No automatic move: the step waits for a pick or Next.
        try await Task.sleep(for: .milliseconds(1_600))
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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
        try await Task.sleep(for: .milliseconds(1_600))
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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
            for (name, query) in [("model-search-openrouter", ""), ("model-search-openrouter-gemini", "gemini")] {
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
            for fake in ["OnboardingPreviewProviders", "OnboardingPreviewSession", "OnboardingPreviewURLProtocol",
                         "OnboardingPreviewTokenStore"] {
                XCTAssertFalse(text.contains(fake), "\(file.lastPathComponent) names \(fake)")
            }
        }
        let delegate = try String(contentsOf: app.appendingPathComponent("AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(delegate.contains("let model = OnboardingJourneyModel()"),
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
        let session = OnboardingPreviewSession(suiteName: suite)
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
        XCTAssertEqual(OnboardingAccessKind.keyboard.pane, "Accessibility")
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

    /// Shortcuts shows the person's own keys: Drop and the Agent first, then
    /// the tools that have a shortcut, six at most; the Agent says Off while
    /// it is off; the keys over the list follow a row's modifiers (REV 58).
    func testShortcutRowsComeFromTheConfiguration() {
        var configuration = HotkeyPreferences(defaults: UserDefaults(suiteName: "OnboardingShortcuts-\(UUID().uuidString)")!)
            .configuration
        let rows = OnboardingShortcutRow.rows(configuration, agentEnabled: false)
        XCTAssertEqual(rows.prefix(2).map(\.id), ["drop", "agent"])
        XCTAssertEqual(rows[0].shortcut, configuration.dropVoiceShortcut)
        XCTAssertEqual(rows[1].note, "Off")
        XCTAssertNil(OnboardingShortcutRow.rows(configuration, agentEnabled: true)[1].note)
        XCTAssertLessThanOrEqual(rows.count, 6)
        for row in rows.dropFirst(2) {
            let tool = HoverTool(rawValue: row.id)
            XCTAssertNotNil(tool.flatMap { configuration.toolShortcuts[$0] }, "only tools with a shortcut")
        }
        configuration.toolShortcuts = [:]
        XCTAssertEqual(OnboardingShortcutRow.rows(configuration, agentEnabled: true).count, 2)
        let command = OnboardingShortcutRow(id: "x", title: "X", symbol: "x", shortcut: configuration.agentTextShortcut)
        XCTAssertEqual(command.modifiers.count, 3)
    }

    /// Try Drop says which key to hold once, in the field's header: the
    /// placeholder, the line under the field and the capsule do not repeat it.
    func testTryDropSaysTheKeyOnce() {
        let placeholder = OnboardingTryDropStage.placeholder.lowercased()
        XCTAssertFalse(placeholder.contains("hold") || placeholder.contains("press") || placeholder.contains("space"))
        for holds in [true, false] {
            XCTAssertEqual(OnboardingTryDropStage.hint(.waiting, holds: holds), "", "no line at rest")
            let states: [OnboardingTryState] = [.waiting, .recording, .done, .failed(OnboardingJourneyModel.noSpeech)]
            for state in states {
                let line = OnboardingTryDropStage.hint(state, holds: holds)
                XCTAssertFalse(line.hasPrefix("Hold") || line.contains("Space"), "\(state) repeats the instruction")
            }
        }
        XCTAssertEqual(OnboardingTryDropStage.hint(.failed(OnboardingJourneyModel.noSpeech), holds: true),
                       OnboardingJourneyModel.noSpeech)
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
        // The whole catalog fits the ring in the window without tiles
        // touching (at their tilted sizes), the first at the top.
        let sizes: [CGSize] = [CGSize(width: 520, height: 186), CGSize(width: 520, height: 210)]
        for size in sizes {
            let spots: [CGPoint] = OnboardingToolboxStage.spots(tools.count, in: size)
            XCTAssertEqual(spots.count, tools.count)
            XCTAssertEqual(Double(spots[0].x), Double(size.width) / 2, accuracy: 0.5)
            XCTAssertLessThan(Double(spots[0].y), Double(size.height) / 2)
            XCTAssertGreaterThan(Self.closestTiles(spots, in: size), 2, "tiles touch at \(size)")
        }
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

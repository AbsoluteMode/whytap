import AppKit
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
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
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
        var server = OnboardingServerDraft(address: "localhost:11434/v1", use: .transcription)
        XCTAssertFalse(server.canSave, "a server needs a model")
        XCTAssertEqual(server.name, "Ollama", "the name comes from the address")
        server.model = "whisper-large-v3"
        await model.saveServer(server, on: .speech)
        XCTAssertEqual(model.outcome(.speechKey), .done("Ollama · whisper-large-v3"))
        XCTAssertEqual(model.step, .speechKey, "the fields stay until the step moves on")
        XCTAssertTrue(model.showsServerForm(.speech), "no return to the key field before the move")
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

    /// OpenAI speech has more than one model: the speech step offers them
    /// too, with the per-minute price, the recommended one set and first, and
    /// waits; Next keeps the recommended model.
    func testOpenAISpeechOffersItsModelsAndWaits() async throws {
        let session = OnboardingPreviewSession(suiteName: "OnboardingPreviewTests-\(UUID().uuidString)")
        defer { session.clear() }
        let model = session.model
        model.chooseYourKey()
        try await eventually { model.step == .speechKey }
        model.speechProvider = .openAI
        await model.useSpeechKey("sk-proj-good-0123456789abcdef", provider: .openAI)
        XCTAssertTrue(model.outcome(.speechKey).isDone)
        let choices = model.modelChoices(.speechKey)
        XCTAssertGreaterThan(choices.count, 1, "\(choices.map(\.id))")
        XCTAssertEqual(choices.first { $0.id == ModelRegistry.openAILiveModel }?.price, "$0.017 / min")
        XCTAssertEqual(model.currentModel(.speechKey), ModelRegistry.openAILiveModel)
        XCTAssertEqual(choices.first?.id, model.recommendedModel(.speechKey), "the recommended model is first")
        try await Task.sleep(for: .milliseconds(1_600))
        XCTAssertEqual(model.step, .speechKey, "the step waits for a pick or Next")
        model.next()
        XCTAssertEqual(model.step, .llmKey)
        XCTAssertEqual(model.currentModel(.speechKey), ModelRegistry.openAILiveModel, "Next keeps the recommended model")
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
}

import AppKit
import AVFoundation
import FluidAudio
import SwiftUI
import XCTest
@testable import Sidekey
@testable import OnboardingPreviewKit

/// The new onboarding as a person goes through it: what each choice sets for
/// every speech and language feature, the automatic move after a success,
/// a refused key, Back during the success beat and permissions granted in
/// System Settings. Stores are temporary, keys live in memory, key checks and
/// model checks are offline fakes, nothing is downloaded and no window shows.
/// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingJourneyModelTests: XCTestCase {
    private var originalStatus: DropHotkeyStatus = .unavailable

    override func setUp() {
        super.setUp()
        originalStatus = AppState.shared.dropHotkeyStatus
    }

    override func tearDown() {
        AppState.shared.dropHotkeyStatus = originalStatus
        super.tearDown()
    }

    // MARK: - Fixtures

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private struct NoModel: Error {}

    private actor FakeStore: OnDeviceSpeechModelManaging {
        let present: Box<Bool>
        init(present: Box<Bool>) { self.present = present }
        func status() -> OnDeviceSpeechModelStatus { present.value ? .ready : .notDownloaded }
        func download(progress: (@Sendable (Double) -> Void)?) async throws { present.value = true }
        func delete() async throws { present.value = false }
        func acquire() async throws -> AsrManager { throw NoModel() }
        func release() {}
    }

    private struct Offline: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        var refusing: Set<String> = []
        /// Language model catalogs as the providers list them: OpenAI has no
        /// registry default, so the newest model the Agent can use is preselected.
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            func model(_ id: String, daysAgo: Double) -> CatalogModel {
                var model = CatalogModel(id: id, uses: [.chat, .chatWithTools], contextLength: 400_000, supportsTools: true)
                model.catalogDate = Date(timeIntervalSince1970: 1_790_000_000 - daysAgo * 86_400)
                return model
            }
            switch account.kind {
            case .anthropic: return [model(ModelRegistry.anthropicAgentModel, daysAgo: 30)]
            case .openAI: return [model("gpt-5.4", daysAgo: 200), model("gpt-5.6", daysAgo: 10), model("gpt-5.5", daysAgo: 90)]
            default: return []
            }
        }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
            refusing.contains(account.storageID) ? .rejected(.invalidKey) : .valid
        }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
    }

    /// A key check that waits for the test for the listed key values.
    private final class GatedChecker: ProviderKeyChecking, @unchecked Sendable {
        private let lock = NSLock()
        private var gated: Set<String>
        private var waiting: [(key: String, resume: CheckedContinuation<Void, Never>)] = []
        init(gated: Set<String>) { self.gated = gated }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
            if let apiKey, lock.withLock({ gated.contains(apiKey) }) {
                await withCheckedContinuation { resume in lock.withLock { waiting.append((apiKey, resume)) } }
            }
            return .valid
        }
        func isWaiting(_ key: String) -> Bool { lock.withLock { waiting.contains { $0.key == key } } }
        func release(_ key: String) {
            let resumes: [CheckedContinuation<Void, Never>] = lock.withLock {
                gated.remove(key)
                let found = waiting.filter { $0.key == key }.map(\.resume)
                waiting.removeAll { $0.key == key }
                return found
            }
            resumes.forEach { $0.resume() }
        }
    }

    /// The success beat, held until the test lets it end.
    private final class Beat {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }
        func wait() async { await withCheckedContinuation { waiting.append($0) } }
        func end() { let all = waiting; waiting = []; all.forEach { $0.resume() } }
    }

    private struct Env {
        let defaults: UserDefaults
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let modelPresent: Box<Bool>
        let snapshot: Box<PermissionsHelper.Snapshot>
        let screen: Box<Bool>
        let beat = Beat()
    }

    private func makeEnv(modelPresent: Bool = false, accessibility: Bool = false,
                         microphone: AVAuthorizationStatus = .notDetermined) throws -> Env {
        let suite = "OnboardingJourneyModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let box = InMemoryTokenStore.Box()
        return Env(defaults: defaults, routing: AIRoutingStore(defaults: defaults),
                   keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) }),
                   modelPresent: Box(modelPresent),
                   snapshot: Box(.init(accessibilityGranted: accessibility, microphoneStatus: microphone)),
                   screen: Box(false))
    }

    private func makeModel(_ env: Env, refusing: [ProviderAccount] = [], supportsOnDevice: Bool = true,
                           hotkey: DropHotkeyStatus = .accessibilityRequired,
                           keyChecker: ProviderKeyChecking? = nil,
                           offersOpenAISpeech: Bool = false, isPreview: Bool = false,
                           realCatalogs: Bool = false) throws -> OnboardingJourneyModel {
        AppState.shared.dropHotkeyStatus = hotkey
        let catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent("journey-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: catalogURL) }
        if realCatalogs {
            let cached = [ProviderAccount.openRouter.storageID:
                            CatalogSnapshot(models: OnboardingPreviewProviders.openRouter, fetchedAt: Date())]
            try JSONEncoder().encode(cached).write(to: catalogURL)
        } else {
            try Data("{}".utf8).write(to: catalogURL)
        }
        let offline = Offline(refusing: Set(refusing.map(\.storageID)))
        let present = env.modelPresent
        let readiness = OnDeviceSpeechReadiness { present.value }
        let models = APIAndModelsViewModel(
            routing: env.routing, keys: env.keys,
            catalogs: ModelCatalogStore(fileURL: catalogURL,
                                        fetcher: realCatalogs ? OnboardingPreviewProviders() as ModelCatalogFetching : offline),
            checks: ModelCheckStore(defaults: env.defaults), keyStatuses: KeyStatusStore(defaults: env.defaults),
            keyChecker: keyChecker ?? offline, probe: offline, serverModelChecker: OnboardingPreviewProviders(),
            endpoints: offline, inputLanguage: { nil }, onDevice: readiness)
        let snapshot = env.snapshot
        let screen = env.screen
        let permissions = PermissionsSettingsViewModel(
            onComplete: {}, autoComplete: false,
            snapshotProvider: { snapshot.value }, screenRecordingAccessProvider: { screen.value },
            screenRecordingRequester: {}, accessibilityRequester: {}, openAccessibilitySettings: {},
            openScreenRecordingSettings: {}, runtimeRefresh: { _, _ in })
        let beat = env.beat
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingPreviewURLProtocol.self]
        let tavily = TavilySettings(keys: env.keys, search: TavilySearch(http: NativeAgentHTTP(session: URLSession(configuration: configuration))))
        let model = OnboardingJourneyModel(
            models: models, permissions: permissions,
            onDevice: OnDeviceSpeechModelController(store: FakeStore(present: env.modelPresent)),
            dropSpeech: OnboardingDropSpeech(routing: env.routing, keys: env.keys, onDevice: readiness, mode: { .fast }),
            supportsOnDevice: supportsOnDevice,
            preferences: PrivacyPreferences(defaults: env.defaults),
            screenRecording: ScreenRecordingAccess(isGranted: { screen.value }, request: {}),
            openScreenRecordingSettings: {}, defaultsChanges: NotificationCenter(),
            dwellWait: { _ in await beat.wait() },
            tavily: tavily,
            isPreview: isPreview,
            offersOpenAISpeech: offersOpenAISpeech)
        addTeardownBlock { model.stop() }
        return model
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Condition never became true", file: file, line: line)
    }

    /// Lets the success beat end and waits for the step it leads to.
    private func endBeat(_ env: Env, until step: OnboardingStep, in model: OnboardingJourneyModel,
                         file: StaticString = #filePath, line: UInt = #line) async throws {
        try await eventually({ env.beat.count > 0 }, file: file, line: line)
        env.beat.end()
        try await eventually({ model.step == step }, file: file, line: line)
    }

    private let speechFeatures: [AIFeature] = [.dropFast, .dropSmart, .agentVoice, .voiceSearch, .meetings]
    private let llmFeatures: [AIFeature] = [.dropSmartCleanup, .meetingNotes, .agent, .translation]

    // MARK: - Your own server

    /// The owner, 2026-11-22: no separate screen. In the app too, "Use your
    /// own server →" turns the step's key field into the server's fields;
    /// Settings does not open and the step stays.
    func testTheServerLinkChangesTheStepInPlace() throws {
        let model = try makeModel(makeEnv())
        var settings: [SettingsWindowTab] = []
        model.openSettings = { tab, _ in settings.append(tab) }
        model.chooseYourKey()
        model.useOwnServer(.speech)
        XCTAssertTrue(model.showsServerForm(.speech))
        XCTAssertFalse(model.showsServerForm(.languageModel))
        model.useOwnServer(.search)
        XCTAssertFalse(model.showsServerForm(.search), "search has no server")
        XCTAssertTrue(settings.isEmpty)
        model.closeServerForm(.speech)
        XCTAssertFalse(model.showsServerForm(.speech))
    }

    /// Save adds the server the way Settings does (address, key, the model's
    /// check), sets the shared row and moves straight on to the next step.
    func testAServerModelIsAddedCheckedAndUsed() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        model.next()
        XCTAssertEqual(model.step, .llmKey)
        model.useOwnServer(.languageModel)
        var server = OnboardingServerDraft(address: "localhost:11434/v1", model: "bad-model")
        await model.saveServer(server, on: .languageModel)
        XCTAssertEqual(model.outcome(.llmKey), .failed("Ollama has no model named bad-model"))
        XCTAssertTrue(model.showsServerForm(.languageModel), "a refusal keeps the fields")
        server.model = "qwen3:8b"
        await model.saveServer(server, on: .languageModel)
        XCTAssertEqual(model.outcome(.llmKey), .done("Ollama · qwen3:8b"))
        let routed = llmFeatures.compactMap { env.routing.route(for: $0) }
        XCTAssertFalse(routed.isEmpty, "the shared LLM row took the server model")
        for route in routed {
            XCTAssertEqual(route.model, "qwen3:8b")
            guard case .server = route.account else { return XCTFail("text features run on the added server") }
        }
        XCTAssertEqual(env.routing.state.servers.count, 1, "the second try reused the server")
        XCTAssertTrue(model.steps.contains(.search), "a server model has no known web search")
        try await endBeat(env, until: .search, in: model)
    }

    // MARK: - OpenAI for speech and text

    func testOpenAIIsOfferedForSpeechOnlyOnceTheAppCanRunItsSpeechModels() throws {
        let env = try makeEnv()
        XCTAssertEqual(try makeModel(env).speechProviders, [.soniox, .deepgram, .elevenLabs],
                       "until task #73 the registry has no OpenAI speech model")
        XCTAssertEqual(OnboardingJourneyModel.offersOpenAISpeech,
                       ModelRegistry.recommended(for: .dropFast, kind: .openAI) != nil, "the registry decides")
        XCTAssertEqual(try makeModel(try makeEnv(), offersOpenAISpeech: true).speechProviders,
                       [.soniox, .deepgram, .elevenLabs, .openAI])
    }

    func testAnOpenAIKeyFromTheLanguageModelStepIsNotAskedForAgainForSpeech() async throws {
        let env = try makeEnv()
        let model = try makeModel(env, offersOpenAISpeech: true)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        model.next()
        XCTAssertEqual(model.step, .llmKey, "speech set up later")
        model.llmProvider = .openAI
        await model.useLLMKey("sk-openai-0123456789abcdef", provider: .openAI)
        XCTAssertTrue(model.outcome(.llmKey).isDone)

        model.back()
        XCTAssertEqual(model.step, .speechKey)
        XCTAssertEqual(model.speechProvider, .openAI, "the speech step opens on the key it already has")
        XCTAssertTrue(model.keySaved(.openAI), "Use saved, no second paste")
    }

    func testASpeechKeyThatAlsoServesTextOpensTheLanguageModelStepOnIt() async throws {
        let env = try makeEnv()
        let model = try makeModel(env, offersOpenAISpeech: true)
        let problem = await model.models.replaceKey("sk-openai-0123456789abcdef", for: try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: .openAI)))
        XCTAssertNil(problem)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        model.speechProvider = .openAI
        model.next()
        XCTAssertEqual(model.step, .llmKey)
        XCTAssertEqual(model.llmProvider, .openAI, "the saved OpenAI key is offered, not asked again")
    }

    // MARK: - Your key

    func testACleanMacWithASpeechKeyGetsSpeechEverywhereAndMovesOnByItself() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        XCTAssertEqual(model.step, .source)
        XCTAssertFalse(model.canGoBack, "the first step has no Back")

        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        await model.useSpeechKey("sk-eleven-0123456789abcdef", provider: .elevenLabs)
        XCTAssertEqual(model.outcome(.speechKey), .done(ModelRegistry.elevenLabsRealtimeModel), "the field shows the model it set")
        for feature in speechFeatures {
            XCTAssertEqual(env.routing.route(for: feature)?.account, .elevenLabs, "\(feature) follows the shared Speech")
        }
        XCTAssertEqual(env.routing.route(for: .meetings)?.model, ModelRegistry.recommended(for: .meetings, kind: .elevenLabs),
                       "Meetings gets the recorded counterpart")
        XCTAssertEqual(model.step, .speechKey, "the success shows for a beat first")
        try await endBeat(env, until: .llmKey, in: model)
        XCTAssertTrue(model.steps.contains(.tryDrop), "speech is on the way, so Try Drop is too")
    }

    func testARefusedKeyStaysWithTheReasonAndSetsNothing() async throws {
        let env = try makeEnv()
        let model = try makeModel(env, refusing: [.soniox])
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        await model.useSpeechKey("bad-0123456789abcdef", provider: .soniox)
        guard case .failed = model.outcome(.speechKey) else { return XCTFail("expected a failure, got \(model.outcome(.speechKey))") }
        XCTAssertEqual(model.step, .speechKey)
        XCTAssertEqual(env.beat.count, 0, "nothing moves on")
        XCTAssertNil(env.routing.route(for: .dropFast))
    }

    func testAKeySavedEarlierIsUsedWithoutPastingIt() async throws {
        let env = try makeEnv()
        let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: .deepgram)?.keychainAccount(in: env.routing))
        try env.keys.save("dg", account: account)
        let model = try makeModel(env)
        XCTAssertTrue(model.keySaved(.deepgram))
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        await model.useSpeechKey("", provider: .deepgram)
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .deepgram)
    }

    func testAnEarlierKeyThatFinishesLastDoesNotReplaceTheLaterChoice() async throws {
        let env = try makeEnv()
        let checker = GatedChecker(gated: ["sk-soniox-0123456789abcdef"])
        let model = try makeModel(env, keyChecker: checker)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        let first = Task { await model.useSpeechKey("sk-soniox-0123456789abcdef", provider: .soniox) }
        try await eventually { checker.isWaiting("sk-soniox-0123456789abcdef") }
        await model.useSpeechKey("sk-eleven-0123456789abcdef", provider: .elevenLabs)
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .elevenLabs)
        checker.release("sk-soniox-0123456789abcdef")
        await first.value
        for feature in speechFeatures {
            XCTAssertEqual(env.routing.route(for: feature)?.account, .elevenLabs, "\(feature) keeps the later choice")
        }
        XCTAssertTrue(model.keySaved(.soniox), "the earlier key stays saved")
    }

    // MARK: - Language model and search

    /// Anthropic searches the web itself: the Tavily step is left out.
    func testAnLLMKeySetsEveryTextFeatureAndSkipsSearchWhenItsProviderSearches() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        XCTAssertFalse(model.steps.contains(.search))
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        model.next() // Set up later for speech
        XCTAssertEqual(model.step, .llmKey)

        await model.useLLMKey("sk-ant-0123456789abcdef", provider: .anthropic)
        let expected = try XCTUnwrap(model.preselectedModel(.anthropic))
        for feature in llmFeatures {
            XCTAssertEqual(env.routing.route(for: feature), FeatureRoute(account: .anthropic, model: expected),
                           "\(feature) follows the shared LLM")
        }
        XCTAssertEqual(model.summary, "LLM: Anthropic \(expected)")
        XCTAssertFalse(model.steps.contains(.search), "Anthropic searches the web itself")
        try await endBeat(env, until: .language, in: model)
    }

    /// A server's model has no web search: the Tavily step comes after it;
    /// Back and a provider's key take the step away again.
    func testOnlyASelfHostedLanguageModelAsksForTavily() async throws {
        let env = try makeEnv()
        let model = try makeModel(env, isPreview: true)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        model.next()
        XCTAssertEqual(model.step, .llmKey)
        model.useOwnServer(.languageModel)
        await model.saveServer(OnboardingServerDraft(address: "localhost:11434/v1", model: "qwen3"), on: .languageModel)
        XCTAssertTrue(model.steps.contains(.search), "a server has no known web search")
        try await endBeat(env, until: .search, in: model)
        model.back()
        XCTAssertEqual(model.step, .llmKey)
        model.closeServerForm(.languageModel)
        await model.useLLMKey("sk-ant-0123456789abcdef", provider: .anthropic)
        XCTAssertFalse(model.steps.contains(.search), "Anthropic searches the web itself: the step goes away")
    }

    /// The Tavily step names the five problems from the real answers.
    func testTheSearchStepNamesTavilysAnswers() async throws {
        let env = try makeEnv()
        let model = try makeModel(env, isPreview: true)
        model.rejectUnrecognizedKey(on: .search)
        XCTAssertEqual(model.keyProblems[.search], .format, "one provider: a foreign key is a format problem")
        let cases: [(String, OnboardingKeyProblem)] = [
            ("tvly-bad-0123456789abcdef", .refused),
            ("tvly-credit-0123456789abcdef", .noCredit),
            ("tvly-busy-0123456789abcdef", .busy),
            ("tvly-offline-0123456789abcdef", .unreachable),
        ]
        for (key, problem) in cases {
            await model.useSearchKey(key)
            XCTAssertEqual(model.keyProblems[.search], problem, key)
            XCTAssertFalse(model.outcome(.search).isDone, key)
        }
        await model.useSearchKey("tvly-dev-0123456789abcdef")
        XCTAssertNil(model.keyProblems[.search])
        XCTAssertTrue(model.outcome(.search).isDone)
        XCTAssertTrue(model.tavily.configured)
    }

    func testSkippingTheLLMSkipsSearchToo() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        model.next()
        model.next() // skip the LLM
        XCTAssertEqual(model.step, .language)
    }

    func testTheSummaryNamesSpeechAndLLM() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        await model.useSpeechKey("sk-0123456789abcdef", provider: .soniox)
        try await endBeat(env, until: .llmKey, in: model)
        await model.useLLMKey("sk-oa-0123456789abcdef", provider: .openAI)
        XCTAssertEqual(model.preselectedModel(.openAI), "gpt-5.6", "the newest model the Agent can use")
        XCTAssertEqual(model.summary, "Speech: Soniox · LLM: OpenAI gpt-5.6")
    }

    // MARK: - On this Mac

    func testOnThisMacWithTheModelHereSetsSpeechAndSkipsTheKeyStep() async throws {
        let env = try makeEnv(modelPresent: true)
        let model = try makeModel(env)
        model.chooseOnThisMac()
        try await endBeat(env, until: .llmKey, in: model)
        XCTAssertFalse(model.steps.contains(.speechKey))
        // The step moves on at once; the routes land when the model is applied.
        try await eventually { env.routing.route(for: .voiceSearch)?.account == .thisMac }
        for feature in [AIFeature.dropFast, .dropSmart, .agentVoice, .voiceSearch] {
            XCTAssertEqual(env.routing.route(for: feature)?.account, .thisMac, "\(feature) runs on this Mac")
        }
    }

    func testOnThisMacStartsTheDownloadAndMovesOnWhileItRuns() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseOnThisMac()
        try await endBeat(env, until: .llmKey, in: model)
        try await eventually { env.routing.route(for: .dropFast)?.account == .thisMac }
        XCTAssertEqual(model.outcome(.source), .done("Speech on this Mac"))
    }

    func testAMacWithoutLocalSpeechStartsAtTheKey() throws {
        let env = try makeEnv()
        let model = try makeModel(env, supportsOnDevice: false)
        XCTAssertEqual(model.step, .speechKey)
    }

    // MARK: - Back during the beat

    func testBackDuringTheBeatStaysBack() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        await model.useSpeechKey("sk-0123456789abcdef", provider: .soniox)
        try await eventually { env.beat.count > 0 }
        model.back()
        XCTAssertEqual(model.step, .source)
        env.beat.end()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.step, .source, "the cancelled move does not happen")
        XCTAssertTrue(model.outcome(.speechKey).isDone, "what was done stays")
    }

    // MARK: - Dwell latch and review

    func testAChoiceOnTheFirstStepFlowsOnAfterItsBeatWithoutAPill() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        XCTAssertEqual(model.step, .source, "the click's motion plays first")
        XCTAssertEqual(model.dwell.state, .idle, "no pill, no Hold")
        try await endBeat(env, until: .speechKey, in: model)
        model.back()
        XCTAssertEqual(model.step, .source)
        XCTAssertEqual(model.dwell.state, .idle, "back on step 1 shows no Continue pill")
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
    }

    func testASecondChoiceDuringStepOnesBeatWins() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await eventually { env.beat.count > 0 }
        model.chooseOnThisMac()
        try await eventually { env.beat.count > 1 }
        env.beat.end()
        try await eventually { model.step == .llmKey }
        XCTAssertEqual(model.progress.source, .onThisMac, "only the last choice moves on")
    }

    func testBackToADoneStepWaitsInReviewUntilReturn() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        await model.useSpeechKey("sk-0123456789abcdef", provider: .soniox)
        func state(_ step: OnboardingStep) -> OnboardingSegmentState? { model.segments.first { $0.step == step }?.state }
        XCTAssertEqual(state(.speechKey), .current, "a fresh success fills the current segment during the beat")
        try await endBeat(env, until: .llmKey, in: model)
        model.back()
        XCTAssertEqual(model.step, .speechKey)
        // The owner, 2026-11-22: a passed step reached by Back stays green
        // and is only highlighted, never reset to "in progress".
        XCTAssertEqual(state(.speechKey), .revisited)
        XCTAssertEqual(state(.source), .completed)
        let following = OnboardingStep.llmKey.shortTitle
        XCTAssertEqual(model.dwell.state, .reviewing(next: following), "Continue · \(following), no jump forward")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.step, .speechKey)
        model.dwell.commitNow() // Return
        XCTAssertEqual(model.step, .llmKey)
        XCTAssertEqual(state(.speechKey), .completed)
        model.back()
        model.back()
        XCTAssertEqual(model.step, .source)
        XCTAssertEqual(state(.source), .revisited, "step 1 too")
        XCTAssertEqual(state(.speechKey), .completed, "done steps after it stay green")
    }

    func testHoldingTheDwellKeepsTheStep() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        await model.useSpeechKey("sk-0123456789abcdef", provider: .soniox)
        try await eventually { env.beat.count > 0 }
        model.dwell.latch() // pointer entered the step
        env.beat.end()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.step, .speechKey, "held as long as the person needs")
        model.dwell.resume() // pointer left
        try await endBeat(env, until: .llmKey, in: model)
    }

    func testTourChaptersWaitForContinue() async throws {
        let env = try makeEnv(accessibility: true, microphone: .authorized)
        let model = try makeModel(env, hotkey: .ready)
        while model.step != .tryDrop && model.step != .toolbox { model.next() }
        if model.step == .tryDrop { model.next() }
        XCTAssertEqual(model.step, .toolbox, "Try Drop leads straight to Toolbox (REV 64)")
        XCTAssertFalse(model.dwell.isCounting, "Toolbox has no timer")
        env.beat.end()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.step, .toolbox, "it waits however long the person reads")
        model.next()
        XCTAssertEqual(model.step, .thanks)
        model.back()
        XCTAssertEqual(model.dwell.state, .reviewing(next: "Finish"), "Back to a chapter offers Continue again")
    }

    // MARK: - Language

    func testPickingALanguageMovesOn() async throws {
        let env = try makeEnv()
        let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: .soniox)?.keychainAccount(in: env.routing))
        try env.keys.save("sx", account: account)
        env.routing.setRoute(FeatureRoute(account: .soniox, model: ModelRegistry.sonioxRealtimeModel), for: .dropFast)
        env.routing.setRoute(FeatureRoute(account: .soniox, model: ModelRegistry.sonioxRealtimeModel), for: .dropSmart)
        let model = try makeModel(env)
        model.next() // skip the LLM
        XCTAssertEqual(model.step, .language)
        model.setLanguage(AppLanguage.find(code: "ru"))
        try await endBeat(env, until: .keyboard, in: model)
        XCTAssertEqual(PrivacyPreferences(defaults: env.defaults).selectedLanguage?.code, "ru")
    }

    // MARK: - Permissions, one at a time

    func testEachPermissionMovesOnWhenGrantedWhileShown() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        // Jump to the permissions by skipping what comes before.
        while model.step != .keyboard { model.next() }
        env.snapshot.value = .init(accessibilityGranted: true, microphoneStatus: .notDetermined)
        model.permissions.refresh(restartRecoveryPolling: false)
        try await endBeat(env, until: .microphone, in: model)
        env.snapshot.value = .init(accessibilityGranted: true, microphoneStatus: .authorized)
        model.permissions.refresh(restartRecoveryPolling: false)
        try await endBeat(env, until: .screenRecording, in: model)
        XCTAssertFalse(model.steps.contains(.inputMonitoring))
    }

    func testAPermissionGrantedWhileAnotherStepShowsDoesNotMove() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        XCTAssertEqual(model.step, .source)
        env.snapshot.value = .init(accessibilityGranted: false, microphoneStatus: .authorized)
        model.permissions.refresh(restartRecoveryPolling: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.step, .source)
        XCTAssertEqual(env.beat.count, 0)
    }

    func testInputMonitoringAppearsOnlyWhenTheShortcutNeedsIt() throws {
        let env = try makeEnv(accessibility: true, microphone: .authorized)
        let model = try makeModel(env, hotkey: .inputMonitoringRequired)
        XCTAssertTrue(model.steps.contains(.inputMonitoring))
        let ready = try makeModel(try makeEnv(accessibility: true, microphone: .authorized), hotkey: .ready)
        XCTAssertFalse(ready.steps.contains(.inputMonitoring))
        XCTAssertFalse(ready.steps.contains(.keyboard), "granted before the window: not shown")
    }

    // MARK: - Informational steps and the end

    func testInformationalStepsNeedNextAndTheLastOneFinishes() throws {
        let env = try makeEnv(accessibility: true, microphone: .authorized)
        let model = try makeModel(env, hotkey: .ready)
        var finished = false
        model.onFinish = { finished = true }
        while model.step != .toolbox { model.next() }
        XCTAssertEqual(model.steps.suffix(2), [.toolbox, .thanks], "no Shortcuts; whytap.ai is part of the last step")
        XCTAssertFalse(model.steps.contains(where: { $0.shortTitle == "Shortcuts" }))
        let tour: [OnboardingStep] = [.toolbox]
        for step in tour {
            XCTAssertEqual(model.step, step)
            XCTAssertEqual(model.dwell.state, OnboardingDwellController.State.idle, "\(step) has no timer")
            XCTAssertEqual(model.dwell.fraction, 0, "its segment does not fill by time")
            model.next()
        }
        XCTAssertEqual(model.step, .thanks)
        XCTAssertFalse(model.dwell.isCounting, "the last step has no timer either")
        XCTAssertEqual(model.fraction, 1)
        model.next()
        XCTAssertTrue(finished)
    }

    // MARK: - Review images

    /// Offscreen PNGs of every step of the frame, walked the way a new Mac
    /// goes through them, in the real window; never shown on screen.
    func testRenderEveryStep() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_ONBOARDING_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_ONBOARDING_RENDER_DIR to save offscreen review images")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        for font in ["InstrumentSerif-Regular", "InstrumentSerif-Italic"] {
            CTFontManagerRegisterFontsForURL(resources.appendingPathComponent("Fonts/\(font).ttf") as CFURL, .process, nil)
        }
        ProviderBrandIconAsset.setResourceDirectoryForTesting(resources.appendingPathComponent("UsefulLinkIcons"))
        defer { ProviderBrandIconAsset.setResourceDirectoryForTesting(nil) }

        let env = try makeEnv()
        let model = try makeModel(env, refusing: [.deepgram], offersOpenAISpeech: true, isPreview: true, realCatalogs: true)
        let controller = OnboardingJourneyWindowController(model: model, onClosed: {})
        var window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer { window.contentViewController = nil; window.close() }
        var index = 0
        func snap(_ name: String, after delay: Int = 600) async throws {
            try await Task.sleep(for: .milliseconds(delay))
            let content = try XCTUnwrap(window.contentView)
            let frameView = try XCTUnwrap(content.superview)
            frameView.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            index += 1
            try png.write(to: directory.appendingPathComponent(String(format: "%02d-%@.png", index, name)))
            XCTAssertFalse(window.isVisible)
        }

        try await snap("source")
        model.chooseYourKey()
        try await snap("source-clicked", after: 160)
        try await endBeat(env, until: .speechKey, in: model)
        // The same key flies from step 1 to its lock on step 2.
        try await snap("key-flight-1", after: 90)
        try await snap("key-flight-2", after: 90)
        try await snap("key-flight-3", after: 120)
        try await snap("speech-key")
        // "Use your own server →": the form in the same window, then back.
        model.useOwnServer(.speech)
        try await snap("server-form")
        model.back()
        try await snap("speech-key-after-server")
        model.speechProvider = .deepgram
        await model.useSpeechKey("bad-0123456789abcdef", provider: .deepgram)
        try await snap("speech-key-refused")
        model.speechProvider = .elevenLabs
        await model.useSpeechKey("sk-0123456789abcdef", provider: .elevenLabs)
        try await snap("speech-key-done")
        try await endBeat(env, until: .llmKey, in: model)
        try await snap("llm-key")
        await model.useLLMKey("sk-ant-0123456789abcdef", provider: .anthropic)
        // The key worked: the recommended Sonnet is set and the person can pick.
        try await snap("llm-key-done")
        // Another mark after the accepted key shows its own state (REV 46).
        model.llmProvider = .openAI
        try await snap("llm-key-switched-openai")
        model.useOwnServer(.languageModel)
        try await snap("llm-key-switched-server")
        model.closeServerForm(.languageModel)
        model.llmProvider = .anthropic
        try await snap("llm-key-back-anthropic")
        await model.chooseModel("claude-fable-5-2", on: .llmKey)
        try await snap("llm-key-model-picked")
        // Anthropic searches the web itself: no Tavily step.
        try await endBeat(env, until: .language, in: model)
        while true {
            try await snap(model.step.rawValue)
            if model.step == .thanks { break }
            model.next()
        }
        model.back()
        try await snap("tour-review")

        // The language globe in its states (REV 50), the springs landed.
        OnboardingGlobeMotion.settlesAtOnce = true
        defer { OnboardingGlobeMotion.settlesAtOnce = false }
        for (name, query, country) in [("rest", "", nil), ("typing-rus", "Rus", nil), ("typing-jap", "Jap", nil),
                                       ("typing-english", "English", nil), ("picked-brazil", "", "BR"),
                                       ("picked-switzerland", "", "CH"), ("picked-uk", "", "GB"), ("picked-mexico", "", "MX"), ("unavailable-iceland", "", "IS"),
                                       ("no-match", "Xyzzy", nil)] as [(String, String, String?)] {
            let stage = OnboardingLanguageStage(model: model, query: query, country: country)
                .frame(width: 520, height: 320)
                .background(OnboardingTheme.bg)
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: stage)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            index += 1
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(String(format: "%02d-language-%@.png", index, name)))
        }

        // The access steps in their four states (REV 57), the springs landed.
        OnboardingAccessMotion.settlesAtOnce = true
        defer { OnboardingAccessMotion.settlesAtOnce = false }
        for kind in OnboardingAccessKind.allCases {
            for (name, state) in [("rest", OnboardingAccessState.rest), ("waiting", .waiting), ("granted", .granted),
                                  ("not-on", .notOn)] {
                let stage = OnboardingAccessStage(kind: kind, model: model, shownState: state)
                    .frame(width: 520, height: 320)
                    .background(OnboardingTheme.bg)
                    .preferredColorScheme(.dark)
                let host = NSHostingView(rootView: stage)
                host.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                index += 1
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(String(format: "%02d-access-%@-%@.png", index,
                                                                       kind.pane.replacingOccurrences(of: " ", with: "-"), name)))
            }
        }

        // The last five steps (REV 58), the springs landed.
        OnboardingFinaleMotion.settlesAtOnce = true
        defer { OnboardingFinaleMotion.settlesAtOnce = false }
        let hotkeys = HotkeyPreferences(defaults: UserDefaults(suiteName: "OnboardingRender-\(UUID().uuidString)")!)
        let drop = hotkeys.configuration.dropVoiceShortcut, gesture = hotkeys.configuration.normalizedDropGesture
        let finale: [(String, AnyView)] = [
            ("try-waiting", AnyView(OnboardingTryDropStage(model: model, shortcut: drop, gesture: gesture, shownState: .waiting))),
            ("try-recording", AnyView(OnboardingTryDropStage(model: model, shortcut: drop, gesture: gesture,
                                                             shownState: .recording, shownLevel: 0.7))),
            ("try-done", AnyView(OnboardingTryDropStage(model: model, shortcut: drop, gesture: gesture, shownState: .done,
                                                        shownText: "Moving our sync to Thursday at 3. I’ll send the new invite tonight."))),
            ("try-failed", AnyView(OnboardingTryDropStage(model: model, shortcut: drop, gesture: gesture,
                                                          shownState: .failed(OnboardingJourneyModel.noSpeech)))),
            ("toolbox-idle", AnyView(OnboardingToolboxStage(model: model))),
            ("toolbox-open", AnyView(OnboardingToolboxStage(model: model, shownTool: HoverTool.caseVault))),
            ("finish", AnyView(OnboardingFinishStage(model: model, still: true))),
            // REV 69: mid-drift (a row rising in, the top one leaving) with
            // the pointer on the second row.
            ("finish-drift-hover", AnyView(OnboardingFinishStage(model: model, still: true,
                                                                 shownOffset: OnboardingQuestionList.step * 0.5,
                                                                 shownPointed: 2))),
        ]
        for (name, view) in finale {
            let stage = view
                .frame(width: 520, height: 320)
                .background(OnboardingTheme.bg)
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: stage)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            index += 1
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(String(format: "%02d-finale-%@.png", index, name)))
        }

        // The "Choose model" list (a popover, not in the window's image).
        for provider in [AIProviderKind.anthropic] {
            let list = OnboardingModelList(choices: model.modelChoices(.llmKey, provider: provider), selected: nil,
                                           recommended: model.recommendedModel(.llmKey, provider: provider)) { _ in }
            let host = NSHostingView(rootView: list)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            index += 1
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(String(format: "%02d-model-list-%@.png", index, provider.rawValue)))
        }

        // A language model on your own server has no known web search, so
        // the Tavily step comes: the same key, padlock and lines.
        let env2 = try makeEnv()
        let second = try makeModel(env2, isPreview: true, realCatalogs: true)
        let controller2 = OnboardingJourneyWindowController(model: second, onClosed: {})
        window.contentViewController = nil
        window.close()
        window = try XCTUnwrap(controller2.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        second.chooseYourKey()
        try await endBeat(env2, until: .speechKey, in: second)
        second.next()
        second.useOwnServer(.languageModel)
        try await snap("llm-server-fields")
        await second.saveServer(OnboardingServerDraft(address: "localhost:11434/v1", model: "qwen3"), on: .languageModel)
        try await snap("llm-server-added", after: 300)
        try await endBeat(env2, until: .search, in: second)
        try await snap("search-key")
        second.rejectUnrecognizedKey(on: .search)
        try await snap("search-key-format")
        await second.useSearchKey("tvly-busy-0123456789abcdef")
        try await snap("search-key-busy")
        await second.useSearchKey("tvly-dev-0123456789abcdef")
        try await snap("search-key-done")
        // The owner's screenshot: back to the server, then Anthropic.
        second.back()
        XCTAssertEqual(second.step, .llmKey)
        try await snap("llm-server-review")
        second.closeServerForm(.languageModel)
        second.llmProvider = .anthropic
        try await snap("llm-server-then-anthropic")
    }
}

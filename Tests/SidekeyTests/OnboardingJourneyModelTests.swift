import AppKit
import AVFoundation
import FluidAudio
import XCTest
@testable import Sidekey

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
                           offersOpenAISpeech: Bool = false) throws -> OnboardingJourneyModel {
        AppState.shared.dropHotkeyStatus = hotkey
        let catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent("journey-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: catalogURL) }
        try Data("{}".utf8).write(to: catalogURL)
        let offline = Offline(refusing: Set(refusing.map(\.storageID)))
        let present = env.modelPresent
        let readiness = OnDeviceSpeechReadiness { present.value }
        let models = APIAndModelsViewModel(
            routing: env.routing, keys: env.keys,
            catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: offline),
            checks: ModelCheckStore(defaults: env.defaults), keyStatuses: KeyStatusStore(defaults: env.defaults),
            keyChecker: keyChecker ?? offline, probe: offline, endpoints: offline, inputLanguage: { nil }, onDevice: readiness)
        let snapshot = env.snapshot
        let screen = env.screen
        let permissions = PermissionsSettingsViewModel(
            onComplete: {}, autoComplete: false,
            snapshotProvider: { snapshot.value }, screenRecordingAccessProvider: { screen.value },
            screenRecordingRequester: {}, accessibilityRequester: {}, openAccessibilitySettings: {},
            openScreenRecordingSettings: {}, runtimeRefresh: { _, _ in })
        let beat = env.beat
        let model = OnboardingJourneyModel(
            models: models, permissions: permissions,
            onDevice: OnDeviceSpeechModelController(store: FakeStore(present: env.modelPresent)),
            dropSpeech: OnboardingDropSpeech(routing: env.routing, keys: env.keys, onDevice: readiness, mode: { .fast }),
            supportsOnDevice: supportsOnDevice,
            preferences: PrivacyPreferences(defaults: env.defaults),
            screenRecording: ScreenRecordingAccess(isGranted: { screen.value }, request: {}),
            openScreenRecordingSettings: {}, defaultsChanges: NotificationCenter(),
            dwellWait: { _ in await beat.wait() },
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

    func testAnLLMKeySetsEveryTextFeatureAndBringsTheSearchStep() async throws {
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
        try await endBeat(env, until: .search, in: model)
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

    func testBackToADoneStepWaitsInReviewUntilReturn() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        model.back()
        XCTAssertEqual(model.step, .source)
        XCTAssertEqual(model.dwell.state, .reviewing(next: "Speech key"), "Continue · Speech key, no jump forward")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.step, .source)
        model.dwell.commitNow() // Return
        XCTAssertEqual(model.step, .speechKey)
    }

    func testHoldingTheDwellKeepsTheStep() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        model.chooseYourKey()
        try await eventually { env.beat.count > 0 }
        model.dwell.latch() // pointer entered the step
        env.beat.end()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.step, .source, "held as long as the person needs")
        model.dwell.resume() // pointer left
        try await endBeat(env, until: .speechKey, in: model)
    }

    func testTourChaptersMoveOnAfterAReadingPauseOnlyGoingForward() async throws {
        let env = try makeEnv(accessibility: true, microphone: .authorized)
        let model = try makeModel(env, hotkey: .ready)
        while model.step != .tryDrop && model.step != .hotkeys { model.next() }
        if model.step == .tryDrop { model.next() }
        XCTAssertEqual(model.step, .hotkeys)
        XCTAssertTrue(model.dwell.isCounting, "Shortcuts moves on by itself after the reading pause")
        try await endBeat(env, until: .toolbox, in: model)
        model.back()
        XCTAssertEqual(model.dwell.state, .reviewing(next: "Toolbox"), "Back to a chapter does not run it again")
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
        while model.step != .hotkeys { model.next() }
        XCTAssertEqual(model.steps.suffix(4), [.hotkeys, .toolbox, .help, .thanks])
        model.next(); model.next(); model.next()
        XCTAssertEqual(model.step, .thanks)
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
        let model = try makeModel(env, refusing: [.deepgram])
        let controller = OnboardingJourneyWindowController(model: model, onClosed: {})
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer { window.contentViewController = nil; window.close() }
        var index = 0
        func snap(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(600))
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
        try await snap("source-key-chosen")
        try await endBeat(env, until: .speechKey, in: model)
        try await snap("speech-key")
        model.speechProvider = .deepgram
        await model.useSpeechKey("bad-0123456789abcdef", provider: .deepgram)
        try await snap("speech-key-refused")
        model.speechProvider = .elevenLabs
        await model.useSpeechKey("sk-0123456789abcdef", provider: .elevenLabs)
        try await snap("speech-key-done")
        try await endBeat(env, until: .llmKey, in: model)
        try await snap("llm-key")
        await model.useLLMKey("sk-ant-0123456789abcdef", provider: .anthropic)
        try await snap("llm-key-done")
        model.dwell.latch()
        try await snap("llm-key-latched")
        model.dwell.commitNow()
        XCTAssertEqual(model.step, .search)
        while true {
            try await snap(model.step.rawValue)
            if model.step == .thanks { break }
            model.next()
        }
        model.back()
        try await snap("help-review")
    }
}

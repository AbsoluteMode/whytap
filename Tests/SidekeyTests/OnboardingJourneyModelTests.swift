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
        /// While true, a download waits (the test lets it land).
        let held: Box<Bool>
        init(present: Box<Bool>, held: Box<Bool> = Box(false)) { self.present = present; self.held = held }
        func status() -> OnDeviceSpeechModelStatus { present.value ? .ready : .notDownloaded }
        func download(progress: (@Sendable (Double) -> Void)?) async throws {
            while held.value { try await Task.sleep(nanoseconds: 5_000_000) }
            present.value = true
        }
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

    /// A model check that waits while `held` is true, then passes.
    private struct HeldProbe: ModelProbing {
        let held: Box<Bool>
        let started: Box<Int>
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
            started.value += 1
            while held.value { try? await Task.sleep(nanoseconds: 5_000_000) }
            return .passed
        }
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
        let downloadHeld = Box(false)
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
                           realCatalogs: Bool = false, probe: ModelProbing? = nil,
                           heldForTeardown: Bool = true,
                           openScreenSettings: @escaping () -> Void = {},
                           settingsOnly: Bool = false,
                           launch: PermissionsHelper.LaunchGrants? = nil,
                           openKeyboardSettings: @escaping () -> Void = {},
                           relaunch: @escaping () -> String? = { nil },
                           systemAudioProbe: @escaping () async -> Void = {},
                           asksSystemAudio: Bool = false,
                           screenRequest: @escaping () async -> Void = {},
                           resumeDefaults: UserDefaults? = nil,
                           skipLanguage: Bool = true) throws -> OnboardingJourneyModel {
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
            keyChecker: keyChecker ?? offline, probe: probe ?? offline, serverModelChecker: OnboardingPreviewProviders(),
            endpoints: offline, inputLanguage: { nil }, onDevice: readiness)
        let snapshot = env.snapshot
        let screen = env.screen
        let permissions = PermissionsSettingsViewModel(
            onComplete: {}, autoComplete: false,
            snapshotProvider: { snapshot.value }, screenRecordingAccessProvider: { screen.value },
            screenRecordingRequester: {}, accessibilityRequester: {}, openAccessibilitySettings: openKeyboardSettings,
            usesProtectionOverridePane: { settingsOnly },
            openScreenRecordingSettings: {},
            launchGrants: launch, relaunch: relaunch,
            runtimeRefresh: { _, _ in })
        let beat = env.beat
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingPreviewURLProtocol.self]
        // Tavily's stand-in answers after 60 ms instead of the preview's 600 ms.
        OnboardingPreviewURLProtocol.pace = 0.1
        let tavily = TavilySettings(keys: env.keys, search: TavilySearch(http: NativeAgentHTTP(session: URLSession(configuration: configuration))))
        let model = OnboardingJourneyModel(
            models: models, permissions: permissions,
            onDevice: OnDeviceSpeechModelController(store: FakeStore(present: env.modelPresent, held: env.downloadHeld)),
            dropSpeech: OnboardingDropSpeech(routing: env.routing, keys: env.keys, onDevice: readiness, mode: { .fast }),
            supportsOnDevice: supportsOnDevice,
            preferences: PrivacyPreferences(defaults: env.defaults),
            screenRecording: ScreenRecordingAccess(isGranted: { screen.value }, request: screenRequest),
            openScreenRecordingSettings: openScreenSettings,
            defaultsChanges: NotificationCenter(),
            dwellWait: { _ in await beat.wait() },
            tavily: tavily,
            isPreview: isPreview,
            offersOpenAISpeech: offersOpenAISpeech,
            resumeDefaults: resumeDefaults,
            systemAudioProbe: systemAudioProbe,
            asksSystemAudio: asksSystemAudio)
        if skipLanguage, model.step == .language { model.skip() }
        if heldForTeardown { addTeardownBlock { model.stop() } }
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
    private let llmFeatures: [AIFeature] = [.dropSmartCleanup, .meetingNotes, .translation]

    // MARK: - Your own server

    /// The owner, 2026-11-22: no separate screen. In the app too, "Use your
    /// own server →" turns the step's key field into the server's fields;
    /// Settings does not open and the step stays.
    /// ⌘Tab could not reach the onboarding (the owner, 2026-11-23): Whytap
    /// has no Dock icon. Closing the onboarding hands the app back to
    /// `.accessory` once, and the controller's own closing still finishes.
    func testClosingTheOnboardingLeavesTheAppSwitcher() throws {
        _ = NSApplication.shared
        let env = try makeEnv()
        let model = try makeModel(env, isPreview: true)
        var calls: [Bool] = []
        var closed = 0
        let controller = OnboardingJourneyWindowController(model: model, inAppSwitcher: { calls.append($0) },
                                                           onClosed: { closed += 1 })
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        XCTAssertEqual(calls, [], "nothing changes before the window is shown")
        window.contentViewController = nil
        window.close()
        window.close()
        XCTAssertEqual(calls, [false])
        XCTAssertEqual(closed, 1)
    }

    /// A key press nothing in the window takes is dropped without the system
    /// alert sound (the owner heard beeps with no visible cause, 2026-11-23);
    /// one the step does take still reaches it.
    func testUnhandledKeysInTheOnboardingWindowDoNotBeep() throws {
        _ = NSApplication.shared
        let env = try makeEnv()
        let model = try makeModel(env, isPreview: true)
        let controller = OnboardingJourneyWindowController(model: model, onClosed: {})
        let window = try XCTUnwrap(controller.window as? OnboardingJourneyWindow)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer { window.contentViewController = nil; window.close() }
        window.makeFirstResponder(nil)
        func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            // What AppKit does with a key press: the first responder gets it.
            (window.firstResponder ?? window).keyDown(with: event)
        }
        try press(" ", keyCode: 49)
        try press("a", keyCode: 0)
        try press("\u{1b}", keyCode: 53)
        XCTAssertEqual(window.silencedKeyPresses, 3)
        // The page itself holding the keyboard: the same.
        let page = try XCTUnwrap(window.contentView)
        if window.makeFirstResponder(page) {
            try press(" ", keyCode: 49)
            XCTAssertEqual(window.silencedKeyPresses, 4)
        }

        // A text field in the window still gets its typing.
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        try XCTUnwrap(window.contentView).addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        try press("a", keyCode: 0)
        XCTAssertEqual(field.string, "a")
        let silenced = window.silencedKeyPresses
        try press("b", keyCode: 11)
        XCTAssertEqual(field.string, "ab")
        XCTAssertEqual(window.silencedKeyPresses, silenced)
    }

    /// Escape in the Try Drop field has nothing to cancel and is taken
    /// quietly; Option-Escape stays the text view's completion command.
    func testEscapeInTheTryDropFieldIsQuietAndOptionEscapeStillCompletes() throws {
        _ = NSApplication.shared
        final class Field: OnboardingTryTextView {
            var completions = 0
            override func complete(_ sender: Any?) { completions += 1 }
        }
        let env = try makeEnv()
        let model = try makeModel(env, isPreview: true)
        let controller = OnboardingJourneyWindowController(model: model, onClosed: {})
        let window = try XCTUnwrap(controller.window as? OnboardingJourneyWindow)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer { window.contentViewController = nil; window.close() }
        let field = Field(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        try XCTUnwrap(window.contentView).addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.string = "hel"
        field.setSelectedRange(NSRange(location: 3, length: 0))
        func escape(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        }
        // The real key events, through the key bindings.
        field.interpretKeyEvents([try escape([])])
        XCTAssertEqual(field.quietEscapes, 1)
        XCTAssertEqual(field.completions, 0)
        field.interpretKeyEvents([try escape(.option)])
        XCTAssertEqual(field.quietEscapes, 1)
        XCTAssertEqual(field.completions, 1)
        XCTAssertEqual(field.string, "hel")
        XCTAssertEqual(window.silencedKeyPresses, 0)
        // Other commands still edit.
        field.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(field.string, "he")
    }

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
        XCTAssertTrue(model.canGoBack, "Back returns to the language choice")

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
        XCTAssertEqual(model.speechProvider, .deepgram, "the only saved speech key is offered on arrival")
        await model.useSavedKey(on: .speech)
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .deepgram)
    }

    // macOS 27.3 (REV 77/78): keyboard control is given in System & App
    // Protection Override with +. The step opens that pane, counts it as on
    // only with posting and listening too (Accessibility alone is Choose
    // Apps), and a grant made after launch restarts Whytap on the same step.
    func testOnMacOS27_3KeyboardControlOpensTheOverridePaneAndRestartsAfterTheGrant() async throws {
        let env = try makeEnv(accessibility: false, microphone: .notDetermined)
        var opened = 0, restarts = 0
        let none = PermissionsHelper.Snapshot(accessibilityGranted: false, microphoneStatus: .notDetermined,
                                              postEventGranted: false, listenEventGranted: false)
        env.snapshot.value = none
        let model = try makeModel(env, settingsOnly: true, launch: .init(snapshot: none, screenRecording: false),
                                  openKeyboardSettings: { opened += 1 }, relaunch: { restarts += 1; return nil })
        for _ in 0..<20 where model.step != .keyboard { model.next() }
        XCTAssertEqual(model.step, .keyboard)
        XCTAssertEqual(model.keyboardSetup, .addWhytap)
        model.requestAccess(.keyboard)
        XCTAssertEqual(opened, 1, "the press opens System & App Protection Override")
        XCTAssertEqual(model.accessState(.keyboard), .waiting)
        model.recheckPermissions()
        XCTAssertEqual(model.accessState(.keyboard), .waiting, "no Not on yet: the grant may show after a restart")
        // Override on, Input Monitoring still missing.
        env.snapshot.value = .init(accessibilityGranted: true, microphoneStatus: .notDetermined,
                                   postEventGranted: true, listenEventGranted: false)
        model.permissions.refresh(restartRecoveryPolling: false)
        XCTAssertEqual(model.keyboardSetup, .inputMonitoring)
        XCTAssertEqual(model.accessState(.keyboard), .waiting)
        // Everything on: restart, and stay on this step for the relaunch.
        env.snapshot.value = .init(accessibilityGranted: true, microphoneStatus: .notDetermined)
        model.permissions.refresh(restartRecoveryPolling: false)
        XCTAssertEqual(model.accessState(.keyboard), .restarting)
        try await eventually { env.beat.count > 0 }
        env.beat.end()
        try await eventually { restarts == 1 }
        XCTAssertEqual(model.step, .keyboard, "the step is kept for the reopened app")
    }

    // After the restart the grant is in the launch grants: the step is done.
    // Accessibility without posting at launch is Choose Apps: the guide says so.
    func testOnMacOS27_3TheRelaunchFindsKeyboardControlOnOrNamesChooseApps() throws {
        let env = try makeEnv(accessibility: true, microphone: .notDetermined)
        let on = PermissionsHelper.Snapshot(accessibilityGranted: true, microphoneStatus: .notDetermined)
        env.snapshot.value = on
        let ready = try makeModel(env, settingsOnly: true, launch: .init(snapshot: on, screenRecording: false))
        XCTAssertFalse(ready.steps.contains(.keyboard), "keyboard control is on: no step")
        let chooseApps = PermissionsHelper.Snapshot(accessibilityGranted: true, microphoneStatus: .notDetermined,
                                                    postEventGranted: false, listenEventGranted: true)
        env.snapshot.value = chooseApps
        let model = try makeModel(env, settingsOnly: true, launch: .init(snapshot: chooseApps, screenRecording: false))
        XCTAssertTrue(model.steps.contains(.keyboard), "Accessibility alone doesn't let Drop paste")
        XCTAssertEqual(model.keyboardSetup, .chooseAppsOnly)
    }

    // Screen & system audio on 27.3: the press opens the pane (the request
    // shows nothing), a grant after launch restarts Whytap; leaving the
    // step first cancels the restart. "Ask for system audio" asks once.
    func testOnMacOS27_3TheScreenStepOpensThePaneRestartsAndAsksForSystemAudio() async throws {
        for leave in [false, true] {
            let env = try makeEnv(accessibility: true, microphone: .authorized)
            var opened = 0, restarts = 0, asked = 0, requests = 0
            let model = try makeModel(env, openScreenSettings: { opened += 1 }, settingsOnly: true,
                                      launch: .init(snapshot: env.snapshot.value, screenRecording: false),
                                      relaunch: { restarts += 1; return nil }, systemAudioProbe: { asked += 1 },
                                      screenRequest: { requests += 1 })
            for _ in 0..<20 where model.step != .screenRecording { model.next() }
            XCTAssertEqual(model.step, .screenRecording)
            model.requestAccess(.screenRecording)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(opened, 1)
            XCTAssertEqual(requests, 0, "no request that shows nothing")
            model.askSystemAudio()
            model.askSystemAudio()
            try await eventually { asked == 1 }
            XCTAssertTrue(model.systemAudioAsked)
            env.screen.value = true
            model.permissions.refresh(restartRecoveryPolling: false)
            XCTAssertEqual(model.accessState(.screenRecording), .restarting)
            try await eventually { env.beat.count > 0 }
            if leave { model.back() }
            env.beat.end()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(restarts, leave ? 0 : 1, "leave=\(leave)")
        }
    }

    // Older macOS: a grant is live, nothing restarts.
    func testBefore27_3AGrantNeedsNoRestart() throws {
        let env = try makeEnv(accessibility: false, microphone: .notDetermined)
        var restarts = 0
        let model = try makeModel(env, relaunch: { restarts += 1; return nil })
        for _ in 0..<20 where model.step != .keyboard { model.next() }
        env.snapshot.value = .init(accessibilityGranted: true, microphoneStatus: .notDetermined)
        model.permissions.refresh(restartRecoveryPolling: false)
        XCTAssertEqual(model.accessState(.keyboard), .granted)
        XCTAssertEqual(restarts, 0)
    }

    // Builder review #503: a restart waits for an activity (a meeting
    // recording…) with its reason on the step; a grant merely found here
    // (no Open System Settings from this step) never restarts by itself;
    // back without the grant, the pane opens again from the step.
    func testA27_3RestartWaitsForActivityAndNeverStartsWithoutThisStepsPress() async throws {
        let none = PermissionsHelper.Snapshot(accessibilityGranted: false, microphoneStatus: .notDetermined,
                                              postEventGranted: false, listenEventGranted: false)
        let all = PermissionsHelper.Snapshot(accessibilityGranted: true, microphoneStatus: .notDetermined)
        for pressed in [true, false] {
            let env = try makeEnv(accessibility: false, microphone: .notDetermined)
            env.snapshot.value = none
            var opened = 0, attempts = 0
            let model = try makeModel(env, settingsOnly: true, launch: .init(snapshot: none, screenRecording: false),
                                      openKeyboardSettings: { opened += 1 },
                                      relaunch: { attempts += 1; return "Ready. Finish the meeting recording, then choose Restart." })
            for _ in 0..<20 where model.step != .keyboard { model.next() }
            if pressed {
                model.requestAccess(.keyboard)
                model.openSystemSettings(for: .keyboard)
                XCTAssertEqual(opened, 2, "Waiting reopens the Override pane")
            }
            env.snapshot.value = all
            model.permissions.refresh(restartRecoveryPolling: false)
            XCTAssertEqual(model.accessState(.keyboard), .restarting)
            if pressed {
                XCTAssertTrue(model.restartPending)
                try await eventually { env.beat.count > 0 }
                env.beat.end()
                try await eventually { attempts == 1 }
                XCTAssertEqual(model.restartNote, "Ready. Finish the meeting recording, then choose Restart.")
                XCTAssertEqual(model.step, .keyboard)
            } else {
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(env.beat.count, 0)
                XCTAssertEqual(attempts, 0, "a grant found here waits for Restart Whytap")
                XCTAssertFalse(model.restartPending)
                model.restartWhytap()
                XCTAssertEqual(attempts, 1)
            }
        }
    }

    // Builder review #503: screen granted first (before the step, or after
    // the restart) keeps Screen & system audio for its system audio ask, with
    // the window's Next; asked once, it stays asked across a relaunch.
    func testScreenOnFirstKeepsTheStepForSystemAudioUntilAsked() async throws {
        let suite = "journey-audio-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let env = try makeEnv(accessibility: true, microphone: .authorized)
        env.screen.value = true
        var asked = 0
        let model = try makeModel(env, systemAudioProbe: { asked += 1 }, asksSystemAudio: true, resumeDefaults: defaults)
        XCTAssertTrue(model.steps.contains(.screenRecording), "screen on, system audio not asked yet")
        for _ in 0..<20 where model.step != .screenRecording { model.next() }
        XCTAssertEqual(model.step, .screenRecording)
        XCTAssertEqual(model.accessState(.screenRecording), .granted)
        XCTAssertTrue(model.systemAudioPending)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(env.beat.count, 0, "held: no automatic move while the audio ask is open")
        XCTAssertEqual(model.step, .screenRecording)
        model.askSystemAudio()
        try await eventually { asked == 1 }
        let again = try makeModel(env, asksSystemAudio: true, resumeDefaults: defaults)
        XCTAssertFalse(again.steps.contains(.screenRecording), "asked once: the relaunch skips the step")
        model.next()
        XCTAssertNotEqual(model.step, .screenRecording, "Next leaves")
    }

    func testPendingScreenRequestOpensNoPaneAfterSkipOrClose() async throws {
        for close in [false, true] {
            let env = try makeEnv()
            var opened = 0
            let request = Beat()
            var returned = false
            let model = try makeModel(env, openScreenSettings: { opened += 1 },
                                      screenRequest: {
                await request.wait()
                returned = true
            })
            for _ in 0..<20 where model.step != .screenRecording { model.next() }
            model.requestScreenRecording()
            try await eventually { request.count == 1 }
            model.requestScreenRecording()
            XCTAssertEqual(opened, 0, "a second press while asking must not open Settings")
            if close { model.stop() } else { model.skip() }
            request.end()
            try await eventually { returned }
            XCTAssertEqual(opened, 0)
        }
    }

    // System Settings' Quit & Reopen after a privacy switch: the relaunch
    // continues at the step that was shown, or the next one still on the way.
    func testARelaunchContinuesAtTheStepThatWasShown() throws {
        let suite = "journey-resume-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let env = try makeEnv()
        let first = try makeModel(env, resumeDefaults: defaults)
        for _ in 0..<20 where first.step != .microphone { first.next() }
        XCTAssertEqual(first.step, .microphone)
        XCTAssertEqual(defaults.string(forKey: OnboardingLaunch.stepKey), "microphone")
        let again = try makeModel(env, resumeDefaults: defaults)
        XCTAssertEqual(again.step, .microphone)
        OnboardingLaunch.finish(in: defaults)
        XCTAssertNil(defaults.string(forKey: OnboardingLaunch.stepKey))

        let steps: [OnboardingStep] = [.keyboard, .microphone, .toolbox, .thanks]
        XCTAssertEqual(OnboardingLaunch.resumedStep(saved: "microphone", on: steps), .microphone)
        // Screen Recording turned on before the relaunch: the next step on the way.
        XCTAssertEqual(OnboardingLaunch.resumedStep(saved: "screenRecording", on: steps), .toolbox)
        XCTAssertEqual(OnboardingLaunch.resumedStep(saved: nil, on: steps), .keyboard)
        XCTAssertEqual(OnboardingLaunch.resumedStep(saved: "gone", on: steps), .keyboard)
    }

    // Settings cleared, Keychain kept (the owner, 2026-11-23): the speech step
    // names Soniox and ElevenLabs; a click on ElevenLabs then Return uses
    // its saved key; a mark without a key keeps the list and Return does nothing.
    func testSavedKeysAreNamedAndAClickThenReturnUsesThePickedOne() async throws {
        let env = try makeEnv()
        for (kind, key) in [(AIProviderKind.soniox, "test-soniox-key"), (.elevenLabs, "test-elevenlabs-key")] {
            let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: kind)?.keychainAccount(in: env.routing))
            try env.keys.save(key, account: account)
        }
        let model = try makeModel(env)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        XCTAssertEqual(model.savedKeyProviders(.speech), [.soniox, .elevenLabs])
        XCTAssertEqual(model.savedKeyProviders(.languageModel), [])
        XCTAssertEqual(model.savedKeyProviders(.search), [])

        // A mark without a key: the list stays, Return checks nothing.
        model.pickSavedKey(.deepgram, on: .speech)
        await model.useSavedKey(on: .speech)
        XCTAssertNil(env.routing.route(for: .dropFast))
        XCTAssertEqual(model.savedKeyProviders(.speech), [.soniox, .elevenLabs])

        // Click ElevenLabs, then Return.
        model.pickSavedKey(.elevenLabs, on: .speech)
        XCTAssertEqual(model.speechProvider, .elevenLabs)
        await model.useSavedKey(on: .speech)
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .elevenLabs)
    }

    /// A store that counts secret reads; `exists` answers without one, as the
    /// Keychain's attribute query does.
    private final class CountingStore: TokenStore {
        let inner: InMemoryTokenStore
        let reads: Box<Int>
        init(_ inner: InMemoryTokenStore, reads: Box<Int>) { self.inner = inner; self.reads = reads }
        func save(_ token: String) throws { try inner.save(token) }
        func read() throws -> String? { reads.value += 1; return try inner.read() }
        func delete() throws { try inner.delete() }
        func exists() -> Bool { ((try? inner.read()) ?? nil).map { !$0.isEmpty } ?? false }
    }

    // Builder review #502 item 3: naming saved keys before a choice reads no
    // secret (a Keychain read can prompt); only using the chosen one does.
    func testNamingSavedKeysReadsNoSecretUntilOneIsUsed() async throws {
        let base = try makeEnv()
        let reads = Box(0)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { CountingStore(InMemoryTokenStore(account: $0, box: box), reads: reads) })
        let env = Env(defaults: base.defaults, routing: base.routing, keys: keys, modelPresent: base.modelPresent,
                      snapshot: base.snapshot, screen: base.screen)
        for provider in [AIProviderKind.soniox, .elevenLabs] {
            let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: provider)?.keychainAccount(in: env.routing))
            try keys.save("key-\(provider)", account: account)
        }
        let model = try makeModel(env)
        reads.value = 0
        XCTAssertEqual(model.savedKeyProviders(.speech), [.soniox, .elevenLabs])
        model.pickSavedKey(.elevenLabs, on: .speech)
        XCTAssertEqual(reads.value, 0, "naming and picking read no secret")
        await model.useSavedKey(on: .speech)
        XCTAssertGreaterThan(reads.value, 0, "Return uses the chosen key")
    }

    // The Keychain's own presence check: an absent item is absent, with no read.
    func testKeychainPresenceCheckForAMissingItem() {
        XCTAssertFalse(KeychainStore(service: "whytap.tests.absent", account: UUID().uuidString).exists())
    }

    func testLanguageChosenFirstMustWorkWithTheSpeechProvider() async throws {
        let env = try makeEnv()
        let model = try makeModel(env, skipLanguage: false)
        let speechModel = try XCTUnwrap(ModelRegistry.recommended(for: .dropFast, kind: .deepgram))
        let supported = try XCTUnwrap(DeepgramLanguagePolicy.supportedLanguageCodes(for: speechModel))
        let unsupported = try XCTUnwrap(AppLanguage.all.first { !supported.contains($0.code) })
        model.setLanguage(unsupported)
        try await endBeat(env, until: .source, in: model)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        await model.useSpeechKey("test-key-0123456789abcdef", provider: .deepgram)
        XCTAssertTrue(model.outcome(.speechKey).failureText?.contains("Go back to Language") == true)
        XCTAssertNil(env.routing.route(for: .dropFast))
    }

    func testFreshPreferencesOfferRetainedElevenLabsAndAnthropicKeys() async throws {
        let env = try makeEnv()
        for provider in [AIProviderKind.elevenLabs, .anthropic] {
            let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: provider)?.keychainAccount(in: env.routing))
            try env.keys.save("test-retained-provider", account: account)
        }
        XCTAssertTrue(OnboardingLaunch.consume(in: env.defaults))
        let model = try makeModel(env, resumeDefaults: env.defaults, skipLanguage: false)
        XCTAssertEqual(model.step, .language)
        model.setLanguage(nil)
        try await endBeat(env, until: .source, in: model)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        XCTAssertEqual(model.speechProvider, .elevenLabs)
        XCTAssertNil(env.routing.route(for: .dropFast))
        await model.useSavedKey(on: .speech)
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .elevenLabs)
        try await endBeat(env, until: .llmKey, in: model)
        XCTAssertEqual(model.savedKeyProviders(.languageModel), [.anthropic])
        await model.useSavedKey(on: .languageModel)
        XCTAssertEqual(env.routing.route(for: .dropSmartCleanup)?.account, .anthropic)
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

    // MARK: - Skip while a check runs (builder findings, ticket 421/457)

    /// Skip leaves a step's routes as they were: a key check still running
    /// answers for nobody, though the key it saved stays saved.
    func testSkippingDuringASpeechKeyCheckSetsNoRoute() async throws {
        let env = try makeEnv()
        let checker = GatedChecker(gated: ["sk-soniox-0123456789abcdef"])
        let model = try makeModel(env, keyChecker: checker)
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        let check = Task { await model.useSpeechKey("sk-soniox-0123456789abcdef", provider: .soniox) }
        try await eventually { checker.isWaiting("sk-soniox-0123456789abcdef") }
        model.skip()
        XCTAssertNotEqual(model.step, .speechKey)
        checker.release("sk-soniox-0123456789abcdef")
        await check.value
        for feature in speechFeatures {
            XCTAssertNil(env.routing.route(for: feature), "\(feature): skipped, so unset")
        }
        XCTAssertNotEqual(model.outcome(.speechKey), .working("Checking the Soniox key…"))
    }

    func testSkippingDuringALanguageModelKeyCheckSetsNoRoute() async throws {
        let env = try makeEnv()
        let checker = GatedChecker(gated: ["sk-ant-api03-0123456789abcdef"])
        let model = try makeModel(env, keyChecker: checker)
        while model.step != .llmKey { model.next() }
        let check = Task { await model.useLLMKey("sk-ant-api03-0123456789abcdef", provider: .anthropic) }
        try await eventually { checker.isWaiting("sk-ant-api03-0123456789abcdef") }
        model.skip()
        checker.release("sk-ant-api03-0123456789abcdef")
        await check.value
        for feature in llmFeatures {
            XCTAssertNil(env.routing.route(for: feature), "\(feature): skipped, so unset")
        }
    }

    /// Skip during the model check that follows an accepted key: nothing is
    /// assigned when the check ends. (Speech models need no such check.)
    func testSkippingDuringTheModelCheckSetsNoRoute() async throws {
        for kind in [SharedModelKind.llm] {
            let env = try makeEnv()
            let held = Box(true), started = Box(0)
            let model = try makeModel(env, probe: HeldProbe(held: held, started: started))
            let task: Task<Void, Never>
            if kind == .speech {
                model.chooseYourKey()
                try await endBeat(env, until: .speechKey, in: model)
                task = Task { await model.useSpeechKey("sk-soniox-0123456789abcdef", provider: .soniox) }
            } else {
                while model.step != .llmKey { model.next() }
                task = Task { await model.useLLMKey("sk-ant-api03-0123456789abcdef", provider: .anthropic) }
            }
            try await eventually { started.value > 0 }
            model.skip()
            held.value = false
            await task.value
            for feature in kind == .speech ? speechFeatures : llmFeatures {
                XCTAssertNil(env.routing.route(for: feature), "\(kind) \(feature): skipped during the model check")
            }
        }
    }

    // MARK: - On this Mac outlives the window

    /// Closing onboarding mid-download still sets the route once the model
    /// lands, and the model is let go afterwards.
    func testOnThisMacSetsTheRouteAfterTheWindowCloses() async throws {
        let env = try makeEnv()
        env.downloadHeld.value = true
        weak var released: OnboardingJourneyModel?
        do {
            let model = try makeModel(env, heldForTeardown: false)
            model.chooseOnThisMac()
            model.stop()
            released = model
        }
        XCTAssertNil(env.routing.route(for: .dropFast))
        XCTAssertNotNil(released, "the download holds the model while it runs")
        env.downloadHeld.value = false
        try await eventually { env.routing.route(for: .dropFast)?.account == .thisMac }
        // The test's beat stands in for step 1's short pause; let it end.
        env.beat.end()
        try await eventually { released == nil }
    }

    /// A speech choice made meanwhile (Settings, say) is newer and stays.
    func testOnThisMacLeavesANewerSpeechChoiceAlone() async throws {
        let env = try makeEnv()
        env.downloadHeld.value = true
        let model = try makeModel(env)
        model.chooseOnThisMac()
        let newer = FeatureRoute(account: .soniox, model: ModelRegistry.sonioxRealtimeModel)
        env.routing.setRoute(newer, for: .dropFast)
        env.downloadHeld.value = false
        try await eventually { env.modelPresent.value }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(env.routing.route(for: .dropFast), newer)
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
        try await endBeat(env, until: .keyboard, in: model)
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
        XCTAssertEqual(model.step, .keyboard)
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
        let model = try makeModel(env, skipLanguage: false)
        XCTAssertEqual(model.step, .language)
        XCTAssertFalse(model.canGoBack)
        model.setLanguage(AppLanguage.find(code: "ru"))
        try await endBeat(env, until: .llmKey, in: model)
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

    func testAnEarlyMicrophoneGrantAdvancesWhenItsStepIsReached() async throws {
        let env = try makeEnv()
        let model = try makeModel(env)
        while model.step != .keyboard { model.next() }
        env.snapshot.value = .init(accessibilityGranted: false, microphoneStatus: .authorized)
        model.permissions.refresh(restartRecoveryPolling: false)
        XCTAssertEqual(model.step, .keyboard)
        env.snapshot.value = .init(accessibilityGranted: true, microphoneStatus: .authorized)
        model.permissions.refresh(restartRecoveryPolling: false)
        try await endBeat(env, until: .microphone, in: model)
        try await endBeat(env, until: .screenRecording, in: model)
        model.back()
        XCTAssertEqual(model.step, .microphone)
        XCTAssertFalse(model.dwell.isCounting, "Back lets the person review the granted step")
    }

    /// A switch turned off after it was granted: the step no longer says
    /// allowed; turned on again, it is allowed again.
    func testARevokedPermissionClearsItsGrantedState() async throws {
        let env = try makeEnv()
        let model = try makeModel(env, hotkey: .inputMonitoringRequired)
        let refresh = { model.permissions.refresh(restartRecoveryPolling: false) }
        func grant(keyboard: Bool, microphone: Bool) {
            env.snapshot.value = .init(accessibilityGranted: keyboard, microphoneStatus: microphone ? .authorized : .denied)
        }
        grant(keyboard: true, microphone: true)
        env.screen.value = true
        refresh()
        AppState.shared.dropHotkeyStatus = .ready
        try await eventually {
            [.keyboard, .microphone, .screenRecording, .inputMonitoring].allSatisfy { model.accessState($0) == .granted }
        }
        grant(keyboard: false, microphone: false)
        env.screen.value = false
        refresh()
        AppState.shared.dropHotkeyStatus = .inputMonitoringRequired
        try await eventually {
            [.keyboard, .microphone, .screenRecording, .inputMonitoring].allSatisfy { model.accessState($0) != .granted }
        }
        for step in [OnboardingStep.keyboard, .microphone, .screenRecording, .inputMonitoring] {
            XCTAssertFalse(model.outcome(step).isDone, "\(step) no longer says allowed")
        }
        grant(keyboard: true, microphone: true)
        env.screen.value = true
        refresh()
        AppState.shared.dropHotkeyStatus = .ready
        try await eventually {
            [.keyboard, .microphone, .screenRecording, .inputMonitoring].allSatisfy { model.accessState($0) == .granted }
        }
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

    /// Keys kept from an earlier setup (settings cleared, Keychain kept) are
    /// named under the empty field; a name picks its tab and Return uses it.
    func testRenderSavedKeysAfterSettingsWereCleared() async throws {
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
        for kind in [AIProviderKind.soniox, .elevenLabs, .anthropic] {
            let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: kind)?.keychainAccount(in: env.routing))
            try env.keys.save("saved-\(kind)", account: account)
        }
        let model = try makeModel(env, isPreview: true)
        let controller = OnboardingJourneyWindowController(model: model, onClosed: {})
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        defer { window.contentViewController = nil; window.close() }
        func snap(_ name: String) async throws {
            try await Task.sleep(for: .milliseconds(700))
            let frameView = try XCTUnwrap(window.contentView?.superview)
            frameView.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("saved-keys-\(name).png"))
        }
        model.chooseYourKey()
        try await endBeat(env, until: .speechKey, in: model)
        try await snap("speech")
        model.speechProvider = .elevenLabs
        try await snap("speech-elevenlabs")
        model.pickSavedKey(.deepgram, on: .speech)
        try await snap("speech-deepgram-without-key")
        XCTAssertTrue(model.keySaved(.elevenLabs))
        XCTAssertFalse(model.keySaved(.deepgram))
    }

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
        let model = try makeModel(env, refusing: [.deepgram], offersOpenAISpeech: true, isPreview: true, realCatalogs: true, asksSystemAudio: true, skipLanguage: false)
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

        try await snap("language")
        model.setLanguage(nil)
        try await endBeat(env, until: .source, in: model)
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
        try await endBeat(env, until: .keyboard, in: model)
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
            var states: [(String, OnboardingAccessState)] = [("rest", .rest), ("waiting", .waiting), ("granted", .granted),
                                                               ("not-on", .notOn)]
            // REV 78: macOS 27.3, given in System Settings and restarting after it.
            if kind == .keyboard || kind == .screenRecording { states.append(("restarting", .restarting)) }
            for (name, state) in states {
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

        // Builder review #503: Screen & system audio with the screen on and
        // system audio still to ask (Continue, the ask).
        do {
            let stage = OnboardingAccessStage(kind: .screenRecording, model: model, shownState: .granted)
                .frame(width: 520, height: 320).background(OnboardingTheme.bg).preferredColorScheme(.dark)
            let host = NSHostingView(rootView: stage)
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(80))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            index += 1
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent(String(format: "%02d-access-screen-audio-held.png", index)))
        }

        // REV 78: the 27.3 keyboard guide at Choose Apps only and at Input Monitoring.
        for (name, setup) in [("choose-apps", PermissionsSettingsViewModel.KeyboardSetup.chooseAppsOnly),
                              ("input-monitoring", .inputMonitoring)] {
            let stage = OnboardingAccessStage(kind: .keyboard, model: model, shownState: .waiting, shownSetup: setup)
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
                .write(to: directory.appendingPathComponent(String(format: "%02d-access-keyboard-guide-%@.png", index, name)))
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

// Builder review #504.
extension OnboardingJourneyModelTests {
    // A restart blocked by an activity is tried once: the next passive poll
    // (every second while the step is open) does not re-arm it when the
    // recording ends; Restart Whytap is the retry, and a fresh Open System
    // Settings allows one more automatic try.
    func testABlockedAutomaticRestartIsNotRetriedByThePoll() async throws {
        let missingKeyboard = PermissionsHelper.Snapshot(accessibilityGranted: false, microphoneStatus: .authorized,
                                                         postEventGranted: false, listenEventGranted: false)
        let reason = "Ready. Finish the meeting recording, then choose Restart."
        for step: OnboardingStep in [.keyboard, .screenRecording] {
            let env = try makeEnv(accessibility: step == .screenRecording, microphone: .authorized)
            if step == .keyboard { env.snapshot.value = missingKeyboard }
            var busy = true
            var attempts = 0
            let model = try makeModel(env, settingsOnly: true,
                                      launch: .init(snapshot: env.snapshot.value, screenRecording: false),
                                      relaunch: { attempts += 1; return busy ? reason : nil }, asksSystemAudio: true)
            defer { model.stop(); env.beat.end() }
            for _ in 0..<20 where model.step != step { model.next() }
            XCTAssertEqual(model.step, step)
            model.requestAccess(step)
            if step == .keyboard {
                env.snapshot.value = .init(accessibilityGranted: true, microphoneStatus: .authorized)
            } else {
                env.screen.value = true
            }
            model.permissions.refresh(restartRecoveryPolling: false)
            try await eventually { env.beat.count > 0 }
            env.beat.end()
            try await eventually { model.restartNote != nil }
            XCTAssertEqual(model.restartNote, reason, "\(step)")
            XCTAssertEqual(attempts, 1)
            busy = false
            for _ in 0..<3 { model.permissions.refresh(restartRecoveryPolling: false) }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertFalse(model.restartPending, "\(step) re-armed without a press")
            XCTAssertEqual(attempts, 1, "\(step) restarted when the recording ended, without a press")
            XCTAssertEqual(model.accessState(step), .restarting)
            model.restartWhytap()
            XCTAssertEqual(attempts, 2, "the button is the retry")
            XCTAssertNil(model.restartNote)
        }
    }

    // Restart Whytap pressed in the guide's Waiting while a recording runs:
    // the reason is on the step (the guide shows it in place of its purpose).
    func testRestartPressedWhileWaitingKeepsItsReason() throws {
        let none = PermissionsHelper.Snapshot(accessibilityGranted: false, microphoneStatus: .authorized,
                                              postEventGranted: false, listenEventGranted: false)
        let env = try makeEnv(accessibility: false, microphone: .authorized)
        env.snapshot.value = none
        let model = try makeModel(env, settingsOnly: true, launch: .init(snapshot: none, screenRecording: false),
                                  relaunch: { "Ready. Finish the meeting recording, then choose Restart." })
        for _ in 0..<20 where model.step != .keyboard { model.next() }
        model.requestAccess(.keyboard)
        XCTAssertEqual(model.accessState(.keyboard), .waiting)
        model.restartWhytap()
        XCTAssertEqual(model.restartNote, "Ready. Finish the meeting recording, then choose Restart.")
        XCTAssertEqual(model.accessState(.keyboard), .waiting)
        model.back()
        XCTAssertNil(model.restartNote, "leaving the step clears it")
    }

    // Request-first macOS: system audio is its own consent, offered on the
    // step before (and without) the screen grant; asked first, a later screen
    // grant moves on as any access step does.
    func testRequestFirstMacOSOffersSystemAudioWithoutTheScreen() async throws {
        let env = try makeEnv(accessibility: true, microphone: .authorized)
        var asked = 0
        let model = try makeModel(env, systemAudioProbe: { asked += 1 }, asksSystemAudio: true)
        for _ in 0..<20 where model.step != .screenRecording { model.next() }
        XCTAssertEqual(model.step, .screenRecording)
        XCTAssertEqual(model.accessState(.screenRecording), .rest)
        XCTAssertTrue(model.offersSystemAudio)
        model.askSystemAudio()
        try await eventually { asked == 1 }
        XCTAssertEqual(model.accessState(.screenRecording), .rest, "the audio ask grants no screen")
        XCTAssertTrue(model.offersSystemAudio, "the row stays, as its asked status")
        env.screen.value = true
        model.permissions.refresh(restartRecoveryPolling: false)
        XCTAssertEqual(model.accessState(.screenRecording), .granted)
        try await eventually { env.beat.count > 0 }
    }

    // Helper failure keeps Whytap open with a reason; a cancelled quit stops
    // the helper so a later Quit never reopens Whytap.
    func testTheRelaunchHelperFailsSafely() {
        var terminated = 0, stopped = 0
        struct NoHelper: Error {}
        XCTAssertEqual(AppRelauncher.relaunch(appState: AppState(), startHelper: { _, _ in throw NoHelper() },
                                              terminate: { terminated += 1 }), AppRelauncher.helperFailed)
        XCTAssertEqual(terminated, 0, "no quit without a helper to reopen")
        var acceptedDuringQuit = false
        XCTAssertNil(AppRelauncher.relaunch(appState: AppState(), startHelper: { pid, path in
            XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier)
            XCTAssertEqual(path, Bundle.main.bundlePath)
            return { stopped += 1 }
        }, terminate: { terminated += 1; acceptedDuringQuit = AppRelauncher.restartAccepted }))
        XCTAssertEqual(terminated, 1)
        XCTAssertTrue(acceptedDuringQuit)
        XCTAssertEqual(stopped, 1, "the quit returned (cancelled): the helper is stopped")
        XCTAssertFalse(AppRelauncher.restartAccepted)
    }

    /// Offscreen: request-first Screen & system audio in each state and the
    /// whole window before and after the audio ask (one way on: Next).
    func testRenderSystemAudioOnEveryScreenState() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_ONBOARDING_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_ONBOARDING_RENDER_DIR to save offscreen review images")
        }
        _ = NSApplication.shared
        let previous = PermissionsHelper.usesProtectionOverridePane
        PermissionsHelper.usesProtectionOverridePane = false
        defer { PermissionsHelper.usesProtectionOverridePane = previous }
        OnboardingAccessMotion.settlesAtOnce = true
        defer { OnboardingAccessMotion.settlesAtOnce = false }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func write(_ view: NSView, _ name: String) async throws {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("504-\(name).png"))
        }
        let env = try makeEnv(accessibility: true, microphone: .authorized)
        let model = try makeModel(env, asksSystemAudio: true)
        for (name, state) in [("rest", OnboardingAccessState.rest), ("waiting", .waiting), ("not-on", .notOn), ("granted", .granted)] {
            let host = NSHostingView(rootView: OnboardingAccessStage(kind: .screenRecording, model: model, shownState: state)
                .frame(width: 520, height: 320).background(OnboardingTheme.bg).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 320)
            try await write(host, "audio-\(name)")
        }
        env.screen.value = true
        let held = try makeModel(env, asksSystemAudio: true)
        for _ in 0..<20 where held.step != .screenRecording { held.next() }
        XCTAssertEqual(held.accessState(.screenRecording), .granted)
        for asked in [false, true] {
            if asked { held.askSystemAudio() }
            let host = NSHostingView(rootView: OnboardingJourneyView(model: held))
            host.frame = NSRect(origin: .zero, size: OnboardingJourneyView.size)
            try await write(host, "window-audio-asked-\(asked)")
        }
    }
}

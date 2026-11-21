import AppKit
import AVFoundation
import Carbon
import FluidAudio
import SwiftUI
import XCTest
@testable import Sidekey

/// The first-launch onboarding, by the situations a person meets it in: a
/// clean Mac, an update, access already given, Intel, each page skipped and a
/// Drop shortcut that did not install. Stores are temporary, keys live in
/// memory, no model is downloaded and no window is shown.
/// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
final class OnboardingTests: XCTestCase {
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

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private struct NoModel: Error {}

    /// A model store whose download lands at once and flips `present`.
    private actor FakeStore: OnDeviceSpeechModelManaging {
        let present: Flag
        private(set) var downloads = 0
        init(present: Flag) { self.present = present }
        func status() -> OnDeviceSpeechModelStatus { present.value ? .ready : .notDownloaded }
        func download(progress: (@Sendable (Double) -> Void)?) async throws {
            downloads += 1
            progress?(0.5)
            present.value = true
        }
        func delete() async throws { present.value = false }
        func acquire() async throws -> AsrManager { throw NoModel() }
        func release() {}
    }

    private struct Env {
        let defaults: UserDefaults
        let routing: AIRoutingStore
        let keys: ProviderKeyStore
        let modelPresent: Flag
        let store: FakeStore
        let speech: OnboardingDropSpeech

        @MainActor
        func controller() -> OnDeviceSpeechModelController { OnDeviceSpeechModelController(store: store) }
    }

    private func makeEnv(modelPresent: Bool = false, mode: TranscriptionMode = .fast) throws -> Env {
        let suite = "OnboardingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let flag = Flag(modelPresent)
        let speech = OnboardingDropSpeech(routing: routing, keys: keys,
                                          onDevice: OnDeviceSpeechReadiness { flag.value }, mode: { mode })
        return Env(defaults: defaults, routing: routing, keys: keys, modelPresent: flag,
                   store: FakeStore(present: flag), speech: speech)
    }

    private func permissions(accessibility: Bool, microphone: AVAuthorizationStatus,
                             hotkey: DropHotkeyStatus) -> PermissionsSettingsViewModel {
        AppState.shared.dropHotkeyStatus = hotkey
        return PermissionsSettingsViewModel(
            onComplete: {}, autoComplete: true,
            snapshotProvider: { .init(accessibilityGranted: accessibility, microphoneStatus: microphone) },
            accessibilityRequester: {}, openAccessibilitySettings: {},
            runtimeRefresh: { _, _ in })
    }

    private func makeModel(_ env: Env, permissions: PermissionsSettingsViewModel,
                           supportsOnDevice: Bool = true) -> OnboardingModel {
        let model = OnboardingModel(speech: env.speech, permissions: permissions, onDevice: env.controller(),
                                    supportsOnDevice: supportsOnDevice, defaultsChanges: NotificationCenter())
        addTeardownBlock { model.stop() }
        return model
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Condition never became true", file: file, line: line)
    }

    private func suite() throws -> UserDefaults {
        let name = "OnboardingLaunch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: - When it opens

    func testCleanMacOpensTheOnboardingOnceAndNotAfterDone() throws {
        let defaults = try suite()
        XCTAssertTrue(OnboardingLaunch.consume(in: defaults))
        OnboardingLaunch.finish(in: defaults)
        XCTAssertFalse(OnboardingLaunch.consume(in: defaults), "Done or a closed window ends it for good")
    }

    func testQuitBeforeDoneBringsItBackOnTheNextLaunch() throws {
        let defaults = try suite()
        XCTAssertTrue(OnboardingLaunch.consume(in: defaults))
        XCTAssertTrue(OnboardingLaunch.consume(in: defaults), "Still pending after a quit or a relaunch macOS asked for")
    }

    func testAnUpdatedMacNeverSeesIt() throws {
        let defaults = try suite()
        defaults.set(true, forKey: OnboardingLaunch.presentedKey)  // any launch since 2026-10-26
        XCTAssertFalse(OnboardingLaunch.consume(in: defaults))
        XCTAssertFalse(defaults.bool(forKey: OnboardingLaunch.pendingKey))

        let legacy = try suite()
        legacy.set(true, forKey: OnboardingLaunch.legacyCompletedKey)  // the former onboarding was finished
        XCTAssertFalse(OnboardingLaunch.consume(in: legacy))
    }

    func testMissingScreenRecordingNoLongerOpensAnythingOnAnUpdatedMac() throws {
        // The former first launch opened Permissions for Screen Recording
        // alone. Screen Recording is now asked at the first screenshot.
        let defaults = try suite()
        defaults.set(true, forKey: OnboardingLaunch.presentedKey)
        XCTAssertFalse(OnboardingLaunch.consume(in: defaults))
    }

    func testMarkersStayOnThisMacAndNeverSync() throws {
        let defaults = try suite()
        _ = OnboardingLaunch.consume(in: defaults)
        let captured = try ConfigBackupRegistry.capture(defaults)
        XCTAssertNil(captured[OnboardingLaunch.presentedKey])
        XCTAssertNil(captured[OnboardingLaunch.pendingKey])
        XCTAssertNil(ConfigBackupRegistry.entries[OnboardingLaunch.pendingKey])
        XCTAssertNil(ConfigBackupRegistry.entries[OnboardingLaunch.presentedKey])
    }

    // MARK: - Which pages

    func testPagesFollowWhatIsAlreadyDone() {
        XCTAssertEqual(OnboardingFlow.pages(for: .init(dropSpeechReady: false, permissionsReady: false)),
                       [.speech, .permissions, .tryDrop, .features])
        XCTAssertEqual(OnboardingFlow.pages(for: .init(dropSpeechReady: false, permissionsReady: true)),
                       [.speech, .tryDrop, .features], "Access already given hides the permissions page")
        XCTAssertEqual(OnboardingFlow.pages(for: .init(dropSpeechReady: true, permissionsReady: false)),
                       [.permissions, .tryDrop, .features], "Drop already set up hides the speech page")
        XCTAssertEqual(OnboardingFlow.pages(for: .init(dropSpeechReady: true, permissionsReady: true)),
                       [.tryDrop, .features])
    }

    func testCleanMacStartsOnSpeechAndOffersOnThisMac() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        XCTAssertEqual(model.pages, [.speech, .permissions, .tryDrop, .features])
        XCTAssertEqual(model.page, .speech)
        XCTAssertFalse(model.showsKeyForm)
    }

    func testAccessAlreadyGivenSkipsThePermissionsPage() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        XCTAssertEqual(model.pages, [.speech, .tryDrop, .features])
    }

    func testRejectedConfiguredSpeechRouteKeepsItsSettingsActionUntilDictationSucceeds() throws {
        let env = try makeEnv(mode: .smart)
        try env.keys.save("fixture", account: BYOKKeyStore.account(for: .deepgram))
        env.routing.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .dropSmart)
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        XCTAssertEqual(model.page, .tryDrop)
        XCTAssertTrue(model.dropReady)

        model.noteDropSetupFailure(.dropSmart)
        XCTAssertEqual(model.dropSetupFailure, .dropSmart)
        var settingsFeature: AIFeature?
        model.openSettings = { tab, feature in
            XCTAssertEqual(tab, .apiAndModels)
            settingsFeature = feature
        }
        model.openDropSpeechSettings()
        XCTAssertEqual(settingsFeature, .dropSmart)
        model.noteDictated()
        XCTAssertNil(model.dropSetupFailure)
    }

    func testAShortcutThatDidNotInstallKeepsThePermissionsPageAndItsRepair() throws {
        let env = try makeEnv()
        let access = permissions(accessibility: true, microphone: .authorized, hotkey: .shortcutInUse)
        let model = makeModel(env, permissions: access)
        XCTAssertEqual(model.pages, [.speech, .permissions, .tryDrop, .features],
                       "Two green checks are not enough: the shortcut must be installed")
        XCTAssertFalse(access.allRequiredGranted, "Continue stays off until it installs")
        AppState.shared.dropHotkeyStatus = .ready
        XCTAssertTrue(access.allRequiredGranted)
    }

    func testIntelGoesStraightToTheKeyForm() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready),
                              supportsOnDevice: false)
        XCTAssertEqual(model.page, .speech)
        XCTAssertTrue(model.showsKeyForm)
    }

    // MARK: - Speech

    func testDownloadAssignsOnThisMacToDropOnlyWhenItLands() async throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        XCTAssertFalse(model.dropReady)

        model.startOnDevice()
        XCTAssertEqual(model.page, .tryDrop, "The download runs on while the next page shows")
        try await eventually { env.routing.route(for: .dropFast) != nil }

        let onDevice = FeatureRoute(account: .thisMac, model: OnDeviceSpeechModel.parakeetTdtV3.rawValue)
        XCTAssertEqual(env.routing.route(for: .dropFast), onDevice)
        XCTAssertEqual(env.routing.route(for: .dropSmart), onDevice)
        for feature in AIFeature.activeCases where !OnboardingDropSpeech.features.contains(feature) {
            XCTAssertNil(env.routing.route(for: feature), "\(feature) keeps its choice: the button names Drop only")
        }
        try await eventually { model.dropReady }
    }

    func testRouteIsNotSetBeforeTheModelIsThere() async throws {
        let env = try makeEnv()
        let speech = env.speech
        XCTAssertFalse(speech.isReady)
        // Nothing is assigned up front: a route without its model would send
        // the first press to Settings instead of dictating.
        XCTAssertTrue(OnboardingDropSpeech.features.allSatisfy { env.routing.route(for: $0) == nil })
    }

    func testAModelAlreadyOnThisMacIsUsedWithoutADownload() async throws {
        let env = try makeEnv(modelPresent: true)
        let controller = env.controller()
        await controller.refresh()
        let model = OnboardingModel(speech: env.speech,
                                    permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready),
                                    onDevice: controller, supportsOnDevice: true, defaultsChanges: NotificationCenter())
        defer { model.stop() }
        model.startOnDevice()
        XCTAssertTrue(model.dropReady)
        let downloads = await env.store.downloads
        XCTAssertEqual(downloads, 0)
    }

    func testAWorkingDropRowKeepsItsChoice() throws {
        let env = try makeEnv(modelPresent: true)
        try env.keys.save("dg-key", account: BYOKKeyStore.account(for: .deepgram))
        let deepgram = FeatureRoute(account: .deepgram, model: "nova-3")
        env.routing.setRoute(deepgram, for: .dropFast)

        let changed = env.speech.useOnDevice()

        XCTAssertEqual(changed, [.dropSmart])
        XCTAssertEqual(env.routing.route(for: .dropFast), deepgram)
    }

    func testASavedKeyUsesItsProviderForDrop() throws {
        let env = try makeEnv()
        try env.keys.save("dg-key", account: BYOKKeyStore.account(for: .deepgram))
        env.speech.use(provider: .deepgram)
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .deepgram, model: "nova-3"))
        XCTAssertTrue(env.speech.isReady)
        XCTAssertNil(env.routing.route(for: .agentVoice))
    }

    func testDropAlreadySetUpSkipsTheSpeechPage() throws {
        let env = try makeEnv(modelPresent: true)
        env.speech.useOnDevice()
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        XCTAssertEqual(model.pages, [.permissions, .tryDrop, .features])
    }

    // MARK: - Skipping

    func testSetUpLaterPassesOverTheTryPage() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        model.setUpSpeechLater()
        XCTAssertEqual(model.page, .permissions, "The shortcut still needs its permissions")
        model.advance()  // Skip
        XCTAssertEqual(model.page, .features, "Nothing to dictate with, so no try page")
    }

    func testEveryPageCanBeSkippedToTheEnd() throws {
        let env = try makeEnv(modelPresent: true)
        env.speech.useOnDevice()
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        var finished = false
        model.onFinish = { finished = true }
        XCTAssertEqual(model.page, .permissions)
        model.advance()
        XCTAssertEqual(model.page, .tryDrop)
        model.advance()
        XCTAssertEqual(model.page, .features)
        XCTAssertFalse(finished)
        model.advance()
        XCTAssertTrue(finished, "Done on the last page ends the onboarding")
    }

    func testPermissionsAdvanceOnlyWhenTheShortcutInstalls() async throws {
        let env = try makeEnv(modelPresent: true)
        env.speech.useOnDevice()
        let access = permissions(accessibility: true, microphone: .authorized, hotkey: .unavailable)
        let model = makeModel(env, permissions: access)
        XCTAssertEqual(model.page, .permissions)
        AppState.shared.dropHotkeyStatus = .ready
        try await eventually { model.page == .tryDrop }
    }

    // MARK: - Try

    func testADropPressWithAMissingPermissionReturnsToThatPage() throws {
        let env = try makeEnv(modelPresent: true)
        env.speech.useOnDevice()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        XCTAssertEqual(model.pages, [.tryDrop, .features])
        model.showPermissions()
        XCTAssertEqual(model.pages, [.permissions, .tryDrop, .features])
        XCTAssertEqual(model.page, .permissions)
    }

    func testDropNotSetUpIsSaidOnTheTryPage() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        model.noteDropSetupFailure(.dropFast)
        XCTAssertEqual(model.dropSetupFailure, .dropFast)
        model.noteDictated()
        XCTAssertNil(model.dropSetupFailure)
        XCTAssertTrue(model.dictated)
    }

    func testTheTryFieldConfirmsOnlyADropInsertionNotTyping() throws {
        _ = NSApplication.shared
        var dictated = 0
        let field = OnboardingTryField(placeholder: "Hold Space", onDictated: { dictated += 1 })
        let host = NSHostingView(rootView: field.frame(width: 300, height: 120))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        let textView = try XCTUnwrap(Self.textView(in: host))
        XCTAssertTrue(window.makeFirstResponder(textView))

        textView.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(dictated, 0, "Typing is not a dictation")

        let editor = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))
        XCTAssertTrue(editor.insert(" dictated"))
        XCTAssertEqual(dictated, 1)
        XCTAssertEqual(textView.string, "typed dictated")

        NotificationCenter.default.post(name: .sidekeyDropInsertedIntoLocalEditor, object: NSTextView())
        XCTAssertEqual(dictated, 1, "Another editor's insertion is not this field's")
    }

    func testTryCopyNamesTheUsersOwnShortcutAndGesture() {
        let hold = OnboardingTryPage.Copy(shortcut: "Space", gesture: .hold)
        XCTAssertTrue(hold.pitch.hasPrefix("Hold Space"))
        XCTAssertEqual(hold.pressVerb, "Hold")
        XCTAssertEqual(hold.releaseVerb, "Let go")
        XCTAssertTrue(hold.placeholder.contains("hold Space"))
        let tap = OnboardingTryPage.Copy(shortcut: "⌥D", gesture: .tap)
        XCTAssertTrue(tap.pitch.hasPrefix("Press ⌥D"))
        XCTAssertEqual(tap.releaseVerb, "Press again")
        XCTAssertTrue(tap.placeholder.contains("press ⌥D"))
    }

    func testOnThisMacCardSaysItSetsDropOnly() {
        let fresh = OnboardingOnDevicePage.Presentation(.notDownloaded)
        XCTAssertEqual(fresh.action, "Download and use for Drop")
        XCTAssertTrue(fresh.detail.contains("about 470 MB"))
        XCTAssertEqual(OnboardingOnDevicePage.Presentation(.ready).action, "Use for Drop")
        XCTAssertTrue(OnboardingOnDevicePage.Presentation(.downloading(0.001)).detail.contains("Starting"))
        XCTAssertTrue(OnboardingOnDevicePage.Presentation(.downloading(0.42)).detail.contains("42%"))
        XCTAssertTrue(OnboardingOnDevicePage.Presentation.scope.contains("Drop only"))
    }

    // MARK: - Features

    func testFeatureRowsOfferAModelWhenNoneRuns() throws {
        let env = try makeEnv()
        XCTAssertEqual(OnboardingFeatureAction.meetings(env.speech), .addModel(.meetings))
        XCTAssertEqual(OnboardingFeatureAction.agent(selectedModel: nil), .addModel(.agent))
        XCTAssertEqual(OnboardingFeatureAction.agent(selectedModel: "anthropic/claude"), .toggle)

        try env.keys.save("sx", account: BYOKKeyStore.account(for: .soniox))
        env.routing.setRoute(FeatureRoute(account: .soniox, model: ModelRegistry.sonioxRecordedModel), for: .meetings)
        XCTAssertEqual(OnboardingFeatureAction.meetings(env.speech), .addModel(.meetingNotes),
                       "Meetings needs its notes model too")
        try env.keys.save("or", account: OpenRouterLLMKeyStore.account)
        env.routing.setRoute(FeatureRoute(account: .openRouter, model: "openai/gpt-5"), for: .meetingNotes)
        XCTAssertEqual(OnboardingFeatureAction.meetings(env.speech), .toggle)
    }

    // MARK: - Permissions at Drop's first press

    func testFirstPressAsksForTheMicrophoneInsteadOfRecordingThroughTheDialog() {
        XCTAssertEqual(DropHotkeyRecovery.startGate(.init(accessibilityGranted: true, microphoneStatus: .notDetermined)),
                       .askMicrophone)
        XCTAssertEqual(DropHotkeyRecovery.startGate(.init(accessibilityGranted: true, microphoneStatus: .authorized)),
                       .proceed)
        XCTAssertEqual(DropHotkeyRecovery.startGate(.init(accessibilityGranted: true, microphoneStatus: .denied)),
                       .explain)
        XCTAssertEqual(DropHotkeyRecovery.startGate(.init(accessibilityGranted: false, microphoneStatus: .authorized)),
                       .explain)
    }

    // MARK: - Automation during the onboarding

    func testNowPlayingDefersItsAutomationPromptWhileTheOnboardingIsOpen() {
        let deferred = Flag(true)
        var asked = 0
        let consent = NowPlayingAutomationConsent(status: { _, ask in
            if ask { asked += 1; return OSStatus(noErr) }
            return OSStatus(errAEEventWouldRequireUserConsent)
        }, promptDeferred: { deferred.value })

        XCTAssertFalse(consent.ensureConsent(for: .music))
        XCTAssertEqual(asked, 0, "No dialog over the onboarding")
        deferred.value = false
        XCTAssertTrue(consent.ensureConsent(for: .music), "Asked on a later poll, once the window closed")
        XCTAssertEqual(asked, 1)
    }

    // MARK: - Review images

    private struct Offline: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] { [] }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
    }

    private actor FixedStore: OnDeviceSpeechModelManaging {
        let fixed: OnDeviceSpeechModelStatus
        init(_ status: OnDeviceSpeechModelStatus) { fixed = status }
        func status() -> OnDeviceSpeechModelStatus { fixed }
        func download(progress: (@Sendable (Double) -> Void)?) async throws {}
        func delete() async throws {}
        func acquire() async throws -> AsrManager { throw NoModel() }
        func release() {}
    }

    private func offlineModels(_ env: Env) throws -> APIAndModelsViewModel {
        let catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: catalogURL) }
        try Data("{}".utf8).write(to: catalogURL)
        let offline = Offline()
        return APIAndModelsViewModel(
            routing: env.routing, keys: env.keys,
            catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: offline),
            checks: ModelCheckStore(defaults: env.defaults), keyStatuses: KeyStatusStore(defaults: env.defaults),
            keyChecker: offline, probe: offline, endpoints: offline, inputLanguage: { nil }, onDevice: .unavailable)
    }

    /// Offscreen PNGs of every page, walked the way a new Mac goes through
    /// them, in the real window; never shown on screen.
    func testRenderEveryPage() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_ONBOARDING_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_ONBOARDING_RENDER_DIR to save offscreen review images")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The packaged app registers its fonts through ATSApplicationFontsPath
        // and finds the clips in its own bundle.
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources")
        for font in ["InstrumentSerif-Regular", "InstrumentSerif-Italic"] {
            CTFontManagerRegisterFontsForURL(resources.appendingPathComponent("Fonts/\(font).ttf") as CFURL, .process, nil)
        }
        let savedBundle = FeatureVideo.resourceBundle
        FeatureVideo.resourceBundle = try XCTUnwrap(Bundle(path: resources.path))
        OnboardingFeatureStage.playsVideo = false
        defer {
            FeatureVideo.resourceBundle = savedBundle
            OnboardingFeatureStage.playsVideo = true
        }

        enum Stop { case speech, speechListening, speechKey, permissions, tryEmpty, tryDone, tryDownloading, features }
        let shots: [(Stop, String)] = [
            (.speech, "1-speech"), (.speechListening, "1-speech-listening"), (.speechKey, "1b-speech-key"),
            (.permissions, "2-permissions"), (.tryEmpty, "3-try-drop-empty"), (.tryDone, "3-try-drop-done"),
            (.tryDownloading, "3-try-drop-downloading"), (.features, "4-features"),
        ]
        for (stop, name) in shots {
            // A new Mac: no model (downloading once asked; landed by the try
            // page), nothing granted.
            let status: OnDeviceSpeechModelStatus
            switch stop {
            case .speech, .speechListening, .speechKey: status = .notDownloaded
            case .permissions, .tryDownloading: status = .downloading(0.42)
            case .tryEmpty, .tryDone, .features: status = .ready
            }
            let env = try makeEnv(modelPresent: status == .ready)
            let controller = OnDeviceSpeechModelController(store: FixedStore(status))
            await controller.refresh()
            let granted = Flag(false)
            AppState.shared.dropHotkeyStatus = .accessibilityRequired
            let permissions = PermissionsSettingsViewModel(
                onComplete: {}, autoComplete: true,
                snapshotProvider: { .init(accessibilityGranted: granted.value,
                                          microphoneStatus: granted.value ? .authorized : .notDetermined) },
                accessibilityRequester: {}, openAccessibilitySettings: {}, runtimeRefresh: { _, _ in })
            let model = OnboardingModel(speech: env.speech, permissions: permissions, onDevice: controller,
                                        supportsOnDevice: true, models: try offlineModels(env),
                                        defaultsChanges: NotificationCenter())
            defer { model.stop() }
            XCTAssertEqual(model.pages, [.speech, .permissions, .tryDrop, .features])
            if stop == .speechKey { model.showsKeyForm = true }
            if ![.speech, .speechListening, .speechKey].contains(stop) {
                model.startOnDevice()  // Download and use for Drop
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(model.page, .permissions)
            }
            if [.tryEmpty, .tryDone, .tryDownloading, .features].contains(stop) {
                granted.value = true
                AppState.shared.dropHotkeyStatus = .ready
                permissions.refresh()
                try await Task.sleep(for: .milliseconds(100))
                if model.page == .permissions { model.advance() }
                XCTAssertEqual(model.page, .tryDrop)
            }
            if stop == .features { model.advance() }

            let windowController = OnboardingWindowController(model: model, onClosed: {})
            let window = try XCTUnwrap(windowController.window)
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            switch stop {
            case .speech: model.demo.show(.done)
            case .speechListening: model.demo.show(.recording, level: 0.62)
            case .tryDone:
                let textView = try XCTUnwrap(Self.textView(in: content))
                XCTAssertTrue(window.makeFirstResponder(textView))
                let editor = try XCTUnwrap(DropLocalEditor(focusedIn: window, isPresented: { _ in true }))
                XCTAssertTrue(editor.insert("Let's move the launch review to Thursday at ten and send the agenda tonight."))
                XCTAssertTrue(model.dictated)
            default: break
            }
            try await Task.sleep(for: .milliseconds(900))
            let frameView = try XCTUnwrap(content.superview)
            frameView.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            XCTAssertFalse(window.isVisible)
            window.contentViewController = nil
            window.close()
        }
    }

    // MARK: - Helpers

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}

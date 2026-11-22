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
                           supportsOnDevice: Bool = true, refusing: [ProviderAccount] = [],
                           keyChecker: ProviderKeyChecking? = nil) -> OnboardingModel {
        // Keys and key checks stay in this test's stores, never the real Keychain.
        let model = OnboardingModel(speech: env.speech, permissions: permissions, onDevice: env.controller(),
                                    supportsOnDevice: supportsOnDevice, models: try? offlineModels(env, refusing: refusing, keyChecker: keyChecker),
                                    preferences: PrivacyPreferences(defaults: env.defaults),
                                    codingTools: OnboardingCodingTools(detect: { [] }, connect: { _ in .init() }),
                                    defaultsChanges: NotificationCenter())
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
                       [.speech, .permissions, .tryDrop, .customize, .features])
        XCTAssertEqual(OnboardingFlow.pages(for: .init(dropSpeechReady: false, permissionsReady: true)),
                       [.speech, .tryDrop, .customize, .features], "Access already given hides the permissions page")
        XCTAssertEqual(OnboardingFlow.pages(for: .init(dropSpeechReady: true, permissionsReady: false)),
                       [.permissions, .tryDrop, .customize, .features], "Drop already set up hides the speech page")
        XCTAssertEqual(OnboardingFlow.pages(for: .init(dropSpeechReady: true, permissionsReady: true)),
                       [.tryDrop, .customize, .features])
    }

    func testCleanMacStartsOnSpeechAndOffersOnThisMac() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        XCTAssertEqual(model.pages, [.speech, .permissions, .tryDrop, .customize, .features])
        XCTAssertEqual(model.page, .speech)
        XCTAssertTrue(model.supportsOnDevice, "The page offers On this Mac beside the key")
    }

    func testAccessAlreadyGivenSkipsThePermissionsPage() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        XCTAssertEqual(model.pages, [.speech, .tryDrop, .customize, .features])
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
        XCTAssertEqual(model.pages, [.speech, .permissions, .tryDrop, .customize, .features],
                       "Two green checks are not enough: the shortcut must be installed")
        XCTAssertFalse(access.allRequiredGranted, "Continue stays off until it installs")
        AppState.shared.dropHotkeyStatus = .ready
        XCTAssertTrue(access.allRequiredGranted)
    }

    func testIntelOffersOnlyTheKey() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready),
                              supportsOnDevice: false)
        XCTAssertEqual(model.page, .speech)
        XCTAssertFalse(model.supportsOnDevice)
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
        XCTAssertEqual(model.pages, [.permissions, .tryDrop, .customize, .features])
    }

    // MARK: - Skipping

    func testSetUpLaterPassesOverTheTryPage() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        model.setUpSpeechLater()
        XCTAssertEqual(model.page, .permissions, "The shortcut still needs its permissions")
        model.advance()  // Skip
        XCTAssertEqual(model.page, .customize, "Nothing to dictate with, so no try page")
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
        XCTAssertEqual(model.page, .customize)
        model.advance()
        XCTAssertEqual(model.page, .features)
        XCTAssertFalse(finished)
        model.advance()
        XCTAssertTrue(finished, "Done on the last page ends the onboarding")
    }

    // MARK: - Speech footer: Continue or Set up later

    private func cleanMac(_ env: Env, refusing: [ProviderAccount] = []) -> OnboardingModel {
        makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                hotkey: .accessibilityRequired), refusing: refusing)
    }

    private func saveKeys(_ env: Env, _ kinds: [AIProviderKind]) throws {
        for kind in kinds {
            let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: kind)?.keychainAccount(in: env.routing))
            try env.keys.save("\(kind)-key", account: account)
        }
    }

    func testNoKeysOffersSetUpLaterAsBefore() throws {
        let env = try makeEnv()
        let model = cleanMac(env)
        XCTAssertEqual(model.dropChoices, [])
        XCTAssertNil(model.chosenDrop)
        XCTAssertFalse(model.speechCanContinue, "Set up later holds the footer's place")
        model.setUpSpeechLater()
        XCTAssertEqual(model.page, .permissions)
        XCTAssertNil(env.routing.route(for: .dropFast))
    }

    func testOneSavedSpeechKeyOffersContinueWithIt() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.elevenLabs])
        let model = cleanMac(env)
        XCTAssertEqual(model.chosenDrop, .provider(.elevenLabs))
        XCTAssertTrue(model.speechCanContinue)
        XCTAssertFalse(model.dropReady, "Saved, but Drop has no route yet")
        model.continueFromSpeech()
        try await eventually { model.page == .permissions }
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .elevenLabs)
        XCTAssertEqual(env.routing.route(for: .dropSmart)?.account, .elevenLabs)
        XCTAssertTrue(model.dropReady)
    }

    func testSeveralSpeechKeysPickByRuleAndATileChangesIt() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.deepgram, .elevenLabs, .soniox])
        let model = cleanMac(env)
        XCTAssertEqual(model.dropChoices, [.provider(.soniox), .provider(.deepgram), .provider(.elevenLabs)])
        XCTAssertEqual(model.chosenDrop, .provider(.soniox), "Soniox, Whytap's default, comes first")
        model.pickDrop(.provider(.deepgram))
        XCTAssertEqual(model.chosenDrop, .provider(.deepgram), "A tile changes the choice")
        model.continueFromSpeech()
        try await eventually { model.page == .permissions }
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .deepgram, model: "nova-3"))
        XCTAssertEqual(env.routing.route(for: .dropSmart)?.account, .deepgram)
    }

    func testTheRouteDropAlreadyRunsOnIsPreferredAndAnotherPickReplacesIt() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.soniox, .elevenLabs])
        env.speech.use(provider: .elevenLabs)
        let model = cleanMac(env)
        XCTAssertEqual(model.chosenDrop, .provider(.elevenLabs), "What Drop runs on wins over the order")
        model.pickDrop(.provider(.soniox))
        model.continueFromSpeech()
        try await eventually { env.routing.route(for: .dropFast)?.account == .soniox }
        XCTAssertEqual(env.routing.route(for: .dropSmart)?.account, .soniox, "Continue applies the pick to both rows")
    }

    func testOnlyAIKeysDoNotOfferContinue() throws {
        let env = try makeEnv()
        try saveKeys(env, [.openRouter, .openAI, .anthropic])
        let model = cleanMac(env)
        XCTAssertTrue(model.keyAvailable(.openAI) == false, "OpenAI is not a Drop speech provider")
        XCTAssertEqual(model.dropChoices, [])
        XCTAssertFalse(model.speechCanContinue, "AI keys alone cannot dictate: Set up later")
    }

    func testARefusedKeyStaysOnThePageWithTheReason() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.deepgram])
        let model = cleanMac(env, refusing: [.deepgram])
        XCTAssertEqual(model.chosenDrop, .provider(.deepgram), "Not checked yet, so still a choice")
        model.continueFromSpeech()
        try await eventually { model.dropCheck != .checking }
        guard case .failed(let choice, let reason) = model.dropCheck else { return XCTFail("\(model.dropCheck)") }
        XCTAssertEqual(choice, .provider(.deepgram))
        XCTAssertEqual(reason, "Key not accepted")
        XCTAssertEqual(model.page, .speech, "A refused key does not move on")
        XCTAssertNil(env.routing.route(for: .dropFast), "Nothing is set to a refused key")
        XCTAssertNotNil(model.keyRefusal(.deepgram))
        XCTAssertEqual(model.dropChoices, [], "Once refused it is no longer offered")
        XCTAssertFalse(model.speechCanContinue)
    }

    // MARK: - Overlapping speech actions (builder findings on #397)

    func testAnEarlierContinueThatFinishesFirstDoesNotWinOverTheLaterOne() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.soniox, .deepgram])
        let checker = GatedChecker(gated: ["soniox-key", "deepgram-key"]) { _ in .valid }
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired), keyChecker: checker)
        XCTAssertEqual(model.chosenDrop, .provider(.soniox))
        model.continueFromSpeech()
        try await eventually { checker.isWaiting("soniox-key") }
        model.pickDrop(.provider(.deepgram))
        model.continueFromSpeech()
        try await eventually { checker.isWaiting("deepgram-key") }

        checker.release("soniox-key")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(env.routing.route(for: .dropFast), "the replaced request sets nothing")
        XCTAssertEqual(model.page, .speech, "and does not move the page")

        checker.release("deepgram-key")
        try await eventually { model.page == .permissions }
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .deepgram)
        XCTAssertEqual(env.routing.route(for: .dropSmart)?.account, .deepgram)
    }

    func testARefusalOfAKeyReplacedDuringTheCheckIsNotRecordedAgainstTheNewKey() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.soniox])
        let checker = GatedChecker(gated: ["soniox-key"]) { key in key == "soniox-key" ? .rejected(.invalidKey) : .valid }
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired), keyChecker: checker)
        model.continueFromSpeech()
        try await eventually { checker.isWaiting("soniox-key") }
        // The key is replaced in Settings while the old one is being checked.
        let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: .soniox)?.keychainAccount(in: env.routing))
        try env.keys.save("soniox-new", account: account)
        checker.release("soniox-key")

        try await eventually { model.page == .permissions }
        XCTAssertNil(model.keyRefusal(.soniox), "the old key's refusal is not the new key's")
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .soniox, "the new key was checked and used")
    }

    func testAnOldKeysSuccessDoesNotValidateAReplacementThatIsRefused() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.soniox])
        let checker = GatedChecker(gated: ["soniox-key"]) { key in key == "soniox-key" ? .valid : .rejected(.invalidKey) }
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired), keyChecker: checker)
        model.continueFromSpeech()
        try await eventually { checker.isWaiting("soniox-key") }
        let account = try XCTUnwrap(APIAndModelsViewModel.builtInAccount(for: .soniox)?.keychainAccount(in: env.routing))
        try env.keys.save("soniox-bad", account: account)
        checker.release("soniox-key")

        try await eventually { if case .failed = model.dropCheck { return true } else { return false } }
        XCTAssertEqual(model.page, .speech)
        XCTAssertNil(env.routing.route(for: .dropFast))
    }

    func testASaveThatFinishesAfterAContinueKeepsTheKeyButNotTheRoute() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.soniox])
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        // Save pressed for a new Deepgram key; while it is checked, Continue with Soniox.
        let save = model.beginSpeechAction()
        model.continueFromSpeech()
        try await eventually { model.page == .permissions }
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .soniox)

        try saveKeys(env, [.deepgram])  // the earlier save lands
        model.useKey(.deepgram, action: save)
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .soniox, "the later choice stays")
        XCTAssertEqual(env.routing.route(for: .dropSmart)?.account, .soniox)
        XCTAssertEqual(model.page, .permissions)
        XCTAssertTrue(model.keyAvailable(.deepgram), "the saved key stays for later")
    }

    func testARefusedKeyFallsBackToTheNextChoice() async throws {
        let env = try makeEnv()
        try saveKeys(env, [.soniox, .deepgram])
        let model = cleanMac(env, refusing: [.soniox])
        model.continueFromSpeech()
        try await eventually { model.dropCheck != .checking }
        XCTAssertEqual(model.page, .speech)
        XCTAssertEqual(model.chosenDrop, .provider(.deepgram), "The next saved key takes its place")
        model.continueFromSpeech()
        try await eventually { model.page == .permissions }
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .deepgram)
    }

    func testTheDownloadedModelIsAChoiceAfterKeys() async throws {
        let env = try makeEnv(modelPresent: true)
        try saveKeys(env, [.deepgram])
        let model = cleanMac(env)
        await model.onDevice.refresh()
        XCTAssertEqual(model.dropChoices, [.provider(.deepgram), .onThisMac])
        model.pickDrop(.onThisMac)
        model.continueFromSpeech()
        XCTAssertEqual(model.page, .permissions, "On this Mac needs no key check")
        XCTAssertEqual(env.routing.route(for: .dropFast)?.account, .thisMac)
    }

    // MARK: - Back

    func testBackRetracesEveryPageAndTheFirstHasNone() throws {
        let env = try makeEnv()
        try env.keys.save("dg-key", account: BYOKKeyStore.account(for: .deepgram))
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        XCTAssertEqual(model.page, .speech)
        XCTAssertNil(model.previousPage, "The first page has no Back")
        XCTAssertNil(model.backAction)
        model.goBack()
        XCTAssertEqual(model.page, .speech, "Back on the first page does nothing")

        model.useKey(.deepgram, action: model.beginSpeechAction())
        var forward = [model.page]
        while !model.isLastPage { model.advance(); forward.append(model.page) }
        XCTAssertEqual(forward, [.permissions, .tryDrop, .customize, .features])

        var backward: [OnboardingPage] = []
        var counters: [Int] = []
        while let action = model.backAction {
            action()
            backward.append(model.page)
            counters.append(model.pageIndex)
        }
        XCTAssertEqual(backward, [.customize, .tryDrop, .permissions, .speech])
        XCTAssertEqual(counters, [3, 2, 1, 0], "The N / M counter follows the page")
        XCTAssertEqual(model.pages.count, 5, "Back never changes the list")
    }

    func testBackSkipsHiddenPages() throws {
        let env = try makeEnv(modelPresent: true)
        env.speech.useOnDevice()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        XCTAssertEqual(model.pages, [.tryDrop, .customize, .features])
        XCTAssertNil(model.previousPage, "Speech and permissions are done, so Try is first and has no Back")
        model.advance()
        model.advance()
        XCTAssertEqual(model.page, .features)
        model.goBack()
        XCTAssertEqual(model.page, .customize)
        model.goBack()
        XCTAssertEqual(model.page, .tryDrop)
        XCTAssertNil(model.previousPage)
    }

    func testBackPassesOverTheTryPageSetUpLaterSkipped() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        model.setUpSpeechLater()
        model.advance()
        XCTAssertEqual(model.page, .customize)
        XCTAssertEqual(model.previousPage, .permissions, "No try page on the way forward, none on the way back")
        model.goBack()
        XCTAssertEqual(model.page, .permissions)
        model.goBack()
        XCTAssertEqual(model.page, .speech)
    }

    func testBackKeepsWhatWasDoneOnEveryPage() async throws {
        let env = try makeEnv()
        try env.keys.save("dg-key", account: BYOKKeyStore.account(for: .deepgram))
        let tools = OnboardingCodingTools(detect: { [.claudeCode] }, connect: { _ in .init() })
        let model = OnboardingModel(speech: env.speech,
                                    permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready),
                                    onDevice: env.controller(), supportsOnDevice: true, models: try offlineModels(env),
                                    preferences: PrivacyPreferences(defaults: env.defaults),
                                    codingTools: tools, defaultsChanges: NotificationCenter())
        addTeardownBlock { model.stop() }
        model.setLanguage(AppLanguage.find(code: "ru"))
        model.useKey(.deepgram, action: model.beginSpeechAction())
        XCTAssertEqual(model.page, .tryDrop)
        model.noteDictated()
        model.advance()
        model.customizeVideo = .hover
        model.advance()
        await tools.refreshIfNeeded()
        tools.connect()
        try await eventually { tools.state == .connected }

        while model.backAction != nil { model.goBack() }
        XCTAssertEqual(model.page, .speech)
        XCTAssertTrue(model.dropReady, "The speech page shows the chosen route as done and offers Continue")
        XCTAssertTrue(model.keyAvailable(.deepgram), "The Deepgram tile still says Saved")
        XCTAssertEqual(model.language, AppLanguage.find(code: "ru"))
        XCTAssertEqual(env.routing.route(for: .dropFast), FeatureRoute(account: .deepgram, model: "nova-3"))

        model.advance()
        XCTAssertEqual(model.page, .tryDrop)
        XCTAssertTrue(model.dictated, "The try page still says That's Drop")
        model.advance()
        XCTAssertEqual(model.customizeVideo, .hover)
        model.advance()
        XCTAssertEqual(tools.state, .connected, "Coding agents stay connected")
        model.goBack()
        model.goBack()
        model.useKey(.deepgram, action: model.beginSpeechAction())
        XCTAssertEqual(model.page, .tryDrop, "Choosing again is safe: only the speech page moves on")
    }

    func testBackToCompletedPermissionsStaysThere() async throws {
        let env = try makeEnv(modelPresent: true)
        env.speech.useOnDevice()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .unavailable))
        AppState.shared.dropHotkeyStatus = .ready
        try await eventually { model.page == .tryDrop }
        model.goBack()
        XCTAssertEqual(model.page, .permissions)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(model.page, .permissions, "Done permissions do not push the person forward again")
    }

    func testArrowAndCommandBracketGoBackOutsideTextFields() {
        let arrow = OnboardingBackKey.leftArrowKeyCode
        let bracket = OnboardingBackKey.leftBracketKeyCode
        XCTAssertTrue(OnboardingBackKey.isBack(keyCode: arrow, modifiers: [], editingText: false))
        XCTAssertTrue(OnboardingBackKey.isBack(keyCode: arrow, modifiers: [.numericPad, .function], editingText: false),
                      "Arrow keys carry these flags")
        XCTAssertTrue(OnboardingBackKey.isBack(keyCode: bracket, modifiers: .command, editingText: false))
        XCTAssertTrue(OnboardingBackKey.isBack(keyCode: bracket, modifiers: [.command, .capsLock], editingText: false))
        XCTAssertFalse(OnboardingBackKey.isBack(keyCode: arrow, modifiers: .shift, editingText: false))
        XCTAssertFalse(OnboardingBackKey.isBack(keyCode: arrow, modifiers: .command, editingText: false))
        XCTAssertFalse(OnboardingBackKey.isBack(keyCode: bracket, modifiers: [], editingText: false))
        XCTAssertFalse(OnboardingBackKey.isBack(keyCode: 124, modifiers: [], editingText: false), "→ is not Back")
        XCTAssertFalse(OnboardingBackKey.isBack(keyCode: arrow, modifiers: [], editingText: true),
                       "In a text field ← moves the caret")
        XCTAssertFalse(OnboardingBackKey.isBack(keyCode: bracket, modifiers: .command, editingText: true))
        XCTAssertTrue(OnboardingBackKey.isEditingText(NSTextView()), "The field editor of a focused field")
        XCTAssertTrue(OnboardingBackKey.isEditingText(NSTextField()))
        XCTAssertFalse(OnboardingBackKey.isEditingText(NSButton()))
        XCTAssertFalse(OnboardingBackKey.isEditingText(nil))
    }

    func testPreviousFollowsTheFlowList() {
        let all: [OnboardingPage] = [.speech, .permissions, .tryDrop, .customize, .features]
        XCTAssertNil(OnboardingFlow.previous(before: .speech, in: all, speechExpected: true))
        XCTAssertEqual(OnboardingFlow.previous(before: .customize, in: all, speechExpected: true), .tryDrop)
        XCTAssertEqual(OnboardingFlow.previous(before: .customize, in: all, speechExpected: false), .permissions)
        XCTAssertNil(OnboardingFlow.previous(before: .speech, in: [.tryDrop, .features], speechExpected: true),
                     "A page not in the list has no Back")
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
        XCTAssertEqual(model.pages, [.tryDrop, .customize, .features])
        model.showPermissions()
        XCTAssertEqual(model.pages, [.permissions, .tryDrop, .customize, .features])
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
        XCTAssertEqual(hold.pressVerb, "Hold")
        XCTAssertEqual(hold.releaseVerb, "Let go")
        XCTAssertTrue(hold.placeholder.contains("hold Space"))
        let tap = OnboardingTryPage.Copy(shortcut: "⌥D", gesture: .tap)
        XCTAssertEqual(tap.pressVerb, "Press")
        XCTAssertEqual(tap.releaseVerb, "Press again")
        XCTAssertTrue(tap.placeholder.contains("press ⌥D"))
    }

    func testOnThisMacCardSaysWhatItDownloads() {
        let fresh = OnboardingSpeechPage.Presentation(.notDownloaded)
        XCTAssertEqual(fresh.action, "Download and use for Drop")
        XCTAssertTrue(fresh.detail.contains("about 470 MB"))
        XCTAssertEqual(OnboardingSpeechPage.Presentation(.ready).action, "Use for Drop")
        XCTAssertTrue(OnboardingSpeechPage.Presentation(.downloading(0.001)).detail.contains("Starting"))
        XCTAssertTrue(OnboardingSpeechPage.Presentation(.downloading(0.42)).detail.contains("42%"))
    }

    func testScreenRecordingIsOptionalAndAskedOnceWithShot() async throws {
        let env = try makeEnv()
        let access = permissions(accessibility: true, microphone: .authorized, hotkey: .ready)
        var requests = 0
        var settingsOpened = 0
        let shared = ScreenRecordingAccess(isGranted: { false }, request: { requests += 1 })
        let model = OnboardingModel(speech: env.speech, permissions: access, onDevice: env.controller(),
                                    preferences: PrivacyPreferences(defaults: env.defaults),
                                    codingTools: OnboardingCodingTools(detect: { [] }, connect: { _ in .init() }),
                                    screenRecording: shared, openScreenRecordingSettings: { settingsOpened += 1 },
                                    defaultsChanges: NotificationCenter())
        addTeardownBlock { model.stop() }
        XCTAssertTrue(access.allRequiredGranted, "Continue does not wait for Screen Recording")
        XCTAssertFalse(model.screenRecordingAsked)
        model.requestScreenRecording()
        XCTAssertTrue(model.screenRecordingAsked)
        XCTAssertEqual(settingsOpened, 0, "Nothing of ours beside macOS's dialog")
        model.requestScreenRecording()
        XCTAssertEqual(settingsOpened, 1, "The next press opens System Settings")
        guard case .alreadyRequested = shared.requestOnce() else {
            return XCTFail("Shot shares the same launch's request")
        }
        try await eventually { requests == 1 }
        XCTAssertEqual(requests, 1, "macOS is asked once")
    }

    func testAKeySavedAfterLeavingTheSpeechPageDoesNotMoveOn() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: false, microphone: .notDetermined,
                                                            hotkey: .accessibilityRequired))
        let save = model.beginSpeechAction()  // Save pressed on the speech page
        model.setUpSpeechLater()
        XCTAssertEqual(model.page, .permissions)
        try env.keys.save("fixture", account: BYOKKeyStore.account(for: .soniox))
        model.useKey(.soniox, action: save)  // the check finished late
        XCTAssertTrue(model.dropReady, "The key still becomes Drop's speech")
        XCTAssertEqual(model.page, .permissions, "and the person stays where they are")
    }

    // MARK: - Language

    func testLanguageIsTheInputLanguageSetting() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        let preferences = PrivacyPreferences(defaults: env.defaults)
        XCTAssertNil(model.language, "A new Mac starts on Auto")
        XCTAssertEqual(OnboardingLanguageRow.title(nil), OnboardingLanguageRow.autoTitle)
        model.setLanguage(AppLanguage.find(code: "ru"))
        XCTAssertEqual(preferences.selectedLanguage?.code, "ru", "The same value as Input Lang and Settings")
        XCTAssertEqual(model.language?.code, "ru")
        XCTAssertTrue(OnboardingLanguageRow.title(model.language).hasPrefix("Russian"))
        model.setLanguage(nil)
        XCTAssertNil(preferences.selectedLanguage, "Back to Auto")
    }

    func testLanguageSearchFindsEnglishAndNativeNames() {
        let all = OnboardingLanguageSearch.results("")
        XCTAssertNotNil(all.first)
        XCTAssertNil(all.first ?? nil, "Any language leads the full list")
        XCTAssertEqual(OnboardingLanguageSearch.results("").count, AppLanguage.all.count + 1)
        XCTAssertEqual(OnboardingLanguageSearch.results("Russian").first??.code, "ru")
        XCTAssertEqual(OnboardingLanguageSearch.results("рус").first??.code, "ru", "Native name, typed in Cyrillic")
        XCTAssertEqual(OnboardingLanguageSearch.results("RUS").first??.code, "ru", "Case does not matter")
        XCTAssertEqual(OnboardingLanguageSearch.results("deu").first??.code, "de", "Deutsch")
        XCTAssertEqual(OnboardingLanguageSearch.results("espanol").first??.code, "es", "Accents do not matter")
        XCTAssertEqual(OnboardingLanguageSearch.results("any").count, 1, "Any language itself")
        XCTAssertTrue(OnboardingLanguageSearch.results("zzzz").isEmpty)
        let ukr = OnboardingLanguageSearch.results("ukr")
        XCTAssertEqual(ukr.first??.code, "uk", "A name that starts with the query comes first")
    }

    func testKeyCardOffersEveryProviderWithItsAPIHintsOffer() {
        let offers = OnboardingKeyOffer.all
        XCTAssertEqual(offers.map(\.target), [.provider(.soniox), .provider(.deepgram), .provider(.elevenLabs),
                                               .provider(.openRouter), .provider(.openAI), .provider(.anthropic), .tavily],
                       "Speech first, then language models, then search")
        func offer(_ target: OnboardingKeyTarget) -> OnboardingKeyOffer? { offers.first { $0.target == target } }
        XCTAssertEqual(offer(.provider(.deepgram))?.short, "$200 credit")
        XCTAssertEqual(offer(.provider(.deepgram))?.url?.host, "deepgram.com")
        XCTAssertEqual(offer(.provider(.elevenLabs))?.short, "10k credits/mo")
        XCTAssertEqual(offer(.provider(.openRouter))?.short, "50/day free")
        XCTAssertEqual(offer(.tavily)?.short, "1k credits/mo")
        XCTAssertEqual(offer(.provider(.anthropic))?.needsPlan, true, "Claude Max credit needs the plan")
        XCTAssertEqual(offer(.provider(.openAI))?.needsPlan, true, "ChatGPT Pro credit needs the plan")
        XCTAssertNil(offer(.provider(.soniox))?.short, "No offer is invented where API hints list none")
        for hint in APIHintsView.hints {
            XCTAssertNotNil(OnboardingKeyOffer.target(of: hint), "\(hint.provider) offer has no tile")
        }
        XCTAssertEqual(offers.filter { $0.target.speechKind != nil }.count, OnboardingDropSpeech.keyProviders.count,
                       "Only speech keys become Drop's speech")
    }

    func testNoProviderIsChosenUntilClicked() throws {
        let env = try makeEnv()
        let model = makeModel(env, permissions: permissions(accessibility: true, microphone: .authorized, hotkey: .ready))
        XCTAssertNil(model.keyTarget)
    }

    // MARK: - Coding agents

    func testCodingAgentsConnectThroughTheCaseClientSetup() async throws {
        var connected: [CaseKnownClient] = []
        let tools = OnboardingCodingTools(detect: { [.codex, .claudeCode] },
                                          connect: { client in connected.append(client); return .init() })
        await tools.refreshIfNeeded()
        XCTAssertEqual(tools.installed, [.claudeCode, .codex], "Offered in a fixed order")
        XCTAssertEqual(tools.names, "Claude Code and Codex")
        tools.connect()
        try await eventually { tools.state == .connected }
        XCTAssertEqual(connected, [.claudeCode, .codex])
    }

    /// The page's Connect through the real `CaseClientSetup` and host
    /// connectors: Claude Code and Codex get the one `whytap` server
    /// (`<helper> mcp`, app tools and Case key names), and our older Case-only
    /// `case` entry is retired, never written. No configured value reaches a
    /// command line.
    // WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
    func testCodingAgentsConnectWritesTheOneWhytapServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-connect-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let binDir = root.appendingPathComponent("bin")
        let helper = root.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let legacyCase = #"{"command":"\#(helper.path)","args":["case","mcp"]}"#
        try Data(#"{"mcpServers":{"case":\#(legacyCase)}}"#.utf8).write(to: home.appendingPathComponent(".claude.json"))

        let claudeRunner = FakeCommandRunner()
        let codexRunner = FakeCommandRunner()
        codexRunner.codexEntries["case"] = FakeCommandRunner.codexStdio("case", command: helper.path, args: ["case", "mcp"])
        let setup = CaseClientSetup(
            helperURL: helper, binDir: binDir, flavorName: BuildFlavor.prod.rawValue,
            connectors: [
                .claudeCode: ClaudeCodeCaseConnector(home: home, socketPath: root.appendingPathComponent("broker.sock").path,
                                                     runner: claudeRunner,
                                                     locate: { URL(fileURLWithPath: "/usr/local/bin/claude") }),
                .codex: CodexCaseConnector(home: home, runner: codexRunner, reader: codexRunner,
                                           locate: { URL(fileURLWithPath: "/usr/local/bin/codex") }),
            ],
            builtInAgentAvailable: { true })
        let tools = OnboardingCodingTools(detect: { await setup.installed(among: OnboardingCodingTools.offered) },
                                          connect: { await setup.connect($0.identity) })

        await tools.refreshIfNeeded()
        XCTAssertEqual(tools.installed, [.claudeCode, .codex])
        tools.connect()
        try await eventually { tools.state != .connecting && tools.state != .idle }
        XCTAssertEqual(tools.state, .connected)

        XCTAssertEqual(claudeRunner.calls.map(\.arguments), [
            ["mcp", "add", "-s", "user", "whytap", "--", helper.path, "mcp"],
            ["mcp", "remove", "-s", "user", "case"],
        ])
        XCTAssertEqual(codexRunner.calls.map(\.arguments), [
            ["mcp", "add", "whytap", "--", helper.path, "mcp"],
            ["mcp", "remove", "case"],
        ])
        let added = (claudeRunner.calls + codexRunner.calls).filter { $0.arguments.starts(with: ["mcp", "add"]) }
        XCTAssertFalse(added.contains { $0.arguments.contains("case") }, "Never a Case-only server")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: binDir.appendingPathComponent("whytap").path),
                       helper.path, "The whytap command points at the bundled helper")
    }

    func testACodingAgentThatCouldNotBeSetUpSaysWhy() async throws {
        let tools = OnboardingCodingTools(detect: { [.claudeCode] },
                                          connect: { _ in CaseClientSetupReport(problems: ["Claude Code: setup failed"]) })
        await tools.refreshIfNeeded()
        tools.connect()
        try await eventually { tools.state != .connecting && tools.state != .idle }
        XCTAssertEqual(tools.state, .failed("Claude Code: setup failed"))
    }

    func testNoCodingAgentOffersNothing() async {
        let tools = OnboardingCodingTools(detect: { [.cursor] }, connect: { _ in .init() })
        await tools.refreshIfNeeded()
        XCTAssertTrue(tools.installed.isEmpty, "Only Claude Code and Codex are offered")
        tools.connect()
        XCTAssertEqual(tools.state, .idle)
    }

    func testOnboardingClipsAreBundledLikeTheSettingsClips() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundle = try XCTUnwrap(Bundle(path: root.appendingPathComponent("Resources").path))
        for video in OnboardingVideo.allCases {
            let url = try XCTUnwrap(video.url(in: bundle), "\(video) clip missing")
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 40_000)
            XCTAssertLessThan(size, 3_000_000)
        }
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
        /// Storage IDs of accounts whose key the provider refuses.
        var refusing: Set<String> = []
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] { [] }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
            refusing.contains(account.storageID) ? .rejected(.invalidKey) : .valid
        }
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

    /// A key check that waits for the test for the listed key values, then
    /// answers by the key value it was asked about.
    private final class GatedChecker: ProviderKeyChecking, @unchecked Sendable {
        private let lock = NSLock()
        private var gated: Set<String>
        private var waiting: [(key: String, resume: CheckedContinuation<Void, Never>)] = []
        private let verdict: @Sendable (String?) -> KeyStatus
        init(gated: Set<String>, verdict: @escaping @Sendable (String?) -> KeyStatus) {
            self.gated = gated
            self.verdict = verdict
        }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
            if let apiKey, lock.withLock({ gated.contains(apiKey) }) {
                await withCheckedContinuation { resume in lock.withLock { waiting.append((apiKey, resume)) } }
            }
            return verdict(apiKey)
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

    private func offlineModels(_ env: Env, refusing: [ProviderAccount] = [],
                               keyChecker: ProviderKeyChecking? = nil) throws -> APIAndModelsViewModel {
        let catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: catalogURL) }
        try Data("{}".utf8).write(to: catalogURL)
        let offline = Offline(refusing: Set(refusing.map(\.storageID)))
        return APIAndModelsViewModel(
            routing: env.routing, keys: env.keys,
            catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: offline),
            checks: ModelCheckStore(defaults: env.defaults), keyStatuses: KeyStatusStore(defaults: env.defaults),
            keyChecker: keyChecker ?? offline, probe: offline, endpoints: offline, inputLanguage: { nil }, onDevice: .unavailable)
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
        OnboardingClipStage.playsVideo = false
        ProviderBrandIconAsset.setResourceDirectoryForTesting(resources.appendingPathComponent("UsefulLinkIcons"))
        defer {
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
            FeatureVideo.resourceBundle = savedBundle
            OnboardingClipStage.playsVideo = true
        }

        enum Stop { case speech, speechProvider, speechModelProvider, speechListening, speechLanguage,
                        speechKeys, speechKeyPicked, speechKeyRefused, permissions, tryEmpty, tryDone, tryDownloading,
                        customize, customizeHover, features, featuresConnected }
        let shots: [(Stop, String)] = [
            (.speech, "1-speech"), (.speechProvider, "1-speech-deepgram"), (.speechModelProvider, "1-speech-anthropic"), (.speechListening, "1-speech-listening"), (.speechLanguage, "1-speech-russian"),
            (.speechKeys, "1-speech-keys-continue"), (.speechKeyPicked, "1-speech-keys-elevenlabs"),
            (.speechKeyRefused, "1-speech-key-refused"),
            (.permissions, "2-permissions"), (.tryEmpty, "3-try-drop-empty"), (.tryDone, "3-try-drop-done"),
            (.tryDownloading, "3-try-drop-downloading"), (.customize, "4-customize-shortcuts"),
            (.customizeHover, "4-customize-hover"), (.features, "5-more"), (.featuresConnected, "5-more-connected"),
        ]
        let keyStops: [Stop] = [.speechKeys, .speechKeyPicked, .speechKeyRefused]
        let beforeCustomize: [Stop] = [.speech, .speechProvider, .speechModelProvider, .speechListening, .speechLanguage] + keyStops
        let fromTry: [Stop] = [.tryEmpty, .tryDone, .tryDownloading, .customize, .customizeHover, .features, .featuresConnected]
        for (stop, name) in shots {
            // A new Mac: no model (downloading once asked; landed by the try
            // page), nothing granted.
            let status: OnDeviceSpeechModelStatus
            switch stop {
            case .speech, .speechProvider, .speechModelProvider, .speechListening, .speechLanguage,
                 .speechKeys, .speechKeyPicked, .speechKeyRefused: status = .notDownloaded
            case .permissions, .tryDownloading: status = .downloading(0.42)
            default: status = .ready
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
                screenRecordingAccessProvider: { false },
                accessibilityRequester: {}, openAccessibilitySettings: {}, runtimeRefresh: { _, _ in })
            let tools = OnboardingCodingTools(detect: { [] }, connect: { _ in CaseClientSetupReport() })
            tools.show([.claudeCode, .codex], state: stop == .featuresConnected ? .connected : .idle)
            let model = OnboardingModel(speech: env.speech, permissions: permissions, onDevice: controller,
                                        supportsOnDevice: true,
                                        models: try offlineModels(env, refusing: stop == .speechKeyRefused ? [.soniox] : []),
                                        preferences: PrivacyPreferences(defaults: env.defaults), codingTools: tools,
                                        screenRecording: ScreenRecordingAccess(isGranted: { false }, request: {}),
                                        defaultsChanges: NotificationCenter())
            defer { model.stop() }
            XCTAssertEqual(model.pages, [.speech, .permissions, .tryDrop, .customize, .features])
            if stop == .speechLanguage { model.setLanguage(AppLanguage.find(code: "ru")) }
            if stop == .speechProvider { model.keyTarget = .provider(.deepgram) }
            if stop == .speechModelProvider { model.keyTarget = .provider(.anthropic) }
            if stop == .speechKeys || stop == .speechKeyPicked {
                // Keys left in the Keychain from an earlier install: every tile is saved.
                try saveKeys(env, [.soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic])
            }
            if stop == .speechKeyPicked {
                model.keyTarget = .provider(.elevenLabs)
                model.pickDrop(.provider(.elevenLabs))
            }
            if stop == .speechKeyRefused {
                try saveKeys(env, [.soniox, .deepgram])
                model.continueFromSpeech()
                try await eventually { model.dropCheck != .checking }
            }
            if stop == .customizeHover { model.customizeVideo = .hover }
            if !beforeCustomize.contains(stop) {
                model.startOnDevice()  // Download and use for Drop
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(model.page, .permissions)
            }
            if fromTry.contains(stop) {
                granted.value = true
                AppState.shared.dropHotkeyStatus = .ready
                permissions.refresh()
                try await Task.sleep(for: .milliseconds(100))
                if model.page == .permissions { model.advance() }
                XCTAssertEqual(model.page, .tryDrop)
            }
            if [.customize, .customizeHover, .features, .featuresConnected].contains(stop) { model.advance() }
            if [.features, .featuresConnected].contains(stop) { model.advance() }

            let windowController = OnboardingWindowController(model: model, onClosed: {})
            let window = try XCTUnwrap(windowController.window)
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            switch stop {
            case .speech, .speechProvider, .speechModelProvider, .speechLanguage: model.demo.show(.done)
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

        // The language list opens in a popover, which an offscreen window
        // does not draw: render its content alone, searched in Russian.
        for (query, name) in [("", "1-speech-language-list"), ("рус", "1-speech-language-search")] {
            let list = OnboardingLanguageList(selected: nil, query: query, choose: { _ in })
            let hosting = NSHostingView(rootView: list)
            hosting.frame = NSRect(x: 0, y: 0, width: 260, height: 285)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
            window.contentView = nil
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

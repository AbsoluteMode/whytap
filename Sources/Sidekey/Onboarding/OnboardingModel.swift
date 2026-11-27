import AppKit
import Combine
import Foundation

/// State of one onboarding: its pages, the speech choice and the permissions
/// it waits for. The window owns it; the On this Mac download and the route
/// it assigns afterwards outlive the window (see `startOnDevice`).
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var pages: [OnboardingPage]
    @Published private(set) var page: OnboardingPage
    /// The provider clicked on the key card; `nil` until one is.
    @Published var keyTarget: OnboardingKeyTarget?
    /// The dictation language; `nil` is Auto. The same value as the Input
    /// Lang tool and Settings.
    @Published private(set) var language: AppLanguage?
    /// The clip the customize page shows.
    @Published var customizeVideo: OnboardingVideo = .hotkeys
    /// Drop's speech route runs. Rechecked on every route change.
    @Published private(set) var dropReady: Bool
    /// The speech route the transcription session could not start.
    @Published private(set) var dropSetupFailure: AIFeature?
    /// A Drop take was inserted into the try field (not merely typed).
    @Published private(set) var dictated = false
    /// Bumped when routes or capability flags change, so the features page
    /// re-reads what each row offers.
    @Published private(set) var revision = 0
    /// The speech tile (or On this Mac) the person picked for Drop; `nil`
    /// until they pick one, when `chosenDrop` falls back to its rule.
    @Published private(set) var dropPick: OnboardingDropChoice?
    /// Continue's key check for the chosen provider.
    @Published private(set) var dropCheck: OnboardingDropCheck = .idle

    let permissions: PermissionsSettingsViewModel
    let onDevice: OnDeviceSpeechModelController
    let supportsOnDevice: Bool
    let speech: OnboardingDropSpeech
    let preferences: PrivacyPreferences
    let codingTools: OnboardingCodingTools
    /// The launch's one Screen Recording request, shared with Shot.
    let screenRecording: ScreenRecordingAccess
    private let openScreenRecordingSettings: () -> Void
    /// This launch already asked macOS for Screen Recording.
    @Published private(set) var screenRecordingAsked: Bool
    /// The silent Drop demo on the speech page.
    let demo = OnboardingDropDemo()
    /// The key card's store of keys and routes; built when the speech page shows.
    private(set) lazy var models: APIAndModelsViewModel = injectedModels ?? APIAndModelsViewModel()
    /// The Tavily search key, saved the way Settings -> API keys saves it.
    private(set) lazy var tavily: TavilySettings = models.makeTavilySettings()
    private let injectedModels: APIAndModelsViewModel?
    /// The user chose Set up later on the speech page.
    private var speechSkipped = false
    private var downloadStarted = false
    /// Numbers every speech action on the page (a tile picked, Continue, a
    /// key save, the download). An answer that arrives after a newer action
    /// changes nothing about Drop's route or the page: the latest action wins.
    // WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
    private(set) var speechAction = 0
    private var pollTimer: Timer?
    private var pollBudget = DropHotkeyRecoveryPollBudget()
    private var subscriptions: Set<AnyCancellable> = []

    var onFinish: () -> Void = {}
    var openSettings: (SettingsWindowTab, AIFeature?) -> Void = { _, _ in }

    init(
        speech: OnboardingDropSpeech? = nil,
        permissions: PermissionsSettingsViewModel? = nil,
        onDevice: OnDeviceSpeechModelController? = nil,
        supportsOnDevice: Bool = OnDeviceSpeechModelStore.isSupportedHost,
        models: APIAndModelsViewModel? = nil,
        preferences: PrivacyPreferences? = nil,
        codingTools: OnboardingCodingTools? = nil,
        screenRecording: ScreenRecordingAccess? = nil,
        openScreenRecordingSettings: @escaping () -> Void = PermissionsHelper.openScreenRecordingSettings,
        defaultsChanges: NotificationCenter = .default
    ) {
        injectedModels = models
        // Main-actor defaults are built here: Swift 5 evaluates default
        // arguments outside the actor.
        let speech = speech ?? OnboardingDropSpeech()
        let onDevice = onDevice ?? .shared
        let permissions = permissions ?? PermissionsSettingsViewModel(onComplete: {}, autoComplete: true)
        self.speech = speech
        self.permissions = permissions
        self.onDevice = onDevice
        self.supportsOnDevice = supportsOnDevice
        let preferences = preferences ?? .shared
        let screenRecording = screenRecording ?? .shared
        self.preferences = preferences
        self.codingTools = codingTools ?? OnboardingCodingTools()
        self.screenRecording = screenRecording
        self.openScreenRecordingSettings = openScreenRecordingSettings
        screenRecordingAsked = screenRecording.requested
        language = preferences.selectedLanguage
        let ready = speech.isReady
        dropReady = ready
        let pages = OnboardingFlow.pages(for: OnboardingConditions(
            dropSpeechReady: ready, permissionsReady: permissions.allRequiredGranted))
        self.pages = pages
        page = pages.first ?? .features
        permissions.updateOnComplete { [weak self] in self?.permissionsCompleted() }
        // Routes live in defaults; a key saved in Settings or a finished
        // download shows up here without the page asking.
        defaultsChanges.publisher(for: UserDefaults.didChangeNotification)
            .merge(with: defaultsChanges.publisher(for: .sidekeyCapabilityFlagsChanged))
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.routesChanged() }
            .store(in: &subscriptions)
        if page == .permissions { startPermissionPolling() }
    }

    var pageIndex: Int { pages.firstIndex(of: page) ?? 0 }
    var isLastPage: Bool { page == pages.last }

    /// Some speech is on its way: a route that runs or a download in progress.
    var speechExpected: Bool {
        if dropReady || downloadStarted { return true }
        if case .downloading = onDevice.status { return true }
        return !speechSkipped && !pages.contains(.speech)
    }

    // MARK: - Navigation

    func advance() {
        guard let next = OnboardingFlow.next(after: page, in: pages, speechExpected: speechExpected) else {
            return finish()
        }
        show(next)
    }

    /// The page Back returns to; `nil` on the first one, which has no Back.
    var previousPage: OnboardingPage? {
        OnboardingFlow.previous(before: page, in: pages, speechExpected: speechExpected)
    }

    /// Back, by button or ← / ⌘[. Only the page changes: what was chosen,
    /// saved, downloaded or connected stays, and that page shows it as done.
    func goBack() {
        guard let previous = previousPage else { return }
        show(previous)
    }

    /// The footer's Back; `nil` hides it.
    var backAction: (() -> Void)? {
        previousPage == nil ? nil : { [weak self] in self?.goBack() }
    }

    func finish() {
        stop()
        onFinish()
    }

    /// The window closed: nothing keeps polling. A running download goes on.
    func stop() {
        stopPermissionPolling()
        demo.stop()
    }

    private func show(_ next: OnboardingPage) {
        page = next
        dropSetupFailure = nil
        if next == .permissions {
            permissions.refresh()
            startPermissionPolling()
        } else {
            stopPermissionPolling()
        }
    }

    // MARK: - Speech

    /// Download and use for Drop. The download and the route it assigns
    /// belong to this task, not to the window: closing the onboarding during
    /// the download still gives Drop its model when it lands.
    func startOnDevice() {
        beginSpeechAction()
        if onDevice.status == .ready {
            // The model is here: this is a choice, like Continue on a tile.
            dropPick = .onThisMac
            speech.chooseOnDevice()
            routesChanged()
        } else {
            downloadStarted = true
            let controller = onDevice
            let speech = speech
            Task { @MainActor [weak self] in
                if await controller.download() { speech.useOnDevice() }
                self?.routesChanged()
            }
        }
        advance()
    }

    /// Starts a speech action and returns its number (see `speechAction`).
    @discardableResult
    func beginSpeechAction() -> Int {
        speechAction += 1
        // The check a newer action replaced no longer holds Continue.
        if dropCheck == .checking { dropCheck = .idle }
        return speechAction
    }

    /// A speech key was accepted and saved. The key stays saved either way;
    /// Drop's route and the page follow it only when no newer speech action
    /// (another tile, Continue, another save) started after this save did.
    func useKey(_ kind: AIProviderKind, action: Int) {
        guard action == speechAction else { return routesChanged() }
        dropPick = .provider(kind)
        dropCheck = .idle
        speech.choose(provider: kind)
        routesChanged()
        if dropReady, page == .speech { advance() }
    }

    // MARK: - Drop's choice

    /// What Drop can use right now, in the preference order: a saved speech
    /// key the provider has not refused (Soniox, Deepgram, ElevenLabs: the
    /// providers Drop runs on, Soniox being Whytap's default), then the
    /// downloaded On this Mac model.
    // WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
    var dropChoices: [OnboardingDropChoice] {
        var choices = OnboardingDropSpeech.keyProviders
            .filter { keyAvailable($0) && keyRefusal($0) == nil }
            .map(OnboardingDropChoice.provider)
        if supportsOnDevice, onDevice.status == .ready { choices.append(.onThisMac) }
        return choices
    }

    /// The choice Continue applies: the person's pick, else the one Drop
    /// already runs on, else the first of `dropChoices`. `nil` = no way to
    /// dictate yet, so the footer offers Set up later.
    var chosenDrop: OnboardingDropChoice? {
        let choices = dropChoices
        if let dropPick, choices.contains(dropPick) { return dropPick }
        if let account = speech.currentAccount, let running = choices.first(where: { $0.account == account }) {
            return running
        }
        return choices.first
    }

    /// The speech page's footer: Continue (with what Drop will use) or Set up later.
    var speechCanContinue: Bool { chosenDrop != nil || dropReady }

    /// A saved speech tile or the downloaded model was picked.
    func pickDrop(_ choice: OnboardingDropChoice) {
        beginSpeechAction()
        dropPick = choice
        dropCheck = .idle
    }

    /// Why the provider refused this key, if it did.
    func keyRefusal(_ kind: AIProviderKind) -> String? {
        APIAndModelsViewModel.builtInAccount(for: kind).flatMap(models.keyRefusal)
    }

    /// Continue on the speech page. A provider Drop does not run on yet gets
    /// Settings' free key check first; a refusal stays on the page with the
    /// reason. Then both Drop rows get the choice and the page moves on.
    func continueFromSpeech() {
        guard dropCheck != .checking else { return }
        guard let choice = chosenDrop else {
            if dropReady { advance() }
            return
        }
        let action = beginSpeechAction()
        guard case .provider(let kind) = choice, speech.currentAccount != choice.account,
              let account = APIAndModelsViewModel.builtInAccount(for: kind) else {
            return apply(choice)
        }
        dropCheck = .checking
        Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await self.models.checkSavedKey(account)
            // A newer pick, Continue or save replaced this request.
            guard action == self.speechAction else { return }
            switch status {
            case .rejected?:
                self.dropCheck = .failed(choice, self.keyRefusal(kind) ?? "\(choice.name) did not accept the key")
            case nil:
                self.dropCheck = .failed(choice, "Couldn't read the \(choice.name) key from the Keychain")
            default:
                self.apply(choice)
            }
        }
    }

    private func apply(_ choice: OnboardingDropChoice) {
        dropPick = choice
        dropCheck = .idle
        switch choice {
        case .provider(let kind): speech.choose(provider: kind)
        case .onThisMac: speech.chooseOnDevice()
        }
        routesChanged()
        if page == .speech { advance() }
    }

    func keyAvailable(_ kind: AIProviderKind) -> Bool {
        guard let account = OnboardingDropSpeech.account(for: kind) else { return false }
        return models.accountIsAvailableForSelection(account)
    }

    func setUpSpeechLater() {
        speechSkipped = true
        advance()
    }

    func restoreFromAnotherMac() {
        openSettings(.backup, nil)
    }

    /// The language Drop listens for; `nil` lets the provider detect it.
    func setLanguage(_ language: AppLanguage?) {
        preferences.selectedLanguage = language
        self.language = preferences.selectedLanguage
    }

    // MARK: - Permissions

    /// A Drop press during the onboarding found a permission missing. The
    /// onboarding shows it instead of a second repair window.
    func showPermissions() {
        pages = OnboardingFlow.addingPermissions(to: pages)
        show(.permissions)
    }

    /// Optional, for Shot. One request per launch, shared with Shot
    /// (`ScreenRecordingAccess.requestOnce`); after it, a press opens System
    /// Settings. On `.requested` nothing else is shown: macOS's dialog has its
    /// own button to System Settings.
    // WHY: .project-docs/decisions/2026-11-22-shot-single-permission-prompt.md
    func requestScreenRecording() {
        switch screenRecording.requestOnce() {
        case .granted: permissions.refresh(restartRecoveryPolling: false)
        case .requested: break
        case .alreadyRequested: openScreenRecordingSettings()
        }
        screenRecordingAsked = screenRecording.requested
    }

    private func permissionsCompleted() {
        guard page == .permissions else { return }
        advance()
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        pollBudget = DropHotkeyRecoveryPollBudget()
        // Accessibility is granted in System Settings, outside the app.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.pollBudget.consume() else { return self.stopPermissionPolling() }
                self.permissions.refresh(restartRecoveryPolling: false)
            }
        }
    }

    private func stopPermissionPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Try

    /// Drop was pressed before its speech was set up. The onboarding says so
    /// in place instead of opening Settings over itself.
    func noteDropSetupFailure(_ feature: AIFeature) {
        dropSetupFailure = feature
    }

    func openDropSpeechSettings() {
        addModel(dropSetupFailure ?? .drop(speech.mode()))
    }

    func noteDictated() {
        dictated = true
        dropSetupFailure = nil
    }

    // MARK: - Features

    @Published private(set) var agentProblem: String?
    @Published private(set) var agentConnecting = false

    var googleOn: Bool { UserPreferencesCache.shared.currentGoogleEnabled }
    var meetingsOn: Bool { UserPreferencesCache.shared.currentMeetingsEnabled }
    var agentOn: Bool {
        AgentOtherSection.isOn(enabled: UserPreferencesCache.shared.currentAgentEnabled,
                               activeProvider: AgentProviderStore.shared.activeProvider)
    }
    var meetingsAction: OnboardingFeatureAction { OnboardingFeatureAction.meetings(speech) }
    var agentAction: OnboardingFeatureAction {
        OnboardingFeatureAction.agent(harness: AgentProviderStore.shared.activeProvider)
    }

    func setGoogle(_ on: Bool) {
        UserPreferencesCache.shared.setGoogleEnabled(on)
        revision &+= 1
    }

    func setMeetings(_ on: Bool) {
        UserPreferencesCache.shared.setMeetingsEnabled(on)
        revision &+= 1
    }

    /// The same rule as the Agent's switch in Features: on needs a harness
    /// chosen in Keys & models; off keeps it.
    func setAgent(_ on: Bool) {
        agentProblem = AgentOtherSection.turn(on, store: .shared) { enabled in
            UserPreferencesCache.shared.setAgentEnabled(enabled)
        }?.message
        revision &+= 1
    }

    func addModel(_ feature: AIFeature) {
        openSettings(.apiAndModels, feature)
    }

    // MARK: - Customize

    func openHotkeys() { openSettings(.hotkeys, nil) }
    func openToolbox() { openSettings(.toolbox, nil) }

    // MARK: - Routes

    private func routesChanged() {
        dropReady = speech.isReady
        revision &+= 1
    }
}

/// What Drop can be set to on the speech page.
enum OnboardingDropChoice: Hashable {
    case provider(AIProviderKind)
    case onThisMac

    var account: ProviderAccount? {
        switch self {
        case .provider(let kind): return OnboardingDropSpeech.account(for: kind)
        case .onThisMac: return .thisMac
        }
    }

    var name: String {
        switch self {
        case .provider(let kind): return OnboardingKeyTarget.provider(kind).name
        case .onThisMac: return "On this Mac"
        }
    }
}

/// Continue's key check on the speech page.
enum OnboardingDropCheck: Equatable {
    case idle
    case checking
    case failed(OnboardingDropChoice, String)
}

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

    let permissions: PermissionsSettingsViewModel
    let onDevice: OnDeviceSpeechModelController
    let supportsOnDevice: Bool
    let speech: OnboardingDropSpeech
    let preferences: PrivacyPreferences
    let codingTools: OnboardingCodingTools
    /// The silent Drop demo on the speech page.
    let demo = OnboardingDropDemo()
    /// The key form's store of keys and routes; built when the form opens.
    private(set) lazy var models: APIAndModelsViewModel = injectedModels ?? APIAndModelsViewModel()
    /// The Tavily search key, saved the way Settings -> API keys saves it.
    private(set) lazy var tavily: TavilySettings = models.makeTavilySettings()
    private let injectedModels: APIAndModelsViewModel?
    /// The user chose Set up later on the speech page.
    private var speechSkipped = false
    private var downloadStarted = false
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
        preferences: PrivacyPreferences = .shared,
        codingTools: OnboardingCodingTools? = nil,
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
        self.preferences = preferences
        self.codingTools = codingTools ?? OnboardingCodingTools()
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
        if onDevice.status == .ready {
            speech.useOnDevice()
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

    /// A speech key was accepted and saved (or an existing one chosen).
    func useKey(_ kind: AIProviderKind) {
        speech.use(provider: kind)
        routesChanged()
        if dropReady { advance() }
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

    private(set) lazy var agentMode = AgentModeViewModel(
        store: .shared, probe: { _ in await NativeAgentProvider().probe() }, notify: { _ in })
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
        OnboardingFeatureAction.agent(selectedModel: AgentSettingsStore.shared.selectedOpenCodeModel)
    }

    func setGoogle(_ on: Bool) {
        UserPreferencesCache.shared.setGoogleEnabled(on)
        revision &+= 1
    }

    func setMeetings(_ on: Bool) {
        UserPreferencesCache.shared.setMeetingsEnabled(on)
        revision &+= 1
    }

    /// The same two steps as Settings -> Other -> Agent: connect the native
    /// Agent, then turn its shortcuts on.
    func setAgent(_ on: Bool) {
        agentProblem = nil
        guard on else {
            UserPreferencesCache.shared.setAgentEnabled(false)
            agentMode.disconnect()
            revision &+= 1
            return
        }
        guard AgentSettingsStore.shared.selectedOpenCodeModel != nil else {
            agentProblem = AgentOtherSection.Problem.noModel.message
            return
        }
        agentConnecting = true
        Task { @MainActor in
            defer { agentConnecting = false; revision &+= 1 }
            if AgentProviderStore.shared.activeProvider != .native { await agentMode.connect(.native) }
            guard AgentProviderStore.shared.activeProvider == .native else {
                agentProblem = AgentOtherSection.Problem.connectFailed.message
                return
            }
            UserPreferencesCache.shared.setAgentEnabled(true)
        }
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

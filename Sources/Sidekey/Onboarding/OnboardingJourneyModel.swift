import AppKit
import Combine
import Foundation

/// Stand-ins for the system permission requests (the standalone preview).
struct OnboardingPermissionRequests {
    var keyboard: () -> Void
    var microphone: () -> Void
    var inputMonitoring: () -> Void
}

/// What the shown step is doing: nothing yet, working, done (with what was
/// set) or failed (with the reason, the step stays).
enum OnboardingStepOutcome: Equatable {
    case idle
    case working(String)
    case done(String)
    case failed(String)

    var isDone: Bool { if case .done = self { return true } else { return false } }
}

/// State of one onboarding: the way through its steps, the choices and what
/// each step's action did. A successful action moves on by itself after a
/// short dwell the person can hold; Back keeps everything done.
///
/// Speech and the language model are set through the shared Speech and LLM
/// rows of Settings -> API & Models (`APIAndModelsViewModel.selectShared`):
/// one pick covers every feature of its kind that it can serve, the rest say
/// why in one line, and nothing switches without that pick.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingJourneyModel: ObservableObject {
    @Published private(set) var step: OnboardingStep
    @Published private(set) var progress: OnboardingProgress
    /// What each step's action did in this onboarding.
    @Published private(set) var outcomes: [OnboardingStep: OnboardingStepOutcome] = [:]
    /// The speech provider whose key field is open on the speech key step.
    @Published var speechProvider: AIProviderKind = .soniox
    /// The language model provider whose key field is open.
    @Published var llmProvider: AIProviderKind = .anthropic
    /// The dictation language; `nil` is Auto.
    @Published private(set) var language: AppLanguage?
    /// Features the shared pick could not serve, one line each.
    @Published private(set) var notes: [String] = []
    /// Bumped when routes change elsewhere, so captions re-read them.
    @Published private(set) var revision = 0
    /// Permission steps whose Allow was pressed: they wait for macOS.
    @Published private(set) var requested: Set<OnboardingStep> = []
    /// Which way the last step change went, for the step transition.
    @Published private(set) var direction: OnboardingNavDirection = .forward

    let start: OnboardingStart
    let models: APIAndModelsViewModel
    let permissions: PermissionsSettingsViewModel
    let onDevice: OnDeviceSpeechModelController
    let preferences: PrivacyPreferences
    let screenRecording: ScreenRecordingAccess
    private let dropSpeech: OnboardingDropSpeech
    private let openScreenRecordingSettings: () -> Void
    /// The pause after a success, which the person can hold (Dwell Latch).
    let dwell: OnboardingDwellController
    /// The Tavily search key, saved the way Settings -> API keys saves it.
    let tavily: TavilySettings
    /// The person's shortcuts, Toolbox and Agent switch for the tour steps.
    let hotkeys: HotkeyPreferences
    let toolbox: HoverLayoutStore
    let agentEnabled: () -> Bool
    /// The standalone preview: nothing asks macOS, a button stands in for Drop.
    let isPreview: Bool
    private let requests: OnboardingPermissionRequests?

    /// The latest speech and language model actions (a source picked, a key
    /// used, the download started). An answer that arrives after a newer
    /// action of its kind changes no route and moves nothing.
    // WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
    private var latest: [SharedModelKind: Int] = [:]
    private var granted: Set<OnboardingStep> = []
    private var pollTimer: Timer?
    private var pollBudget = DropHotkeyRecoveryPollBudget()
    private var subscriptions: Set<AnyCancellable> = []

    var onFinish: () -> Void = {}
    var openSettings: (SettingsWindowTab, AIFeature?) -> Void = { _, _ in }

    /// The speech providers of the speech key step (Drop runs on these), in
    /// their tab order. OpenAI joins them once the app can run its speech
    /// models: the registry then names its Drop model (task #73).
    let speechProviders: [AIProviderKind]
    /// The language model providers of the LLM key step.
    static let llmProviders: [AIProviderKind] = [.anthropic, .openAI, .openRouter]

    static var offersOpenAISpeech: Bool { ModelRegistry.recommended(for: .dropFast, kind: .openAI) != nil }

    init(
        models: APIAndModelsViewModel? = nil,
        permissions: PermissionsSettingsViewModel? = nil,
        onDevice: OnDeviceSpeechModelController? = nil,
        dropSpeech: OnboardingDropSpeech? = nil,
        supportsOnDevice: Bool = OnDeviceSpeechModelStore.isSupportedHost,
        preferences: PrivacyPreferences? = nil,
        screenRecording: ScreenRecordingAccess? = nil,
        openScreenRecordingSettings: @escaping () -> Void = PermissionsHelper.openScreenRecordingSettings,
        defaultsChanges: NotificationCenter = .default,
        dwellWait: ((TimeInterval) async -> Void)? = nil,
        tavily: TavilySettings? = nil,
        hotkeys: HotkeyPreferences? = nil,
        toolbox: HoverLayoutStore? = nil,
        agentEnabled: (() -> Bool)? = nil,
        requests: OnboardingPermissionRequests? = nil,
        isPreview: Bool = false,
        offersOpenAISpeech: Bool? = nil
    ) {
        let openAI = offersOpenAISpeech ?? Self.offersOpenAISpeech
        speechProviders = OnboardingDropSpeech.keyProviders + (openAI ? [.openAI] : [])
        let models = models ?? APIAndModelsViewModel()
        let permissions = permissions ?? PermissionsSettingsViewModel(onComplete: {}, autoComplete: false)
        let preferences = preferences ?? .shared
        let dropSpeech = dropSpeech ?? OnboardingDropSpeech()
        let screenRecording = screenRecording ?? .shared
        self.models = models
        self.permissions = permissions
        self.onDevice = onDevice ?? .shared
        self.dropSpeech = dropSpeech
        self.preferences = preferences
        self.screenRecording = screenRecording
        self.openScreenRecordingSettings = openScreenRecordingSettings
        dwell = OnboardingDwellController(wait: dwellWait)
        language = preferences.selectedLanguage
        let tavily = tavily ?? models.makeTavilySettings()
        self.tavily = tavily
        self.hotkeys = hotkeys ?? .shared
        self.toolbox = toolbox ?? .shared
        self.agentEnabled = agentEnabled ?? { UserPreferencesCache.shared.currentAgentEnabled }
        self.requests = requests
        self.isPreview = isPreview

        let llm = models.sharedRow(.llm)
        let snapshot = permissions.snapshot
        var start = OnboardingStart()
        start.speechReady = dropSpeech.isReady
        start.llmReady = llm.map { $0.choice != nil || $0.isMixed } ?? false
        start.searchReady = tavily.configured
        start.languageChosen = preferences.selectedLanguage != nil
        start.keyboardGranted = snapshot.accessibilityGranted
        start.microphoneGranted = snapshot.microphoneGranted
        start.screenRecordingGranted = permissions.screenRecordingGranted
        start.onDeviceSupported = supportsOnDevice
        self.start = start
        var progress = OnboardingProgress()
        progress.hasLanguageModel = start.llmReady
        progress.needsInputMonitoring = permissions.dropHotkeyStatus == .inputMonitoringRequired
        progress.speechExpected = start.speechReady
        self.progress = progress
        step = OnboardingJourney.steps(start: start, progress: progress).first ?? .thanks

        observePermissions()
        defaultsChanges.publisher(for: UserDefaults.didChangeNotification)
            .merge(with: defaultsChanges.publisher(for: .sidekeyCapabilityFlagsChanged))
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.revision += 1 }
            .store(in: &subscriptions)
        arrive(at: step)
    }

    // MARK: - The way

    var steps: [OnboardingStep] { OnboardingJourney.steps(start: start, progress: progress) }
    var fraction: Double { OnboardingJourney.fraction(at: step, in: steps) }
    var canGoBack: Bool { OnboardingJourney.previous(before: step, in: steps) != nil }
    func outcome(_ step: OnboardingStep) -> OnboardingStepOutcome { outcomes[step] ?? .idle }

    /// The progress bar: every step, with skipped and unnecessary ones hollow.
    var segments: [OnboardingSegment] {
        let done = Set(outcomes.compactMap { $0.value.isDone ? $0.key : nil })
        return OnboardingJourney.segments(start: start, progress: progress, current: step, done: done)
    }

    /// The step after this one, for "Next: Language".
    var nextStep: OnboardingStep? { OnboardingJourney.next(after: step, in: steps) }

    /// Next, Set up later, Skip, Return or the pill: go on now.
    func next() {
        guard let next = OnboardingJourney.next(after: step, in: steps) else { return finish() }
        show(next, direction: .forward)
    }

    /// Back, by button or ← / ⌘[. Only the step changes; a pending automatic
    /// move is cancelled, and a step already done waits in review.
    func back() {
        guard let previous = OnboardingJourney.previous(before: step, in: steps) else { return }
        show(previous, direction: .backward)
    }

    func finish() {
        stop()
        onFinish()
    }

    /// The window closed: nothing keeps polling. A running download goes on.
    func stop() {
        stopPolling()
    }

    private func show(_ next: OnboardingStep, direction: OnboardingNavDirection) {
        dwell.cancel()
        self.direction = direction
        step = next
        arrive(at: next)
        let following = nextStep?.shortTitle ?? OnboardingStep.thanks.shortTitle
        if direction == .backward, outcome(next).isDone || next.isInformational, next != .thanks {
            dwell.review(next: following) { [weak self] in self?.next() }
        } else if direction == .forward, next.isInformational, let seconds = next.dwell {
            dwell.schedule(seconds, next: following) { [weak self] in self?.next() }
        }
    }

    private func arrive(at step: OnboardingStep) {
        if case .failed = outcome(step) { outcomes[step] = .idle }
        offerSavedKey(on: step)
        switch step {
        case .keyboard, .microphone, .inputMonitoring, .screenRecording:
            permissions.refresh(restartRecoveryPolling: false)
            startPolling()
        default:
            stopPolling()
        }
    }

    /// One key serves both steps where its provider does speech and text
    /// (OpenAI): a key saved on one step opens the other step's tab with
    /// "Use saved", never asking for it again.
    private func offerSavedKey(on step: OnboardingStep) {
        switch step {
        case .llmKey where Self.llmProviders.contains(speechProvider) && keySaved(speechProvider):
            llmProvider = speechProvider
        case .speechKey where speechProviders.contains(llmProvider) && keySaved(llmProvider) && !keySaved(speechProvider):
            speechProvider = llmProvider
        default:
            break
        }
    }

    /// The shown step's action succeeded: show it for the step's dwell, then
    /// move on. A success of a step that is not shown is only recorded.
    private func succeed(_ done: OnboardingStep, _ text: String) {
        outcomes[done] = .done(text)
        guard done == step, !dwell.isCounting, !dwell.isLatched, let seconds = done.dwell else { return }
        let following = nextStep?.shortTitle ?? OnboardingStep.thanks.shortTitle
        dwell.schedule(seconds, next: following) { [weak self] in self?.next() }
    }

    private func begin(_ kind: SharedModelKind) -> Int {
        let action = (latest[kind] ?? 0) + 1
        latest[kind] = action
        return action
    }

    private func isLatest(_ action: Int, _ kind: SharedModelKind) -> Bool { latest[kind] == action }

    // MARK: - 1. Source

    /// On this Mac: download the model (or use the downloaded one) and give it
    /// every speech feature it serves. The download and the route outlive the
    /// window, like before.
    func chooseOnThisMac() {
        let action = begin(.speech)
        progress.source = .onThisMac
        progress.speechExpected = true
        if onDevice.status == .ready {
            Task { @MainActor [weak self] in await self?.applyOnDevice(advance: true, action: action) }
            return
        }
        outcomes[.source] = .working("Downloading the speech model…")
        let controller = onDevice
        Task { @MainActor [weak self] in
            let landed = await controller.download()
            guard let self else { return }
            guard self.isLatest(action, .speech) else { return }
            if landed { await self.applyOnDevice(advance: false, action: action) } else { self.outcomes[.source] = .failed("The download did not finish. Try again or use your key.") }
        }
        // Starting the download is this step's success; it goes on in the background.
        succeed(.source, "Speech on this Mac")
    }

    private func applyOnDevice(advance: Bool, action: Int) async {
        guard isLatest(action, .speech) else { return }
        let applied = await models.selectShared(model: OnDeviceSpeechModel.parakeetTdtV3.rawValue, account: .thisMac,
                                                kind: .speech, replaceCustom: false)
        guard isLatest(action, .speech) else { return }
        notes = models.sharedRow(.speech)?.notes ?? []
        if applied || dropSpeech.isReady {
            if advance { succeed(.source, "Speech on this Mac") } else { outcomes[.source] = .done("Speech on this Mac") }
        } else {
            outcomes[.source] = .failed(notes.first ?? "Couldn't use the model on this Mac")
        }
    }

    func chooseYourKey() {
        _ = begin(.speech)
        progress.source = .yourKey
        progress.speechExpected = dropSpeech.isReady
        succeed(.source, "Your key")
    }

    // MARK: - 2. Speech key

    /// Saves (or, with an empty key, reuses the saved) key of `provider`,
    /// checks it like Settings does and makes it the shared Speech.
    func useSpeechKey(_ key: String, provider: AIProviderKind) async {
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider),
              let model = ModelRegistry.recommended(for: .dropFast, kind: provider) else { return }
        let action = begin(.speech)
        outcomes[.speechKey] = .working("Checking the \(provider.displayName) key…")
        let problem = await saveOrCheck(key, account: account)
        // A newer speech choice answers for this step now; this key stays saved.
        guard isLatest(action, .speech) else { return }
        if let problem {
            outcomes[.speechKey] = .failed(problem)
            return
        }
        let applied = await models.selectShared(model: model, account: account, kind: .speech, replaceCustom: false)
        guard isLatest(action, .speech) else { return }
        notes = models.sharedRow(.speech)?.notes ?? []
        guard applied || dropSpeech.isReady else {
            outcomes[.speechKey] = .failed(notes.first ?? "\(provider.displayName) could not be used for speech")
            return
        }
        progress.speechExpected = true
        succeed(.speechKey, model)
    }

    // MARK: - 3. Language model key

    /// The model the LLM step preselects for `provider`: the Agent's
    /// recommended one when the registry has it (so the pick also serves the
    /// Agent's tools), otherwise the newest catalog model the Agent can use.
    /// OpenAI has no registry default: its live catalog is the source.
    func preselectedModel(_ provider: AIProviderKind) -> String? {
        if let recommended = ModelRegistry.recommended(for: .agent, kind: provider) { return recommended }
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider) else { return nil }
        let options = models.sections(for: .agent).filter { $0.account == account }.flatMap(\.options)
        let usable = options.filter { if case .notSupported = $0.state { return false } else { return true } }
        return usable.max { ($0.catalogDate ?? .distantPast) < ($1.catalogDate ?? .distantPast) }?.model
    }

    /// The model the person picked on the LLM step, or `nil` for the preselected one.
    @Published var llmModel: String?

    func useLLMKey(_ key: String, provider: AIProviderKind) async {
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider) else { return }
        let action = begin(.llm)
        outcomes[.llmKey] = .working("Checking the \(provider.displayName) key…")
        let problem = await saveOrCheck(key, account: account)
        guard isLatest(action, .llm) else { return }
        if let problem {
            outcomes[.llmKey] = .failed(problem)
            return
        }
        // Saving the key loaded its catalog, so a catalog-only provider has a model now.
        guard let model = llmModel ?? preselectedModel(provider) else {
            outcomes[.llmKey] = .failed("\(provider.displayName) lists no model the Agent can use")
            return
        }
        let applied = await models.selectShared(model: model, account: account, kind: .llm, replaceCustom: false)
        guard isLatest(action, .llm) else { return }
        notes = models.sharedRow(.llm)?.notes ?? []
        guard applied || models.sharedRow(.llm)?.choice != nil else {
            outcomes[.llmKey] = .failed(notes.first ?? "\(provider.displayName) · \(model) could not be used")
            return
        }
        progress.hasLanguageModel = true
        succeed(.llmKey, model)
    }

    /// A new key goes through Settings' save (check + Keychain); an empty one
    /// means "use the key already saved", checked for free.
    private func saveOrCheck(_ key: String, account: ProviderAccount) async -> String? {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            guard models.accountIsAvailableForSelection(account) else { return "Paste the key first" }
            let status = await models.checkSavedKey(account)
            if status == nil { return "Couldn't read the \(account.kind.displayName) key from the Keychain" }
            if let refusal = models.keyRefusal(account) { return refusal }
            await models.refreshModels()
            return nil
        }
        return await models.replaceKey(candidate, for: account)
    }

    func keySaved(_ provider: AIProviderKind) -> Bool {
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider) else { return false }
        return models.accountIsAvailableForSelection(account)
    }

    // MARK: - 4. Search

    func useSearchKey(_ key: String) async {
        outcomes[.search] = .working("Checking the Tavily key…")
        tavily.draftKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        await tavily.save()
        if tavily.messageIsError || !tavily.configured {
            outcomes[.search] = .failed(tavily.message ?? "Key not accepted")
        } else {
            succeed(.search, "Tavily")
        }
    }

    // MARK: - 5. Language

    func setLanguage(_ language: AppLanguage?) {
        preferences.selectedLanguage = language
        self.language = preferences.selectedLanguage
        succeed(.language, language?.englishName ?? "Detect automatically")
    }

    // MARK: - 6–8. Permissions

    func requestKeyboard() {
        requested.insert(.keyboard)
        if let requests { requests.keyboard() } else { permissions.requestAccessibility() }
    }

    func requestMicrophone() {
        requested.insert(.microphone)
        if let requests { requests.microphone() } else { permissions.requestMicrophone() }
    }

    func requestInputMonitoring() {
        requested.insert(.inputMonitoring)
        if let requests { requests.inputMonitoring() } else { permissions.requestInputMonitoring() }
    }

    /// Coming back from System Settings: check again at once.
    func recheckPermissions() { permissions.refresh(restartRecoveryPolling: false) }

    /// One request per launch, shared with Shot; afterwards System Settings.
    // WHY: .project-docs/decisions/2026-11-22-shot-single-permission-prompt.md
    func requestScreenRecording() {
        requested.insert(.screenRecording)
        switch screenRecording.requestOnce() {
        case .granted: permissions.refresh(restartRecoveryPolling: false)
        case .requested: break
        case .alreadyRequested: openScreenRecordingSettings()
        }
    }

    /// A permission that turns granted while its step is shown moves on; one
    /// granted earlier (another step, before the window) is only recorded.
    private func observePermissions() {
        permissions.$snapshot
            .combineLatest(permissions.$screenRecordingGranted, permissions.$dropHotkeyStatus)
            .sink { [weak self] snapshot, screen, hotkey in
                self?.permissionsChanged(snapshot: snapshot, screen: screen, hotkey: hotkey)
            }
            .store(in: &subscriptions)
    }

    private func permissionsChanged(snapshot: PermissionsHelper.Snapshot, screen: Bool, hotkey: DropHotkeyStatus) {
        let needsInputMonitoring = hotkey == .inputMonitoringRequired
        if needsInputMonitoring, !progress.needsInputMonitoring { progress.needsInputMonitoring = true }
        let now: [(OnboardingStep, Bool, String)] = [
            (.keyboard, snapshot.accessibilityGranted, "Keyboard control allowed"),
            (.microphone, snapshot.microphoneGranted, "Microphone allowed"),
            (.inputMonitoring, progress.needsInputMonitoring && !needsInputMonitoring && hotkey == .ready, "Keyboard access allowed"),
            (.screenRecording, screen, "Screen Recording allowed"),
        ]
        for (permission, isGranted, text) in now where isGranted && !granted.contains(permission) {
            granted.insert(permission)
            succeed(permission, text)
        }
    }

    private func startPolling() {
        stopPolling()
        pollBudget = DropHotkeyRecoveryPollBudget()
        // Permissions are granted in System Settings, outside the app.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.pollBudget.consume() else { return self.stopPolling() }
                self.permissions.refresh(restartRecoveryPolling: false)
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// A Drop press during the onboarding found a permission missing: the
    /// onboarding shows the first missing one instead of a repair window.
    func showPermissions() {
        progress.permissionsMissing = true
        let snapshot = permissions.snapshot
        show(snapshot.accessibilityGranted ? .microphone : .keyboard, direction: .forward)
    }

    // MARK: - 9. Try Drop

    func noteDictated() {
        succeed(.tryDrop, "That's Drop")
    }

    /// Drop was pressed before its speech was set up (or while the model is
    /// still downloading): said on the try step instead of Settings over it.
    func noteDropSetupFailure(_ feature: AIFeature) {
        if case .downloading = onDevice.status {
            outcomes[.tryDrop] = .failed("The speech model is still downloading")
        } else {
            outcomes[.tryDrop] = .failed("\(feature.title) has no speech model yet")
        }
    }

    // MARK: - Summary

    /// The last step's receipt, from the saved routes and grants.
    var receipt: (speech: String, llm: String, language: String, access: String) {
        _ = revision
        func label(_ kind: SharedModelKind) -> String {
            guard let row = models.sharedRow(kind) else { return "Not set" }
            if row.isMixed { return "Mixed" }
            guard let choice = row.choice else { return "Not set" }
            let provider = choice.account.kind == .onDevice ? "On this Mac" : choice.account.kind.displayName
            return "\(provider) · \(choice.model)"
        }
        let snapshot = permissions.snapshot
        let granted = [snapshot.accessibilityGranted, snapshot.microphoneGranted, permissions.screenRecordingGranted]
            .filter { $0 }.count
        return (label(.speech), label(.llm), language?.englishName ?? "Any language", "\(granted) / 3 allowed")
    }

    /// "Speech: ElevenLabs · LLM: Anthropic claude-sonnet-5-5", from the
    /// saved shared rows; empty parts are left out.
    var summary: String {
        _ = revision
        var parts: [String] = []
        if let speech = models.sharedRow(.speech)?.choice {
            parts.append("Speech: \(speech.account.kind == .onDevice ? "On this Mac" : speech.account.kind.displayName)")
        }
        if let llm = models.sharedRow(.llm)?.choice {
            parts.append("LLM: \(llm.account.kind.displayName) \(llm.model)")
        }
        return parts.joined(separator: " · ")
    }
}

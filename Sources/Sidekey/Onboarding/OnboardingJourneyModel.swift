import AppKit
import Combine
import Foundation

/// Why a pasted key was not taken: its shape, or the provider's answer.
/// The key check tells apart a refused key, an empty balance, a key without
/// speech access and no answer; a rate limit has no answer of its own.
enum OnboardingKeyProblem: Equatable {
    case format
    /// Neither the key's own format nor a picked mark names a provider.
    case unrecognized
    case refused
    case noCredit
    case noSpeechAccess
    case unreachable
    /// The service answered "too many requests" (HTTP 429): the key may be
    /// fine, so the same key can be tried again in a moment.
    case busy
    case other(String)

    init?(status: KeyStatus) {
        switch status {
        case .valid, .limited: return nil
        case .rejected(.invalidKey): self = .refused
        case .rejected(.outOfCredit): self = .noCredit
        case .rejected(.missingSpeechPermission): self = .noSpeechAccess
        case .unreachable: self = .unreachable
        }
    }

    /// A key is one unbroken run of printable ASCII, at least 16 characters.
    static func looksLikeAKey(_ key: String) -> Bool {
        key.count >= 16 && key.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 && $0.value < 127 }
    }

    func message(provider: String) -> String {
        switch self {
        case .format: return "That doesn't look like a \(provider) key. Check for missing characters."
        case .unrecognized: return "That doesn't look like a key from these providers. Check it, or pick its provider below."
        case .refused: return "\(provider) didn't accept this key. It may be mistyped or revoked."
        case .noCredit: return "The key works, but this \(provider) account is out of credit."
        case .noSpeechAccess: return "This \(provider) key has no Speech to Text access."
        case .unreachable: return "Couldn't reach \(provider). Check your connection and try again."
        case .busy: return "\(provider) is limiting requests right now. Wait a moment and try again."
        case .other(let text): return text
        }
    }

    /// No answer: the same key can simply be tried again.
    var offersRetry: Bool { self == .unreachable || self == .busy }

    /// A failed Tavily check, by its HTTP status: 401 and 403 refuse the key,
    /// 432 and 433 are Tavily's plan and pay-as-you-go limits (no credit),
    /// 429 is too many requests, and no HTTP answer is unreachable.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    init(tavily error: Error) {
        if case .service(_, let status, _)? = error as? NativeAgentError {
            switch status {
            case 401, 403: self = .refused
            case 402, 432, 433: self = .noCredit
            case 429: self = .busy
            default: self = .other("Tavily answered with an error (\(status)). Try again later.")
            }
        } else if error is URLError {
            self = .unreachable
        } else {
            self = .other("Couldn't check the Tavily key. Try again.")
        }
    }
}

/// Stand-ins for the system permission requests (the standalone preview).
struct OnboardingPermissionRequests {
    var keyboard: () -> Void
    var microphone: () -> Void
    var inputMonitoring: () -> Void
    /// "Open System Settings" on an access step.
    var openSettings: (OnboardingStep) -> Void = { _ in }
}

/// What Drop is doing while Try Drop is shown, from the app's own state: a
/// take recording, its voice level (read per frame, not published), and
/// whether the take reached the insert. The preview drives it by hand.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
final class OnboardingVoiceSignal: ObservableObject {
    /// Drop is recording.
    @Published private(set) var recording = false
    /// Drop is working on a take (recording, transcribing or inserting).
    @Published private(set) var working = false
    /// The latest voice level, 0 to 1.
    private(set) var level = 0.0
    /// When the latest take started.
    private(set) var startedAt: Date?
    /// The latest take reached the insert (its text went somewhere).
    private(set) var inserted = false
    /// The latest take ended in Drop's own delivery failure.
    private(set) var failedDelivery = false
    private var subscriptions: Set<AnyCancellable> = []

    init(appState: AppState?) {
        guard let appState else { return }
        appState.$phase
            .sink { [weak self] phase in self?.phaseChanged(phase) }
            .store(in: &subscriptions)
        appState.$audioLevels
            .sink { [weak self] levels in self?.level = Double(levels.last ?? 0) }
            .store(in: &subscriptions)
    }

    func phaseChanged(_ phase: AppPhase) {
        let nowRecording = phase == .recording
        if nowRecording, !recording {
            startedAt = Date()
            inserted = false
            failedDelivery = false
        }
        if phase == .inserting { inserted = true }
        if phase == .deliveryFailed { failedDelivery = true }
        if !nowRecording { level = 0 }
        if recording != nowRecording { recording = nowRecording }
        let nowWorking = phase != .idle && phase != .deliveryFailed
        if working != nowWorking { working = nowWorking }
    }

    /// The preview's stand-in for the microphone.
    func setLevel(_ value: Double) { level = max(0, min(1, value)) }
}

/// The standalone preview's stand-in for Drop on Try Drop (it lives in
/// OnboardingPreviewKit, which the app does not link). The app has none:
/// there Drop itself listens and inserts into the field.
@MainActor
protocol OnboardingDropStandIn: AnyObject {
    /// Try Drop is shown: listen for the person's Drop shortcut, drive
    /// `voice` like Drop's phases and hand over the take's text.
    func attach(shortcut: HotkeyShortcut, gesture: HotkeyGesture, voice: OnboardingVoiceSignal,
                deliver: @escaping (String) -> Void)
    /// Try Drop is gone (Continue, Skip, Back or the window): stop listening
    /// and end a take that is still running.
    func detach()
}

/// Where an access step stands (the design pass's screen 04): Allow, then
/// waiting for System Settings, then allowed and on to the next step; a
/// return from System Settings with the switch still off is "not on yet",
/// with Allow again.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
enum OnboardingAccessState: Equatable {
    case rest
    case waiting
    case granted
    case notOn
    /// This macOS refused the request without a dialog (27.3 beta): an
    /// honest line and Continue, never the "+" list.
    // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
    case unavailable
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

/// Whose answer a key step's state is: a provider's key, the person's own
/// server or Tavily. An accepted key belongs to its provider; another mark
/// shows its own state and never borrows that answer.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
enum OnboardingRoute: Hashable {
    case provider(AIProviderKind)
    case server
    case tavily

    var provider: AIProviderKind? { if case .provider(let kind) = self { return kind } else { return nil } }
}

/// The route a key step runs on now and the line its success showed.
struct OnboardingAcceptance: Equatable {
    let route: OnboardingRoute
    var text: String
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
    @Published private(set) var step: OnboardingStep {
        didSet { resumeDefaults?.set(step.rawValue, forKey: OnboardingLaunch.stepKey) }
    }
    /// Where the shown step is kept for a relaunch; nil in tests and the preview.
    private let resumeDefaults: UserDefaults?
    @Published private(set) var progress: OnboardingProgress
    /// What each step's action did in this onboarding. On a key step it is
    /// the latest attempt; the route that holds is in `accepted`.
    @Published private(set) var outcomes: [OnboardingStep: OnboardingStepOutcome] = [:]
    /// The provider or server each key step's shared row runs on after this
    /// onboarding's check. It changes only after a new check succeeds.
    @Published private(set) var accepted: [OnboardingStep: OnboardingAcceptance] = [:]
    /// Whose key or server the latest attempt on a key step checked.
    private var attempts: [OnboardingStep: OnboardingRoute] = [:]
    /// The server fields as they were accepted, shown again when the person
    /// comes back to Self-hosted.
    private var acceptedServerDrafts: [OnboardingKeyStageKind: OnboardingServerDraft] = [:]
    /// The speech provider whose key field is open on the speech key step.
    @Published var speechProvider: AIProviderKind = .soniox
    /// The language model provider whose key field is open.
    @Published var llmProvider: AIProviderKind = .anthropic
    /// The dictation language; `nil` is Auto.
    @Published private(set) var language: AppLanguage?
    /// The variant picked with it on the globe ("en-GB"), kept beside it.
    @Published private(set) var languageVariant: String?
    /// Features the shared pick could not serve, one line each.
    @Published private(set) var notes: [String] = []
    /// Bumped when routes change elsewhere, so captions re-read them.
    @Published private(set) var revision = 0
    /// Why the speech or language model key was not taken, for its action.
    @Published private(set) var keyProblems: [OnboardingStep: OnboardingKeyProblem] = [:]
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
    /// The screen request is out and its answer not yet seen.
    private var screenAsking = false
    /// The pause after a success, which the person can hold (Dwell Latch).
    let dwell: OnboardingDwellController
    /// Step 1's own beat: the chosen figure's click motion plays, then the
    /// step flows on. No pill; tests hold it like the dwell.
    static let sourceBeat: TimeInterval = 0.34
    private let pause: (TimeInterval) async -> Void
    private var sourceMove: Task<Void, Never>?
    /// The Tavily search key, saved the way Settings -> API keys saves it.
    let tavily: TavilySettings
    /// The person's shortcuts, Toolbox and Agent switch for the tour steps.
    let hotkeys: HotkeyPreferences
    let toolbox: HoverLayoutStore
    let agentEnabled: () -> Bool
    /// The standalone preview: nothing asks macOS, a button stands in for Drop.
    let isPreview: Bool
    private let requests: OnboardingPermissionRequests?
    /// Drop's take while Try Drop is shown.
    let voice: OnboardingVoiceSignal
    /// The standalone preview's Drop on Try Drop; nil in the app.
    let dropStandIn: OnboardingDropStandIn?
    /// How long the take that reached the try field took, from the press.
    @Published private(set) var tryDropSeconds: Double?
    private var tryCheck: Task<Void, Never>?
    /// The quiet after a take ends before Try Drop says nothing arrived.
    static let tryQuiet: TimeInterval = 1.2

    /// The latest speech and language model actions (a source picked, a key
    /// used, the download started). An answer that arrives after a newer
    /// action of its kind changes no route and moves nothing.
    // WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
    private var latest: [SharedModelKind: Int] = [:]
    private var granted: Set<OnboardingStep> = []
    private var pollTimer: Timer?
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
        voice: OnboardingVoiceSignal? = nil,
        dropStandIn: OnboardingDropStandIn? = nil,
        isPreview: Bool = false,
        offersOpenAISpeech: Bool? = nil,
        resumeDefaults: UserDefaults? = nil
    ) {
        self.resumeDefaults = resumeDefaults
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
        pause = dwellWait ?? { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        language = preferences.selectedLanguage
        languageVariant = preferences.selectedLanguageVariant
        let tavily = tavily ?? models.makeTavilySettings()
        self.tavily = tavily
        self.hotkeys = hotkeys ?? .shared
        self.toolbox = toolbox ?? .shared
        self.agentEnabled = agentEnabled ?? { UserPreferencesCache.shared.currentAgentEnabled }
        self.requests = requests
        self.isPreview = isPreview
        self.voice = voice ?? OnboardingVoiceSignal(appState: isPreview ? nil : .shared)
        self.dropStandIn = dropStandIn

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
        if case .server? = llm?.choice?.account { progress.languageModelSelfHosted = true }
        progress.needsInputMonitoring = permissions.dropHotkeyStatus == .inputMonitoringRequired
        progress.speechExpected = start.speechReady
        self.progress = progress
        step = OnboardingLaunch.resumedStep(saved: resumeDefaults?.string(forKey: OnboardingLaunch.stepKey),
                                            on: OnboardingJourney.steps(start: start, progress: progress))

        observePermissions()
        observeVoice()
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
    /// The step's state for the way: a key step whose route holds is done,
    /// whatever another provider's attempt answered since.
    func outcome(_ step: OnboardingStep) -> OnboardingStepOutcome {
        accepted[step].map { .done($0.text) } ?? latest(step)
    }

    /// A key step's state for one provider or the server: its own attempt
    /// while that runs or failed, "accepted" when it is the route that holds,
    /// otherwise nothing yet. One provider's name never meets another's data.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    func outcome(_ step: OnboardingStep, for route: OnboardingRoute) -> OnboardingStepOutcome {
        let attempt = latest(step)
        switch attempt {
        case .working, .failed:
            if attempts[step] == route { return attempt }
        case .idle, .done:
            break
        }
        if let accepted = accepted[step], accepted.route == route { return .done(accepted.text) }
        return .idle
    }

    /// The route a key step shows now: the server's fields or the open mark.
    func shownRoute(_ step: OnboardingStep) -> OnboardingRoute {
        switch step {
        case .speechKey: return serverForms.contains(.speech) ? .server : .provider(speechProvider)
        case .llmKey: return serverForms.contains(.languageModel) ? .server : .provider(llmProvider)
        default: return .tavily
        }
    }

    /// Another mark was opened on the shown key step: a pending automatic
    /// move with the accepted route waits for Next instead.
    func routeShown(on step: OnboardingStep) {
        guard step == self.step, let accepted = accepted[step], accepted.route != shownRoute(step),
              dwell.isCounting else { return }
        dwell.cancel()
    }

    /// The server fields this onboarding accepted on a key step.
    func acceptedServerDraft(_ kind: OnboardingKeyStageKind) -> OnboardingServerDraft? {
        acceptedServerDrafts[kind]
    }

    private func latest(_ step: OnboardingStep) -> OnboardingStepOutcome { outcomes[step] ?? .idle }

    /// Steps the person went on from; one reached again by Back is passed.
    private var leftSteps: Set<OnboardingStep> = []

    /// The progress bar: every step, with skipped and unnecessary ones hollow.
    var segments: [OnboardingSegment] {
        let done = Set(OnboardingStep.allCases.filter { outcome($0).isDone })
        let passed = leftSteps.contains(step) && (done.contains(step) || step.isInformational)
        return OnboardingJourney.segments(start: start, progress: progress, current: step, done: done,
                                          currentPassed: passed)
    }

    /// The step after this one, for "Next: Language".
    var nextStep: OnboardingStep? { OnboardingJourney.next(after: step, in: steps) }

    /// Skip or Set up later: go on and leave this step's route as it was. A
    /// key or model check still running answers for nobody now (a key it
    /// saved stays saved, but no route changes).
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    func skip() {
        let kinds: [OnboardingStep: SharedModelKind] = [.speechKey: .speech, .llmKey: .llm]
        if let kind = kinds[step] {
            _ = begin(kind)
            if case .working = latest(step) { outcomes[step] = .idle }
        }
        next()
    }

    /// Next, Set up later, Skip, Return or the pill: go on now.
    func next() {
        guard let next = OnboardingJourney.next(after: step, in: steps) else { return finish() }
        show(next, direction: .forward)
    }

    /// Back, by button or ← / ⌘[. Only the step changes; a pending automatic
    /// move is cancelled, and a step already done waits in review.
    func back() {
        // On the server fields, Back returns to the key field first.
        if let kind = OnboardingKeyStageKind(step: step), serverForms.contains(kind), !outcome(step, for: .server).isDone {
            return closeServerForm(kind)
        }
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
        dwell.cancel()
        sourceMove?.cancel()
        tryCheck?.cancel()
    }

    private func show(_ next: OnboardingStep, direction: OnboardingNavDirection) {
        dwell.cancel()
        sourceMove?.cancel()
        self.direction = direction
        if direction == .forward { leftSteps.insert(step) }
        step = next
        arrive(at: next)
        let following = nextStep?.shortTitle ?? OnboardingStep.thanks.shortTitle
        // Step 1 is its own Continue: a click on a figure moves on at once.
        guard next != .source else { return }
        if direction == .backward, outcome(next).isDone || next.isInformational, next != .thanks {
            dwell.review(next: following) { [weak self] in self?.next() }
        } else if direction == .forward, next.isInformational, let seconds = next.dwell {
            dwell.schedule(seconds, next: following) { [weak self] in self?.next() }
        }
    }

    private func arrive(at step: OnboardingStep) {
        if case .failed = latest(step) { outcomes[step] = .idle }
        offerSavedKey(on: step)
        switch step {
        case .keyboard, .microphone, .inputMonitoring, .screenRecording:
            // Back on an access step that is still off: Allow again, not a
            // wait left over from before.
            if !latest(step).isDone { requested.remove(step) }
            permissions.refresh(restartRecoveryPolling: false)
            startPolling()
            if direction == .forward, case .done(let text) = latest(step) {
                // macOS can grant this access while the preceding step is still visible.
                succeed(step, text)
            }
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
        case .speechKey where !keySaved(speechProvider):
            let saved = savedKeyProviders(.speech)
            if saved.contains(llmProvider) {
                speechProvider = llmProvider
            } else if !leftSteps.contains(.speechKey), saved.count == 1, let only = saved.first {
                speechProvider = only
            }
        case .llmKey where !keySaved(llmProvider) && !leftSteps.contains(.llmKey):
            let saved = savedKeyProviders(.languageModel)
            if saved.count == 1, let only = saved.first { llmProvider = only }
        default:
            break
        }
    }

    /// The shown step's action succeeded: show it for the step's dwell, then
    /// move on. A success of a step that is not shown is only recorded.
    /// `holds`: the step has a model to choose, so it waits for the pick or
    /// Next instead of moving on by itself.
    private func succeed(_ done: OnboardingStep, _ text: String, holds: Bool = false, route: OnboardingRoute? = nil) {
        outcomes[done] = .done(text)
        if let route { accepted[done] = OnboardingAcceptance(route: route, text: text) }
        if done == .source, step == .source { moveOnFromSource(); return }
        guard !holds, done == step, !dwell.isCounting, !dwell.isLatched, let seconds = done.dwell else { return }
        let following = nextStep?.shortTitle ?? OnboardingStep.thanks.shortTitle
        dwell.schedule(seconds, next: following) { [weak self] in self?.next() }
    }

    /// Step 1 is its own Continue: after the click's beat the chosen key flies
    /// on to step 2 in one motion, with no pill.
    private func moveOnFromSource() {
        sourceMove?.cancel()
        let choice = progress.source
        sourceMove = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pause(Self.sourceBeat)
            guard !Task.isCancelled, self.step == .source, self.progress.source == choice else { return }
            self.next()
        }
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
    /// window, like before: the download's task holds this model until it
    /// lands, so closing onboarding mid-download still sets the route, unless
    /// a newer speech choice came first (here, or in Settings meanwhile).
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
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
        let speech = SharedModelKind.speech.pickerFeature
        let before = models.currentRoute(for: speech)
        Task { @MainActor in
            let landed = await controller.download()
            guard self.isLatest(action, .speech) else { return }
            guard self.models.currentRoute(for: speech) == before else { return }
            if landed { await self.applyOnDevice(advance: false, action: action) } else { self.outcomes[.source] = .failed("The download did not finish. Try again or use your key.") }
        }
        // Starting the download is this step's success; it goes on in the background.
        succeed(.source, "Speech on this Mac")
    }

    private func applyOnDevice(advance: Bool, action: Int) async {
        guard isLatest(action, .speech) else { return }
        let applied = await models.selectShared(model: OnDeviceSpeechModel.parakeetTdtV3.rawValue, account: .thisMac,
                                                kind: .speech, replaceCustom: false,
                                                stillWanted: { self.isLatest(action, .speech) })
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
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider) else { return }
        let model = ModelRegistry.recommended(for: .dropFast, kind: provider)
        // The preview offers OpenAI before the app has a speech model for it.
        guard model != nil || isPreview else { return }
        let action = begin(.speech)
        attempts[.speechKey] = .provider(provider)
        if provider == .deepgram, let model,
           let error = DeepgramLanguagePolicy.configurationError(model: model, language: language?.code) {
            let message = error.localizedDescription + " Go back to Language or choose another speech provider."
            keyProblems[.speechKey] = .other(message)
            outcomes[.speechKey] = .failed(message)
            return
        }
        outcomes[.speechKey] = .working("Checking the \(provider.displayName) key…")
        let problem = await saveOrCheck(key, account: account)
        // A newer speech choice answers for this step now; this key stays saved.
        guard isLatest(action, .speech) else { return }
        keyProblems[.speechKey] = problem
        if let problem {
            outcomes[.speechKey] = .failed(problem.message(provider: provider.displayName))
            return
        }
        guard let model else {
            progress.speechExpected = true
            pickedModels.remove(.speechKey)
            succeed(.speechKey, "\(provider.displayName) speech", route: .provider(provider))
            return
        }
        let applied = await models.selectShared(model: model, account: account, kind: .speech, replaceCustom: false,
                                                stillWanted: { [weak self] in self?.isLatest(action, .speech) ?? false })
        guard isLatest(action, .speech) else { return }
        notes = models.sharedRow(.speech)?.notes ?? []
        guard applied || dropSpeech.isReady else {
            outcomes[.speechKey] = .failed(notes.first ?? "\(provider.displayName) could not be used for speech")
            return
        }
        progress.speechExpected = true
        pickedModels.remove(.speechKey)
        // One speech model per provider, the one Settings -> Speech sets: no
        // choice here, the step moves on (the owner, REV 54).
        // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
        succeed(.speechKey, model, route: .provider(provider))
    }

    // MARK: - 3. Language model key

    /// The model the LLM step preselects for `provider`: the Agent's
    /// recommended one when the registry has it (so the pick also serves the
    /// Agent's tools), otherwise the newest catalog model the Agent can use.
    /// OpenAI has no registry default: its live catalog is the source.
    func preselectedModel(_ provider: AIProviderKind) -> String? {
        // The provider's current catalog decides (its recommended family's
        // newest model); the registry only before the catalog is there.
        // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
        recommendedModel(.llmKey, provider: provider) ?? ModelRegistry.recommended(for: .agent, kind: provider)
    }

    /// The model a key step marks "Recommended": the language model step's
    /// family pick (OnboardingModelPick.recommended), the speech step's
    /// registry model. The one place the onboarding recommends a model.
    func recommendedModel(_ step: OnboardingStep, provider: AIProviderKind? = nil) -> String? {
        switch step {
        case .llmKey:
            let provider = provider ?? llmProvider
            return OnboardingModelPick.recommended(allChoices(for: provider, speech: false), provider: provider)?.id
        case .speechKey:
            return ModelRegistry.recommended(for: .dropFast, kind: provider ?? speechProvider)
        default:
            return nil
        }
    }

    // MARK: - The model, after a key is accepted

    /// The models a key step offers for its provider, newest first, each
    /// with a short price when the catalogs know it.
    func modelChoices(_ step: OnboardingStep, provider: AIProviderKind? = nil) -> [OnboardingModelChoice] {
        // Only the language model step offers a choice: speech has one model
        // per provider (REV 54).
        switch step {
        case .llmKey: return choices(for: provider ?? llmProvider, speech: false)
        default: return []
        }
    }

    /// Every usable model of the step's provider, for the search in
    /// "Choose model" (the list itself shows a selection).
    func modelCatalog(_ step: OnboardingStep, provider: AIProviderKind? = nil) -> [OnboardingModelChoice] {
        switch step {
        case .llmKey:
            return allChoices(for: provider ?? llmProvider, speech: false).filter { OnboardingModelPick.isListed($0.id, speech: false) }
        default: return []
        }
    }

    private func choices(for provider: AIProviderKind, speech: Bool) -> [OnboardingModelChoice] {
        let all = allChoices(for: provider, speech: speech)
        var listed = OnboardingModelPick.listed(all, speech: speech, router: provider == .openRouter)
        // The recommended model is always on the list, and first.
        if let id = recommendedModel(speech ? .speechKey : .llmKey, provider: provider),
           let recommended = all.first(where: { $0.id == id }) ?? listed.first(where: { $0.id == id }) {
            listed.removeAll { $0.id == id }
            listed.insert(recommended, at: 0)
        }
        return listed
    }

    private func allChoices(for provider: AIProviderKind, speech: Bool) -> [OnboardingModelChoice] {
        _ = revision
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider) else { return [] }
        let options = models.sections(for: speech ? .dropFast : .agent).filter { $0.account == account }.flatMap(\.options)
        let usable = options.filter { if case .notSupported = $0.state { return false } else { return true } }
        let all = usable.map { option -> OnboardingModelChoice in
            let perMinute = provider == .openAI ? ModelRegistry.openAISpeechUSDPerMinute(option.model) : nil
            let price = speech ? perMinute.map { "$\(OnboardingModelPick.minutePrice($0)) / min" }
                               : OnboardingModelPick.shortPrice(option.priceLabel)
            return OnboardingModelChoice(id: option.model, price: price, date: option.catalogDate,
                                         outputPerMillion: speech ? nil : OnboardingModelPick.outputPrice(option.priceLabel))
        }
        return all
    }

    /// The model the step's shared row runs on its provider now.
    /// The model checked in "Choose model": none until the person picks one
    /// (the owner: "the checkmark after the choice"); the recommended model
    /// is only tagged until then, and Next keeps it.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    func checkedModel(_ step: OnboardingStep) -> String? {
        pickedModels.contains(step) ? currentModel(step) : nil
    }

    func currentModel(_ step: OnboardingStep) -> String? {
        _ = revision
        let kind: SharedModelKind = step == .speechKey ? .speech : .llm
        let provider = accepted[step]?.route.provider ?? (step == .speechKey ? speechProvider : llmProvider)
        guard let choice = models.sharedRow(kind)?.choice,
              choice.account == APIAndModelsViewModel.builtInAccount(for: provider) else { return nil }
        return choice.model
    }

    /// The pause after a picked model is applied, before the step moves on.
    static let afterModelPick: TimeInterval = 0.78

    /// A model is being applied on this step.
    @Published private(set) var choosingModel: OnboardingStep?

    /// The person picked another model on an accepted key step: it goes
    /// through the shared row like the first pick, then the step moves on.
    /// Key steps where the person picked a model in "Choose model" (the
    /// recommended one included): its button then names that model.
    @Published private(set) var pickedModels: Set<OnboardingStep> = []

    /// "Choose model" opened or closed without a pick: the automatic move
    /// waits while the list is open and goes on from where it was.
    func modelMenu(open: Bool) {
        if open { dwell.latch() } else if dwell.isLatched { dwell.resume() }
    }

    func chooseModel(_ id: String, on step: OnboardingStep) async {
        guard step == .llmKey, choosingModel == nil else { return }
        // Only the accepted provider's list picks: a provider whose key was
        // not checked here never gets the route by a model pick.
        // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
        let shown = step == .speechKey ? speechProvider : llmProvider
        guard let route = accepted[step]?.route, route == .provider(shown), let provider = route.provider else { return }
        if step == self.step, dwell.isCounting || dwell.isLatched { dwell.cancel() }
        // The model already set (the recommended one): picked, nothing to change.
        if currentModel(step) == id {
            pickedModels.insert(step)
            outcomes[step] = .done(id)
            accepted[step]?.text = id
            moveOnAfterPick(step)
            return
        }
        let kind: SharedModelKind = step == .speechKey ? .speech : .llm
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider) else { return }
        let action = begin(kind)
        attempts[step] = route
        choosingModel = step
        defer { if choosingModel == step { choosingModel = nil } }
        if step == .llmKey { llmModel = id }
        let applied = await models.selectShared(model: id, account: account, kind: kind, replaceCustom: false,
                                                stillWanted: { [weak self] in self?.isLatest(action, kind) ?? false })
        guard isLatest(action, kind) else { return }
        notes = models.sharedRow(kind)?.notes ?? []
        revision += 1
        guard applied || models.sharedRow(kind)?.choice?.model == id else {
            outcomes[step] = .failed(notes.first ?? "\(provider.displayName) · \(id) could not be used")
            return
        }
        pickedModels.insert(step)
        outcomes[step] = .done(id)
        accepted[step]?.text = id
        moveOnAfterPick(step)
    }

    private func moveOnAfterPick(_ step: OnboardingStep) {
        guard step == self.step, !dwell.isCounting, !dwell.isLatched else { return }
        let following = nextStep?.shortTitle ?? OnboardingStep.thanks.shortTitle
        dwell.schedule(Self.afterModelPick, next: following) { [weak self] in self?.next() }
    }

    // MARK: - Key steps: the field and your own server

    /// The key in a key step's field changed: an earlier refusal no longer
    /// describes it. An accepted key stays accepted until a new check.
    func keyEdited(on step: OnboardingStep) {
        guard case .failed = latest(step) else { return }
        outcomes[step] = .idle
        keyProblems[step] = nil
    }

    /// Return on a key whose format names no offered provider and no mark
    /// was picked: a format problem, never a guess.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    func rejectUnrecognizedKey(on step: OnboardingStep) {
        // The search step has one provider: a key without its format is a
        // format problem, not "which provider is it".
        let problem: OnboardingKeyProblem = step == .search ? .format : .unrecognized
        keyProblems[step] = problem
        attempts[step] = shownRoute(step)
        outcomes[step] = .failed(problem.message(provider: step == .search ? "Tavily" : ""))
    }

    /// The key steps showing their own-server fields in place of the key
    /// field (the "Self-hosted" mark). The step itself does not change.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    @Published private(set) var serverForms: Set<OnboardingKeyStageKind> = []
    /// The server this onboarding added for a step, reused when the same
    /// address and key are tried again (another model, or after a refusal).
    private var addedServers: [OnboardingKeyStageKind: (address: String, key: String, account: ProviderAccount)] = [:]

    func showsServerForm(_ kind: OnboardingKeyStageKind) -> Bool { serverForms.contains(kind) }

    /// The server added on the other key step, its address and key filled in
    /// so the person names only this step's model.
    func serverPrefill(for kind: OnboardingKeyStageKind) -> OnboardingServerDraft? {
        let other: OnboardingKeyStageKind = kind == .speech ? .languageModel : .speech
        guard kind != .search, let added = addedServers[other] else { return nil }
        return OnboardingServerDraft(address: added.address, key: added.key)
    }

    /// "Self-hosted": the step's key field turns into the server's
    /// fields, in the same window and step, in the app and the preview alike.
    func useOwnServer(_ kind: OnboardingKeyStageKind) {
        guard kind.serverHelp != nil else { return }
        clearFailure(kind.step)
        serverForms.insert(kind)
    }

    /// A provider mark, Escape or Back: the fields turn back into the key field.
    func closeServerForm(_ kind: OnboardingKeyStageKind) {
        clearFailure(kind.step)
        serverForms.remove(kind)
    }

    private func clearFailure(_ step: OnboardingStep) {
        guard case .failed = latest(step) else { return }
        outcomes[step] = .idle
        keyProblems[step] = nil
    }

    /// The server's Return: the server is added the way Settings adds one
    /// (its address answers, the key if any is accepted), its model passes
    /// the same small check, and the shared Speech or LLM row takes it. On
    /// success the step is done and moves on like an accepted key, straight
    /// to the next step.
    func saveServer(_ server: OnboardingServerDraft, on kind: OnboardingKeyStageKind) async {
        let step = kind.step
        attempts[step] = .server
        guard let url = server.url else {
            outcomes[step] = .failed("Enter an address like http://localhost:11434/v1"); return
        }
        let name = server.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { outcomes[step] = .failed("Enter the model's name"); return }
        let shared: SharedModelKind = kind == .speech ? .speech : .llm
        let action = begin(shared)
        keyProblems[step] = nil
        outcomes[step] = .working("Checking \(server.name)…")
        let address = url.absoluteString
        let key = server.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let account: ProviderAccount
        // The same server from either key step is added once.
        if let added = addedServers.values.first(where: { $0.address == address && $0.key == key }) {
            account = added.account
            addedServers[kind] = added
        } else {
            if let problem = await models.addServer(name: server.name, baseURL: address, key: key, proposeModels: false) {
                guard isLatest(action, shared) else { return }
                outcomes[step] = .failed(problem); return
            }
            guard isLatest(action, shared) else { return }
            guard let added = models.lastAddedServer else { outcomes[step] = .failed("Couldn't add the server"); return }
            addedServers[kind] = (address, key, added)
            account = added
        }
        let modelKind: ServerModel.Kind = kind == .speech ? .transcription : .llm
        if !models.serverHasModel(name, kind: modelKind, on: account) {
            let connection: ServerSheetConnection
            switch models.serverSheetConnection(baseURL: address, typedKey: key, account: account) {
            case .success(let made): connection = made
            case .failure(let problem): outcomes[step] = .failed(problem.message); return
            }
            let result = await models.checkServerModel(name, kind: modelKind, on: connection)
            guard isLatest(action, shared) else { return }
            switch result {
            case .passed: break
            case .failed(let text): outcomes[step] = .failed(text); return
            case .unreachable(let text): keyProblems[step] = .unreachable; outcomes[step] = .failed(text); return
            }
            if let problem = models.addServerModel(name, kind: modelKind, checked: true, to: account) {
                outcomes[step] = .failed(problem); return
            }
        }
        let applied = await models.selectShared(model: name, account: account, kind: shared, replaceCustom: false,
                                                stillWanted: { [weak self] in self?.isLatest(action, shared) ?? false })
        guard isLatest(action, shared) else { return }
        notes = models.sharedRow(shared)?.notes ?? []
        guard applied || models.sharedRow(shared)?.choice != nil else {
            outcomes[step] = .failed(notes.first ?? "\(server.name) · \(name) could not be used"); return
        }
        if shared == .llm {
            progress.languageModelSelfHosted = true
        } else {
            progress.speechExpected = true
        }
        pickedModels.remove(step)
        acceptedServerDrafts[kind] = server
        succeed(step, "\(server.name) · \(name)", route: .server)
    }

    /// The model the person picked on the LLM step, or `nil` for the preselected one.
    @Published var llmModel: String?

    func useLLMKey(_ key: String, provider: AIProviderKind) async {
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider) else { return }
        let action = begin(.llm)
        attempts[.llmKey] = .provider(provider)
        outcomes[.llmKey] = .working("Checking the \(provider.displayName) key…")
        let problem = await saveOrCheck(key, account: account)
        guard isLatest(action, .llm) else { return }
        keyProblems[.llmKey] = problem
        if let problem {
            outcomes[.llmKey] = .failed(problem.message(provider: provider.displayName))
            return
        }
        // Saving the key loaded its catalog, so a catalog-only provider has a model now.
        guard let model = llmModel ?? preselectedModel(provider) else {
            outcomes[.llmKey] = .failed("\(provider.displayName) lists no model the Agent can use")
            return
        }
        let applied = await models.selectShared(model: model, account: account, kind: .llm, replaceCustom: false,
                                                stillWanted: { [weak self] in self?.isLatest(action, .llm) ?? false })
        guard isLatest(action, .llm) else { return }
        notes = models.sharedRow(.llm)?.notes ?? []
        guard applied || models.sharedRow(.llm)?.choice != nil else {
            outcomes[.llmKey] = .failed(notes.first ?? "\(provider.displayName) · \(model) could not be used")
            return
        }
        // A provider's key: its own web search, no Tavily step.
        progress.languageModelSelfHosted = false
        // With a choice of models the step waits for a pick or Next, which
        // keeps the recommended model already set.
        // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
        pickedModels.remove(.llmKey)
        succeed(.llmKey, model, holds: modelChoices(.llmKey, provider: provider).count > 1,
                route: .provider(provider))
    }

    /// A new key is checked for its shape here, then goes through Settings'
    /// save (provider check + Keychain); an empty one means "use the key
    /// already saved", checked for free.
    private func saveOrCheck(_ key: String, account: ProviderAccount) async -> OnboardingKeyProblem? {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            guard models.accountIsAvailableForSelection(account) else { return .other("Paste the key first") }
            guard let status = await models.checkSavedKey(account) else {
                return .other("Couldn't read the \(account.kind.displayName) key from the Keychain")
            }
            if case .rejected = status { return OnboardingKeyProblem(status: status) ?? .refused }
            await models.refreshModels()
            return nil
        }
        guard OnboardingKeyProblem.looksLikeAKey(candidate) else { return .format }
        guard let failure = await models.replaceKeyReportingStatus(candidate, for: account) else { return nil }
        return failure.status.flatMap(OnboardingKeyProblem.init(status:)) ?? .other(failure.message)
    }

    func keySaved(_ provider: AIProviderKind) -> Bool {
        guard let account = APIAndModelsViewModel.builtInAccount(for: provider) else { return false }
        return models.accountIsAvailableForSelection(account)
    }

    /// The step's providers whose key is already in the Keychain, in the
    /// order of the step's marks: named under the empty field so a key kept
    /// from an earlier setup is found without guessing its mark.
    // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
    func savedKeyProviders(_ kind: OnboardingKeyStageKind) -> [AIProviderKind] {
        switch kind {
        case .speech: return speechProviders.filter(keySaved)
        case .languageModel: return Self.llmProviders.filter(keySaved)
        case .search: return []
        }
    }

    /// A click on a saved provider's name: its tab opens, and Return then
    /// uses its key (`useSavedKey`).
    func pickSavedKey(_ provider: AIProviderKind, on kind: OnboardingKeyStageKind) {
        switch kind {
        case .speech: speechProvider = provider
        case .languageModel: llmProvider = provider
        case .search: break
        }
    }

    /// Return in an empty key field: checks the key already saved for the
    /// open tab's provider; nothing when it has none.
    func useSavedKey(on kind: OnboardingKeyStageKind) async {
        switch kind {
        case .speech:
            guard keySaved(speechProvider) else { return }
            await useSpeechKey("", provider: speechProvider)
        case .languageModel:
            guard keySaved(llmProvider) else { return }
            await useLLMKey("", provider: llmProvider)
        case .search:
            guard tavily.configured else { return }
            await useSearchKey("")
        }
    }

    // MARK: - 4. Search

    func useSearchKey(_ key: String) async {
        attempts[.search] = .tavily
        outcomes[.search] = .working("Checking the Tavily key…")
        keyProblems[.search] = nil
        tavily.draftKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        await tavily.save()
        if tavily.messageIsError || !tavily.configured {
            let problem = tavily.lastFailure.map(OnboardingKeyProblem.init(tavily:)) ?? .other(tavily.message ?? "Key not accepted")
            keyProblems[.search] = problem
            outcomes[.search] = .failed(problem.message(provider: "Tavily"))
        } else {
            succeed(.search, "Tavily", route: .tavily)
        }
    }

    // MARK: - 5. Language

    /// The languages the speech route set on the speech steps can take:
    /// Deepgram's model lists its own; the other routes take the menu set
    /// (`AppLanguage.all`, the Soniox realtime languages).
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    var speechLanguages: [AppLanguage] {
        _ = revision
        return Self.languages(account: models.sharedRow(.speech)?.choice?.account, model: models.sharedRow(.speech)?.choice?.model)
    }

    static func languages(account: ProviderAccount?, model: String?) -> [AppLanguage] {
        guard account == .deepgram, let model,
              let codes = DeepgramLanguagePolicy.supportedLanguageCodes(for: model) else { return AppLanguage.all }
        return AppLanguage.all.filter { codes.contains($0.code) }
    }

    /// Whether the speech route can find the language by itself (Deepgram
    /// models without "multi" cannot).
    var speechDetectsLanguage: Bool {
        Self.detectsLanguage(account: models.sharedRow(.speech)?.choice?.account, model: models.sharedRow(.speech)?.choice?.model)
    }

    static func detectsLanguage(account: ProviderAccount?, model: String?) -> Bool {
        guard account == .deepgram else { return true }
        return DeepgramLanguagePolicy.automaticLanguageCodes(for: model ?? "") != nil
    }

    /// Why a language is not offered: the route's own list (Soniox, whose
    /// realtime set is Whytap's menu, or a Deepgram model's), otherwise
    /// Whytap's dictation menu, never a guess about another provider.
    var speechLanguageLimit: String {
        let route = models.sharedRow(.speech)?.choice
        switch route?.account {
        case .soniox?: return "isn't available with Soniox"
        case .deepgram? where DeepgramLanguagePolicy.supportedLanguageCodes(for: route?.model ?? "") != nil:
            return "isn't available with Deepgram \(route?.model ?? "")"
        default: return "isn't in Whytap's dictation languages yet"
        }
    }

    /// `variant` ("en-GB") is stored beside the language; providers still
    /// get the language's own code.
    func setLanguage(_ language: AppLanguage?, variant: String? = nil) {
        preferences.selectedLanguage = language
        preferences.selectedLanguageVariant = language == nil ? nil : variant
        self.language = preferences.selectedLanguage
        languageVariant = preferences.selectedLanguageVariant
        let name = OnboardingLanguageVariant.all.first { $0.tag == languageVariant }
            .map { "\(language?.englishName ?? "") (\($0.code))" }
        succeed(.language, name ?? language?.englishName ?? "Detect automatically")
    }

    // MARK: - 6–8. Permissions

    func requestKeyboard() {
        asking(.keyboard)
        if let requests { requests.keyboard() } else { permissions.requestAccessibility() }
    }

    func requestMicrophone() {
        asking(.microphone)
        if let requests { requests.microphone() } else { permissions.requestMicrophone() }
    }

    func requestInputMonitoring() {
        asking(.inputMonitoring)
        if let requests { requests.inputMonitoring() } else { permissions.requestInputMonitoring() }
    }

    /// Allow (or Allow again): the step waits for System Settings.
    private func asking(_ step: OnboardingStep) {
        requested.insert(step)
        if case .failed = latest(step) { outcomes[step] = .idle }
    }

    /// The access step's Allow.
    func requestAccess(_ step: OnboardingStep) {
        switch step {
        case .keyboard: requestKeyboard()
        case .microphone: requestMicrophone()
        case .inputMonitoring: requestInputMonitoring()
        case .screenRecording: requestScreenRecording()
        default: break
        }
    }

    /// Where the access step stands, from the system's own answer: only a
    /// granted check moves it on; nothing here pretends.
    func accessState(_ step: OnboardingStep) -> OnboardingAccessState {
        if accessUnavailable(step), !outcome(step).isDone { return .unavailable }
        switch outcome(step) {
        case .done: return .granted
        case .failed: return .notOn
        default: return requested.contains(step) ? .waiting : .rest
        }
    }

    /// This macOS refused the step's request without a dialog.
    func accessUnavailable(_ step: OnboardingStep) -> Bool {
        switch step {
        case .keyboard: return permissions.keyboardUnavailable
        case .screenRecording: return permissions.screenUnavailable
        default: return false
        }
    }

    /// Drop can't run on this Mac for now: keyboard control was refused.
    var dropUnavailable: Bool { permissions.keyboardUnavailable }

    /// The quiet "Open System Settings" while a step waits.
    func openSystemSettings(for step: OnboardingStep) {
        if let requests { return requests.openSettings(step) }
        switch step {
        case .keyboard: PermissionsHelper.openAccessibilitySettings()
        case .microphone: PermissionsHelper.openMicrophoneSettings()
        case .inputMonitoring: PermissionsHelper.openInputMonitoringSettings()
        case .screenRecording: openScreenRecordingSettings()
        default: break
        }
    }

    /// Coming back from System Settings: check again at once. A waiting step
    /// whose switch is still off says so, calmly, and offers Allow again;
    /// polling still moves it on if the switch turns on later.
    func recheckPermissions() {
        permissions.refresh(restartRecoveryPolling: false)
        guard [.keyboard, .microphone, .inputMonitoring, .screenRecording].contains(step),
              requested.contains(step), !latest(step).isDone, !accessUnavailable(step) else { return }
        // macOS's own microphone dialog is still open: nothing was refused.
        if step == .microphone, permissions.snapshot.microphoneStatus == .notDetermined { return }
        outcomes[step] = .failed("Not on yet")
    }

    /// One request per launch, shared with Shot; afterwards System Settings.
    /// On 27.3 beta the request can be refused without a dialog: the step
    /// then says so and never opens the pane's "+" list.
    // WHY: .project-docs/decisions/2026-11-22-shot-single-permission-prompt.md
    // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
    func requestScreenRecording() {
        asking(.screenRecording)
        // Refused, or the request's answer is still being watched: nothing to open.
        guard !permissions.screenUnavailable, !screenAsking else { return }
        switch screenRecording.requestOnce(afterRequest: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.permissions.checkRefusal(.screen)
                self?.screenAsking = false
            }
        }) {
        case .granted: permissions.refresh(restartRecoveryPolling: false)
        case .requested: screenAsking = true
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
        // A refusal found after a request changes the shown step.
        permissions.refusals.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
    }

    private func permissionsChanged(snapshot: PermissionsHelper.Snapshot, screen: Bool, hotkey: DropHotkeyStatus) {
        let needsInputMonitoring = hotkey == .inputMonitoringRequired
        if needsInputMonitoring, !progress.needsInputMonitoring { progress.needsInputMonitoring = true }
        // Granted, revoked (a switch turned off in System Settings), the step's text.
        let now: [(OnboardingStep, Bool, Bool, String)] = [
            (.keyboard, snapshot.accessibilityGranted, !snapshot.accessibilityGranted, "Keyboard control allowed"),
            (.microphone, snapshot.microphoneGranted, !snapshot.microphoneGranted, "Microphone allowed"),
            (.inputMonitoring, progress.needsInputMonitoring && !needsInputMonitoring && hotkey == .ready,
             needsInputMonitoring, "Keyboard access allowed"),
            (.screenRecording, screen, !screen, "Screen Recording allowed"),
        ]
        for (permission, isGranted, isRevoked, text) in now {
            if isGranted, !granted.contains(permission) {
                granted.insert(permission)
                succeed(permission, text)
            } else if isRevoked, granted.contains(permission) {
                revoked(permission)
            }
        }
    }

    /// A permission turned off after it was granted: the step no longer says
    /// it is allowed (nor moves on), and a fresh grant completes it again.
    // WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
    private func revoked(_ permission: OnboardingStep) {
        granted.remove(permission)
        requested.remove(permission)
        if latest(permission).isDone { outcomes[permission] = .idle }
        accepted[permission] = nil
        if permission == step, dwell.isCounting || dwell.isLatched { dwell.cancel() }
    }

    private func startPolling() {
        stopPolling()
        // A person can spend several minutes in System Settings before confirming.
        // Leaving a permission step or closing the window invalidates this timer.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.pollTimer != nil else { return }
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
        tryCheck?.cancel()
        tryDropSeconds = voice.startedAt.map { max(0.1, Date().timeIntervalSince($0)) }
        succeed(.tryDrop, "That's Drop")
    }

    /// A take on Try Drop that ends with nothing in the field says so calmly:
    /// nothing heard, Drop's own delivery failed, or the text went to another
    /// field. A new take clears it.
    private func observeVoice() {
        voice.$working
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] working in self?.dropWorkingChanged(working) }
            .store(in: &subscriptions)
    }

    private func dropWorkingChanged(_ working: Bool) {
        tryCheck?.cancel()
        guard step == .tryDrop, !latest(.tryDrop).isDone else { return }
        if working {
            if case .failed = latest(.tryDrop) { outcomes[.tryDrop] = .idle }
            return
        }
        let voice = self.voice
        tryCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.tryQuiet * 1_000_000_000))
            guard let self, !Task.isCancelled, self.step == .tryDrop, !voice.working,
                  !self.latest(.tryDrop).isDone else { return }
            if case .failed = self.latest(.tryDrop) { return }
            self.outcomes[.tryDrop] = .failed(voice.failedDelivery ? "Drop couldn’t finish that take — try again."
                                              : voice.inserted ? "The text went to another field — click this one and try again."
                                              : Self.noSpeech)
        }
    }

    static let noSpeech = "No speech heard — try again."

    /// Drop was pressed before its speech was set up (or while the model is
    /// still downloading): said on the try step instead of Settings over it.
    func noteDropSetupFailure(_ feature: AIFeature) {
        if case .downloading = onDevice.status {
            outcomes[.tryDrop] = .failed("The speech model is still downloading — try again in a moment.")
        } else {
            outcomes[.tryDrop] = .failed("\(feature.title) has no speech model yet — set one in Settings.")
        }
    }

    // MARK: - Summary

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

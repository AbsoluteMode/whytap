import Foundation

/// The onboarding's one route change: the speech page's button names Drop,
/// and only Drop's speech rows (Fast and Smart) get the chosen model. Other
/// features stay as they are, and a Drop row that already runs keeps its
/// choice (a key or a sync that arrived during the download wins).
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
struct OnboardingDropSpeech {
    static let features: [AIFeature] = [.dropFast, .dropSmart]
    /// The speech providers offered under "I have an API key".
    static let keyProviders: [AIProviderKind] = [.soniox, .deepgram, .elevenLabs]

    let routing: AIRoutingStore
    let resolver: FeatureRouteResolver
    let mode: @MainActor () -> TranscriptionMode

    init(routing: AIRoutingStore? = nil, keys: ProviderKeyStore = ProviderKeyStore(),
         onDevice: OnDeviceSpeechReadiness = .live,
         mode: @escaping @MainActor () -> TranscriptionMode = { UserPreferencesCache.shared.currentMode }) {
        let routing = routing ?? .shared
        self.routing = routing
        self.resolver = FeatureRouteResolver(routing: routing, keys: keys, onDevice: onDevice)
        self.mode = mode
    }

    /// The speech route of the current Drop mode can run now.
    var isReady: Bool { runs(.drop(mode())) }

    func runs(_ feature: AIFeature) -> Bool { (try? resolver.resolve(feature)) != nil }

    /// Assigns `model` on `account` to the Drop speech rows that cannot run
    /// now. Returns the rows it changed.
    @discardableResult
    func use(_ account: ProviderAccount, model: String) -> [AIFeature] {
        let changed = Self.features.filter { !runs($0) }
        for feature in changed {
            routing.setRoute(FeatureRoute(account: account, model: model), for: feature)
        }
        return changed
    }

    /// On this Mac after its model is in place.
    @discardableResult
    func useOnDevice() -> [AIFeature] {
        use(.thisMac, model: OnDeviceSpeechModel.parakeetTdtV3.rawValue)
    }

    /// The built-in provider's recommended live model, after its key was saved.
    @discardableResult
    func use(provider kind: AIProviderKind) -> [AIFeature] {
        guard let account = Self.account(for: kind),
              let model = ModelRegistry.recommended(for: .dropFast, kind: kind) else { return [] }
        return use(account, model: model)
    }

    /// The person picked this on the speech page and pressed Continue (or
    /// saved its key there): both Drop rows get it. A row already running on
    /// the same account keeps its model.
    @discardableResult
    func choose(_ account: ProviderAccount, model: String) -> [AIFeature] {
        let changed = Self.features.filter { routing.route(for: $0)?.account != account || !runs($0) }
        for feature in changed {
            routing.setRoute(FeatureRoute(account: account, model: model), for: feature)
        }
        return changed
    }

    @discardableResult
    func choose(provider kind: AIProviderKind) -> [AIFeature] {
        guard let account = Self.account(for: kind),
              let model = ModelRegistry.recommended(for: .dropFast, kind: kind) else { return [] }
        return choose(account, model: model)
    }

    @discardableResult
    func chooseOnDevice() -> [AIFeature] {
        choose(.thisMac, model: OnDeviceSpeechModel.parakeetTdtV3.rawValue)
    }

    /// The account the current Drop mode's speech row runs on now.
    var currentAccount: ProviderAccount? {
        let feature = AIFeature.drop(mode())
        return runs(feature) ? routing.route(for: feature)?.account : nil
    }

    nonisolated static func account(for kind: AIProviderKind) -> ProviderAccount? {
        switch kind {
        case .soniox: return .soniox
        case .deepgram: return .deepgram
        case .elevenLabs: return .elevenLabs
        case .onDevice: return .thisMac
        case .openRouter, .openAI, .anthropic, .openAICompatible: return nil
        }
    }
}

/// What a feature row on the last page offers: its switch, or a way to a
/// model when the feature has none that runs.
enum OnboardingFeatureAction: Equatable {
    case toggle
    case addModel(AIFeature)

    /// Meetings needs both its speech and its notes model.
    @MainActor
    static func meetings(_ speech: OnboardingDropSpeech) -> OnboardingFeatureAction {
        for feature in [AIFeature.meetings, .meetingNotes] where !speech.runs(feature) {
            return .addModel(feature)
        }
        return .toggle
    }

    /// The Agent switch connects the native Agent, which needs its model.
    static func agent(selectedModel: String?) -> OnboardingFeatureAction {
        selectedModel == nil ? .addModel(.agent) : .toggle
    }
}

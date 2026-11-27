import Combine
import Foundation

/// One provider account in the API keys row, with its check and server settings.
struct KeyChip: Equatable, Identifiable {
    let account: ProviderAccount
    let title: String
    let statusText: String
    let checkedAt: Date?
    /// A server's added models, in the order added; `nil` for other accounts.
    var serverModels: [ServerModel]? = nil
    /// The last check said the key works: its tile shows the status in green.
    var keyWorks = false
    var id: String { account.storageID }
}

/// One feature's row in the Models block.
struct FeatureRow: Equatable, Identifiable {
    let feature: AIFeature
    /// `"<Provider> · <model>"` (a server shows its own name), or `"Choose a model"`.
    let selectionLabel: String
    let status: ModelRowStatus
    /// A probe of a newly picked model is running.
    let isChecking: Bool
    /// Why the last pick did not stick, or a Deepgram input-language warning.
    let message: String?
    /// The provider choice of an OpenRouter route; `nil` for other accounts.
    var provider: ProviderChoice? = nil
    /// The exact selected model, without transport modes or repeated account names.
    var modelSummary: String = "Choose a model"

    var fieldLabel: String {
        if feature == .subtitlesTranslation { return "LLM" }
        switch feature.mode {
        case .realtime, .recorded: return "Speech"
        case .llm, .llmWithTools: return "Text"
        case .decision: return "Decision"
        }
    }
    var id: AIFeature { feature }
}

/// Subtitles' row: the engine the keys give, preselected. Soniox live
/// translation with the Soniox key, otherwise OpenAI gpt-realtime-translate
/// with the OpenAI key; no engine choice.
// WHY: .project-docs/decisions/2026-11-25-subtitle-soniox-engine.md
// WHY: .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
struct AudioTranslateSlot: Equatable {
    var soniox: SubtitleAudioTranslate.KeyState
    var openAI: SubtitleAudioTranslate.KeyState

    var engine: SubtitleAudioTranslate.Engine? { SubtitleAudioTranslate.engine(soniox: soniox, openAI: openAI) }
    /// Subtitles can run: one of the keys can be read.
    var isActive: Bool { engine != nil }
    /// Without a key, the engine a Soniox key would give.
    var label: String { (engine ?? .soniox).label }
}

/// One line of the Models card: what the user turns on (Drop Smart, Meetings)
/// with every route it runs on, speech first, then its LLM.
struct FeatureGroup: Equatable, Identifiable {
    let title: String
    let rows: [FeatureRow]
    /// Subtitles only.
    var audioTranslate: AudioTranslateSlot? = nil
    var id: String { title }

    /// What the collapsed line names: Subtitles' one model, otherwise every
    /// route's model.
    var summaryParts: [String] {
        if let slot = audioTranslate { return [(slot.engine ?? .soniox).model] }
        return rows.map(\.modelSummary)
    }
    var summary: String { summaryParts.joined(separator: " · ") }
    /// A link or an error naming `feature` opens this card. Subtitles'
    /// retired features lead to the Audio translate slot.
    func covers(_ feature: AIFeature) -> Bool {
        rows.contains { $0.feature == feature }
            || (audioTranslate != nil && [.subtitlesAudio, .subtitlesTranslation].contains(feature))
    }
    /// Subtitles ask for setup without a Soniox or OpenAI key, other groups for an
    /// unset route.
    var needsSetup: Bool {
        if let slot = audioTranslate { return !slot.isActive }
        return rows.contains { $0.status == .notSet }
    }

    /// Every feature exactly once (Costs groups usage by it too). Paired
    /// functions keep their speech route beside the LLM route that processes
    /// its text, speech first: the Agent's card holds its voice model and its
    /// answer model, and there is no separate "Agent voice" card. Subtitles'
    /// features are retired: the card shows the Audio translate slot instead
    /// of rows.
    static let layout: [(title: String, features: [AIFeature])] = [
        ("Drop Fast", [.dropFast]),
        ("Drop Smart", [.dropSmart, .dropSmartCleanup]),
        ("Meetings", [.meetings, .meetingNotes]),
        ("Agent", [.agentVoice, .agent]),
        ("Voice search", [.voiceSearch]),
        ("Translation", [.translation]),
        ("Subtitles", [.subtitlesAudio, .subtitlesTranslation]),
    ]
}

/// Which OpenRouter provider an OpenRouter route runs on.
struct ProviderChoice: Equatable {
    let model: String
    /// The pinned endpoint tag; `nil` is Auto.
    let pinned: String?
    /// `"Auto"`, or the pinned provider's name.
    let label: String
}

/// The providers of one OpenRouter model, as last loaded.
enum ProviderList: Equatable {
    case loading
    case loaded([OpenRouterEndpoint], at: Date)
    case failed
}

/// One feature the "Use <Provider> for" window offers to assign.
struct AssignItem: Equatable, Identifiable {
    let feature: AIFeature
    let account: ProviderAccount
    let model: String
    var id: AIFeature { feature }
}

struct AssignProposal: Equatable {
    let title: String
    let items: [AssignItem]
}

/// State and actions of the Keys & models tab. Routes change only through an
/// explicit pick, a Switch action or the assign window: adding a key proposes,
/// removing one un-sets, and neither moves a feature to another provider.
/// Keys go from the Keychain straight to the checker, catalog and probe; none
/// is kept in published state.
/// Why a key was not saved: the text Settings shows and, when a provider
/// answered, its check result.
struct KeyStoreFailure: Equatable {
    let message: String
    let status: KeyStatus?

    init(_ message: String, status: KeyStatus? = nil) {
        self.message = message
        self.status = status
    }
}

@MainActor
final class APIAndModelsViewModel: ObservableObject {
    @Published private(set) var chips: [KeyChip] = []
    @Published private(set) var rows: [FeatureRow] = []
    @Published private(set) var audioTranslate = AudioTranslateSlot(soniox: .missing, openAI: .missing)

    /// `rows` as the Models card shows them.
    var groups: [FeatureGroup] {
        FeatureGroup.layout.map { entry in
            FeatureGroup(
                title: entry.title,
                rows: entry.features.compactMap { feature in rows.first { $0.feature == feature } },
                audioTranslate: entry.features.contains(.subtitlesAudio) ? audioTranslate : nil
            )
        }
    }
    /// Speech and LLM, read from the per-feature routes.
    // WHY: .project-docs/decisions/2026-11-22-shared-model-rows.md
    @Published private(set) var sharedRows: [SharedModelRow] = []
    /// The Agent's web search, shown under Speech and LLM.
    @Published private(set) var searchRow = AgentSearchRow(options: AgentRunOptions(), tavilyConnected: false)
    @Published private(set) var aliasGroups: [AliasGroupAction] = []
    @Published private(set) var unsetBanner: String?
    @Published var proposal: AssignProposal?
    /// Keyed by OpenRouter model ID.
    @Published private(set) var providerLists: [String: ProviderList] = [:]

    /// Built-in providers in the order the tab lists them and Set up picks them.
    private static let builtInAccounts: [ProviderAccount] = [.soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic, .thisMac]

    private let routing: AIRoutingStore
    private let keys: ProviderKeyStore
    private let agentSettings: AgentSettingsStore

    func makeTavilySettings() -> TavilySettings { TavilySettings(keys: keys) }
    private let catalogs: ModelCatalogStore
    private let checks: ModelCheckStore
    private let keyStatuses: KeyStatusStore
    private let keyChecker: any ProviderKeyChecking
    private let probe: any ModelProbing
    private let serverModelChecker: any ServerModelChecking
    private let endpoints: any OpenRouterEndpointsFetching
    private let now: () -> Date
    private let inputLanguage: @MainActor () -> String?
    private let resolver: ModelStatusResolver
    private let onDevice: OnDeviceSpeechReadiness

    private var checking: Set<AIFeature> = []
    private var messages: [AIFeature: String] = [:]
    private var sharedChecking: Set<SharedModelKind> = []
    private var sharedNotes: [SharedModelKind: [String]] = [:]
    private var observers: Set<AnyCancellable> = []
    /// Whether a window shows this model. Other owners (onboarding, the app
    /// control plugin) keep the default and recompute on every change.
    private var isPresented = true
    /// The debounced recompute after a burst of defaults changes, while shown.
    private var pendingDefaultsRecompute: DispatchWorkItem?
    static let defaultsDebounce: TimeInterval = 0.1

    /// The `.shared` stores and the input language are main-actor state, so
    /// their defaults are applied in the body (Swift 5 evaluates default
    /// arguments outside the actor).
    init(
        routing: AIRoutingStore? = nil,
        keys: ProviderKeyStore = ProviderKeyStore(),
        catalogs: ModelCatalogStore? = nil,
        checks: ModelCheckStore? = nil,
        keyStatuses: KeyStatusStore? = nil,
        keyChecker: any ProviderKeyChecking = ProviderKeyChecker(),
        probe: any ModelProbing = ModelProbe(),
        serverModelChecker: any ServerModelChecking = ServerModelChecker(),
        endpoints: any OpenRouterEndpointsFetching = OpenRouterEndpointsClient(),
        now: @escaping () -> Date = Date.init,
        inputLanguage: (@MainActor () -> String?)? = nil,
        onDevice: OnDeviceSpeechReadiness = .live,
        agentSettings: AgentSettingsStore? = nil
    ) {
        self.onDevice = onDevice
        self.agentSettings = agentSettings ?? .shared
        let routing = routing ?? .shared
        let catalogs = catalogs ?? .shared
        let checks = checks ?? .shared
        let keyStatuses = keyStatuses ?? .shared
        self.routing = routing
        self.keys = keys
        self.catalogs = catalogs
        self.checks = checks
        self.keyStatuses = keyStatuses
        self.keyChecker = keyChecker
        self.probe = probe
        self.serverModelChecker = serverModelChecker
        self.endpoints = endpoints
        self.now = now
        self.inputLanguage = inputLanguage ?? { PrivacyPreferences.shared.selectedLanguage?.code }
        self.resolver = ModelStatusResolver(
            routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses,
            onDevice: onDevice
        )
        recompute()

        // The input language is changed in the island and in meeting settings;
        // the stores write UserDefaults too. Bursts collapse into one pass.
        // Handled synchronously on the main thread (not through a debounced
        // publisher), so opening the window right after a write sees it.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in Self.onMain { self?.defaultsChanged() } }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: .whytapTavilyKeyChanged)
            .sink { [weak self] _ in Self.onMain { self?.tavilyKeyChanged() } }
            .store(in: &observers)
    }

    /// Keys & models → Models → Search: the Agent model's search (`.auto`) or Tavily.
    func selectSearch(_ choice: AgentWebSearchChoice) {
        agentSettings.webSearchChoice = choice
        recompute()
    }

    /// Kinds the Add key menu offers: built-in providers without a key (an
    /// unreadable one already has a chip), and always a server.
    var addableKinds: [AIProviderKind] {
        AIProviderKind.allCases.filter { kind in
            // Not a key: its tile downloads a model instead.
            guard kind != .onDevice else { return false }
            guard let account = Self.builtInAccount(for: kind) else { return true }
            return lookup(account) == .absent
        }
    }

    func account(for kind: AIProviderKind) -> ProviderAccount? { Self.builtInAccount(for: kind) }

    // MARK: - Opening

    /// Refreshes stale catalogs and re-checks keys whose result is a day old,
    /// with free requests only.
    func onAppear() async {
        for account in keyedAccounts() {
            guard let access = access(account) else { continue }
            await catalogs.refreshIfStale(account, apiKey: access.apiKey, server: access.server)
            if keyStatuses.needsCheck(account, now: now()) {
                let status = await keyChecker.check(account, apiKey: access.apiKey, server: access.server, allowPaidProbe: false)
                // The free check cannot see what a dictation or a paid check
                // found (a key without the speech permission answers
                // "limited" here), so it does not clear a refusal on its own.
                // A dictation that works clears it (`forgetDropKeyRefusal`).
                if status == .limited, case .rejected = keyStatuses.record(for: account)?.status { continue }
                keyStatuses.set(status, for: account, at: now())
            }
        }
        // A picker opened during this refresh can share its in-flight request.
        // Publish catalog-only changes even when all saved rows stay equal.
        objectWillChange.send()
        recompute()
    }

    // MARK: - Keys

    /// `nil` when the key was accepted and saved; otherwise what to show.
    /// Never assigns a feature: it opens the "Use <Provider> for" proposal.
    func addKey(_ key: String, kind: AIProviderKind) async -> String? {
        guard let account = Self.builtInAccount(for: kind) else { return "Add a server with its base URL" }
        return await store(key, for: account, proposing: true)?.message
    }

    /// Adds a user's own OpenAI-compatible server. A blank key means the server
    /// runs without one.
    func addServer(name: String, baseURL: String, key: String?, proposeModels: Bool = true) async -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Enter a name" }
        if let error = Self.baseURLError(baseURL) { return error }
        let apiKey = key?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        let server = routing.addServer(name: name, baseURL: baseURL)
        let account = ProviderAccount.server(server.id)
        let status = await keyChecker.check(account, apiKey: apiKey, server: server, allowPaidProbe: true)
        if case .rejected(.invalidKey) = status {
            routing.removeServer(server.id)
            recompute()
            return apiKey == nil ? "This server asks for a key" : "Key not accepted"
        }
        guard status == .valid || status == .limited else {
            routing.removeServer(server.id)
            recompute()
            return Self.statusText(for: status, account: account)
        }
        if let apiKey {
            do {
                try keys.save(apiKey, account: server.keyAccount)
            } catch {
                routing.removeServer(server.id)
                recompute()
                return "Couldn't save the key"
            }
        }
        keyStatuses.set(status, for: account, at: now())
        await catalogs.refresh(account, apiKey: apiKey, server: server)
        if proposeModels { proposeSetup(for: account) }
        lastAddedServer = account
        recompute()
        return nil
    }

    /// Saves an inline-form key without opening a model proposal, including the
    /// first key. A rejected replacement leaves the previous saved key in place.
    func replaceKey(_ key: String, for account: ProviderAccount) async -> String? {
        await store(key, for: account, proposing: false)?.message
    }

    /// `replaceKey` with the check's answer kept, so the onboarding can say
    /// which refusal it was (`nil` status: not a provider's answer).
    func replaceKeyReportingStatus(_ key: String, for account: ProviderAccount) async -> KeyStoreFailure? {
        await store(key, for: account, proposing: false)
    }

    // MARK: - Server models

    /// The server the last successful `addServer` created, so the server
    /// window can store its models right after.
    private(set) var lastAddedServer: ProviderAccount?

    private func serverModels(of account: ProviderAccount) -> [ServerModel]? {
        guard case .server(let id) = account else { return nil }
        return routing.server(id)?.models ?? []
    }

    /// Names from the server's `/v1/models`, for the Model field: only
    /// suggestions, the user can type any name. Names already added for both
    /// kinds are left out.
    func modelSuggestions(for account: ProviderAccount) -> [String] {
        guard case .server(let id) = account, let server = routing.server(id) else { return [] }
        let ids = (catalogs.snapshot(for: account, server: server)?.models ?? []).map(\.id)
        return Array(Set(ids)).filter { name in
            !ServerModel.Kind.allCases.allSatisfy { server.hasModel(name, kind: $0) }
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Whether the server already has `name` as `kind` (the onboarding's
    /// server step tried again after the model was added).
    func serverHasModel(_ name: String, kind: ServerModel.Kind, on account: ProviderAccount) -> Bool {
        guard case .server(let id) = account else { return false }
        return routing.server(id)?.hasModel(name, kind: kind) ?? false
    }

    /// Why `name` cannot be added as `kind`, before any request; `nil` when it can.
    func serverModelProblem(_ name: String, kind: ServerModel.Kind, on account: ProviderAccount) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .server(let id) = account, let server = routing.server(id) else { return "This server was removed" }
        if name.isEmpty { return "Enter the model's name" }
        if server.hasModel(name, kind: kind) { return "\(name) is already added as \(kind.label)" }
        return nil
    }

    // MARK: - Server sheet

    /// The server window's starting state: an empty server with one model row,
    /// or the saved server with its models (checked ones as Works).
    func serverSheetDraft(for account: ProviderAccount?) -> ServerSheetDraft {
        guard case .server(let id)? = account, let server = routing.server(id) else {
            return ServerSheetDraft(isNew: true, baseURL: "", apiKey: "", hasStoredKey: false, rows: [.init()])
        }
        var storedKey = false
        if case .key = keys.lookup(account: server.keyAccount) { storedKey = true }
        let rows = (server.models ?? []).map {
            ServerSheetDraft.Row(name: $0.name, kind: $0.kind, status: $0.checked ? .works : .notChecked)
        }
        return ServerSheetDraft(isNew: false, baseURL: server.baseURL, apiKey: "", hasStoredKey: storedKey,
                                rows: rows.isEmpty ? [.init()] : rows)
    }

    /// What the window's model checks run against: the typed address and the
    /// typed key, or the saved key when none is typed and the address is still
    /// the saved server's origin (scheme, host and port). A saved key is never
    /// sent to another origin: the user types it again for the new address.
    // WHY: .project-docs/decisions/2026-11-22-server-window.md
    func serverSheetConnection(baseURL: String, typedKey: String, account: ProviderAccount) -> Result<ServerSheetConnection, ServerSheetProblem> {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return .failure(.init(message: "Enter the server's base URL")) }
        if let error = Self.baseURLError(url) { return .failure(.init(message: error)) }
        var apiKey = typedKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard case .server(let id) = account else { return .failure(.init(message: "This server was removed")) }
        var endpoint = ServerEndpoint(id: id, name: ServerEndpoint.displayName(for: url) ?? url, baseURL: url,
                                      keyAccount: AIRoutingStore.serverKeyAccount(for: id))
        if let saved = routing.server(id) {
            endpoint = saved
            endpoint.baseURL = url
            if apiKey == nil, Self.origin(url) == Self.origin(saved.baseURL) {
                switch keys.lookup(account: saved.keyAccount) {
                case .key(let key): apiKey = key
                case .absent: break
                case .unreadable: return .failure(.init(message: "Couldn't read this server's key from the Keychain"))
                }
            }
        }
        return .success(ServerSheetConnection(
            server: endpoint, apiKey: apiKey,
            target: ServerModelTarget(account: account, baseURL: url, apiKey: apiKey)
        ))
    }

    /// The saved server has a key that the window will not send, because the
    /// address now points to another origin and no key is typed.
    func serverSheetWithholdsKey(baseURL: String, typedKey: String, account: ProviderAccount) -> Bool {
        guard case .server(let id) = account, let saved = routing.server(id),
              typedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Self.origin(baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) != Self.origin(saved.baseURL)
        else { return false }
        if case .absent = keys.lookup(account: saved.keyAccount) { return false }
        return true
    }

    /// `/v1/models` names for the window: only while it points at the saved
    /// server's own address, whose list they are.
    func serverSheetSuggestions(baseURL: String, account: ProviderAccount) -> [String] {
        guard case .server(let id) = account, let saved = routing.server(id),
              baseURL.trimmingCharacters(in: .whitespacesAndNewlines) == saved.baseURL else { return [] }
        return modelSuggestions(for: account)
    }

    /// `scheme://host:port`, lower case, with the scheme's default port.
    static func origin(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let port = components.port ?? (scheme == "https" || scheme == "wss" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// One small request to the server: a one-word chat for an LLM, half a
    /// second of silence for a transcription model.
    // WHY: .project-docs/decisions/2026-11-22-server-explicit-models.md
    func checkServerModel(_ name: String, kind: ServerModel.Kind, on connection: ServerSheetConnection) async -> ServerModelCheckResult {
        await serverModelChecker.check(name, kind: kind, on: connection.server, apiKey: connection.apiKey)
    }

    /// Saves the whole window at once: the address (and the name older builds
    /// show, which is the address), a typed key and the model list. A new
    /// server, a changed address or a typed key goes through the ordinary key
    /// check first, with the same key the rows were checked with; nothing is
    /// stored before it passes. `expected` is what the rows were checked
    /// against: if the address or key changed meanwhile (a synced key, say),
    /// nothing is stored. The address, name and models are written together;
    /// models taken off the list un-set the features of that kind that ran on
    /// them. A saved key that would go to another origin is removed unless a
    /// key is typed. `nil` on success.
    // WHY: .project-docs/decisions/2026-11-22-server-window.md
    func saveServer(_ draft: ServerSheetDraft, models: [ServerModel], account: ProviderAccount,
                    expected: ServerModelTarget) async -> String? {
        guard case .server(let id) = account else { return "This server was removed" }
        let connection: ServerSheetConnection
        switch serverSheetConnection(baseURL: draft.baseURL, typedKey: draft.apiKey, account: account) {
        case .success(let value): connection = value
        case .failure(let problem): return problem.message
        }
        guard connection.target == expected else { return Self.serverChangedDuringCheck }
        let url = connection.server.baseURL
        let name = ServerEndpoint.displayName(for: url) ?? url
        let typed = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let saved = routing.server(id)
        if !draft.isNew, saved == nil { return "This server was removed" }

        var status: KeyStatus?
        if saved == nil || url != saved?.baseURL || typed != nil {
            let checked = await keyChecker.check(account, apiKey: connection.apiKey, server: connection.server,
                                                 allowPaidProbe: true)
            if case .rejected(.invalidKey) = checked {
                return connection.apiKey == nil ? "This server asks for a key" : "Key not accepted"
            }
            guard checked == .valid || checked == .limited else { return Self.statusText(for: checked, account: account) }
            status = checked
            // The check awaited: the window's state must still be the one checked.
            guard case .success(let after) = serverSheetConnection(baseURL: draft.baseURL, typedKey: draft.apiKey, account: account),
                  after.target == expected else { return Self.serverChangedDuringCheck }
            if !draft.isNew, routing.server(id) == nil { return "This server was removed" }
        }

        // From here nothing awaits until everything is written, and Save
        // ends here: what it reports is what is stored.
        let current = routing.server(id)
        if saved != nil, current == nil { return "This server was removed" }
        let keyAccount = current?.keyAccount ?? AIRoutingStore.serverKeyAccount(for: id)
        let movesOrigin = current.map { Self.origin(url) != Self.origin($0.baseURL) } ?? false
        do {
            if let typed {
                try keys.save(typed, account: keyAccount)
            } else if movesOrigin, keys.lookup(account: keyAccount) != .absent {
                // Read now, not when Save began: a key synced for the old
                // address meanwhile does not go with the new one either.
                try keys.delete(account: keyAccount)
            }
        } catch {
            return "Couldn't save the key"
        }
        let before = Dictionary(uniqueKeysWithValues: AIFeature.activeCases.compactMap { feature in
            routing.route(for: feature).flatMap { $0.account == account ? (feature, $0.model) : nil }
        })
        if current == nil {
            routing.insertServer(ServerEndpoint(id: id, name: name, baseURL: url, keyAccount: keyAccount, models: models))
            lastAddedServer = account
        } else {
            if url != current?.baseURL { catalogs.forget(account) }
            for feature in routing.updateServer(id, name: name, baseURL: url, models: models) {
                messages[feature] = "\(before[feature] ?? "Its model") was removed from \(name)"
            }
        }
        if let status { keyStatuses.set(status, for: account, at: now()) }
        recompute()
        // The list only suggests names: it is loaded after Save, which does
        // not wait for it, and a server removed meanwhile just has no list.
        let apiKey = connection.apiKey
        Task { [weak self] in
            guard let self, let server = self.routing.server(id), server.baseURL == url else { return }
            await self.catalogs.refresh(account, apiKey: apiKey, server: server)
            self.recompute()
        }
        return nil
    }

    static let serverChangedDuringCheck = "The server's address or key changed during the check. Save again."


    /// Adds the model to the server; `checked` is false when the user saved it
    /// without a passing check. `nil` on success, otherwise what to show.
    @discardableResult
    func addServerModel(_ name: String, kind: ServerModel.Kind, checked: Bool, to account: ProviderAccount) -> String? {
        if let problem = serverModelProblem(name, kind: kind, on: account) { return problem }
        guard case .server(let id) = account else { return "This server was removed" }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        routing.addModel(ServerModel(name: name, kind: kind, checked: checked), toServer: id)
        recompute()
        return nil
    }

    func featuresUsing(_ account: ProviderAccount) -> [AIFeature] {
        AIFeature.activeCases.filter { routing.route(for: $0)?.account == account }
    }

    /// Deletes the key (and a server's entry) and un-sets the features that ran
    /// on it. Nothing is moved to another provider (Review Focus 3).
    func remove(_ account: ProviderAccount) {
        if let keychainAccount = account.keychainAccount(in: routing) {
            try? keys.delete(account: keychainAccount)
        }
        switch account {
        case .server(let id): routing.removeServer(id)
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic, .thisMac: routing.clearRoutes(using: account)
        }
        catalogs.forget(account)
        keyStatuses.forget(account)
        if proposal?.items.contains(where: { $0.account == account }) == true { proposal = nil }
        recompute()
    }

    /// Check now in a chip's popover; may spend a paid probe.
    func checkKey(_ account: ProviderAccount) async {
        guard let access = access(account) else { return }
        let status = await keyChecker.check(account, apiKey: access.apiKey, server: access.server, allowPaidProbe: true)
        keyStatuses.set(status, for: account, at: now())
        recompute()
    }

    /// The free check Settings runs on opening, now, for a saved key about to
    /// be used (the onboarding's Continue). `nil` without a readable key. A
    /// free "limited" does not clear a recorded refusal, as on opening.
    func checkSavedKey(_ account: ProviderAccount) async -> KeyStatus? {
        // An answer counts only for the key it was about: a key replaced in
        // Settings while the request ran is checked again, never marked with
        // the old key's result.
        // WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
        for _ in 0..<3 {
            guard let checked = access(account) else { return nil }
            let status = await keyChecker.check(account, apiKey: checked.apiKey, server: checked.server, allowPaidProbe: false)
            guard let current = access(account) else { return nil }
            guard current.apiKey == checked.apiKey else { continue }
            if status == .limited, case .rejected(let reason) = keyStatuses.record(for: account)?.status {
                return .rejected(reason)
            }
            keyStatuses.set(status, for: account, at: now())
            recompute()
            return status
        }
        return nil
    }

    /// Why a saved key was refused, in the API keys tile's words; `nil` when
    /// it was not.
    func keyRefusal(_ account: ProviderAccount) -> String? {
        guard let status = keyStatuses.record(for: account)?.status, case .rejected = status else { return nil }
        return Self.statusText(for: status, account: account)
    }

    // MARK: - On this Mac

    /// The model was downloaded or removed. A fresh download offers it for
    /// every feature that has no model yet; removing it un-sets the features
    /// that ran on it, and nothing moves to a provider.
    func onDeviceModelChanged() {
        if onDevice.isReady() {
            keyStatuses.set(.valid, for: .thisMac, at: now())
            // A download can finish while another provider's offer is open;
            // that offer is the user's current question and is left alone.
            if proposal == nil { proposeSetup(for: .thisMac) }
        } else {
            remove(.thisMac)
        }
        objectWillChange.send()
        recompute()
    }

    /// A feature's screen chose the model on this Mac for `feature`: assigned
    /// as the Assign window's Use does, without a probe and without offering
    /// it for other features. Nothing changes when the model is not on this
    /// Mac or the feature cannot run on it.
    // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
    @discardableResult
    func useOnDeviceModel(for feature: AIFeature) -> Bool {
        guard feature.isActive, onDevice.isReady(),
              let model = ModelRegistry.recommended(for: feature, kind: .onDevice) else { return false }
        keyStatuses.set(.valid, for: .thisMac, at: now())
        routing.setRoute(FeatureRoute(account: .thisMac, model: model), for: feature)
        checks.clearRefusal(feature: feature, model: model)
        messages[feature] = nil
        objectWillChange.send()
        recompute()
        return true
    }

    /// The on-device download a feature's screen started has finished: the
    /// model is used only if the feature's route is still the one it was
    /// when the download began. A model chosen meanwhile is kept.
    // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
    @discardableResult
    func useOnDeviceModel(for feature: AIFeature, ifRouteIs startedFrom: FeatureRoute?) -> Bool {
        guard routing.route(for: feature) == startedFrom else { return false }
        return useOnDeviceModel(for: feature)
    }

    // MARK: - Models

    func sections(for feature: AIFeature) -> [PickerSection] {
        resolver.sections(for: feature)
    }

    func missingProviderHint(for feature: AIFeature) -> String? {
        resolver.missingProviderHint(for: feature)
    }

    /// Local preflight for application-control requests; never exposes the key.
    func accountIsAvailableForSelection(_ account: ProviderAccount) -> Bool {
        access(account) != nil
    }

    /// Whether the account has a saved key, without reading the secret or
    /// allowing a Keychain prompt: for naming saved keys before a choice.
    func hasSavedKey(_ account: ProviderAccount) -> Bool {
        if account == .thisMac { return onDevice.isReady() }
        guard let keychainAccount = account.keychainAccount(in: routing) else { return false }
        return keys.hasKey(account: keychainAccount)
    }

    /// A verified model is assigned at once; a new one only after its probe
    /// passes. Otherwise the previous route stays and the row says why. A model
    /// whose earlier probe failed is probed again: picking it is the user
    /// asking to check it again, so a stored failure never bans it for good.
    @discardableResult
    func select(model: String, account: ProviderAccount, for feature: AIFeature) async -> Bool {
        guard feature.isActive else { return false }
        guard !checking.contains(feature) else { return false }
        // Re-picking the current model keeps its provider; a new model starts on Auto.
        let current = routing.route(for: feature)
        let route = FeatureRoute(
            account: account, model: model,
            provider: current?.account == account && current?.model == model ? current?.provider : nil
        )
        let failedBefore = resolver.hasStoredProbeFailure(model: model, account: account, for: feature)
        switch resolver.verdict(model: model, account: account, for: feature, ignoringStoredFailure: true) {
        case .verified where !failedBefore:
            guard !Task.isCancelled else { return false }
            assign(route, to: [feature])
            return true
        case .notSupported(let reason):
            messages[feature] = reason
            recompute()
            return false
        case .verified, .new:
            guard await probePassed(route, for: [feature]), !Task.isCancelled,
                  routing.route(for: feature) == current else { return false }
            assign(route, to: [feature])
            return true
        }
    }

    // MARK: - Shared Speech / LLM

    /// The route a feature runs on now (onboarding reads it to leave a
    /// newer choice alone).
    func currentRoute(for feature: AIFeature) -> FeatureRoute? { routing.route(for: feature) }

    func sharedRow(_ kind: SharedModelKind) -> SharedModelRow? {
        sharedRows.first { $0.kind == kind }
    }

    func sharedSections(_ kind: SharedModelKind) -> [PickerSection] {
        resolver.sections(for: kind.pickerFeature)
    }

    /// Puts one model on every feature of `kind` it can serve: the same model,
    /// or for Meetings the provider's recorded counterpart. Features set to
    /// their own model (custom) keep it unless `replaceCustom`. A feature the
    /// model cannot serve keeps its route, and the row says which. Every
    /// distinct model and use that is not verified yet is checked once; a
    /// passed tool-use check also covers plain text on the same model. Nothing
    /// changes for a model whose check fails.
    // WHY: .project-docs/decisions/2026-11-22-shared-model-rows.md
    /// `stillWanted` is asked once the checks are done, right before any
    /// route changes: a caller whose person moved on (onboarding's Skip)
    /// answers false and nothing is assigned.
    @discardableResult
    func selectShared(model: String, account: ProviderAccount, kind: SharedModelKind, replaceCustom: Bool,
                      stillWanted: @MainActor () -> Bool = { true }) async -> Bool {
        guard !sharedChecking.contains(kind) else { return false }
        let planner = makePlanner()
        let before = planner.row(kind: kind, title: title(of:))
        let choice = FeatureRoute(account: account, model: model)
        let custom = Set(before.custom)
        var notes: [String] = []
        var targets: [(feature: AIFeature, route: FeatureRoute, current: FeatureRoute?)] = []
        let plan = planner.plan(choice, kind: kind)
        for item in plan {
            let current = routing.route(for: item.feature)
            guard let planned = item.route else {
                let kept = current.map { " · kept \($0.model)" } ?? ""
                notes.append("\(item.feature.title): \(item.skipReason ?? "not available")\(kept)")
                continue
            }
            if custom.contains(item.feature), !replaceCustom { continue }
            if current?.account == planned.account, current?.model == planned.model { continue }
            targets.append((item.feature, planned, current))
        }

        // One check per distinct model and use that is not verified yet.
        struct Check { let route: FeatureRoute; let use: ModelUse; var features: [AIFeature] }
        var pending: [Check] = []
        for target in targets {
            guard let use = target.feature.modelUse(on: target.route.account.kind) else { continue }
            let failedBefore = resolver.hasStoredProbeFailure(model: target.route.model, account: target.route.account, for: target.feature)
            let verdict = resolver.verdict(model: target.route.model, account: target.route.account,
                                           for: target.feature, ignoringStoredFailure: true)
            if case .verified = verdict, !failedBefore { continue }
            if let index = pending.firstIndex(where: { $0.route == target.route && $0.use == use }) {
                pending[index].features.append(target.feature)
            } else {
                pending.append(Check(route: target.route, use: use, features: [target.feature]))
            }
        }
        // Tool use first: when it passes, plain text on that model needs no request.
        pending.sort { ($0.use == .chatWithTools ? 0 : 1) < ($1.use == .chatWithTools ? 0 : 1) }
        var passedTools: Set<String> = []
        var refused: Set<AIFeature> = []
        if !pending.isEmpty {
            sharedChecking.insert(kind)
            sharedNotes[kind] = nil
            recompute()
        }
        for check in pending {
            if check.use == .chat, passedTools.contains("\(check.route.account.storageID)|\(check.route.model)") {
                checks.store(.passed, for: ModelCheckKey(account: check.route.account.storageID, model: check.route.model, use: .chat),
                             adapterVersion: ModelRegistry.adapterVersion(check.route.account.kind, .chat), at: now())
                continue
            }
            if await probePassed(check.route, for: check.features) {
                if check.use == .chatWithTools { passedTools.insert("\(check.route.account.storageID)|\(check.route.model)") }
            } else {
                refused.formUnion(check.features)
                let reason = check.features.first.flatMap { messages[$0] } ?? "the check failed"
                notes.append("\(check.features.map(\.title).joined(separator: ", ")): \(reason)")
            }
        }
        sharedChecking.remove(kind)
        guard !Task.isCancelled, stillWanted() else { recompute(); return false }

        var assigned = 0
        for target in targets where !refused.contains(target.feature) {
            // A route changed meanwhile (Advanced, another window) is the user's newer choice.
            guard routing.route(for: target.feature) == target.current else { continue }
            assign(target.route, to: [target.feature])
            assigned += 1
        }
        sharedNotes[kind] = notes.isEmpty ? nil : notes
        recompute()
        // A model no feature of the kind can take (an LLM typed into Speech)
        // changed nothing: not a success, the notes say why.
        guard plan.contains(where: { $0.route != nil }) else { return false }
        return refused.isEmpty && (assigned > 0 || targets.isEmpty)
    }

    /// Answers are memoized for one planner (one recompute or one pick); the
    /// accounts with a section are read once, not per question.
    private func makePlanner() -> SharedModelPlanner {
        var cache: [String: PickerReach] = [:]
        var accounts: [ProviderAccount]?
        let resolver = self.resolver
        let routing = self.routing
        return SharedModelPlanner(
            reach: { model, account, feature in
                let key = "\(feature.rawValue)|\(account.storageID)|\(model)"
                if let hit = cache[key] { return hit }
                if accounts == nil { accounts = resolver.pickerAccounts() }
                let found = resolver.pickerReach(model: model, account: account, for: feature, accountsWithSection: accounts)
                cache[key] = found
                return found
            },
            route: { routing.route(for: $0) }
        )
    }

    // MARK: - OpenRouter provider

    /// How long a loaded provider list (with its speed figures) is reused.
    static let providerListLifetime: TimeInterval = 5 * 60

    /// Loads the providers of the feature's OpenRouter model with their speed,
    /// using the OpenRouter key. A free metadata request.
    func loadProviders(for feature: AIFeature, force: Bool = false) async {
        guard let route = routing.route(for: feature), route.account == .openRouter,
              let access = access(.openRouter), let key = access.apiKey
        else { return }
        let model = route.model
        switch providerLists[model] {
        case .loading: return
        case .loaded(_, let at) where !force && now().timeIntervalSince(at) < Self.providerListLifetime: return
        default: break
        }
        providerLists[model] = .loading
        do {
            let list = try await endpoints.endpoints(model: model, apiKey: key)
            providerLists[model] = .loaded(OpenRouterEndpointsClient.sorted(list), at: now())
        } catch {
            providerLists[model] = .failed
        }
        recompute()
    }

    /// Pins the feature's OpenRouter model to one provider, or back to Auto.
    func selectProvider(_ tag: String?, for feature: AIFeature) {
        routing.setProvider(tag, for: feature)
        recompute()
    }

    /// Probes the feature's current model again. The route does not change.
    func checkNow(_ feature: AIFeature) async {
        guard !checking.contains(feature), let route = routing.route(for: feature) else { return }
        _ = await probePassed(route, for: [feature])
    }

    /// Opening a model picker refreshes stale or failed catalogs automatically.
    /// Fresh successful catalogs keep their daily cache and never run a probe.
    func refreshModels() async {
        for account in keyedAccounts() {
            guard let access = access(account) else { continue }
            await catalogs.refreshIfStale(account, apiKey: access.apiKey, server: access.server)
        }
        // Catalog contents can change without changing any selected row/chip.
        // Refresh the open searchable picker in that case as well.
        objectWillChange.send()
        recompute()
    }

    /// Switch: moves every feature of the group to the alias's target, after a
    /// probe unless the target is already verified for all of them.
    func apply(_ group: AliasGroupAction) async {
        guard !group.features.isEmpty else { return }
        let target = FeatureRoute(account: group.account, model: group.to)
        let unverified = group.features.filter {
            resolver.verdict(model: group.to, account: group.account, for: $0) != .verified
        }
        if let probed = unverified.first {
            guard await probePassed(target, for: [probed], messageTo: group.features) else { return }
        }
        assign(target, to: group.features)
    }

    // MARK: - Assign window

    /// `account` — after its key was added: its recommended model for every
    /// Not set feature it serves. `nil` — Set up: for every Not set feature, the
    /// first keyed built-in provider with a recommended model. An empty
    /// proposal is not shown.
    func proposeSetup(for account: ProviderAccount) {
        let unset = AIFeature.activeCases.filter { resolver.status(for: $0) == .notSet }
        let items = unset.compactMap { feature in
            ModelRegistry.recommended(for: feature, kind: account.kind)
                .map { AssignItem(feature: feature, account: account, model: $0) }
        }
        proposal = items.isEmpty ? nil : AssignProposal(title: "Use \(title(of: account)) for", items: items)
    }

    /// Use: assigns the checked registry models as they are, without a probe.
    func applyProposal(selected: Set<AIFeature>) {
        for item in proposal?.items ?? [] where selected.contains(item.feature) {
            routing.setRoute(FeatureRoute(account: item.account, model: item.model), for: item.feature)
            checks.clearRefusal(feature: item.feature, model: item.model)
            messages[item.feature] = nil
        }
        proposal = nil
        recompute()
    }

    // MARK: - Key flow

    private func store(_ rawKey: String, for account: ProviderAccount, proposing: Bool) async -> KeyStoreFailure? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let server: ServerEndpoint?
        switch account {
        case .server(let id):
            guard let endpoint = routing.server(id) else { return KeyStoreFailure("This server was removed") }
            server = endpoint
        case .thisMac:
            return KeyStoreFailure("On this Mac needs no key")
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic:
            guard !key.isEmpty else { return KeyStoreFailure("Enter a key") }
            server = nil
        }
        guard let keychainAccount = account.keychainAccount(in: routing) else { return KeyStoreFailure("This server was removed") }
        let apiKey = key.nilIfEmpty

        // Checked before it is stored, so a key the provider turns down never
        // replaces anything.
        let status = await keyChecker.check(account, apiKey: apiKey, server: server, allowPaidProbe: true)
        if account == .openAI, status == .limited {
            return KeyStoreFailure("Allow model-list access for this OpenAI key, then try again.", status: status)
        }
        guard status == .valid || status == .limited else {
            return KeyStoreFailure(Self.statusText(for: status, account: account), status: status)
        }
        do {
            if let apiKey {
                try keys.save(apiKey, account: keychainAccount)
            } else {
                try keys.delete(account: keychainAccount)
            }
        } catch {
            return KeyStoreFailure("Couldn't save the key")
        }
        keyStatuses.set(status, for: account, at: now())
        await catalogs.refresh(account, apiKey: apiKey, server: server)
        if proposing { proposeSetup(for: account) }
        recompute()
        return nil
    }

    // MARK: - Probe flow

    /// Probes `route` for the first of `features`, keeps a conclusive outcome
    /// in `ModelCheckStore`, and puts the reason of a non-pass on the rows of
    /// `messageTo`.
    private func probePassed(_ route: FeatureRoute, for features: [AIFeature], messageTo: [AIFeature]? = nil) async -> Bool {
        guard let feature = features.first else { return false }
        let shown = messageTo ?? features
        guard let use = feature.modelUse(on: route.account.kind) else {
            setMessage("\(route.account.kind.displayName) can't serve \(feature.title)", on: shown)
            return false
        }
        let resolved: ResolvedRoute
        do {
            resolved = try FeatureRouteResolver(routing: routing, keys: keys, onDevice: onDevice).resolve(route, for: feature)
        } catch {
            setMessage("Couldn't check: \(Self.reason(for: error))", on: shown)
            return false
        }

        checking.formUnion(shown)
        recompute()
        let catalog = catalogs.snapshot(for: route.account)?.models.first { $0.id == route.model }
        let outcome = await probe.probe(resolved, use: use, catalog: catalog)
        checking.subtract(shown)

        checks.store(
            outcome,
            for: ModelCheckKey(account: route.account.storageID, model: route.model, use: use),
            adapterVersion: ModelRegistry.adapterVersion(route.account.kind, use),
            at: now()
        )
        switch outcome {
        case .passed:
            for feature in shown {
                messages[feature] = nil
                checks.clearRefusal(feature: feature, model: route.model)
            }
            recompute()
            return true
        case .failed(let reason):
            setMessage(reason, on: shown)
        case .inconclusive(let reason):
            setMessage("Couldn't check: \(reason)", on: shown)
        }
        return false
    }

    private func assign(_ route: FeatureRoute, to features: [AIFeature]) {
        for feature in features {
            routing.setRoute(route, for: feature)
            // Picking a model again is the user's call to try it again.
            checks.clearRefusal(feature: feature, model: route.model)
            messages[feature] = nil
        }
        recompute()
    }

    private func setMessage(_ message: String, on features: [AIFeature]) {
        for feature in features { messages[feature] = message }
        recompute()
    }

    private static func reason(for error: Error) -> String {
        guard let error = error as? FeatureRouteError else { return "this route can't run" }
        switch error {
        case .notSet: return "no model"
        case .missingKey: return "the key can't be read"
        case .missingBaseURL: return "the server has no base URL"
        case .invalidBaseURL: return "the server's base URL is invalid"
        case .invalidLanguageConfiguration(_, let language): return language.localizedDescription
        }
    }

    // MARK: - Derived state

    /// The Settings window shows (`true`) or no longer shows (`false`) this
    /// model. While hidden, change notifications do nothing: the recompute
    /// reads every provider key from the Keychain on the main thread (about
    /// 40 ms with a full set of keys), and the island writes defaults from its
    /// own controls (Drop Mode, languages) while their animations run.
    /// Becoming shown always recomputes once, synchronously, before the window
    /// draws: keys can change without any notification (a Settings Sync round
    /// with only credentials, the app control plugin), so a "stale" flag
    /// could not be trusted. It also takes over a pending debounced pass.
    // WHY: .project-docs/decisions/2026-11-27-settings-models-recompute-while-hidden.md
    func setPresented(_ presented: Bool) {
        guard presented != isPresented else { return }
        isPresented = presented
        cancelPendingDefaultsRecompute()
        if presented { recompute() }
    }

    private func defaultsChanged() {
        guard isPresented else { return }
        cancelPendingDefaultsRecompute()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingDefaultsRecompute = nil
                guard self.isPresented else { return }
                self.recompute()
            }
        }
        pendingDefaultsRecompute = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.defaultsDebounce, execute: work)
    }

    /// Saved or removed locally or by Settings Sync: immediate while shown.
    private func tavilyKeyChanged() {
        guard isPresented else { return }
        recompute()
    }

    private func cancelPendingDefaultsRecompute() {
        pendingDefaultsRecompute?.cancel()
        pendingDefaultsRecompute = nil
    }

    /// Notifications can be posted off the main thread (defaults written by
    /// another thread); the model is main-actor state.
    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    private func recompute() {
        let chips = keyedAccounts().map(chip(for:))
        let slot = AudioTranslateSlot(soniox: .init(lookup(.soniox)), openAI: .init(lookup(SubtitleAudioTranslate.account)))
        if audioTranslate != slot { audioTranslate = slot }
        let rows = AIFeature.activeCases.map(row(for:))
        let groups = resolver.aliasGroups()
        // Subtitles without a Soniox or OpenAI key count as a feature without a model.
        let unset = rows.filter { $0.status == .notSet }.count + (slot.isActive ? 0 : 1)
        let banner: String?
        if chips.isEmpty || unset == 0 {
            banner = nil
        } else {
            banner = unset == 1 ? "1 feature has no model" : "\(unset) features have no model"
        }
        if self.chips != chips { self.chips = chips }
        if self.rows != rows { self.rows = rows }
        if self.aliasGroups != groups { self.aliasGroups = groups }
        let planner = makePlanner()
        let shared = SharedModelKind.allCases.map { kind in
            var row = planner.row(kind: kind, title: title(of:))
            row.isChecking = sharedChecking.contains(kind)
            row.notes = sharedNotes[kind] ?? []
            return row
        }
        if self.sharedRows != shared { self.sharedRows = shared }
        let search = makeSearchRow()
        if self.searchRow != search { self.searchRow = search }
        if self.unsetBanner != banner { self.unsetBanner = banner }
    }

    private func makeSearchRow() -> AgentSearchRow {
        AgentSearchRow(options: agentSettings.options(for: .native),
                       tavilyConnected: keys.read(account: TavilySearch.keychainAccount) != nil)
    }

    private func row(for feature: AIFeature) -> FeatureRow {
        let route = routing.route(for: feature)
        let label = route.map { "\(title(of: $0.account)) · \($0.model)" } ?? "Choose a model"
        return FeatureRow(
            feature: feature,
            selectionLabel: label,
            status: resolver.status(for: feature),
            isChecking: checking.contains(feature),
            message: messages[feature] ?? route.flatMap(languageWarning(for:)),
            provider: route.flatMap(providerChoice(for:)),
            modelSummary: route?.model ?? "Choose a model"
        )
    }

    private func providerChoice(for route: FeatureRoute) -> ProviderChoice? {
        guard route.account == .openRouter else { return nil }
        guard let pinned = route.provider else {
            return ProviderChoice(model: route.model, pinned: nil, label: "Auto")
        }
        var label = pinned
        if case .loaded(let list, _) = providerLists[route.model],
           let endpoint = list.first(where: { $0.tag == pinned }) {
            label = endpoint.title
        }
        return ProviderChoice(model: route.model, pinned: pinned, label: label)
    }

    /// PR #35: a Deepgram model that cannot take the current input language.
    private func languageWarning(for route: FeatureRoute) -> String? {
        switch route.account {
        case .deepgram:
            return DeepgramLanguagePolicy.configurationError(model: route.model, language: inputLanguage())?
                .localizedDescription
        case .soniox, .elevenLabs, .openRouter, .openAI, .anthropic, .server, .thisMac:
            return nil
        }
    }

    private func chip(for account: ProviderAccount) -> KeyChip {
        if account == .thisMac {
            return KeyChip(account: account, title: title(of: account), statusText: "Model downloaded", checkedAt: nil)
        }
        let models = serverModels(of: account)
        if lookup(account) == .unreadable {
            return KeyChip(account: account, title: title(of: account),
                           statusText: "Couldn't read the key from the Keychain", checkedAt: nil, serverModels: models)
        }
        let record = keyStatuses.record(for: account)
        return KeyChip(
            account: account, title: title(of: account),
            statusText: record.map { Self.statusText(for: $0.status, account: account) } ?? "Not checked yet",
            checkedAt: record?.checkedAt, serverModels: models, keyWorks: record?.status == .valid
        )
    }

    private static func statusText(for status: KeyStatus, account: ProviderAccount) -> String {
        switch status {
        case .valid: return "Key works"
        case .limited: return "Limited key"
        case .unreachable: return "Couldn't check"
        case .rejected(.outOfCredit): return "Out of credit or key limit reached"
        case .rejected(.missingSpeechPermission): return "No Speech to Text access on this key"
        case .rejected(.invalidKey):
            switch account {
            case .soniox, .elevenLabs: return "Key not accepted. Regional keys aren't supported yet."
            case .deepgram, .openRouter, .openAI, .anthropic, .server, .thisMac: return "Key not accepted"
            }
        }
    }

    // MARK: - Accounts

    /// Built-in providers with a key (readable or not), then every server by name.
    private func keyedAccounts() -> [ProviderAccount] {
        let builtIn = Self.builtInAccounts.filter { lookup($0) != .absent }
        let servers = routing.state.servers
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { ProviderAccount.server($0.id) }
        return builtIn + servers
    }

    private func lookup(_ account: ProviderAccount) -> ProviderKeyStore.KeyLookup {
        // Its downloaded model stands in for a key; there is no secret.
        if account == .thisMac { return onDevice.isReady() ? .key("") : .absent }
        guard let keychainAccount = account.keychainAccount(in: routing) else { return .absent }
        return keys.lookup(account: keychainAccount)
    }

    private struct Access {
        let apiKey: String?
        let server: ServerEndpoint?
    }

    /// What a request on `account` needs, or `nil` when it cannot be made: no
    /// key, an unreadable key, or a removed server. Only a server runs keyless.
    private func access(_ account: ProviderAccount) -> Access? {
        switch account {
        case .server(let id):
            guard let server = routing.server(id) else { return nil }
            switch keys.lookup(account: server.keyAccount) {
            case .key(let key): return Access(apiKey: key, server: server)
            case .absent: return Access(apiKey: nil, server: server)
            case .unreadable: return nil
            }
        case .thisMac:
            return onDevice.isReady() ? Access(apiKey: nil, server: nil) : nil
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic:
            guard case .key(let key) = lookup(account) else { return nil }
            return Access(apiKey: key, server: nil)
        }
    }

    private func title(of account: ProviderAccount) -> String {
        if case .server(let id) = account, let server = routing.server(id) { return server.displayName }
        return account.kind.displayName
    }

    static func builtInAccount(for kind: AIProviderKind) -> ProviderAccount? {
        switch kind {
        case .soniox: return .soniox
        case .deepgram: return .deepgram
        case .elevenLabs: return .elevenLabs
        case .openRouter: return .openRouter
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .onDevice: return .thisMac
        case .openAICompatible: return nil
        }
    }

    /// An http(s) URL with a host and no user name or password in it.
    private static func baseURLError(_ baseURL: String) -> String? {
        guard let components = URLComponents(string: baseURL),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else { return "Enter an http or https URL" }
        if components.user != nil || components.password != nil {
            return "Remove the user name and password from the URL"
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

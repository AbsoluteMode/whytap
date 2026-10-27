import Combine
import Foundation

/// One provider account in the API keys row. Carries the check outcome, never
/// the key.
struct KeyChip: Equatable, Identifiable {
    let account: ProviderAccount
    let title: String
    let statusText: String
    let checkedAt: Date?
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
    /// Unset and required; an optional route left unset is a valid choice.
    var needsSetup: Bool { status == .notSet && !feature.isOptional }

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

/// One line of the Models card: what the user turns on (Drop Smart, Meetings)
/// with every route it runs on, speech first, then its LLM.
struct FeatureGroup: Equatable, Identifiable {
    let title: String
    let rows: [FeatureRow]
    var id: String { title }

    var summary: String { rows.map(\.modelSummary).joined(separator: " · ") }

    /// Every feature exactly once. Paired functions keep their speech route
    /// beside the LLM route that processes its text.
    static let layout: [(title: String, features: [AIFeature])] = [
        ("Drop Fast", [.dropFast]),
        ("Drop Smart", [.dropSmart, .dropSmartCleanup]),
        ("Meetings", [.meetings, .meetingNotes]),
        ("Agent", [.agent]),
        ("Agent voice", [.agentVoice]),
        ("Voice search", [.voiceSearch]),
        ("Translation", [.translation]),
        ("Subtitles", [.subtitlesAudio, .subtitlesTranslation]),
        ("Meeting Assistant (Beta)", [.meetingAssistantAudio, .meetingAssistantDetector, .meetingAssistant]),
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

/// State and actions of the API & Models tab. Routes change only through an
/// explicit pick, a Switch action or the assign window: adding a key proposes,
/// removing one un-sets, and neither moves a feature to another provider.
/// Keys go from the Keychain straight to the checker, catalog and probe; none
/// is kept in published state.
@MainActor
final class APIAndModelsViewModel: ObservableObject {
    @Published private(set) var chips: [KeyChip] = []
    @Published private(set) var rows: [FeatureRow] = []

    /// `rows` as the Models card shows them.
    var groups: [FeatureGroup] {
        FeatureGroup.layout.map { entry in
            FeatureGroup(title: entry.title, rows: entry.features.compactMap { feature in
                rows.first { $0.feature == feature }
            })
        }
    }
    @Published private(set) var aliasGroups: [AliasGroupAction] = []
    @Published private(set) var unsetBanner: String?
    @Published var proposal: AssignProposal?
    /// Keyed by OpenRouter model ID.
    @Published private(set) var providerLists: [String: ProviderList] = [:]

    /// Built-in providers in the order the tab lists them and Set up picks them.
    private static let builtInAccounts: [ProviderAccount] = [.soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic]

    private let routing: AIRoutingStore
    private let keys: ProviderKeyStore

    func makeTavilySettings() -> TavilySettings { TavilySettings(keys: keys) }
    private let catalogs: ModelCatalogStore
    private let checks: ModelCheckStore
    private let keyStatuses: KeyStatusStore
    private let keyChecker: any ProviderKeyChecking
    private let probe: any ModelProbing
    private let endpoints: any OpenRouterEndpointsFetching
    private let now: () -> Date
    private let inputLanguage: @MainActor () -> String?
    private let resolver: ModelStatusResolver

    private var checking: Set<AIFeature> = []
    private var messages: [AIFeature: String] = [:]
    private var observers: Set<AnyCancellable> = []

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
        endpoints: any OpenRouterEndpointsFetching = OpenRouterEndpointsClient(),
        now: @escaping () -> Date = Date.init,
        inputLanguage: (@MainActor () -> String?)? = nil
    ) {
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
        self.endpoints = endpoints
        self.now = now
        self.inputLanguage = inputLanguage ?? { PrivacyPreferences.shared.selectedLanguage?.code }
        self.resolver = ModelStatusResolver(
            routing: routing, keys: keys, catalogs: catalogs, checks: checks, keyStatuses: keyStatuses
        )
        recompute()

        // The input language is changed in the island and in meeting settings;
        // the stores write UserDefaults too. Bursts collapse into one pass.
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.recompute() }
            }
            .store(in: &observers)
    }

    /// Kinds the Add key menu offers: built-in providers without a key (an
    /// unreadable one already has a chip), and always a server.
    var addableKinds: [AIProviderKind] {
        AIProviderKind.allCases.filter { kind in
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
        return await store(key, for: account, proposing: true)
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
        recompute()
        return nil
    }

    /// Saves an inline-form key without opening a model proposal, including the
    /// first key. A rejected replacement leaves the previous saved key in place.
    func replaceKey(_ key: String, for account: ProviderAccount) async -> String? {
        await store(key, for: account, proposing: false)
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
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic: routing.clearRoutes(using: account)
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
        let unset = AIFeature.activeCases.filter { resolver.status(for: $0) == .notSet && !$0.isOptional }
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

    private func store(_ rawKey: String, for account: ProviderAccount, proposing: Bool) async -> String? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let server: ServerEndpoint?
        switch account {
        case .server(let id):
            guard let endpoint = routing.server(id) else { return "This server was removed" }
            server = endpoint
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic:
            guard !key.isEmpty else { return "Enter a key" }
            server = nil
        }
        guard let keychainAccount = account.keychainAccount(in: routing) else { return "This server was removed" }
        let apiKey = key.nilIfEmpty

        // Checked before it is stored, so a key the provider turns down never
        // replaces anything.
        let status = await keyChecker.check(account, apiKey: apiKey, server: server, allowPaidProbe: true)
        if account == .openAI, status == .limited {
            return "Allow model-list access for this OpenAI key, then try again."
        }
        guard status == .valid || status == .limited else {
            return Self.statusText(for: status, account: account)
        }
        do {
            if let apiKey {
                try keys.save(apiKey, account: keychainAccount)
            } else {
                try keys.delete(account: keychainAccount)
            }
        } catch {
            return "Couldn't save the key"
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
            resolved = try FeatureRouteResolver(routing: routing, keys: keys).resolve(route, for: feature)
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

    private func recompute() {
        let chips = keyedAccounts().map(chip(for:))
        let rows = AIFeature.activeCases.map(row(for:))
        let groups = resolver.aliasGroups()
        let unset = rows.filter(\.needsSetup).count
        let banner: String?
        if chips.isEmpty || unset == 0 {
            banner = nil
        } else {
            banner = unset == 1 ? "1 feature has no model" : "\(unset) features have no model"
        }
        if self.chips != chips { self.chips = chips }
        if self.rows != rows { self.rows = rows }
        if self.aliasGroups != groups { self.aliasGroups = groups }
        if self.unsetBanner != banner { self.unsetBanner = banner }
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
        case .soniox, .elevenLabs, .openRouter, .openAI, .anthropic, .server:
            return nil
        }
    }

    private func chip(for account: ProviderAccount) -> KeyChip {
        if lookup(account) == .unreadable {
            return KeyChip(account: account, title: title(of: account),
                           statusText: "Couldn't read the key from the Keychain", checkedAt: nil)
        }
        let record = keyStatuses.record(for: account)
        return KeyChip(
            account: account, title: title(of: account),
            statusText: record.map { Self.statusText(for: $0.status, account: account) } ?? "Not checked yet",
            checkedAt: record?.checkedAt
        )
    }

    private static func statusText(for status: KeyStatus, account: ProviderAccount) -> String {
        switch status {
        case .valid: return "Key works"
        case .limited: return "Limited key"
        case .unreachable: return "Couldn't check"
        case .rejected(.outOfCredit): return "Out of credit or key limit reached"
        case .rejected(.invalidKey):
            switch account {
            case .soniox, .elevenLabs: return "Key not accepted. Regional keys aren't supported yet."
            case .deepgram, .openRouter, .openAI, .anthropic, .server: return "Key not accepted"
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
        case .soniox, .deepgram, .elevenLabs, .openRouter, .openAI, .anthropic:
            guard case .key(let key) = lookup(account) else { return nil }
            return Access(apiKey: key, server: nil)
        }
    }

    private func title(of account: ProviderAccount) -> String {
        if case .server(let id) = account, let server = routing.server(id) { return server.name }
        return account.kind.displayName
    }

    private static func builtInAccount(for kind: AIProviderKind) -> ProviderAccount? {
        switch kind {
        case .soniox: return .soniox
        case .deepgram: return .deepgram
        case .elevenLabs: return .elevenLabs
        case .openRouter: return .openRouter
        case .openAI: return .openAI
        case .anthropic: return .anthropic
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

import Foundation

/// Per-provider model / reasoning / speed settings chosen in Settings,
/// persisted in UserDefaults. Codex models and controls come from its registry;
/// the same resolution feeds both the Settings UI and per-turn CLI flags.
/// The Agent's web search pick in Keys & models → Models → Search.
enum AgentWebSearchChoice: String, Sendable {
    /// The Agent model's built-in search; Tavily for a model without it.
    case auto
    /// Tavily, when its key exists; otherwise as `.auto`.
    case tavily
}

@MainActor
final class AgentSettingsStore: ObservableObject {
    static let shared = AgentSettingsStore()
    static let webSearchChoiceKey = "agent.native.webSearch"
    /// Claude's reasoning when the user has not picked one and the model takes it.
    static let defaultEffort = "low"
    /// Claude Code's levels, used only until its catalog has loaded; then the
    /// selected model's own levels apply. Codex capabilities come from model/list.
    static let claudeEffortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    @Published var claudeModel: String?       { didSet { write(Keys.claudeModel, claudeModel) } }
    @Published var claudeEffort: String?      { didSet { write(Keys.claudeEffort, claudeEffort) } }
    @Published var codexModel: String?        { didSet { write(Keys.codexModel, codexModel) } }
    @Published var codexEffort: String?       { didSet { write(Keys.codexEffort, codexEffort) } }
    @Published var codexServiceTier: String?  { didSet { write(Keys.codexServiceTier, codexServiceTier) } }
    /// "Allow file edits and commands". Stored under the key the earlier
    /// agents used, so the user's choice carries over unchanged.
    /// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
    @Published var allowActions: Bool { didSet { defaults.set(allowActions, forKey: Keys.allowActions) } }
    /// Keys & models → Models → Search. `.auto` (default): the Agent model's
    /// built-in search, else Tavily. WHY: .project-docs/decisions/2026-11-22-agent-provider-web-search.md
    @Published var webSearchChoice: AgentWebSearchChoice { didSet { defaults.set(webSearchChoice.rawValue, forKey: Keys.webSearchChoice) } }

    private enum Keys {
        static let claudeModel = "agent.claude.model"
        static let claudeEffort = "agent.claude.effort"
        static let codexModel = "agent.codex.model"
        static let codexEffort = "agent.codex.effort"
        static let codexServiceTier = "agent.codex.serviceTier"
        static let allowActions = "agent.opencode.allowActions"
        static let webSearchChoice = AgentSettingsStore.webSearchChoiceKey
    }

    @Published private(set) var claudeCatalog: [ClaudeModelOption] = []
    @Published private(set) var claudeVersion: String?
    @Published private(set) var claudeCatalogLoading = false
    @Published private(set) var claudeCatalogError: String?
    private var claudeCatalogUpdatedAt: Date?
    @Published private(set) var codexCatalog: [CodexModelOption] = []
    @Published private(set) var codexCatalogLoading = false
    @Published private(set) var codexCatalogError: String?
    private var catalogUpdatedAt: Date?
    private var codexConfig: CodexConfigSnapshot
    private let defaults: UserDefaults
    /// `nil` means the shared store, looked up when the model is read.
    private let injectedRouting: AIRoutingStore?
    private var routing: AIRoutingStore { injectedRouting ?? .shared }
    private let injectedCatalogs: ModelCatalogStore?
    private var catalogs: ModelCatalogStore { injectedCatalogs ?? .shared }
    /// The running app's `whytap mcp` helper for Claude Code and Codex turns.
    private let whytapMCPCommand: () -> [String]?

    init(defaults: UserDefaults = .standard, codexConfig: CodexConfigSnapshot = CodexConfigReader().read(), routing: AIRoutingStore? = nil,
         catalogs: ModelCatalogStore? = nil,
         whytapMCPCommand: @escaping () -> [String]? = { AgentHarnessFlags.bundledWhytapMCPCommand }) {
        self.codexConfig = codexConfig
        self.defaults = defaults
        self.injectedRouting = routing
        self.injectedCatalogs = catalogs
        self.whytapMCPCommand = whytapMCPCommand
        self.allowActions = defaults.object(forKey: Keys.allowActions) as? Bool ?? true
        self.webSearchChoice = defaults.string(forKey: Keys.webSearchChoice).flatMap(AgentWebSearchChoice.init) ?? .auto
        // Property observers do not fire on initial assignment in init, so this
        // load does not write back. A stored model is kept exactly as saved.
        self.claudeModel = defaults.string(forKey: Keys.claudeModel)
        self.claudeEffort = defaults.string(forKey: Keys.claudeEffort)
        self.codexModel = defaults.string(forKey: Keys.codexModel)
        self.codexEffort = defaults.string(forKey: Keys.codexEffort)
        self.codexServiceTier = defaults.string(forKey: Keys.codexServiceTier)
    }

    /// A choice that arrived by settings sync (SettingsSyncLiveReload).
    func reloadWebSearchChoice() {
        let stored = defaults.string(forKey: Keys.webSearchChoice).flatMap(AgentWebSearchChoice.init) ?? .auto
        if stored != webSearchChoice { webSearchChoice = stored }
    }

    /// Resolve the overrides for one provider into the run-time options struct.
    /// Codex overrides are validated against the selected model’s live capabilities.
    /// Without a catalog, retain the model but let Codex resolve its controls.
    func options(for id: CLIProviderID) -> AgentRunOptions {
        switch id {
        case .claude:
            return AgentRunOptions(
                model: claudeRunModel,
                effort: claudeRunEffort,
                allowActions: allowActions,
                whytapMCPCommand: whytapMCPCommand()
            )
        case .codex:
            return AgentRunOptions(
                model: selectedCodexModel,
                effort: selectedCodexOption?.resolvedEffort(codexEffort),
                serviceTier: selectedCodexOption?.resolvedTier(codexServiceTier ?? codexConfig.serviceTier),
                allowActions: allowActions,
                whytapMCPCommand: whytapMCPCommand()
            )
        case .native:
            return AgentRunOptions(model: selectedOpenCodeModel, allowActions: allowActions,
                                   openCodeModelSpec: selectedOpenCodeModelSpec,
                                   openCodeProvider: selectedOpenCodeProvider ?? .openRouter,
                                   openRouterProvider: selectedOpenCodeProvider == .openRouter
                                       ? routing.route(for: .agent)?.provider : nil,
                                   // Read from defaults: a synced choice applies at once.
                                   preferTavilySearch: defaults.string(forKey: Keys.webSearchChoice) == AgentWebSearchChoice.tavily.rawValue,
                                   webSearchSupport: selectedWebSearchSupport,
                                   lowEffortSupport: selectedCatalogEntry?.supportsLowEffort,
                                   openRouterReasoning: selectedOpenCodeProvider == .openRouter
                                       ? selectedCatalogEntry?.reasoning : nil,
                                   outputTokenLimit: selectedCatalogEntry?.maxOutputTokens.flatMap { $0 > 0 ? $0 : nil })
        case .opencode:
            return AgentRunOptions(model: selectedOpenCodeModel, allowActions: allowActions,
                                   openCodeModelSpec: selectedOpenCodeModelSpec,
                                   openCodeProvider: selectedOpenCodeProvider ?? .openRouter,
                                   caseMCPCommand: CaseBuiltInAgentAccess.currentMCPCommand(),
                                   screenMCPCommand: CaseBuiltInAgentAccess.bundledHelperURL.map {
                                       [$0.path, "app", "screen-mcp"]
                                   },
                                   openRouterProvider: selectedOpenCodeProvider == .openRouter
                                       ? routing.route(for: .agent)?.provider : nil)
        }
    }

    /// The OpenCode provider of the `Agent` route: OpenRouter or Anthropic, or
    /// `nil` for no route or a route OpenCode cannot run.
    var selectedOpenCodeProvider: OpenCodeModelProvider? {
        routing.route(for: .agent).flatMap { OpenCodeModelProvider(account: $0.account) }
    }

    /// The model OpenCode runs: the `Agent` feature's route when it is on
    /// OpenRouter or Anthropic, else none. The old `agent.opencode.model`
    /// preference is only read by the routing migration.
    var selectedOpenCodeModel: String? {
        guard let route = routing.route(for: .agent), selectedOpenCodeProvider != nil else { return nil }
        let value = OpenCodeEnvironment.normalizeModel(route.model)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
        return value
    }

    /// `"<provider> · <model id>"` for the agent route, or `nil` without a
    /// usable model. New agent providers add a case to `OpenCodeModelProvider`.
    var selectedOpenCodeModelLabel: String? {
        guard let route = routing.route(for: .agent), let model = selectedOpenCodeModel else { return nil }
        return "\(route.account.kind.displayName) · \(model)"
    }

    /// The selected model's limits from the route provider's catalog snapshot;
    /// `nil` when the catalog does not give a context length.
    var selectedOpenCodeModelSpec: OpenCodeModelSpec? {
        guard let id = selectedOpenCodeModel, let provider = selectedOpenCodeProvider,
              let entry = catalogs.snapshot(for: provider.account)?.models.first(where: {
                  OpenCodeEnvironment.normalizeModel($0.id) == id
              }),
              let context = entry.contextLength else { return nil }
        return OpenCodeModelSpec(toolCall: entry.supportsTools ?? true,
                                 reasoning: entry.supportsReasoning ?? false,
                                 contextLimit: context,
                                 outputLimit: entry.maxOutputTokens ?? 16_384)
    }

    /// The catalog's built-in web search flag for the Agent model, independent
    /// of whether the catalog gives token limits (the Search row and the next
    /// turn must agree). WHY: .project-docs/decisions/2026-11-22-agent-provider-web-search.md
    var selectedWebSearchSupport: Bool? { selectedCatalogEntry?.supportsWebSearch }

    /// The Agent model's entry in its route provider's catalog snapshot.
    var selectedCatalogEntry: CatalogModel? {
        guard let id = selectedOpenCodeModel, let provider = selectedOpenCodeProvider else { return nil }
        return catalogs.snapshot(for: provider.account)?.models.first {
            OpenCodeEnvironment.normalizeModel($0.id) == id
        }
    }

    /// The user's explicit pick when it is a level this CLI accepts, else Low.
    /// Case-insensitive; unknown Claude levels do not pass through to CLI flags.
    static func resolvedEffort(stored: String?, allowed: Set<String>) -> String {
        if let v = stored?.lowercased(), allowed.contains(v) { return v }
        return defaultEffort
    }

    static func normalizedCodexModel(_ model: String?) -> String? {
        guard let model else { return nil }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var selectedCodexModel: String? {
        Self.normalizedCodexModel(codexModel)
            ?? Self.normalizedCodexModel(codexConfig.model)
            ?? codexCatalog.first(where: { $0.isDefault == true })?.model
            ?? codexCatalog.first?.model
    }

    var selectedCodexOption: CodexModelOption? {
        codexCatalog.first { $0.model == selectedCodexModel }
    }

    func updateCodexCatalog(_ models: [CodexModelOption]) {
        codexCatalog = models
        catalogUpdatedAt = Date()
        codexCatalogError = nil
    }

    func refreshCodexCatalog(force: Bool = false,
        load: () async throws -> [CodexModelOption] = { try await CodexModelCatalogReader().read() }
    ) async {
        guard !codexCatalogLoading else { return }
        if !force, let date = catalogUpdatedAt, Date().timeIntervalSince(date) < 60 { return }
        codexCatalogLoading = true
        defer { codexCatalogLoading = false }
        codexConfig = CodexConfigReader().read()
        do {
            let models = try await load()
            try Task.checkCancellation()
            updateCodexCatalog(models)
        } catch is CancellationError {
            // Closing Settings cancels discovery; preserve the previous catalog.
        } catch {
            codexCatalogError = "Couldn’t refresh models from Codex. Check that Codex is installed and signed in, then retry."
        }
    }

    // MARK: Claude Code

    /// The saved Claude model, exactly as picked; nil for Claude Code's own default.
    static func normalizedClaudeModel(_ model: String?) -> String? {
        guard let value = model?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value != ClaudeModelCatalog.cliDefaultValue else { return nil }
        return value
    }

    /// The `--model` a turn sends: the user's pick, verbatim, or none, so
    /// Claude Code uses its own default. Never a model Whytap chose.
    var claudeRunModel: String? { Self.normalizedClaudeModel(claudeModel) }

    /// The catalog entry of the selected model (Claude Code's default entry
    /// when nothing is picked); nil before the catalog loads or for a saved
    /// model the catalog no longer lists.
    var selectedClaudeOption: ClaudeModelOption? {
        let value = claudeRunModel ?? ClaudeModelCatalog.cliDefaultValue
        return claudeCatalog.first { $0.value == value }
    }

    /// The `--effort` a turn sends. With the catalog: the user's pick when the
    /// model takes it, else Low when it takes Low, else none (a model without
    /// reasoning levels gets no flag). Before the catalog loads: the user's
    /// pick among Claude Code's levels, else Low.
    var claudeRunEffort: String? {
        guard let option = selectedClaudeOption else {
            return Self.resolvedEffort(stored: claudeEffort, allowed: Self.claudeEffortLevels)
        }
        return Self.resolvedEffort(stored: claudeEffort, levels: option.efforts)
    }

    static func resolvedEffort(stored: String?, levels: [String]) -> String? {
        if let value = stored?.lowercased(), levels.contains(value) { return value }
        return levels.contains(defaultEffort) ? defaultEffort : nil
    }

    func updateClaudeCatalog(_ catalog: ClaudeModelCatalog) {
        claudeCatalog = catalog.models
        claudeVersion = catalog.cliVersion
        claudeCatalogUpdatedAt = Date()
        claudeCatalogError = nil
    }

    func refreshClaudeCatalog(force: Bool = false,
        load: () async throws -> ClaudeModelCatalog = { try await ClaudeModelCatalogReader().read() }
    ) async {
        guard !claudeCatalogLoading else { return }
        if !force, let date = claudeCatalogUpdatedAt, Date().timeIntervalSince(date) < 60 { return }
        claudeCatalogLoading = true
        defer { claudeCatalogLoading = false }
        do {
            let catalog = try await load()
            try Task.checkCancellation()
            updateClaudeCatalog(catalog)
        } catch is CancellationError {
            // Closing Settings cancels discovery; keep the previous catalog.
        } catch ClaudeModelCatalogError.notInstalled {
            claudeCatalogError = "Claude Code isn’t installed on this Mac."
        } catch {
            claudeCatalogError = "Couldn’t load models from Claude Code. Check that it is installed and signed in, then retry."
        }
    }

    private func write(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

import Foundation

/// Per-provider model / reasoning / speed settings chosen in Settings,
/// persisted in UserDefaults. Codex models and controls come from its registry;
/// the same resolution feeds both the Settings UI and per-turn CLI flags.
@MainActor
final class AgentSettingsStore: ObservableObject {
    static let shared = AgentSettingsStore()
    static let pinnedClaudeModel = "sonnet"
    /// Claude retains its existing low-effort default.
    static let defaultEffort = "low"
    /// Claude options; Codex capabilities come from model/list.
    static let claudeEffortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]

    @Published var claudeModel: String?       { didSet { write(Keys.claudeModel, claudeModel) } }
    @Published var claudeEffort: String?      { didSet { write(Keys.claudeEffort, claudeEffort) } }
    @Published var codexModel: String?        { didSet { write(Keys.codexModel, codexModel) } }
    @Published var codexEffort: String?       { didSet { write(Keys.codexEffort, codexEffort) } }
    @Published var codexServiceTier: String?  { didSet { write(Keys.codexServiceTier, codexServiceTier) } }
    @Published var openCodeAllowActions: Bool { didSet { defaults.set(openCodeAllowActions, forKey: Keys.openCodeAllowActions) } }

    private enum Keys {
        static let claudeModel = "agent.claude.model"
        static let claudeEffort = "agent.claude.effort"
        static let codexModel = "agent.codex.model"
        static let codexEffort = "agent.codex.effort"
        static let codexServiceTier = "agent.codex.serviceTier"
        static let openCodeAllowActions = "agent.opencode.allowActions"
    }

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

    init(defaults: UserDefaults = .standard, codexConfig: CodexConfigSnapshot = CodexConfigReader().read(), routing: AIRoutingStore? = nil,
         catalogs: ModelCatalogStore? = nil) {
        self.codexConfig = codexConfig
        self.defaults = defaults
        self.injectedRouting = routing
        self.injectedCatalogs = catalogs
        self.openCodeAllowActions = defaults.object(forKey: Keys.openCodeAllowActions) as? Bool ?? true
        // Property observers do not fire on initial assignment in init, so this
        // load does not write back.
        self.claudeModel = defaults.string(forKey: Keys.claudeModel)
        if let normalized = Self.normalizedClaudeModel(claudeModel), normalized != claudeModel {
            self.claudeModel = normalized
            defaults.set(normalized, forKey: Keys.claudeModel)
        }
        self.claudeEffort = defaults.string(forKey: Keys.claudeEffort)
        self.codexModel = defaults.string(forKey: Keys.codexModel)
        self.codexEffort = defaults.string(forKey: Keys.codexEffort)
        self.codexServiceTier = defaults.string(forKey: Keys.codexServiceTier)
    }

    /// Resolve the overrides for one provider into the run-time options struct.
    /// Codex overrides are validated against the selected model’s live capabilities.
    /// Without a catalog, retain the model but let Codex resolve its controls.
    func options(for id: CLIProviderID) -> AgentRunOptions {
        switch id {
        case .claude:
            return AgentRunOptions(
                model: Self.normalizedClaudeModel(claudeModel) ?? Self.pinnedClaudeModel,
                effort: Self.resolvedEffort(stored: claudeEffort,
                                            allowed: Self.claudeEffortLevels)
            )
        case .codex:
            return AgentRunOptions(
                model: selectedCodexModel,
                effort: selectedCodexOption?.resolvedEffort(codexEffort),
                serviceTier: selectedCodexOption?.resolvedTier(codexServiceTier ?? codexConfig.serviceTier)
            )
        case .native:
            return AgentRunOptions(model: selectedOpenCodeModel, allowActions: openCodeAllowActions,
                                   openCodeModelSpec: selectedOpenCodeModelSpec,
                                   openCodeProvider: selectedOpenCodeProvider ?? .openRouter,
                                   openRouterProvider: selectedOpenCodeProvider == .openRouter
                                       ? routing.route(for: .agent)?.provider : nil)
        case .opencode:
            return AgentRunOptions(model: selectedOpenCodeModel, allowActions: openCodeAllowActions,
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
                                 outputLimit: entry.maxOutputTokens ?? 16_384,
                                 webSearch: entry.supportsWebSearch)
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

    static func normalizedClaudeModel(_ model: String?) -> String? {
        guard let model else { return nil }
        return model == pinnedClaudeModel ? model : pinnedClaudeModel
    }

    private func write(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

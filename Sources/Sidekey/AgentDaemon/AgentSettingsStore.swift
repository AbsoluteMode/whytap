import Foundation

/// Per-provider model / reasoning / speed settings chosen in Settings,
/// persisted in UserDefaults. Codex models and controls come from its registry;
/// the same resolution feeds both the Settings UI and per-turn CLI flags.
@MainActor
final class AgentSettingsStore: ObservableObject {
    static let shared = AgentSettingsStore()
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
    private enum Keys {
        static let claudeModel = "agent.claude.model"
        static let claudeEffort = "agent.claude.effort"
        static let codexModel = "agent.codex.model"
        static let codexEffort = "agent.codex.effort"
        static let codexServiceTier = "agent.codex.serviceTier"
        static let allowActions = "agent.opencode.allowActions"
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
    /// The running app's `whytap mcp` helper for Claude Code and Codex turns.
    private let whytapMCPCommand: () -> [String]?

    init(defaults: UserDefaults = .standard, codexConfig: CodexConfigSnapshot = CodexConfigReader().read(),
         whytapMCPCommand: @escaping () -> [String]? = { AgentHarnessFlags.bundledWhytapMCPCommand }) {
        self.codexConfig = codexConfig
        self.defaults = defaults
        self.whytapMCPCommand = whytapMCPCommand
        self.allowActions = defaults.object(forKey: Keys.allowActions) as? Bool ?? true
        // Property observers do not fire on initial assignment in init, so this
        // load does not write back. A stored model is kept exactly as saved.
        self.claudeModel = defaults.string(forKey: Keys.claudeModel)
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
    /// reasoning levels, or a saved model the catalog does not list, gets no
    /// flag). Before the catalog loads: the user's pick among Claude Code's
    /// levels, else Low.
    var claudeRunEffort: String? {
        guard let option = selectedClaudeOption else {
            // A loaded list without the saved model gives no evidence that
            // the model takes the flag.
            guard claudeCatalog.isEmpty else { return nil }
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
        } catch ClaudeModelCatalogError.workspaceUnavailable {
            claudeCatalogError = AgentHarnessMessages.workspaceUnavailable
        } catch {
            claudeCatalogError = "Couldn’t load models from Claude Code. Check that it is installed and signed in, then retry."
        }
    }

    private func write(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

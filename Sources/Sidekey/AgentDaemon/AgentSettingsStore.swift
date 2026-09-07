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

    private enum Keys {
        static let claudeModel = "agent.claude.model"
        static let claudeEffort = "agent.claude.effort"
        static let codexModel = "agent.codex.model"
        static let codexEffort = "agent.codex.effort"
        static let codexServiceTier = "agent.codex.serviceTier"
    }

    @Published private(set) var codexCatalog: [CodexModelOption] = []
    @Published private(set) var codexCatalogLoading = false
    @Published private(set) var codexCatalogError: String?
    private var catalogUpdatedAt: Date?
    private var codexConfig: CodexConfigSnapshot
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, codexConfig: CodexConfigSnapshot = CodexConfigReader().read()) {
        self.codexConfig = codexConfig
        self.defaults = defaults
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

    static func normalizedClaudeModel(_ model: String?) -> String? {
        guard let model else { return nil }
        return model == pinnedClaudeModel ? model : pinnedClaudeModel
    }

    private func write(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

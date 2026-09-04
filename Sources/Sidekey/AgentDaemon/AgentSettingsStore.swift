import Foundation

/// Per-provider model / reasoning / speed settings chosen in Settings,
/// persisted in UserDefaults. Models are pinned by Whytap for a stable tool
/// surface; effort is always sent per-invocation (never inherited from the
/// user's CLI config) so agent turns are consistently fast.
@MainActor
final class AgentSettingsStore: ObservableObject {
    static let shared = AgentSettingsStore()
    static let pinnedClaudeModel = "sonnet"
    static let pinnedCodexModel = "gpt-5.5"
    /// Whytap pins reasoning to Low unless the user explicitly picks another
    /// level: the session flag must always be sent, otherwise the CLI inherits
    /// the user's terminal config (often high/max) and turns feel slow.
    static let defaultEffort = "low"
    /// Levels each CLI accepts (`--effort` / `model_reasoning_effort`). The
    /// pickers offer exactly these sets (guarded by tests).
    static let claudeEffortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]
    static let codexEffortLevels: Set<String> = ["low", "medium", "high", "xhigh"]

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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
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
        // Keep Whytap on the full Codex model. Earlier builds exposed Spark;
        // normalize any stored Codex model so old preferences do not silently
        // keep running a model with a narrower tool surface.
        if let normalized = Self.normalizedCodexModel(codexModel), normalized != codexModel {
            self.codexModel = normalized
            defaults.set(normalized, forKey: Keys.codexModel)
        }
        self.codexEffort = defaults.string(forKey: Keys.codexEffort)
        self.codexServiceTier = defaults.string(forKey: Keys.codexServiceTier)
    }

    /// Resolve the overrides for one provider into the run-time options struct.
    /// Effort is always populated (stored -> "low"), the same chain the
    /// Reasoning picker displays, so the run sends exactly what the picker
    /// shows and neither the CLI's built-in default nor the user's CLI config
    /// ever applies.
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
                model: Self.normalizedCodexModel(codexModel) ?? Self.pinnedCodexModel,
                effort: Self.resolvedEffort(stored: codexEffort,
                                            allowed: Self.codexEffortLevels),
                serviceTier: codexServiceTier
            )
        }
    }

    /// The user's explicit pick when it is a level this CLI accepts, else Low.
    /// Case-insensitive; values outside `allowed` (e.g. codex "minimal",
    /// claude-only "max" on codex) never pass through to a CLI flag.
    static func resolvedEffort(stored: String?, allowed: Set<String>) -> String {
        if let v = stored?.lowercased(), allowed.contains(v) { return v }
        return defaultEffort
    }

    static func normalizedCodexModel(_ model: String?) -> String? {
        guard let model else { return nil }
        return model == pinnedCodexModel ? model : pinnedCodexModel
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

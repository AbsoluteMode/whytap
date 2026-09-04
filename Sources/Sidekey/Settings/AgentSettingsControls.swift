import SwiftUI

/// Picker over concrete values (always a real selection). Used for the model
/// picker, which mirrors the CLI's current model by name.
@MainActor
struct ConcreteSettingPicker: View {
    let title: String
    let options: [(label: String, value: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { opt in
                    Text(opt.label).tag(opt.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// Claude model (mirrored from ~/.claude.json, real version names) + reasoning.
@MainActor
struct AgentControlsClaude: View {
    @ObservedObject var settings: AgentSettingsStore
    let catalog: ClaudeModelCatalog

    static func modelOptions(_ catalog: ClaudeModelCatalog) -> [(label: String, value: String)] {
        // Hardcoded for now — a single pinned model. (Previously mapped the
        // dynamically-scanned catalog; auto-resolve is a later decision.)
        [(label: "Sonnet", value: AgentSettingsStore.pinnedClaudeModel)]
    }

    static let effortOptions: [(label: String, value: String)] = [
        ("Low", "low"), ("Medium", "medium"), ("High", "high"),
        ("Very high", "xhigh"), ("Max", "max"),
    ]

    /// The Reasoning picker shows (no write-back) exactly what the run sends —
    /// stored override, else Low (`AgentSettingsStore.resolvedEffort`, the
    /// single display == send code path). The old config-mirror is gone: since
    /// we now always pass --effort, mirroring ~/.claude/settings.json would
    /// show a value that is NOT what the run uses.
    static func displayedEffort(stored: String?) -> String {
        AgentSettingsStore.resolvedEffort(stored: stored,
                                          allowed: AgentSettingsStore.claudeEffortLevels)
    }

    private var modelSelection: Binding<String> {
        Binding(get: {
            AgentSettingsStore.normalizedClaudeModel(settings.claudeModel)
                ?? AgentSettingsStore.pinnedClaudeModel
        },
                set: { settings.claudeModel = $0 })
    }

    /// Displaying the fallback never writes it: the store is only touched on
    /// an explicit pick (the `set` side).
    private var effortSelection: Binding<String> {
        Binding(get: { Self.displayedEffort(stored: settings.claudeEffort) },
                set: { settings.claudeEffort = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConcreteSettingPicker(title: "Model",
                                  options: Self.modelOptions(catalog),
                                  selection: modelSelection)
            ConcreteSettingPicker(title: "Reasoning",
                                  options: Self.effortOptions,
                                  selection: effortSelection)
        }
        .padding(.horizontal, 16)
    }
}

/// Codex model (mirrored from ~/.codex/config.toml) + reasoning + speed.
@MainActor
struct AgentControlsCodex: View {
    @ObservedObject var settings: AgentSettingsStore
    let config: CodexConfigSnapshot

    static func modelOptions(config _: CodexConfigSnapshot) -> [(label: String, value: String)] {
        [("GPT-5.5", AgentSettingsStore.pinnedCodexModel)]
    }

    /// Map a raw `service_tier` from `~/.codex/config.toml` to one of our two
    /// option values, so the Speed picker mirrors the user's current Codex
    /// setting the way Model does. "fast"/"priority" are the same fast lane;
    /// "default"/"normal"/"standard" are the normal lane. Unknown -> nil.
    static func mirroredTier(_ raw: String?) -> String? {
        switch raw?.lowercased() {
        case "priority", "fast": return "priority"
        case "default", "normal", "standard": return "default"
        default: return nil
        }
    }

    static func supportsSpeed(model: String?) -> Bool {
        CodexProvider.supportsServiceTier(model: model)
    }

    static let effortOptions: [(label: String, value: String)] = [
        ("Low", "low"), ("Medium", "medium"), ("High", "high"), ("Very high", "xhigh"),
    ]

    /// The Reasoning picker shows (no write-back) exactly what the run sends —
    /// stored override, else Low (`AgentSettingsStore.resolvedEffort`, the
    /// single display == send code path). The old config-mirror is gone: since
    /// we now always pass -c model_reasoning_effort=..., mirroring
    /// ~/.codex/config.toml would show a value that is NOT what the run uses.
    static func displayedEffort(stored: String?) -> String {
        AgentSettingsStore.resolvedEffort(stored: stored,
                                          allowed: AgentSettingsStore.codexEffortLevels)
    }

    private var selectedModel: String {
        AgentSettingsStore.normalizedCodexModel(settings.codexModel)
            ?? AgentSettingsStore.pinnedCodexModel
    }

    /// Speed mirrors config (display-only) until the user picks: show the stored
    /// override, else the mirrored config tier, else Normal.
    private var speedSelection: Binding<String> {
        Binding(get: { settings.codexServiceTier ?? Self.mirroredTier(config.serviceTier) ?? "default" },
                set: { settings.codexServiceTier = $0 })
    }

    /// Displaying the fallback never writes it: the store is only touched on
    /// an explicit pick (the `set` side).
    private var effortSelection: Binding<String> {
        Binding(get: { Self.displayedEffort(stored: settings.codexEffort) },
                set: { settings.codexEffort = $0 })
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { selectedModel },
            set: {
                settings.codexModel = $0
                if !Self.supportsSpeed(model: $0) {
                    settings.codexServiceTier = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConcreteSettingPicker(title: "Model",
                                  options: Self.modelOptions(config: config),
                                  selection: modelSelection)
            ConcreteSettingPicker(title: "Reasoning",
                                  options: Self.effortOptions,
                                  selection: effortSelection)
            if Self.supportsSpeed(model: selectedModel) {
                ConcreteSettingPicker(
                    title: "Speed",
                    options: [("Fast", "priority"), ("Normal", "default")],
                    selection: speedSelection)
            }
        }
        .padding(.horizontal, 16)
    }
}

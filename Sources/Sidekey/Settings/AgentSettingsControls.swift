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

/// Controls are populated from the same Codex catalog used for runtime options.
@MainActor
struct AgentControlsCodex: View {
    @ObservedObject var settings: AgentSettingsStore

    static func modelOptions(catalog: [CodexModelOption], selected: String?) -> [(label: String, value: String)] {
        var options = catalog.map { (label: $0.label, value: $0.model) }
        if let selected, !options.contains(where: { $0.value == selected }) {
            options.insert((label: selected + " (saved)", value: selected), at: 0)
        }
        if options.isEmpty { options = [(label: "Codex default", value: "")] }
        return options
    }

    private var modelSelection: Binding<String> {
        Binding(get: { settings.selectedCodexModel ?? "" }, set: { settings.codexModel = $0 })
    }
    private var effortSelection: Binding<String> {
        Binding(get: { settings.options(for: .codex).effort ?? "" }, set: { settings.codexEffort = $0 })
    }
    private var speedSelection: Binding<String> {
        Binding(get: { settings.options(for: .codex).serviceTier ?? "default" }, set: { settings.codexServiceTier = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConcreteSettingPicker(title: "Model", options: Self.modelOptions(
                catalog: settings.codexCatalog, selected: settings.selectedCodexModel), selection: modelSelection)
            if let model = settings.selectedCodexOption {
                if !model.efforts.isEmpty {
                    ConcreteSettingPicker(title: "Reasoning",
                        options: model.efforts.map { (label: $0.capitalized, value: $0) }, selection: effortSelection)
                }
                if !model.tiers.isEmpty {
                    ConcreteSettingPicker(title: "Speed",
                        options: [(label: "Normal", value: "default")] + model.tiers.map {
                            (label: $0.name ?? $0.id.capitalized, value: $0.id)
                        }, selection: speedSelection)
                    if let description = model.tiers.first(where: { $0.id == settings.options(for: .codex).serviceTier })?.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                if settings.codexCatalogLoading { ProgressView().controlSize(.small) }
                if let error = settings.codexCatalogError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                } else if settings.selectedCodexModel != nil && settings.selectedCodexOption == nil && !settings.codexCatalogLoading {
                    Text("The saved model isn’t in the current Codex catalog. Choose an available model or refresh.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh models") { Task { await settings.refreshCodexCatalog(force: true) } }
                    .font(.caption).disabled(settings.codexCatalogLoading)
            }
        }
        .padding(.horizontal, 16)
    }
}

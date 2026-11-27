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
                .foregroundStyle(MacSettingsTheme.text2)
            Spacer(minLength: 0)
            MacPopup(items: options.map { .init(value: $0.value, label: $0.label) },
                     selection: $selection, maxWidth: 300)
                .accessibilityLabel(title)
        }
    }
}

/// Claude Code model and reasoning, from Claude Code's own catalog.
@MainActor
struct AgentControlsClaude: View {
    @ObservedObject var settings: AgentSettingsStore

    /// Catalog entries in Claude Code's order; a saved model the catalog no
    /// longer lists stays selectable as "(saved)". Without a catalog only
    /// Claude Code's default is offered.
    static func modelOptions(catalog: [ClaudeModelOption], selected: String?) -> [(label: String, value: String)] {
        var options = catalog.map { (label: $0.displayName, value: $0.value) }
        if options.isEmpty { options = [(label: "Claude Code default", value: ClaudeModelCatalog.cliDefaultValue)] }
        if let selected, !options.contains(where: { $0.value == selected }) {
            options.insert((label: selected + " (saved)", value: selected), at: 0)
        }
        return options
    }

    static func effortLabel(_ level: String) -> String {
        switch level {
        case "xhigh": return "Very high"
        default: return level.capitalized
        }
    }

    private var modelSelection: Binding<String> {
        Binding(get: { settings.claudeRunModel ?? ClaudeModelCatalog.cliDefaultValue },
                set: { settings.claudeModel = $0 == ClaudeModelCatalog.cliDefaultValue ? nil : $0 })
    }

    /// Displaying the fallback never writes it: the store is only touched on
    /// an explicit pick (the `set` side).
    private var effortSelection: Binding<String> {
        Binding(get: { settings.claudeRunEffort ?? "" }, set: { settings.claudeEffort = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConcreteSettingPicker(title: "Model",
                                  options: Self.modelOptions(catalog: settings.claudeCatalog,
                                                             selected: settings.claudeRunModel),
                                  selection: modelSelection)
            if let levels = settings.selectedClaudeOption?.efforts, !levels.isEmpty {
                ConcreteSettingPicker(title: "Reasoning",
                                      options: levels.map { (label: Self.effortLabel($0), value: $0) },
                                      selection: effortSelection)
            }
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

import SwiftUI

/// Keys & models → Models → Harness. Laid out like the other Models rows: the
/// title, a one-line summary and a disclosure chevron; the settings open in
/// place under a separator. No separate tab and no Configure button.
// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
@MainActor
struct HarnessModelsCard: View {
    static let groupID = "shared.harness"
    static let checkAgainID = "shared.harness.checkAgain"
    static let headerHeight: CGFloat = 54
    static let headerCornerRadius: CGFloat = 8
    static let title = "Harness"
    static let caption = "Runs the Agent"
    private static let labelWidth: CGFloat = 72

    @ObservedObject var model: HarnessSettingsModel
    @Binding var expanded: Bool
    var focused: FocusState<String?>.Binding
    var agentEnabled: () -> Bool = { UserPreferencesCache.shared.currentAgentEnabled }
    @State private var checkedOnOpen = false

    private var settings: AgentSettingsStore { model.settings }

    var body: some View {
        MacCard(needsSetup: model.needsSetup(agentEnabled: agentEnabled())) {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded {
                    MacRowSeparator()
                    controls
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                statusLine
            }
            .onKeyPress(.escape) {
                guard expanded else { return .ignored }
                expanded = false
                focused.wrappedValue = Self.groupID
                return .handled
            }
        }
        .task(id: expanded) {
            // The first opening checks the chosen harness and loads its
            // models; nothing runs while the row stays closed.
            guard expanded, !checkedOnOpen else { return }
            checkedOnOpen = true
            await model.refresh()
        }
    }

    // MARK: Closed row

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.title)
                        .font(.system(size: 13))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(Self.caption)
                        .font(.system(size: 10.5))
                        .foregroundStyle(MacSettingsTheme.text3)
                        .lineLimit(1)
                }
                .frame(width: 116, alignment: .leading)
                HStack(spacing: 7) {
                    if let id = model.active {
                        HarnessMark(id: id)
                    }
                    ForEach(Array(model.summaryParts.enumerated()), id: \.offset) { index, part in
                        if index > 0 { Text("·").accessibilityHidden(true) }
                        Text(part).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(MacSettingsTheme.text2)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .frame(width: 12)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight)
            .contentShape(Rectangle())
        }
        // The whole 54 pt row answers the pointer, a press and keyboard focus,
        // like the other Models controls.
        .buttonStyle(MacButtonInteractionStyle(highlight: MacSettingsTheme.text,
                                               focused: focused.wrappedValue == Self.groupID,
                                               cornerRadius: Self.headerCornerRadius))
        .focused(focused, equals: Self.groupID)
        .accessibilityLabel(Self.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(expanded ? "Hide harness settings" : "Show harness settings")
        .onKeyPress(.return) {
            expanded.toggle()
            return .handled
        }
    }

    private var accessibilityValue: String {
        let state = expanded ? "Expanded" : "Collapsed"
        let setup = model.needsSetup(agentEnabled: agentEnabled()) ? ", Needs setup" : ""
        return "\(state), \(model.summaryParts.joined(separator: ", "))\(setup)"
    }

    // MARK: Open row

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Harness") {
                MacMenu(title: model.active.map(HarnessSettingsModel.name) ?? "Choose…", minWidth: 220, maxWidth: 220) {
                    ForEach(AgentProviderStore.harnesses, id: \.self) { id in
                        Button {
                            Task { await model.choose(id) }
                        } label: {
                            if id == model.active {
                                Label(HarnessSettingsModel.name(id), systemImage: "checkmark")
                            } else {
                                Text(HarnessSettingsModel.name(id))
                            }
                        }
                    }
                }
                .disabled(model.isChecking)
            }
            switch model.active {
            case .claude: claudeControls
            case .codex: codexControls
            case .opencode, .native, nil: EmptyView()
            }
        }
    }

    @ViewBuilder
    private var claudeControls: some View {
        let options = AgentControlsClaude.modelOptions(catalog: settings.claudeCatalog, selected: settings.claudeRunModel)
        field("Model") {
            MacPopup(items: options.map { .init(value: $0.value, label: $0.label) },
                     selection: Binding(get: { settings.claudeRunModel ?? ClaudeModelCatalog.cliDefaultValue },
                                        set: { settings.claudeModel = $0 == ClaudeModelCatalog.cliDefaultValue ? nil : $0 }),
                     minWidth: 220, maxWidth: 220)
                .accessibilityLabel("Model")
        }
        if let levels = settings.selectedClaudeOption?.efforts, !levels.isEmpty {
            field("Reasoning") {
                MacPopup(items: levels.map { .init(value: $0, label: HarnessSettingsModel.effortLabel($0)) },
                         selection: Binding(get: { settings.claudeRunEffort ?? "" }, set: { settings.claudeEffort = $0 }),
                         minWidth: 220, maxWidth: 220)
                    .accessibilityLabel("Reasoning")
            }
        }
    }

    @ViewBuilder
    private var codexControls: some View {
        let options = AgentControlsCodex.modelOptions(catalog: settings.codexCatalog, selected: settings.selectedCodexModel)
        field("Model") {
            MacPopup(items: options.map { .init(value: $0.value, label: $0.label) },
                     selection: Binding(get: { settings.selectedCodexModel ?? "" }, set: { settings.codexModel = $0 }),
                     minWidth: 220, maxWidth: 220)
                .accessibilityLabel("Model")
        }
        if let efforts = settings.selectedCodexOption?.efforts, !efforts.isEmpty {
            field("Reasoning") {
                MacPopup(items: efforts.map { .init(value: $0, label: HarnessSettingsModel.effortLabel($0)) },
                         selection: Binding(get: { settings.options(for: .codex).effort ?? "" },
                                            set: { settings.codexEffort = $0 }),
                         minWidth: 220, maxWidth: 220)
                    .accessibilityLabel("Reasoning")
            }
        }
        if let tier = model.fastTier {
            field("Fast mode") {
                HStack(spacing: 10) {
                    MacSwitch(isOn: Binding(get: { model.fastModeOn }, set: { model.setFastMode($0) }),
                              size: .compact, label: "Fast mode")
                    if let description = tier.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(MacSettingsTheme.text2)
                .frame(width: Self.labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: MacPopupMetrics.height)
    }

    // MARK: Status

    @ViewBuilder
    private var statusLine: some View {
        if let line = model.statusLine, expanded || line.isProblem {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.isChecking { ProgressView().controlSize(.mini) }
                Text(line.text).fixedSize(horizontal: false, vertical: true)
                if (model.attempted ?? model.active) != nil {
                    // Stays in place while a check runs, disabled, so the line
                    // does not jump; hover, press and focus as other links.
                    Button { Task { await model.refresh() } } label: {
                        Text("Check again")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                    }
                    .buttonStyle(MacButtonInteractionStyle(highlight: MacSettingsTheme.accent,
                                                           focused: focused.wrappedValue == Self.checkAgainID,
                                                           cornerRadius: 5))
                    .foregroundStyle(MacSettingsTheme.accent)
                    .focused(focused, equals: Self.checkAgainID)
                    .disabled(model.isChecking)
                    .opacity(model.isChecking ? 0.42 : 1)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(line.isProblem ? MacSettingsTheme.orange : MacSettingsTheme.text2)
            .padding(.horizontal, 14)
            .padding(.bottom, 9)
            .accessibilityElement(children: .combine)
        }
    }
}

/// The harness's own mark beside its name.
@MainActor
private struct HarnessMark: View {
    let id: CLIProviderID

    var body: some View {
        switch id {
        case .claude: ProviderBrandIcon(brand: .agent(.claude), size: 13)
        case .codex: ProviderBrandIcon(brand: .agent(.codex), size: 13)
        case .opencode, .native: EmptyView()
        }
    }
}

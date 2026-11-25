import SwiftUI

/// Settings -> Other -> Agent. Replaces the former Agents tab with two rows:
/// one switch that both enables the Agent shortcuts and connects the native
/// Agent, and the separate "Allow file edits and commands" switch. The model
/// is chosen in API & Models; the workspace path is in the Whytap plugin's
/// `whytap_get_state`; Coding tools moved to Integrations.
// WHY: .project-docs/decisions/2026-11-20-other-feature-videos.md
@MainActor
struct AgentOtherSection: View {
    @ObservedObject var viewModel: AgentModeViewModel
    @ObservedObject var settings: AgentSettingsStore
    @ObservedObject var store: AgentProviderStore
    private let agentEnabledProvider: () -> Bool
    private let onAgentToggle: (Bool) -> Void
    private let openAPIAndModels: (AIFeature) -> Void
    private let shortcuts: @MainActor () -> HotkeyConfiguration
    private let highlighted: Bool
    @State private var agentEnabled: Bool
    @State private var problem: Problem?

    enum Problem: Equatable {
        case noModel
        case connectFailed

        var message: String {
            switch self {
            case .noModel: return "Choose an Agent model in API & Models."
            case .connectFailed: return "Couldn’t connect the Agent. Check its model and key in API & Models."
            }
        }
    }

    static let title = "Agent"
    static let subtitle = "Ask by text or voice. Shortcuts in Hotkeys."
    static let actionsTitle = "Allow file edits and commands"
    static let actionsSubtitle = "Uses your Mac user’s permissions. Off blocks edits and shell commands."

    init(viewModel: AgentModeViewModel, settings: AgentSettingsStore, store: AgentProviderStore,
         agentEnabled: @escaping () -> Bool, onAgentToggle: @escaping (Bool) -> Void,
         openAPIAndModels: @escaping (AIFeature) -> Void,
         shortcuts: @escaping @MainActor () -> HotkeyConfiguration = { HotkeyPreferences.shared.configuration },
         highlighted: Bool = false) {
        self.viewModel = viewModel
        self.settings = settings
        self.store = store
        self.agentEnabledProvider = agentEnabled
        self.onAgentToggle = onAgentToggle
        self.openAPIAndModels = openAPIAndModels
        self.shortcuts = shortcuts
        self.highlighted = highlighted
        _agentEnabled = State(initialValue: agentEnabled())
    }

    /// On only when the shortcuts are enabled AND the native Agent is connected.
    static func isOn(enabled: Bool, activeProvider: CLIProviderID?) -> Bool {
        enabled && activeProvider == .native
    }

    static func videoShortcuts(_ configuration: HotkeyConfiguration) -> [FeatureVideoShortcut] {
        [FeatureVideoShortcut(label: "Text", contents: configuration.agentTextShortcut.contents),
         FeatureVideoShortcut(label: "Voice", contents: configuration.agentVoiceShortcut.contents)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: Self.title)
            MacCard {
                MacRow(title: Self.title, subtitle: Self.subtitle) {
                    FeatureVideoButton(video: .agent, shortcuts: { Self.videoShortcuts(shortcuts()) })
                } trailing: {
                    HStack(spacing: 10) {
                        if viewModel.connecting != nil { ProgressView().controlSize(.small) }
                        MacSwitch(isOn: Binding(get: { Self.isOn(enabled: agentEnabled, activeProvider: store.activeProvider) },
                                                set: { setAgent($0) }),
                                  label: Self.title)
                            .disabled(viewModel.connecting != nil)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(highlighted ? MacSettingsTheme.selection.opacity(0.35) : Color.clear)
                )
                if let problem {
                    HStack(spacing: 10) {
                        Text(problem.message)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        MacButton(title: "Choose model", style: .default) { openAPIAndModels(.agent) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                }
                MacRowSeparator()
                MacRow(title: Self.actionsTitle, subtitle: Self.actionsSubtitle) {
                    MacSwitch(isOn: $settings.openCodeAllowActions, label: Self.actionsTitle)
                }
            }
        }
        .onAppear { agentEnabled = agentEnabledProvider() }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyCapabilityFlagsChanged)) { _ in
            agentEnabled = agentEnabledProvider()
        }
    }

    private func setAgent(_ on: Bool) {
        problem = nil
        if !on { agentEnabled = false }
        Task {
            problem = await Self.turn(on, viewModel: viewModel, settings: settings, store: store,
                                      onAgentToggle: { agentEnabled = $0; onAgentToggle($0) })
        }
    }

    /// Turns the Agent on (connects the native Agent; needs a chosen model)
    /// or off. Returns why it did not turn on. Shared by Other and the
    /// Agent's screen in Features.
    static func turn(_ on: Bool, viewModel: AgentModeViewModel, settings: AgentSettingsStore,
                     store: AgentProviderStore, onAgentToggle: (Bool) -> Void) async -> Problem? {
        guard on else {
            onAgentToggle(false)
            viewModel.disconnect()
            return nil
        }
        guard settings.selectedOpenCodeModel != nil else { return .noModel }
        if store.activeProvider != .native { await viewModel.connect(.native) }
        guard store.activeProvider == .native else { return .connectFailed }
        onAgentToggle(true)
        return nil
    }
}

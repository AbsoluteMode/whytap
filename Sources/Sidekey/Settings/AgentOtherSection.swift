import SwiftUI

/// The Agent's switch and its words, shared by the Agent's screen in
/// Features and onboarding. It was a group in Settings -> Other until every
/// feature got its own screen; the name is kept for the callers.
/// The model is chosen on the Agent screen (or in API & Models); the
/// workspace path is in the Whytap plugin's `whytap_get_state`.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
@MainActor
enum AgentOtherSection {
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

    /// On only when the shortcuts are enabled AND the native Agent is connected.
    static func isOn(enabled: Bool, activeProvider: CLIProviderID?) -> Bool {
        enabled && activeProvider == .native
    }

    static func videoShortcuts(_ configuration: HotkeyConfiguration) -> [FeatureVideoShortcut] {
        [FeatureVideoShortcut(label: "Text", contents: configuration.agentTextShortcut.contents),
         FeatureVideoShortcut(label: "Voice", contents: configuration.agentVoiceShortcut.contents)]
    }

    /// Turns the Agent on (connects the native Agent; needs a chosen model)
    /// or off. Returns why it did not turn on.
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

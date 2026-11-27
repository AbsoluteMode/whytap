import SwiftUI

/// The Agent's switch and its words, shared by the Agent's screen in
/// Features and onboarding. It was a group in Settings -> Other until every
/// feature got its own screen; the name is kept for the callers.
/// The harness (Claude Code or Codex) and its model are chosen in Keys &
/// models → Models → Harness; the workspace path is in the Whytap plugin's
/// `whytap_get_state`.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
@MainActor
enum AgentOtherSection {
    enum Problem: Equatable {
        case noHarness

        var message: String {
            switch self {
            case .noHarness: return "Choose Claude Code or Codex under Harness in Keys & models → Models."
            }
        }
    }

    static let title = "Agent"
    static let subtitle = "Ask by text or voice. Shortcuts in Hotkeys."
    static let actionsTitle = "Allow file edits and commands"
    static let actionsSubtitle = "On: your Claude Code or Codex reviews each action itself. Off: it reads, searches and answers only."

    /// On only when the shortcuts are enabled AND a harness (Claude Code or
    /// Codex) is chosen.
    static func isOn(enabled: Bool, activeProvider: CLIProviderID?) -> Bool {
        enabled && activeProvider.map(AgentProviderStore.harnesses.contains) == true
    }

    static func videoShortcuts(_ configuration: HotkeyConfiguration) -> [FeatureVideoShortcut] {
        [FeatureVideoShortcut(label: "Text", contents: configuration.agentTextShortcut.contents),
         FeatureVideoShortcut(label: "Voice", contents: configuration.agentVoiceShortcut.contents)]
    }

    /// Turns the Agent on (needs a chosen harness) or off. Turning it off keeps
    /// the harness: that is a Keys & models choice. Returns why it did not turn on.
    static func turn(_ on: Bool, store: AgentProviderStore, onAgentToggle: (Bool) -> Void) -> Problem? {
        guard on else {
            onAgentToggle(false)
            return nil
        }
        guard isOn(enabled: true, activeProvider: store.activeProvider) else { return .noHarness }
        onAgentToggle(true)
        return nil
    }
}

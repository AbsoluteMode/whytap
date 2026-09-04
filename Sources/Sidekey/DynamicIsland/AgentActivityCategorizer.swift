import Foundation

/// Maps raw agent activity signals to the action-category label shown in
/// the island agent slot ("читает документацию", "ищет в интернете").
/// Today labels arrive ready-made from the CLI event mapper
/// (`AskResponseStore.currentToolLabel`); a richer tool-call -> category
/// mapping can be added behind this same entry point.
enum AgentActivityCategorizer {
    static func label(toolLabel: String?, status: AgentLocalStatus) -> String {
        if let toolLabel, !toolLabel.isEmpty { return toolLabel }
        switch status {
        case .transcribing: return "transcribing…"
        case .uploading: return "sending…"
        case .thinking: return "thinking…"
        default: return "working…"
        }
    }
}

import Foundation

/// One confirmed change the built-in Agent made in Whytap, as the app shows
/// it: the operation that ran and the app-owned line built from the saved
/// value ("Vocab + whytap", "Hotkey: Shot — ⌥S", "Toolbox − Monitor"); a
/// model change says what it was and what it is ("Agent: old → new").
/// WHY: .project-docs/decisions/2026-11-24-agent-step-drops.md
struct AgentAppStep: Equatable, Sendable {
    /// The app-control operation without its prefix: "vocab_add".
    let operation: String
    let line: String

    /// The mark in the step's drop: which part of Whytap changed.
    var symbol: String {
        switch operation {
        case "vocab_add", "vocab_remove": return "book.closed"
        case "filler_add", "filler_remove": return "scissors"
        case "todo_add", "todo_update": return "checklist"
        case "toolbox_set": return "square.grid.2x2"
        case "hotkey_set": return "keyboard"
        case "set_model", "set_provider": return "cpu"
        default: return "slider.horizontal.3"
        }
    }

    /// The line split at its first sign: what changed, the sign, the saved
    /// value. A line without a sign is all value.
    var parts: (subject: String, sign: String, value: String) {
        let signs = [" + ", " − ", " → ", ": "]
        let first = signs.compactMap { sign in line.range(of: sign).map { (sign, $0) } }
            .min { $0.1.lowerBound < $1.1.lowerBound }
        guard let (sign, range) = first else { return ("", "", line) }
        return (String(line[..<range.lowerBound]), sign, String(line[range.upperBound...]))
    }

    /// What History keeps for a turn that showed only drops: the same lines,
    /// as Markdown that renders exactly as saved.
    static func historyMarkdown(_ steps: [AgentAppStep]) -> String {
        steps.map { NativeAgentAppControl.markdownLiteral($0.line) }.joined(separator: "\n\n")
    }
}

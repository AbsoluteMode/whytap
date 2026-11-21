import Foundation

/// The running caption of the compact subtitle overlay: the newest translated
/// phrases as one paragraph, as in the original RealtimeTranslator overlay.
/// The view shows at most five lines and clips older text out at the top.
// WHY: .project-docs/decisions/2026-11-21-compact-subtitle-overlay.md
enum SubtitleCaption {
    /// Enough phrases to fill five caption lines; older ones are never visible.
    static let maxPhrases = 8

    static func text(lines: [SubtitleLine], phase: SubtitlePhase, issue: TranslationIssue?) -> String? {
        if let issue { return issue.message }
        let translated = lines.compactMap(\.translation)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(maxPhrases)
        if !translated.isEmpty { return translated.joined(separator: " ") }
        switch phase {
        case .connecting: return "Connecting…"
        case .listening: return lines.isEmpty ? "Waiting for speech…" : "Translating…"
        case .finishing: return lines.isEmpty ? nil : "Translating…"
        case .idle, .failed: return nil
        }
    }
}

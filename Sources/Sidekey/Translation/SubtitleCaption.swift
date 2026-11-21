import Foundation

/// What the compact subtitle overlay shows: the newest phrases as pairs, the
/// original on the left and its translation on the right, newest at the
/// bottom; or one status line while there is nothing to pair.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md,
// .project-docs/decisions/2026-11-21-compact-subtitle-overlay.md
enum SubtitleCaption {
    /// Enough pairs to fill the box; older pairs are never visible.
    static let maxPairs = 4

    struct Row: Identifiable, Equatable {
        enum Translation: Equatable {
            /// Not back yet, or the phrase is still being heard.
            case pending
            case text(String)
            /// The translation failed or timed out: only the original shows.
            case failed
        }

        let id: UUID
        let source: String
        let translation: Translation
        /// The phrase still being heard (display only, not yet translated).
        let isLive: Bool
    }

    /// The live row keeps one identity, so it updates in place while growing.
    static let liveID = UUID(uuidString: "00000000-0000-0000-0000-00000000117E")!

    static func rows(lines: [SubtitleLine], live: String) -> [Row] {
        var rows = lines.compactMap { line -> Row? in
            let source = line.source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty else { return nil }
            let translation: Row.Translation
            if let value = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                translation = .text(value)
            } else if line.failed || line.translation != nil {
                // A blank answer is not a translation: keep the original.
                translation = .failed
            } else {
                translation = .pending
            }
            return Row(id: line.id, source: source, translation: translation, isLive: false)
        }
        let heard = live.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heard.isEmpty {
            rows.append(Row(id: liveID, source: heard, translation: .pending, isLive: true))
        }
        return Array(rows.suffix(maxPairs))
    }

    /// The one line shown instead of pairs: an error, or the session's state
    /// while no phrase has been heard yet.
    static func status(hasRows: Bool, phase: SubtitlePhase, issue: TranslationIssue?) -> String? {
        if let issue { return issue.message }
        guard !hasRows else { return nil }
        switch phase {
        case .connecting: return "Connecting…"
        case .listening: return "Waiting for speech…"
        case .idle, .finishing, .failed: return nil
        }
    }
}

import Foundation

/// What the compact subtitle overlay shows: the newest phrases as pairs, the
/// original on the left and its translation on the right, newest at the
/// bottom; or one status line while there is nothing to pair.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md,
// .project-docs/decisions/2026-11-21-compact-subtitle-overlay.md
enum SubtitleCaption {
    /// More pairs than the box holds: the oldest visible one leaves at the top
    /// a line at a time as new text pushes it up, never as a whole pair.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
    static let maxPairs = 12

    struct Row: Identifiable, Equatable {
        enum Translation: Equatable {
            /// Not back yet, or the phrase is still being heard.
            case pending
            case text(String)
            /// The translation failed or timed out: only the original shows.
            case failed
            /// A speech translator is still saying it (dim, still growing).
            case live(String)
        }

        let id: UUID
        let source: String
        let translation: Translation
        /// The phrase still being heard (display only, not yet translated).
        let isLive: Bool
        /// Position in the session, stable while older pairs leave, so an
        /// alternating mark never moves from one pair to another.
        var ordinal = 0
    }

    /// The live row's identity when the caller has none of its own.
    static let liveID = UUID(uuidString: "00000000-0000-0000-0000-00000000117E")!

    /// `liveID` is the identity the next committed pair will take, so the live
    /// row settles in place.
    static func rows(lines: [SubtitleLine], live: String, liveTranslation: String = "",
                     liveID: UUID = SubtitleCaption.liveID) -> [Row] {
        var rows = lines.compactMap { line -> Row? in
            let source = line.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasTranslation = !(line.translation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // A speech translator may translate a phrase it reported no
            // original for; a pair needs at least one side.
            guard !source.isEmpty || hasTranslation else { return nil }
            let translation: Row.Translation
            if let value = line.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                translation = .text(value)
            } else if line.failed || line.translation != nil {
                // A blank answer is not a translation: keep the original.
                translation = .failed
            } else {
                translation = .pending
            }
            return Row(id: line.id, source: source, translation: translation, isLive: false, ordinal: line.ordinal)
        }
        let heard = live.trimmingCharacters(in: .whitespacesAndNewlines)
        let spoken = liveTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !heard.isEmpty || !spoken.isEmpty {
            rows.append(Row(id: liveID, source: heard, translation: spoken.isEmpty ? .pending : .live(spoken),
                            isLive: true, ordinal: (lines.last?.ordinal ?? -1) + 1))
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
        case .finishing: return "Finishing…"
        case .idle, .failed: return nil
        }
    }
}

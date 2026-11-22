import Foundation

/// What the drops right of the island say for one suggestion: the list it
/// changes (icon drop), whether it adds or removes (+/− in a thin circle) and
/// a short action. No explanations.
/// WHY: .project-docs/decisions/2026-11-22-drop-learning-drops.md
struct DropLearningDropContent: Equatable {
    enum List: Equatable {
        case vocab, replace, filler

        /// SF Symbol of the icon drop.
        var symbol: String {
            switch self {
            case .vocab: return "book.closed"
            case .replace: return "arrow.left.arrow.right"
            case .filler: return "scissors"
            }
        }
    }

    /// One run of the action line.
    enum Run: Equatable {
        case plain(String)
        case emphasis(String)
        case arrow
    }

    let list: List
    let adds: Bool
    let runs: [Run]
    /// The route's real limit, only when the Vocab list is full.
    let detail: String?
    /// Y opens Vocab instead of saving (the list is full).
    let yesOpens: Bool

    /// Spoken by VoiceOver for the whole row.
    var accessibilityLabel: String {
        let line = runs.map { run -> String in
            switch run {
            case .plain(let text), .emphasis(let text): return text
            case .arrow: return " to "
            }
        }.joined()
        return [line, detail].compactMap { $0 }.joined(separator: ", ")
    }

    static func make(_ candidate: DropLearningCandidate) -> Self {
        switch candidate {
        case .vocabAdd(let term):
            return Self(list: .vocab, adds: true, runs: question("Add", term), detail: nil, yesOpens: false)
        case .vocabRemove(let term):
            return Self(list: .vocab, adds: false, runs: question("Forget", term), detail: nil, yesOpens: false)
        case .replaceAdd(let rule):
            return Self(list: .replace, adds: true, runs: [.plain(rule.heard), .arrow, .emphasis(rule.wanted)],
                        detail: nil, yesOpens: false)
        case .replaceRemove(let rule):
            return Self(list: .replace, adds: false, runs: question("Stop replacing", rule.heard),
                        detail: nil, yesOpens: false)
        case .fillerAdd(let term):
            return Self(list: .filler, adds: true, runs: question("Cut", term), detail: nil, yesOpens: false)
        case .fillerRemove(let term):
            return Self(list: .filler, adds: false, runs: question("Stop cutting", term), detail: nil, yesOpens: false)
        case .vocabFull(let term, let usage):
            return Self(list: .vocab, adds: true, runs: question("Add", term),
                        detail: "Vocab full " + limit(usage), yesOpens: true)
        }
    }

    /// `50/50` for terms, `≈450/450` for estimated tokens.
    static func limit(_ usage: VocabularyBudget.Usage) -> String {
        let prefix = usage.unit == .tokens ? "≈" : ""
        return "\(prefix)\(usage.used)/\(usage.limit)"
    }

    private static func question(_ verb: String, _ term: String) -> [Run] {
        [.plain(verb + " “"), .emphasis(term), .plain("”?")]
    }
}

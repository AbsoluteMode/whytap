import Foundation

/// A word of a text: its spelling and a comparison form (lower case, no
/// diacritics), so case changes are not edits.
struct DropEditToken: Equatable {
    let text: String
    var key: String { Self.key(text) }

    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
    }

    /// Words with letters or digits, keeping inner `'`, `-`, `.`, `+`, `#`
    /// ("don't", "Wi-Fi", "Node.js", "C++", "C#").
    static func tokenize(_ text: String) -> [DropEditToken] {
        let pattern = "[\\p{L}\\p{N}_](?:[\\p{L}\\p{N}_'’\\-.]*[\\p{L}\\p{N}_])?[+#]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { DropEditToken(text: ns.substring(with: $0.range)) }
    }
}

/// One change between what Whytap pasted and what the field holds now.
struct DropEditHunk: Equatable {
    /// Words of the pasted text the user removed or replaced.
    let removed: [DropEditToken]
    /// Words the user typed in their place.
    let inserted: [DropEditToken]
    /// Index in the pasted words where the hunk starts.
    let pastedIndex: Int
}

/// Semi-global word alignment: the pasted text is found inside the field's
/// text (anything before or after it is free), then the user's edits inside it
/// are read as hunks. Deterministic, no model.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
enum DropEditDiff {
    static let maxPastedWords = 400
    static let maxFieldWords = 4_000
    /// More than this share of the pasted words changed = a rewrite, not
    /// corrections: nothing is learned from the take.
    static let maxChangedShare = 0.5

    struct Result: Equatable {
        let hunks: [DropEditHunk]
        let pastedWordCount: Int
        /// The field's words right before and after the matched text: a
        /// filler typed back at the edge of the take lands outside the match.
        let wordBefore: DropEditToken?
        let wordAfter: DropEditToken?
    }

    static func diff(pasted: String, field: String) -> Result? {
        let a = DropEditToken.tokenize(pasted)
        let b = DropEditToken.tokenize(field)
        guard !a.isEmpty, !b.isEmpty, a.count <= maxPastedWords, b.count <= maxFieldWords else { return nil }
        let n = a.count, m = b.count
        let ak = a.map(\.key), bk = b.map(\.key)
        // cost[i][j]: aligning a[0..<i] so that it ends at b[j].
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n { cost[i][0] = i }
        for i in 1...n {
            for j in 1...m {
                let match = cost[i - 1][j - 1] + (ak[i - 1] == bk[j - 1] ? 0 : 1)
                cost[i][j] = min(match, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }
        var end = 0
        // Ties prefer the longer match: a changed last word is a substitution,
        // not a deletion followed by text typed after the take.
        for j in 0...m where cost[n][j] <= cost[n][end] { end = j }
        guard Double(cost[n][end]) <= Double(n) * maxChangedShare else { return nil }

        // Backtrack into aligned pairs, then group runs of non-matches.
        enum Step { case same, sub(Int, Int), del(Int), ins(Int) }
        var steps: [Step] = []
        var i = n, j = end
        while i > 0 {
            // Matches first, then a typed or removed word, then a changed one:
            // "Скажи привет" -> "Скажи типа привет" is an insertion, not
            // "Скажи" changed into "типа".
            if j > 0, ak[i - 1] == bk[j - 1], cost[i][j] == cost[i - 1][j - 1] {
                steps.append(.same); i -= 1; j -= 1
            } else if j > 0, cost[i][j] == cost[i][j - 1] + 1 {
                steps.append(.ins(j - 1)); j -= 1
            } else if cost[i][j] == cost[i - 1][j] + 1 {
                steps.append(.del(i - 1)); i -= 1
            } else {
                steps.append(.sub(i - 1, j - 1)); i -= 1; j -= 1
            }
        }
        steps.reverse()
        var hunks: [DropEditHunk] = []
        var removed: [DropEditToken] = [], inserted: [DropEditToken] = []
        var start: Int?
        var pastedCursor = 0
        func flush() {
            if !removed.isEmpty || !inserted.isEmpty {
                hunks.append(DropEditHunk(removed: removed, inserted: inserted, pastedIndex: start ?? pastedCursor))
            }
            removed = []; inserted = []; start = nil
        }
        for step in steps {
            switch step {
            case .same:
                flush(); pastedCursor += 1
            case .sub(let x, let y):
                if start == nil { start = pastedCursor }
                removed.append(a[x]); inserted.append(b[y]); pastedCursor += 1
            case .del(let x):
                if start == nil { start = pastedCursor }
                removed.append(a[x]); pastedCursor += 1
            case .ins(let y):
                if start == nil { start = pastedCursor }
                inserted.append(b[y])
            }
        }
        flush()
        return Result(
            hunks: hunks, pastedWordCount: n,
            wordBefore: j > 0 ? b[j - 1] : nil, wordAfter: end < m ? b[end] : nil
        )
    }
}

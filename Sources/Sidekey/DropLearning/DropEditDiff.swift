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
        let ns = text as NSString
        return ranges(text).map { DropEditToken(text: ns.substring(with: $0)) }
    }

    /// Where each word of `tokenize` sits (UTF-16 ranges).
    static func ranges(_ text: String) -> [NSRange] {
        let pattern = "[\\p{L}\\p{N}_](?:[\\p{L}\\p{N}_'’\\-.]*[\\p{L}\\p{N}_])?[+#]*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
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

/// Word alignment of the pasted text with the field. The first time the
/// paste is seen it must appear verbatim somewhere in the field (semi-global:
/// anything before or after it is free); the field's words before and after
/// it are kept as the paste's `Context`. Later reads compare the paste only
/// with the words between that context (global alignment), so text typed or
/// cut at the paste's edges and an older draft around it stay apart.
/// Deterministic, no model.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
enum DropEditDiff {
    static let maxPastedWords = 400
    static let maxFieldWords = 4_000
    /// More than this share of the kept pasted words changed = a rewrite,
    /// not corrections: nothing is learned from the take. Words cut from the
    /// start or the end of the take (a made-up tail the provider added) and
    /// words typed before or after it are not counted.
    // WHY: .project-docs/decisions/2026-11-22-drop-learning-cut-tail.md
    static let maxChangedShare = 0.5

    /// The field's words (comparison keys) before and after the paste when
    /// it was first seen.
    struct Context: Equatable {
        let before: [String]
        let after: [String]
    }

    struct Result: Equatable {
        let hunks: [DropEditHunk]
        let pastedWordCount: Int
        /// The field's words right before and after the matched text when no
        /// context is known: a filler typed back at the edge of the take
        /// lands outside the match.
        let wordBefore: DropEditToken?
        let wordAfter: DropEditToken?
        /// Where the paste sits in this field.
        let context: Context
        /// The paste appears verbatim.
        var isExact: Bool { hunks.isEmpty }
    }

    private enum Step { case same(Int, Int), sub(Int, Int), del(Int), ins(Int) }

    static func diff(pasted: String, field: String, context: Context? = nil) -> Result? {
        let a = DropEditToken.tokenize(pasted)
        let b = DropEditToken.tokenize(field)
        guard !a.isEmpty, !b.isEmpty, a.count <= maxPastedWords, b.count <= maxFieldWords else { return nil }
        let n = a.count, m = b.count
        let ak = a.map(\.key), bk = b.map(\.key)
        // The region of the field compared with the paste.
        let low: Int, high: Int
        if let context {
            guard context.before.count + context.after.count < m,
                  Array(bk.prefix(context.before.count)) == context.before,
                  Array(bk.suffix(context.after.count)) == context.after else { return nil }
            low = context.before.count
            high = m - context.after.count
        } else {
            low = 0
            high = m
        }
        let width = high - low
        // cost[i][j]: aligning a[0..<i] with the region's first j words. Without
        // a context the field's words before the paste are free (row 0 is 0)
        // and its end is chosen below.
        var cost = [[Int]](repeating: [Int](repeating: 0, count: width + 1), count: n + 1)
        for i in 1...n { cost[i][0] = i }
        if context != nil { for j in 0...width { cost[0][j] = j } }
        for i in 1...n {
            for j in 1...width {
                let match = cost[i - 1][j - 1] + (ak[i - 1] == bk[low + j - 1] ? 0 : 1)
                cost[i][j] = min(match, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }
        var end = width
        if context == nil {
            end = 0
            // Ties prefer the longer match: a changed last word is a
            // substitution, not a deletion followed by text typed after it.
            for j in 0...width where cost[n][j] <= cost[n][end] { end = j }
        }

        // Backtrack into aligned pairs.
        var steps: [Step] = []
        var i = n, j = end
        while i > 0 || (context != nil && j > 0) {
            // Matches first, then a typed or removed word, then a changed one:
            // "Скажи привет" -> "Скажи типа привет" is an insertion, not
            // "Скажи" changed into "типа".
            if i > 0, j > 0, ak[i - 1] == bk[low + j - 1], cost[i][j] == cost[i - 1][j - 1] {
                steps.append(.same(i - 1, low + j - 1)); i -= 1; j -= 1
            } else if j > 0, cost[i][j] == cost[i][j - 1] + 1 {
                steps.append(.ins(low + j - 1)); j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                steps.append(.del(i - 1)); i -= 1
            } else {
                steps.append(.sub(i - 1, low + j - 1)); i -= 1; j -= 1
            }
        }
        steps.reverse()
        let start = low + j
        guard let first = steps.firstIndex(where: { if case .same = $0 { return true } else { return false } }),
              let last = steps.lastIndex(where: { if case .same = $0 { return true } else { return false } })
        else { return nil }

        // Edges: before the first and after the last matched word. Changed
        // words there sit next to the kept text; the rest of the edge was
        // cut (pasted words) or typed around the paste (field words).
        let lead = edge(Array(steps[..<first]), ak: ak, bk: bk, leading: true)
        let tail = edge(Array(steps[(last + 1)...]), ak: ak, bk: bk, leading: false)
        let middle = Array(steps[first...last])
        let changedInside = middle.filter { if case .same = $0 { return false } else { return true } }.count
        let cutWords = lead.cut.count + tail.cut.count
        let kept = n - cutWords
        func isChange(_ step: Step) -> Bool { if case .same = step { return false } else { return true } }
        let changed = changedInside + lead.changed.filter(isChange).count + tail.changed.filter(isChange).count
        guard kept > 0, Double(changed) <= Double(kept) * maxChangedShare else { return nil }

        var hunks: [DropEditHunk] = []
        func hunk(_ removed: [Int], _ inserted: [Int]) {
            guard !removed.isEmpty || !inserted.isEmpty else { return }
            hunks.append(DropEditHunk(removed: removed.map { a[$0] }, inserted: inserted.map { b[$0] },
                                      pastedIndex: removed.first ?? 0))
        }
        // Cut words and typed words are separate hunks: neither is a
        // substitution of the other.
        hunk(lead.cut, [])
        hunk([], lead.typed)
        var removed: [Int] = [], inserted: [Int] = []
        func flush() { hunk(removed, inserted); removed = []; inserted = [] }
        for step in lead.changed + middle + tail.changed {
            switch step {
            case .same: flush()
            case .sub(let x, let y): removed.append(x); inserted.append(y)
            case .del(let x): removed.append(x)
            case .ins(let y): inserted.append(y)
            }
        }
        flush()
        hunk(tail.cut, [])
        hunk([], tail.typed)
        let resolved = context ?? Context(before: Array(bk[..<start]), after: Array(bk[end...]))
        // The word right next to the take: without a context, the field word
        // outside the match; with one, the typed word nearest the take inside
        // the watched region (typed since the paste, never an older draft),
        // even when the whole typed run is too long to be one edit.
        let before: DropEditToken? = context == nil
            ? (start > 0 ? b[start - 1] : nil)
            : lead.typed.last.map { b[$0] }
        let after: DropEditToken? = context == nil
            ? (end < m ? b[end] : nil)
            : tail.typed.first.map { b[$0] }
        return Result(hunks: hunks, pastedWordCount: n, wordBefore: before, wordAfter: after, context: resolved)
    }

    /// One place where the paste appears verbatim: its context and the index
    /// of the field word right after it.
    struct Place: Equatable {
        let context: Context
        let end: Int
    }

    /// Every place the paste appears verbatim in the field, in field order.
    /// More than one (a new paste next to an identical older draft) is
    /// ambiguous unless the caret tells which copy was just pasted.
    // WHY: .project-docs/decisions/2026-11-22-drop-learning-cut-tail.md
    static func exactPlaces(pasted: String, field: String) -> [Place] {
        let ak = DropEditToken.tokenize(pasted).map(\.key)
        let bk = DropEditToken.tokenize(field).map(\.key)
        guard !ak.isEmpty, ak.count <= maxPastedWords, bk.count <= maxFieldWords, ak.count <= bk.count else { return [] }
        return (0...(bk.count - ak.count)).compactMap { start in
            guard Array(bk[start..<(start + ak.count)]) == ak else { return nil }
            let end = start + ak.count
            return Place(context: Context(before: Array(bk[..<start]), after: Array(bk[end...])), end: end)
        }
    }

    /// The number of field words before a caret position (UTF-16 offset):
    /// the `end` of the place the caret sits right after. Only a caret
    /// between words counts (after a word's last character, before the next
    /// word's first); a caret inside a word proves no place.
    static func wordCount(_ field: String, before caret: Int) -> Int? {
        let ns = field as NSString
        guard caret >= 0, caret <= ns.length else { return nil }
        let ranges = DropEditToken.ranges(field)
        if ranges.contains(where: { $0.location < caret && caret < NSMaxRange($0) }) { return nil }
        return ranges.filter { NSMaxRange($0) <= caret }.count
    }

    /// An edge run rebuilt so that its changed pairs sit next to the kept
    /// text and its cut and typed words are outermost. The run's own number
    /// of changed pairs is kept, so its cost is never higher.
    private static func edge(_ run: [Step], ak: [String], bk: [String], leading: Bool)
        -> (changed: [Step], cut: [Int], typed: [Int]) {
        var pastedWords: [Int] = [], fieldWords: [Int] = []
        var pairs = 0
        for step in run {
            switch step {
            case .same(let x, let y): pastedWords.append(x); fieldWords.append(y)
            case .sub(let x, let y): pastedWords.append(x); fieldWords.append(y); pairs += 1
            case .del(let x): pastedWords.append(x)
            case .ins(let y): fieldWords.append(y)
            }
        }
        let p = leading ? Array(pastedWords.suffix(pairs)) : Array(pastedWords.prefix(pairs))
        let f = leading ? Array(fieldWords.suffix(pairs)) : Array(fieldWords.prefix(pairs))
        let changed: [Step] = zip(p, f).map { ak[$0] == bk[$1] ? .same($0, $1) : .sub($0, $1) }
        let cut = leading ? Array(pastedWords.dropLast(pairs)) : Array(pastedWords.dropFirst(pairs))
        let typed = leading ? Array(fieldWords.dropLast(pairs)) : Array(fieldWords.dropFirst(pairs))
        return (changed, cut, typed)
    }
}

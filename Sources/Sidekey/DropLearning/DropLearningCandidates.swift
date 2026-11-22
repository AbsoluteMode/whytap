import Foundation

/// One thing Whytap could offer after the user corrected a take. Plain text
/// lives only in memory; the ledger keeps a salted hash of `ledgerKey`.
enum DropLearningCandidate: Equatable {
    case vocabAdd(term: String)
    case vocabRemove(term: String)
    /// The provider writes `heard`; the user wants `wanted`.
    case replaceAdd(DropReplacement)
    /// A rule the user keeps undoing.
    case replaceRemove(DropReplacement)
    case fillerAdd(term: String)
    /// "Stop cutting “типа”": a filler the user types back.
    case fillerRemove(term: String)
    /// The term would help but the current route's list is full.
    case vocabFull(term: String, usage: VocabularyBudget.Usage)

    /// The kind as a fixed name, for the reason counters.
    var kind: String {
        switch self {
        case .vocabAdd: return "vocabAdd"
        case .vocabRemove: return "vocabRemove"
        case .replaceAdd: return "replaceAdd"
        case .replaceRemove: return "replaceRemove"
        case .fillerAdd: return "fillerAdd"
        case .fillerRemove: return "fillerRemove"
        case .vocabFull: return "vocabFull"
        }
    }

    var ledgerKey: String {
        switch self {
        case .vocabAdd(let term): return "vocab+|" + DropEditToken.key(term)
        case .vocabRemove(let term): return "vocab-|" + DropEditToken.key(term)
        case .replaceAdd(let rule): return "replace+|" + DropEditToken.key(rule.heard) + "|" + rule.wanted
        case .replaceRemove(let rule): return "replace-|" + DropEditToken.key(rule.heard)
        case .fillerAdd(let term): return "filler+|" + DropEditToken.key(term)
        case .fillerRemove(let term): return "filler-|" + DropEditToken.key(term)
        // Counted as the same correction as its Vocab add: only what the drop
        // can do differs.
        case .vocabFull(let term, _): return "vocab+|" + DropEditToken.key(term)
        }
    }
}

/// Is a word an ordinary dictionary word of its language? Names and terms are
/// not, which is what Vocab and Replace are for.
@MainActor
protocol DropWordLexicon {
    func isKnownWord(_ word: String) -> Bool
}

/// What one delivered take looked like, kept in memory until the read.
struct DropLearningTake {
    /// Exactly what reached the field (the plain text of a rich paste).
    let pasted: String
    /// The provider's transcript before Smart, Replace and Filler.
    let raw: String
    let mode: TranscriptionMode
    /// Smart translated the take: its words cannot be compared with speech.
    let translated: Bool
    let firedReplacements: [DropReplacement]
    let firedFillers: [String]
    /// How this take's speech request carried Vocab (`.none` for On this Mac,
    /// batch recovery and Retry).
    let vocabTransport: VocabularyTransport
}

/// The user's current lists, read when the field is read.
struct DropLearningLists {
    var vocabulary: [String]
    var fillers: [String]
    var replacements: [DropReplacement]
}

/// Turns the user's edits of one take into candidates. Pure apart from the
/// lexicon. Rules: docs/decisions/2026-11-22-drop-edit-learning.md
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
@MainActor
enum DropLearningClassifier {
    static let maxHunkWords = 3
    static let maxFillerWords = 2
    static let maxFillerLength = 20
    /// Transliterated edit distance over the longer spelling: a correction
    /// sounds like what was heard; anything further is a rewrite.
    static let maxSoundDistance = 0.5

    /// `note` hears why each edit did or did not become a candidate, as
    /// fixed reason names with no words (DropLearningStats).
    static func candidates(
        take: DropLearningTake, field: String, lists: DropLearningLists, lexicon: DropWordLexicon,
        note: (String) -> Void = { _ in }
    ) -> [DropLearningCandidate] {
        guard !take.translated else { note("take.translated"); return [] }
        guard let diff = DropEditDiff.diff(pasted: take.pasted, field: field) else { note("take.rewrite"); return [] }
        if diff.hunks.isEmpty { note("take.unchanged") }
        let rawTokens = DropEditToken.tokenize(take.raw)
        let rawKeys = rawTokens.map(\.key)
        // Parts of hyphenated words ("джефф-модели"): a fix of one part is
        // checked against the part.
        let rawParts = Set(rawTokens.flatMap { hyphenParts($0.text).map(DropEditToken.key) })
        var result: [DropLearningCandidate] = []
        func add(_ candidate: DropLearningCandidate?) {
            if let candidate, !result.contains(where: { $0.ledgerKey == candidate.ledgerKey }) { result.append(candidate) }
        }
        for hunk in diff.hunks {
            guard hunk.removed.count <= maxHunkWords, hunk.inserted.count <= maxHunkWords else {
                note(hunk.inserted.isEmpty ? "cut.long" : "edit.tooLong")
                continue
            }
            switch (hunk.removed.isEmpty, hunk.inserted.isEmpty) {
            case (false, false):
                add(substitution(hunk, take: take, rawKeys: rawKeys, rawParts: rawParts, lists: lists,
                                 lexicon: lexicon, note: note))
            case (false, true):
                add(deletion(hunk.removed, take: take, rawKeys: rawKeys, lists: lists))
            case (true, false):
                add(insertion(hunk.inserted, take: take))
            case (true, true):
                break
            }
        }
        // A filler typed back right before or after the take.
        for edge in [diff.wordBefore, diff.wordAfter].compactMap({ $0 }) {
            add(insertion([edge], take: take))
        }
        return result
    }

    // MARK: - Substitution: a word was heard wrong

    private static func substitution(
        _ hunk: DropEditHunk, take: DropLearningTake, rawKeys: [String], rawParts: Set<String>,
        lists: DropLearningLists, lexicon: DropWordLexicon, note: (String) -> Void
    ) -> DropLearningCandidate? {
        var wrong = phrase(hunk.removed), right = phrase(hunk.inserted)
        var wrongInRaw = contains(rawKeys, phraseKeys: hunk.removed.map(\.key))
        // One part of a hyphenated word fixed ("джефф-модели" ->
        // "jev-модели"): the term is that part ("jev").
        if let (part, fixed) = changedHyphenPart(wrong, right) {
            wrong = part
            right = fixed
            wrongInRaw = wrongInRaw || rawParts.contains(DropEditToken.key(part))
        }
        let wrongKey = DropEditToken.key(wrong), rightKey = DropEditToken.key(right)
        guard wrongKey != rightKey else { note("sub.sameWord"); return nil }
        guard !isInflection(wrongKey, rightKey) else { note("sub.inflection"); return nil }
        guard soundsAlike(wrong, right) else { note("sub.notSoundAlike"); return nil }

        // The user undoes one of our replacements.
        if let rule = take.firedReplacements.first(where: { DropEditToken.key($0.wanted) == wrongKey }) {
            return .replaceRemove(rule)
        }
        // A Vocab term makes the provider write it where it was not said.
        if let term = lists.vocabulary.first(where: { DropEditToken.key($0) == wrongKey }) {
            return .vocabRemove(term: term)
        }
        let replacement = replaceCandidate(heard: wrong, wanted: right, lists: lists, lexicon: lexicon)
        // Smart can make its own mistakes; Vocab only helps with what the
        // provider wrote.
        guard wrongInRaw else { note(replacement == nil ? "sub.notInRawNoReplace" : "sub.notInRaw"); return replacement }
        guard isTermLike(right, replacing: wrong, lexicon: lexicon) else {
            note(replacement == nil ? "sub.notTermNoReplace" : "sub.notTerm")
            return replacement
        }
        let alreadyInVocab = lists.vocabulary.contains { DropEditToken.key($0) == rightKey }
        if alreadyInVocab || take.vocabTransport == .none || right.count > VocabularyCache.maxTermLength {
            note(alreadyInVocab ? "sub.inVocab" : take.vocabTransport == .none ? "sub.noVocabRoute" : "sub.termTooLong")
            return replacement
        }
        if VocabularyBudget.accepts(right, appendedTo: lists.vocabulary, on: take.vocabTransport) {
            return .vocabAdd(term: right)
        }
        if let replacement { return replacement }
        guard let usage = VocabularyBudget.usage(lists.vocabulary, on: take.vocabTransport) else { return nil }
        return .vocabFull(term: right, usage: usage)
    }

    /// Replace never rewrites an ordinary word: it would fire in every text.
    private static func replaceCandidate(
        heard: String, wanted: String, lists: DropLearningLists, lexicon: DropWordLexicon
    ) -> DropLearningCandidate? {
        let words = DropEditToken.tokenize(heard)
        guard !words.isEmpty, !words.allSatisfy({ lexicon.isKnownWord($0.text) }) else { return nil }
        let rule = DropReplacement(heard: heard, wanted: wanted)
        guard DropReplacementStore.validate(rule, against: lists.replacements) == .added else { return nil }
        return .replaceAdd(rule)
    }

    // MARK: - Deletion: a filler the user keeps cutting

    private static func deletion(
        _ removed: [DropEditToken], take: DropLearningTake, rawKeys: [String], lists: DropLearningLists
    ) -> DropLearningCandidate? {
        let term = phrase(removed).lowercased()
        guard removed.count <= maxFillerWords, term.count <= maxFillerLength,
              !term.contains(where: \.isNumber),
              contains(rawKeys, phraseKeys: removed.map(\.key)),
              !lists.vocabulary.contains(where: { DropEditToken.key($0) == DropEditToken.key(term) }),
              !lists.fillers.contains(where: { DropEditToken.key($0) == DropEditToken.key(term) }),
              !take.firedReplacements.contains(where: { DropEditToken.key($0.wanted) == DropEditToken.key(term) })
        else { return nil }
        return .fillerAdd(term: term)
    }

    // MARK: - Insertion: a cut filler typed back

    private static func insertion(_ inserted: [DropEditToken], take: DropLearningTake) -> DropLearningCandidate? {
        let key = DropEditToken.key(phrase(inserted))
        guard let term = take.firedFillers.first(where: { DropEditToken.key($0) == key }) else { return nil }
        return .fillerRemove(term: term)
    }

    // MARK: - Helpers

    static func phrase(_ tokens: [DropEditToken]) -> String { tokens.map(\.text).joined(separator: " ") }

    static func hyphenParts(_ word: String) -> [String] {
        word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
    }

    /// The one differing part of two single hyphenated words with the same
    /// number of parts; nil otherwise.
    static func changedHyphenPart(_ wrong: String, _ right: String) -> (String, String)? {
        guard !wrong.contains(" "), !right.contains(" ") else { return nil }
        let a = hyphenParts(wrong), b = hyphenParts(right)
        guard a.count > 1, a.count == b.count else { return nil }
        let differing = zip(a, b).enumerated().filter { DropEditToken.key($0.element.0) != DropEditToken.key($0.element.1) }
        guard differing.count == 1, let index = differing.first?.offset,
              !a[index].isEmpty, !b[index].isEmpty else { return nil }
        return (a[index], b[index])
    }

    private static func contains(_ haystack: [String], phraseKeys: [String]) -> Bool {
        guard !phraseKeys.isEmpty, haystack.count >= phraseKeys.count else { return false }
        return (0...(haystack.count - phraseKeys.count)).contains {
            Array(haystack[$0..<($0 + phraseKeys.count)]) == phraseKeys
        }
    }

    /// Same stem, different ending ("Сева" / "Севой", "report" / "reports"):
    /// a grammar fix, not a recognition error.
    static func isInflection(_ a: String, _ b: String) -> Bool {
        guard !a.contains(" "), !b.contains(" ") else { return false }
        let common = zip(a, b).prefix { $0 == $1 }.count
        let shorter = min(a.count, b.count)
        return common >= 3 && common >= shorter - 3 && max(a.count, b.count) - common <= 4
    }

    /// Close spelling after transliteration, or the same consonant skeleton
    /// ("клод" -> "klod" -> "klt", "Claude" -> "klt"): English names written in
    /// Cyrillic keep their consonants and lose their vowels. Voiced and
    /// voiceless pairs are one sound ("Джефф" -> "tjf", "jev" -> "tjf"),
    /// because Russian spelling of a heard name often swaps them.
    // WHY: .project-docs/decisions/2026-11-22-drop-learning-cut-tail.md
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let x = latin(a), y = latin(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if Double(levenshtein(x, y)) / Double(max(x.count, y.count)) <= maxSoundDistance { return true }
        let sx = skeleton(x), sy = skeleton(y)
        guard sx.count >= 2, sy.count >= 2 else { return false }
        return Double(levenshtein(sx, sy)) / Double(max(sx.count, sy.count)) <= 0.34
    }

    static func skeleton(_ latin: String) -> String {
        var s = latin
        // "Дж" transliterates to "dz" once the caron is folded away.
        for (from, to) in [("dzh", "j"), ("dz", "j"), ("ph", "f"), ("ck", "k"), ("qu", "kv"), ("x", "ks"),
                           ("c", "k"), ("q", "k"), ("w", "v"), ("j", "dj"), ("h", "")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        let voiceless: [Character: Character] = ["b": "p", "d": "t", "g": "k", "v": "f", "z": "s"]
        var out = ""
        for raw in s where !"aeiouy'".contains(raw) {
            let ch = voiceless[raw] ?? raw
            if out.last != ch { out.append(ch) }
        }
        return out
    }

    /// Names, brands and identifiers: digits, a capital inside a word ("iOS"),
    /// Latin among Cyrillic, a word the system dictionary does not know, or a
    /// capital the user added (not one that only starts a sentence).
    static func isTermLike(_ text: String, replacing wrong: String, lexicon: DropWordLexicon) -> Bool {
        let words = DropEditToken.tokenize(text)
        guard !words.isEmpty else { return false }
        if text.contains(where: \.isNumber) { return true }
        if words.contains(where: { $0.text.dropFirst().contains(where: \.isUppercase) }) { return true }
        let scripts = Set(text.unicodeScalars.compactMap(scriptOf))
        if scripts.count > 1 { return true }
        if words.contains(where: { !lexicon.isKnownWord($0.text.lowercased()) }) { return true }
        let addedCapital = text.first?.isUppercase == true && wrong.first?.isUppercase != true
        return addedCapital
    }

    private static func scriptOf(_ scalar: Unicode.Scalar) -> String? {
        guard CharacterSet.letters.contains(scalar) else { return nil }
        switch scalar.value {
        case 0x0400...0x04FF: return "cyrillic"
        case 0x0041...0x024F: return "latin"
        default: return "other"
        }
    }

    private static func latin(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let folded = latin.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[y.count]
    }
}

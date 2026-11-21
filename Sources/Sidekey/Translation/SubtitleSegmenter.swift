import Foundation

/// Cuts committed provider text into whole phrases for translation. Partials
/// are shown separately (the live original row) and are never billed.
///
/// A phrase ends at a sentence end inside the text (at once), a sentence end at
/// the tail (after a short settle), a pause in the provider's finals, or, for a
/// long phrase without punctuation, at its last clause mark or word boundary.
/// It never cuts inside a word: a text that is still growing keeps its last
/// word until a space, a sentence end or a pause shows the word is complete.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
struct SubtitleSegmenter {
    /// Finals that stop for this long close the phrase (a speaker pause).
    static let pause: TimeInterval = 0.6
    /// A sentence end at the tail waits this long for the next word.
    static let sentenceSettle: TimeInterval = 0.15
    /// A phrase without punctuation is cut at its last clause mark or word
    /// boundary once it is this long (characters) or this old (seconds).
    static let longPhraseCharacters = 60
    static let longPhraseSeconds: TimeInterval = 2.5
    /// A clause cut keeps at least this many characters before the mark.
    static let minimumClause = 20
    /// One bad or very large provider event cannot create an unbounded request.
    static let hardLimit = 300

    private(set) var pending = ""
    private var firstAt: TimeInterval?
    private var lastAt: TimeInterval = 0

    mutating func append(_ text: String, join: BYOKTranscriptJoin, now: TimeInterval) {
        guard !text.isEmpty else { return }
        if pending.isEmpty { firstAt = now }
        if join == .wordBoundary, !pending.isEmpty,
           pending.last?.isWhitespace == false, text.first?.isWhitespace == false {
            pending += " "
        }
        pending += text
        lastAt = now
    }

    /// The next whole phrase, if one is ready. `force` (Stop) takes the rest.
    mutating func take(now: TimeInterval, force: Bool = false) -> String? {
        // A phrase of only punctuation or noise marks ("...", "—") is not
        // speech: drop it and look at what follows.
        while let phrase = takeAny(now: now, force: force) {
            if phrase.contains(where: { $0.isLetter || $0.isNumber }) { return phrase }
        }
        return nil
    }

    private mutating func takeAny(now: TimeInterval, force: Bool) -> String? {
        let text = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { pending = ""; firstAt = nil; return nil }
        let quiet = now - lastAt
        var cut: String.Index?
        if let end = Self.firstSentenceEnd(in: text) {
            cut = end
        } else if Self.endsSentence(text) {
            // A whole sentence: never split it by length, only wait briefly.
            if force || quiet >= Self.sentenceSettle { cut = text.endIndex }
        } else if force || quiet >= Self.pause {
            cut = text.endIndex
        } else if text.count >= Self.longPhraseCharacters || now - (firstAt ?? now) >= Self.longPhraseSeconds {
            cut = Self.clauseCut(in: text) ?? Self.lastWordBoundary(in: text)
        }
        if let current = cut, text.distance(from: text.startIndex, to: current) > Self.hardLimit {
            cut = nil
        }
        if cut == nil, text.count > Self.hardLimit {
            let limit = text.index(text.startIndex, offsetBy: Self.hardLimit)
            let prefix = text[..<limit]
            cut = prefix.lastIndex(where: \.isWhitespace) ?? limit
        }
        guard let split = cut, split > text.startIndex else { return nil }
        let phrase = String(text[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
        pending = String(text[split...]).trimmingCharacters(in: .whitespacesAndNewlines)
        firstAt = pending.isEmpty ? nil : now
        return phrase.isEmpty ? nil : phrase
    }

    // MARK: - Boundaries

    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "»", "]"]
    static let clauseMarks: Set<Character> = [",", ";", ":", "—", "–", "，", "；"]
    /// Words whose trailing period does not end a sentence.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "e.g", "i.e", "jr", "sr", "inc", "ltd", "no", "fig", "approx"
    ]

    static func endsSentence(_ text: String) -> Bool {
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            if closers.contains(text[previous]) { index = previous; continue }
            return terminators.contains(text[previous]) && !isAbbreviation(text, terminatorAt: previous)
        }
        return false
    }

    /// The end (after closing quotes) of the first sentence that is followed by
    /// more text: only a terminator followed by whitespace counts, so "3.5" and
    /// "e.g." in the middle of a phrase stay together.
    static func firstSentenceEnd(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            if terminators.contains(text[index]), !isAbbreviation(text, terminatorAt: index) {
                var end = text.index(after: index)
                while end < text.endIndex, terminators.contains(text[end]) || closers.contains(text[end]) {
                    end = text.index(after: end)
                }
                if end < text.endIndex, text[end].isWhitespace,
                   text[end...].contains(where: { !$0.isWhitespace }) {
                    return end
                }
                index = end
                continue
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// After the last clause mark that is followed by a space and leaves a
    /// phrase of at least `minimumClause` characters.
    static func clauseCut(in text: String) -> String.Index? {
        var best: String.Index?
        var index = text.startIndex
        var offset = 0
        while index < text.endIndex {
            let next = text.index(after: index)
            if clauseMarks.contains(text[index]), offset + 1 >= minimumClause,
               next < text.endIndex, text[next].isWhitespace {
                best = next
            }
            index = next
            offset += 1
        }
        return best
    }

    /// Before the last word, which may still be growing, and before up to
    /// three short function words ("every weight | a little bit"), so a
    /// phrase cut by length still reads as a phrase.
    static func lastWordBoundary(in text: String) -> String.Index? {
        guard var space = text.lastIndex(where: \.isWhitespace) else { return nil }
        for _ in 0..<3 {
            let before = text[..<space]
            guard let previous = before.lastIndex(where: \.isWhitespace) else { break }
            let word = before[before.index(after: previous)...]
            guard isFunctionWord(String(word)),
                  text[..<previous].split(whereSeparator: \.isWhitespace).count >= 3 else { break }
            space = previous
        }
        let before = text[..<space].trimmingCharacters(in: .whitespaces)
        return before.isEmpty ? nil : space
    }

    /// Articles, prepositions, conjunctions and pronouns a phrase should not
    /// end on (English and Russian, the common pair).
    static func isFunctionWord(_ word: String) -> Bool {
        functionWords.contains(word.lowercased().filter(\.isLetter))
    }

    private static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on", "at", "by", "for", "with", "from",
        "as", "that", "which", "who", "if", "than", "then", "is", "are", "was", "were", "be", "we", "you", "i",
        "it", "they", "he", "she", "this", "these", "those", "my", "our", "your", "their", "its", "not", "very",
        "и", "а", "но", "или", "в", "во", "на", "с", "со", "к", "ко", "по", "о", "об", "у", "за", "из", "от",
        "до", "для", "что", "чтобы", "как", "не", "это", "мы", "вы", "я", "он", "она", "они", "его", "её", "их",
    ]

    private static func isAbbreviation(_ text: String, terminatorAt index: String.Index) -> Bool {
        guard text[index] == "." else { return false }
        var start = index
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace { break }
            start = previous
        }
        let word = text[start..<index].lowercased()
        if abbreviations.contains(word) { return true }
        // A single capital letter ("J. Smith") is an initial, not a sentence.
        return word.count == 1 && text[start].isUppercase
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var values = samples.map { sample -> Int16 in
            guard sample.isFinite else { return 0 }
            return Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
        }
        return values.withUnsafeMutableBytes { Data($0) }
    }
}

import Foundation

/// Sentence and clause boundaries of subtitle text, for `SubtitleSpeechPairer`
/// (which cuts pairs at the translation's sentences), and the PCM16 framing
/// of captured system audio. The phrase segmenter of the former Speech + LLM
/// path is gone with it.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md,
// .project-docs/decisions/2026-11-22-subtitle-audio-translate-slot.md
enum SubtitleSegmenter {
    /// A clause cut keeps at least this many characters before the mark.
    static let minimumClause = 20

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

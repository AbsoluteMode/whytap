import Foundation

/// Builds pairs from a speech-translation session's two append-only streams:
/// the original as the model heard it and the translation it speaks. The
/// model shares no segment ids between them, only `elapsed_ms`, its position
/// in the input audio, so pairs are cut on the translation (what is read)
/// and the original is matched to each cut by sentence ends and that clock.
///
/// Measured on a live `gpt-realtime-translate` session (2026-11-21): the two
/// streams keep sentence for sentence, the translation of a sentence ends
/// 0.4-3 s of audio after its original, before the next original ends; the
/// original's period arrives with the next word.
// WHY: .project-docs/decisions/2026-11-21-subtitle-speech-translation.md
struct SubtitleSpeechPairer {
    struct Pair: Equatable {
        var source: String
        var translation: String
    }

    /// No new translation for this long: the speaker paused, the pair closes.
    static let pause: TimeInterval = 1.2
    /// A translation ending in a terminator closes after this quiet time.
    static let sentenceSettle: TimeInterval = 0.3
    /// A translation this long without a sentence end closes at a clause.
    static let longTranslation = 160
    /// Originals whose sentence ended this much audio before the translation's
    /// cut belong to it too: the model merged two sentences into one.
    static let mergeLag = 5_000

    private var source: [(character: Character, elapsed: Int)] = []
    private var translation: [(character: Character, elapsed: Int)] = []
    private var lastElapsed = 0
    private var lastTranslationAt: TimeInterval?
    private var emittedPair = false
    /// A sentence end that arrived at the head of the original after its pair
    /// closed ("guest" | ". So …"): it belongs to the previous pair.
    private(set) var carry = ""

    var liveSource: String { String(source.map(\.character)).trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The live pair's original: the heard text up to its first sentence end.
    /// The original runs ahead of the translation, and the words after that
    /// end usually belong to the next pair; showing them here would move them
    /// out of this row when it settles.
    // WHY: .project-docs/decisions/2026-11-22-subtitle-steady-overlay.md
    var liveSourceHead: String {
        let text = liveSource
        guard let end = SubtitleSegmenter.firstSentenceEnd(in: text), end < text.endIndex else { return text }
        return text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The translation still being spoken, whole words only: the model
    /// streams parts of words ("ошиб" + "лась"), and a fragment is never shown.
    var liveTranslation: String {
        let text = String(translation.map(\.character))
        guard let last = text.last, !last.isWhitespace, !SubtitleSegmenter.clauseMarks.contains(last),
              !SubtitleSegmenter.endsSentence(text) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let space = text.lastIndex(where: \.isWhitespace) else { return "" }
        return text[..<space].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func addSource(_ text: String, elapsedMs: Int?) {
        let elapsed = elapsedMs ?? lastElapsed
        lastElapsed = max(lastElapsed, elapsed)
        var text = Substring(text)
        if source.allSatisfy({ $0.character.isWhitespace }), emittedPair {
            // Punctuation that closes the previous pair's original.
            let head = text.prefix { Self.leading.contains($0) || $0.isWhitespace }
            if head.contains(where: { !$0.isWhitespace }) {
                carry += head.filter { !$0.isWhitespace }
                text = text.dropFirst(head.count)
            }
        }
        source += text.map { ($0, elapsed) }
    }

    mutating func addTranslation(_ text: String, elapsedMs: Int?, now: TimeInterval) {
        let elapsed = elapsedMs ?? lastElapsed
        lastElapsed = max(lastElapsed, elapsed)
        translation += text.map { ($0, elapsed) }
        lastTranslationAt = now
    }

    /// The session broke off: drop a word the model had only begun, so the
    /// pairs kept on screen never end in a fragment.
    mutating func dropUnfinishedWord() {
        let text = String(translation.map(\.character))
        guard let last = text.last, !last.isWhitespace, !SubtitleSegmenter.clauseMarks.contains(last),
              !SubtitleSegmenter.endsSentence(text) else { return }
        let keep = text.lastIndex(where: \.isWhitespace).map { text.distance(from: text.startIndex, to: $0) } ?? 0
        translation.removeLast(translation.count - keep)
    }

    mutating func takeCarry() -> String {
        defer { carry = "" }
        return carry
    }

    /// Every pair whose translation is complete. `force` closes what is left
    /// (the session ended).
    mutating func take(now: TimeInterval, force: Bool = false) -> [Pair] {
        var pairs: [Pair] = []
        while let pair = takeOne(now: now, force: force) { pairs.append(pair) }
        return pairs
    }

    private enum Cut { case sentence, clause, pause, all }

    private mutating func takeOne(now: TimeInterval, force: Bool) -> Pair? {
        let text = String(translation.map(\.character))
        guard text.contains(where: { !$0.isWhitespace }) else {
            if force, !liveSource.isEmpty { return emit(translationCount: translation.count, cut: .all) }
            return nil
        }
        let quiet = lastTranslationAt.map { now - $0 } ?? .infinity
        if let end = SubtitleSegmenter.firstSentenceEnd(in: text) {
            return emit(translationCount: text.distance(from: text.startIndex, to: end), cut: .sentence)
        }
        if force { return emit(translationCount: translation.count, cut: .all) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if SubtitleSegmenter.endsSentence(trimmed), quiet >= Self.sentenceSettle {
            return emit(translationCount: translation.count, cut: .sentence)
        }
        if quiet >= Self.pause { return emit(translationCount: translation.count, cut: .pause) }
        if text.count >= Self.longTranslation, let index = SubtitleSegmenter.clauseCut(in: text) {
            return emit(translationCount: text.distance(from: text.startIndex, to: index), cut: .clause)
        }
        return nil
    }

    private mutating func emit(translationCount: Int, cut: Cut) -> Pair? {
        let piece = translation.prefix(translationCount)
        translation.removeFirst(translationCount)
        let elapsed = piece.last?.elapsed ?? lastElapsed
        let sourceCount = sourceCut(at: elapsed, cut: cut)
        let original = String(source.prefix(sourceCount).map(\.character))
        source.removeFirst(sourceCount)
        let pair = Pair(source: original.trimmingCharacters(in: .whitespacesAndNewlines),
                        translation: String(piece.map(\.character)).trimmingCharacters(in: .whitespacesAndNewlines))
        guard !pair.translation.isEmpty || !pair.source.isEmpty else { return nil }
        emittedPair = true
        return pair
    }

    /// How much of the original belongs to a translation cut at `elapsed`.
    private func sourceCut(at elapsed: Int, cut: Cut) -> Int {
        guard cut != .all else { return source.count }
        let text = String(source.map(\.character))
        // Sentence ends of the original with the audio position they were
        // heard at (the delta that carried the terminator).
        var ends: [(count: Int, elapsed: Int)] = []
        var rest = text
        var offset = 0
        while let end = SubtitleSegmenter.firstSentenceEnd(in: rest) {
            let length = rest.distance(from: rest.startIndex, to: end)
            offset += length
            guard offset > 0, offset <= source.count else { break }
            ends.append((offset, source[offset - 1].elapsed))
            rest = String(rest[end...])
        }
        if let first = ends.first, first.elapsed <= elapsed {
            // The next sentence of the original, plus any the model merged in.
            var count = first.count
            for end in ends.dropFirst() where end.elapsed <= elapsed - Self.mergeLag { count = end.count }
            return count
        }
        if cut == .clause, let index = SubtitleSegmenter.clauseCut(in: text) {
            let count = text.distance(from: text.startIndex, to: index)
            if count > 0, count <= source.count, source[count - 1].elapsed <= elapsed { return count }
        }
        // No sentence end of the original yet: a pause (its period comes
        // with the next word) or a sentence the model split. Take the words
        // heard up to the translation's position.
        if let last = source.lastIndex(where: { $0.elapsed <= elapsed }) {
            var count = last + 1
            // Whole words only.
            while count < source.count, !source[count].character.isWhitespace { count += 1 }
            return count
        }
        return 0
    }

    private static let leading: Set<Character> = [".", "!", "?", "…", ",", ";", ":"]
}

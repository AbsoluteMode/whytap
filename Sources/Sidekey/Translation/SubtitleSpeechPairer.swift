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

    /// The product choice for the live row's original (the user's to make):
    /// false shows it only as far as its translation has reached, so a word
    /// shown never moves to another row, 1-3 s after it was heard; true shows
    /// it as heard (up to its first sentence end), and a word the cut gives to
    /// the next pair moves there when the row settles.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    static let liveOriginalAsHeard = false

    /// No new translation for this long: the speaker paused, the pair closes.
    static let pause: TimeInterval = 1.2
    /// The translation's last word waits at most this long for the delta
    /// that shows whether it was whole (deltas arrive about every 0.2 s).
    static let wordHold: TimeInterval = 0.3
    /// A translation ending in a terminator closes after this quiet time.
    static let sentenceSettle: TimeInterval = 0.3
    /// A translation this long without a sentence end closes at a clause.
    static let longTranslation = 160
    /// Originals whose sentence ended this much audio before the translation's
    /// cut belong to it too: the model merged two sentences into one.
    static let mergeLag = 5_000
    /// A sentence end of the original heard up to this much audio after the
    /// translation's cut may still belong to it: the original's period
    /// arrives with the next word, in the model's 200 ms steps.
    static let sentenceEndSlack = 400
    /// Before a session has settled pairs of its own: the translation about
    /// as long as its original, its end about 1.5 s of audio after it.
    static let priorRatio = 1.0
    static let priorLag = 1_500

    /// `liveOriginalAsHeard` for this pairer (tests compare both).
    var originalAsHeard = SubtitleSpeechPairer.liveOriginalAsHeard
    private var source: [(character: Character, elapsed: Int)] = []
    private var translation: [(character: Character, elapsed: Int)] = []
    private var lastElapsed = 0
    private var lastTranslationAt: TimeInterval?
    private var emittedPair = false
    /// How much of each stream the live row has shown (`showLive`).
    private var shownSource = 0
    private var shownTranslation = 0
    /// What the live row showed of the translation in whole words, without a
    /// last word shown only because nothing followed it (`wordHold`).
    private var shownWholeTranslation = 0
    /// Lengths of this session's settled sentence pairs (characters) and how
    /// far each translation's end trailed its original's (audio ms): what a
    /// merged translation is matched against.
    private var settledSource = 0
    private var settledTranslation = 0
    private var lags: [Int] = []
    /// A sentence end that arrived at the head of the original after its pair
    /// closed ("guest" | ". So …"): it belongs to the previous pair.
    private(set) var carry = ""

    var liveSource: String { String(source.map(\.character)).trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The live pair's original: the words heard up to the audio position the
    /// translation has reached, and at most up to the original's first
    /// sentence end. The original runs ahead of the translation; words past
    /// either bound may belong to the next pair, and a row never shows what it
    /// may have to give away when it settles.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
    var liveSourceHead: String {
        if originalAsHeard { return text(source.prefix(headCount)) }
        return text(source.prefix(max(min(headCount, translatedCount), shownSource)))
    }
    /// The translation still being spoken, whole words only: the model
    /// streams parts of words ("ошиб" + "лась"), and a fragment is never shown.
    var liveTranslation: String { text(translation.prefix(max(wholeWordCount, shownTranslation))) }

    /// What the live row shows now. The pairer remembers it, so the pair it
    /// settles into keeps at least this much of both streams: text on screen
    /// never moves to the next row, whatever the cut.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
    ///
    /// A last word held back as a possible fragment is shown once nothing has
    /// followed it for `wordHold` (`now` is the clock `addTranslation` got):
    /// the speaker paused, and the word would otherwise wait for the next one.
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    mutating func showLive(now: TimeInterval? = nil) -> (source: String, translation: String) {
        if let now, let last = lastTranslationAt, now - last >= Self.wordHold {
            shownTranslation = max(shownTranslation, translation.count)
        }
        let row = (source: liveSourceHead, translation: liveTranslation)
        if !originalAsHeard { shownSource = max(shownSource, min(headCount, translatedCount)) }
        shownTranslation = max(shownTranslation, wholeWordCount)
        shownWholeTranslation = max(shownWholeTranslation, wholeWordCount)
        return row
    }

    /// Characters of the original up to its first sentence end that more
    /// text follows, or all of it.
    private var headCount: Int {
        let text = String(source.map(\.character))
        guard let end = SubtitleSegmenter.firstSentenceEnd(in: text) else { return source.count }
        return text.distance(from: text.startIndex, to: end)
    }

    /// Characters of the original heard by the audio position of the last
    /// shown translation word, whole words only: the timing cut of this pair
    /// takes at least these.
    private var translatedCount: Int {
        guard let reached = translation.prefix(max(wholeWordCount, shownTranslation)).map(\.elapsed).max() else { return 0 }
        return heardCount(by: reached)
    }

    /// Characters of the original heard by audio position `elapsed`, whole
    /// words only. A word heard in part is finished from the next delta; a
    /// separating space already heard ends the words there, so the next
    /// phrase's first word is never taken (the space may arrive with either
    /// delta).
    private func heardCount(by elapsed: Int) -> Int {
        guard let last = source.lastIndex(where: { $0.elapsed <= elapsed }) else { return 0 }
        var count = last + 1
        guard !source[last].character.isWhitespace else { return count }
        while count < source.count, !source[count].character.isWhitespace { count += 1 }
        return count
    }

    /// Characters of the translation up to its last whole word.
    private var wholeWordCount: Int {
        let text = String(translation.map(\.character))
        guard let last = text.last, !last.isWhitespace, !SubtitleSegmenter.clauseMarks.contains(last),
              !SubtitleSegmenter.endsSentence(text) else { return translation.count }
        guard let space = text.lastIndex(where: \.isWhitespace) else { return 0 }
        return text.distance(from: text.startIndex, to: space)
    }

    private func text(_ characters: ArraySlice<(character: Character, elapsed: Int)>) -> String {
        String(characters.map(\.character)).trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Never below what the live row showed in whole words (a clause mark
        // the next fragment followed without a space). A last word shown
        // only after `wordHold` may be a fragment and goes.
        let keep = max(shownWholeTranslation,
                       text.lastIndex(where: \.isWhitespace).map { text.distance(from: text.startIndex, to: $0) } ?? 0)
        translation.removeLast(translation.count - keep)
        shownTranslation = min(shownTranslation, translation.count)
        shownWholeTranslation = min(shownWholeTranslation, translation.count)
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
        // What the live row showed stays in the pair it settles into.
        let translationCount = min(translation.count, max(translationCount, shownTranslation))
        let piece = translation.prefix(translationCount)
        translation.removeFirst(translationCount)
        let elapsed = piece.last?.elapsed ?? lastElapsed
        let translated = String(piece.map(\.character)).trimmingCharacters(in: .whitespacesAndNewlines)
        let (cutCount, sentenceEnd) = sourceCut(at: elapsed, cut: cut, translationLength: translated.count)
        let sourceCount = min(source.count, max(cutCount, shownSource))
        shownSource = 0
        shownTranslation = 0
        shownWholeTranslation = 0
        let original = String(source.prefix(sourceCount).map(\.character))
        source.removeFirst(sourceCount)
        let pair = Pair(source: original.trimmingCharacters(in: .whitespacesAndNewlines), translation: translated)
        if let sentenceEnd, sourceCount == cutCount, !pair.source.isEmpty, !pair.translation.isEmpty {
            settledSource += pair.source.count
            settledTranslation += pair.translation.count
            lags = Array((lags + [elapsed - sentenceEnd]).suffix(8))
        }
        guard !pair.translation.isEmpty || !pair.source.isEmpty else { return nil }
        emittedPair = true
        return pair
    }

    /// How much of the original belongs to a translation cut at `elapsed`,
    /// and the audio position of the sentence end it was cut at, if any.
    private func sourceCut(at elapsed: Int, cut: Cut, translationLength: Int) -> (count: Int, sentenceEnd: Int?) {
        guard cut != .all else { return (source.count, nil) }
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
            // The next sentence of the original, plus any the model merged in:
            // those ended long before the translation surely did.
            var sure = 0
            for (index, end) in ends.enumerated() where index == 0 || end.elapsed <= elapsed - Self.mergeLag {
                sure = index
            }
            // Later sentence ends heard by the cut may be merged in too (a
            // short sentence the model joined to the one before) or may start
            // the next pair. Take the one this translation fits best.
            let candidates = ends.prefix { $0.elapsed <= elapsed + Self.sentenceEndSlack }.dropFirst(sure)
            let chosen = candidates.min {
                mergeScore($0, elapsed: elapsed, translationLength: translationLength)
                    < mergeScore($1, elapsed: elapsed, translationLength: translationLength)
            } ?? ends[sure]
            return (chosen.count, chosen.elapsed)
        }
        if cut == .clause, let index = SubtitleSegmenter.clauseCut(in: text) {
            let count = text.distance(from: text.startIndex, to: index)
            if count > 0, count <= source.count, source[count - 1].elapsed <= elapsed { return (count, nil) }
        }
        // No sentence end of the original yet: a pause (its period comes
        // with the next word) or a sentence the model split. Take the words
        // heard up to the translation's position.
        return (heardCount(by: elapsed), nil)
    }

    /// How badly a translation of `translationLength` characters ending at
    /// audio position `elapsed` fits the original up to `end`: its length
    /// against this session's translation-to-original ratio, and its delay
    /// after that sentence end against this session's usual delay. A merged
    /// translation ends its usual delay after the last sentence it covers;
    /// one that does not cover a sentence ends before that sentence did,
    /// plus the delay (the two streams keep sentence for sentence otherwise).
    // WHY: .project-docs/decisions/2026-11-23-subtitle-pairs-close-speed.md
    private func mergeScore(_ end: (count: Int, elapsed: Int), elapsed: Int, translationLength: Int) -> Double {
        let original = String(source.prefix(end.count).map(\.character))
            .trimmingCharacters(in: .whitespacesAndNewlines).count
        guard original > 0, translationLength > 0 else { return .infinity }
        let lengthMiss = abs(log(Double(translationLength) / (ratio * Double(original))))
        let lagMiss = Double(abs(elapsed - end.elapsed - typicalLag))
        // A ratio that misses by a third weighs as much as a delay that
        // misses by a second (measured spread of single sentences).
        return lengthMiss / 0.3 + lagMiss / 1_000
    }

    /// Translation characters per original character in this session,
    /// starting from `priorRatio`.
    private var ratio: Double {
        let weight = 100.0
        return (Double(settledTranslation) + Self.priorRatio * weight) / (Double(settledSource) + weight)
    }

    /// The median delay of this session's settled translations after their
    /// original's sentence end, starting from `priorLag`.
    private var typicalLag: Int {
        guard lags.count >= 2 else { return Self.priorLag }
        return lags.sorted()[lags.count / 2]
    }

    private static let leading: Set<Character> = [".", "!", "?", "…", ",", ";", ":"]
}

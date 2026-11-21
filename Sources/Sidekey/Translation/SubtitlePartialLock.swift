import Foundation

/// Lets Subtitles translate the stable start of a segment-long partial
/// (ElevenLabs sends the whole uncommitted segment as each partial and
/// commits only at a pause) instead of waiting seconds for the commit.
///
/// Words that have not changed for `stableFor` seconds are cut into whole
/// phrases by the same boundaries as committed text, never including the
/// partial's last word (it may still be growing). When the provider commits,
/// the words already cut are removed from the committed text by word
/// alignment, so each spoken word lands in exactly one pair even when the
/// commit edits the wording slightly.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
struct SubtitlePartialLock {
    static let stableFor: TimeInterval = 0.6

    /// Words of the current segment already cut into phrases.
    private(set) var locked: [String] = []
    private var words: [String] = []
    private var changedAt: [TimeInterval] = []
    private var candidateSince: TimeInterval?

    /// The latest partial for the current segment.
    mutating func update(partial: String, now: TimeInterval) {
        let next = partial.split(whereSeparator: \.isWhitespace).map(String.init)
        var times: [TimeInterval] = []
        for (index, word) in next.enumerated() {
            let same = index < words.count && Self.normalized(words[index]) == Self.normalized(word)
            times.append(same ? changedAt[index] : now)
        }
        words = next
        changedAt = times
        if candidateSince == nil, words.count > locked.count { candidateSince = now }
    }

    /// Where the locked words end in the current partial. The provider may
    /// have revised them since (ElevenLabs removes fillers and repeats from
    /// text it already sent), so this is an alignment, not a count.
    private var boundary: Int {
        locked.isEmpty ? 0 : min(words.count, Self.alignedEnd(of: locked, in: words))
    }

    /// Words of the partial not yet cut: the live original.
    var unlockedText: String {
        let start = boundary
        return words.count > start ? words[start...].joined(separator: " ") : ""
    }

    /// The next stable phrase beyond the locked words, if one is ready.
    mutating func take(now: TimeInterval) -> String? {
        let start = boundary
        guard words.count > start + 1 else { return nil }
        let candidate = Array(words[start..<(words.count - 1)])
        let times = changedAt[start..<(words.count - 1)]
        // A word ElevenLabs is still spelling ends in a hyphen ("вы-"): it and
        // everything after it wait, whatever their age.
        let stable = zip(candidate, times)
            .prefix { now - $0.1 >= Self.stableFor && !Self.isUnfinished($0.0) }
            .map(\.0)
        guard !stable.isEmpty else { return nil }
        var cut: Int?
        if let end = stable.firstIndex(where: { SubtitleSegmenter.endsSentence($0) }) {
            cut = end + 1
        } else {
            let text = candidate.joined(separator: " ")
            let long = text.count >= SubtitleSegmenter.longPhraseCharacters
                || now - (candidateSince ?? now) >= SubtitleSegmenter.longPhraseSeconds
            if long {
                var length = 0, clause: Int?
                for (index, word) in stable.enumerated() {
                    length += word.count + (index == 0 ? 0 : 1)
                    if length >= SubtitleSegmenter.minimumClause, let last = word.last,
                       SubtitleSegmenter.clauseMarks.contains(last) { clause = index + 1 }
                }
                if let clause {
                    cut = clause
                } else if stable.count >= 3 {
                    // Same shape as committed text: never end on "a", "the", "and".
                    var count = stable.count
                    while count > 3, stable.count - count < 3, SubtitleSegmenter.isFunctionWord(stable[count - 1]) {
                        count -= 1
                    }
                    cut = count
                }
            }
        }
        guard let count = cut else { return nil }
        let phrase = Array(stable.prefix(count))
        locked += phrase
        candidateSince = words.count > start + count ? now : nil
        let text = phrase.joined(separator: " ")
        return text.contains(where: { $0.isLetter || $0.isNumber }) ? text : nil
    }

    /// The provider committed the segment: returns its text without the words
    /// already cut, and starts a new segment.
    mutating func commit(_ text: String) -> String {
        defer { locked = []; words = []; changedAt = []; candidateSince = nil }
        guard !locked.isEmpty else { return text }
        let committed = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let skip = Self.alignedEnd(of: locked, in: committed)
        return committed.dropFirst(skip).joined(separator: " ")
    }

    mutating func reset() { locked = []; words = []; changedAt = []; candidateSince = nil }

    /// How many committed words the locked words cover: an exact prefix, or
    /// else where the locked phrase's last words (3, 2, then 1) reappear
    /// within three words of its length (the commit may drop a filler), or
    /// where the words before its last one do (the commit fixed that word),
    /// or else its length.
    static func alignedEnd(of locked: [String], in committed: [String]) -> Int {
        let lockedKeys = locked.map(normalized), keys = committed.map(normalized)
        let count = lockedKeys.count
        if keys.starts(with: lockedKeys) { return count }
        func ends(_ size: Int, shift: Int) -> [Int] {
            let lower = max(size, count - 3 - shift), upper = min(keys.count - shift, count + 3 - shift)
            guard size > 0, lower <= upper else { return [] }
            // Prefer the candidate closest to the locked length.
            return (lower...upper).sorted { abs($0 + shift - count) < abs($1 + shift - count) }
        }
        for size in stride(from: min(3, count), through: 1, by: -1) {
            let tail = Array(lockedKeys.suffix(size))
            if let end = ends(size, shift: 0).first(where: { Array(keys[($0 - size)..<$0]) == tail }) { return end }
        }
        if count >= 2, let last = lockedKeys.last {
            let head = Array(lockedKeys.dropLast())
            for size in stride(from: min(3, head.count), through: 1, by: -1) {
                let tail = Array(head.suffix(size))
                if let end = ends(size, shift: 1).first(where: { Array(keys[($0 - size)..<$0]) == tail }) {
                    // The last cut word was corrected ("net" -> "network"):
                    // it is covered. It was removed ("ну"): the next word is new.
                    return end < keys.count && similar(keys[end], last) ? end + 1 : end
                }
            }
        }
        return min(keys.count, count)
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        let shared = zip(a, b).prefix { $0 == $1 }.count
        return shared >= min(3, min(a.count, b.count)) && shared > 0
    }

    /// ElevenLabs marks a word it is still hearing with a trailing hyphen.
    static func isUnfinished(_ word: String) -> Bool {
        word.hasSuffix("-") || word.hasSuffix("–")
    }

    static func normalized(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

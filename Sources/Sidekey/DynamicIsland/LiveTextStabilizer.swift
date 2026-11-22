import Foundation

/// Keeps the live line from going back when a provider alternates between
/// versions of the phrase it is still decoding.
///
/// ElevenLabs `scribe_v3_live` decodes the whole segment again for every
/// partial. For a second or two it can switch between two readings ("Ага.
/// Так, щас. А в GitHub" and "Так, сейчас. А в"), and some partials are an
/// earlier, shorter state of the phrase. Shown as they arrive, the words on
/// screen disappear and come back.
///
/// The stabilizer compares each snapshot with the text it gave out last, word
/// by word:
/// - new words after the last word both have in common are shown at once,
///   and they replace whatever was shown after that word;
/// - a snapshot that only ends earlier is not shown: the words on screen stay;
/// - a change before that word waits. It is shown in one step once the
///   provider has kept it for `confirmSeconds`.
/// Display only: paste, Drop auto-stop and the fallback read the provider's
/// own text. The same for every provider: only the text is compared.
/// WHY: .project-docs/decisions/2026-11-23-live-text-stable-display.md
/// Pure: the caller supplies the clock.
struct LiveTextStabilizer {
    /// How long the provider must keep a change of earlier words, or a
    /// shorter phrase, before the line shows it. Zero turns the stabilizer off.
    var confirmSeconds: TimeInterval = 1.5
    /// A change spanning more words than this is shown as it is.
    static let longestRevision = 120

    /// The text the line shows.
    private(set) var shown = ""
    private var pending: Pending?

    private struct Pending {
        /// The provider's newest text.
        var text: String
        /// The provider's reading being waited on: while its snapshots begin
        /// with these words, it has not changed its mind.
        let key: [String]
        let since: TimeInterval
    }

    /// Text that was already on screen.
    mutating func reset(_ text: String) {
        shown = text
        pending = nil
    }

    /// The provider's text is now `text`; the first `revealed` characters of
    /// the line's text are on screen. Returns the line's new text. Words that
    /// were delivered but not revealed yet are replaced freely.
    mutating func arrived(_ text: String, revealed: Int = .max, now: TimeInterval) -> String {
        guard confirmSeconds > 0 else {
            reset(text)
            return text
        }
        let merged = Self.merge(shown: shown, revealed: revealed, incoming: text)
        shown = merged.text
        if merged.text == text {
            pending = nil
        } else if let waiting = pending, Self.words(Array(text)).map(\.key).starts(with: waiting.key) {
            pending = Pending(text: text, key: waiting.key, since: waiting.since)
        } else {
            pending = Pending(text: text, key: merged.key, since: now)
        }
        return shown
    }

    /// The provider's text, once it has kept a waiting change long enough.
    mutating func settled(now: TimeInterval) -> String? {
        guard let waiting = pending, now - waiting.since >= confirmSeconds else { return nil }
        reset(waiting.text)
        return shown
    }

    // MARK: - Merge

    struct Word: Equatable {
        /// Where the word begins in the text; it runs to the next word.
        let start: Int
        /// The word without case and punctuation.
        let key: String
    }

    /// Words with the spaces after them. Languages written without spaces
    /// give one word per phrase and are shown as the provider sends them.
    static func words(_ characters: [Character]) -> [Word] {
        var words: [Word] = []
        var index = 0
        while index < characters.count {
            let start = words.isEmpty ? 0 : index
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            let wordStart = index
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            guard index > wordStart else { break }
            let raw = characters[wordStart..<index]
            let letters = String(raw.filter { $0.isLetter || $0.isNumber }).lowercased()
            words.append(Word(start: start, key: letters.isEmpty ? String(raw) : letters))
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }
        return words
    }

    static func merge(
        shown: String, revealed: Int = .max, incoming: String
    ) -> (text: String, key: [String]) {
        guard revealed > 0, !shown.isEmpty, !incoming.isEmpty, !incoming.hasPrefix(shown) else {
            return (incoming, [])
        }
        let old = Array(Array(shown).prefix(revealed)), new = Array(incoming)
        let oldWords = words(old), newWords = words(new)
        var common = 0
        while common < min(oldWords.count, newWords.count), oldWords[common].key == newWords[common].key {
            common += 1
        }
        let oldRest = oldWords[common...].map(\.key), newRest = newWords[common...].map(\.key)
        guard oldRest.count <= longestRevision, newRest.count <= longestRevision else { return (incoming, []) }
        // The last word both texts have in common, matching each word as
        // early as it can be: a repeated word at the live edge ("и" -> "и вот
        // и") is new speech, not the word already shown.
        var last: (old: Int, new: Int)? = common > 0 ? (common - 1, common - 1) : nil
        if !oldRest.isEmpty, !newRest.isEmpty {
            var length = Array(repeating: Array(repeating: 0, count: newRest.count + 1), count: oldRest.count + 1)
            for i in stride(from: oldRest.count - 1, through: 0, by: -1) {
                for j in stride(from: newRest.count - 1, through: 0, by: -1) {
                    length[i][j] = oldRest[i] == newRest[j]
                        ? length[i + 1][j + 1] + 1
                        : max(length[i + 1][j], length[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < oldRest.count, j < newRest.count {
                if oldRest[i] == newRest[j], length[i][j] == length[i + 1][j + 1] + 1 {
                    last = (common + i, common + j)
                    i += 1
                    j += 1
                } else if length[i + 1][j] >= length[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        guard let last else { return (incoming, []) }
        let keys = newWords.map(\.key)
        if last.new == newWords.count - 1, last.old < oldWords.count - 1 {
            // Nothing new after the common word and the line shows more: an
            // earlier state of the phrase. Its last word may be unfinished.
            return (shown, Array(keys.dropLast(keys.count > 1 ? 1 : 0)))
        }
        let text = String(old[..<oldWords[last.old].start] + new[newWords[last.new].start...])
        return (text, Array(keys[...last.new]))
    }
}

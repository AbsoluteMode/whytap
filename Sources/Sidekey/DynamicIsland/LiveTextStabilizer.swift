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
/// The stabilizer compares each snapshot with the text on screen, word by
/// word:
/// - new words after the last word both have in common are shown at once,
///   and they replace whatever was shown after that word;
/// - a snapshot that only ends earlier is not shown: the words on screen stay;
/// - a change before that word waits. It is shown in one step once the
///   provider has kept that same change for `confirmSeconds`.
/// Only text that reached the screen is kept: words delivered but not
/// revealed yet always follow the newest snapshot.
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

    /// The line's text: what `arrived` or `settled` returned last.
    private(set) var shown = ""
    private var pending: Pending?

    /// Whether a change is waiting for `settled`.
    var isWaiting: Bool { pending != nil }

    /// What the provider wants changed in the text on screen: the words on
    /// screen and the provider's words for them, without the words around
    /// them that both have. New words at the end do not change it.
    struct Correction: Equatable {
        let old: [String]
        let new: [String]
    }

    private struct Pending {
        /// The provider's newest text.
        var text: String
        let correction: Correction
        let since: TimeInterval
    }

    /// Text that was already on screen.
    mutating func reset(_ text: String) {
        shown = text
        pending = nil
    }

    /// The provider's text is now `text`, and `visible` is the part of the
    /// line that is on screen. Returns the line's new text.
    mutating func arrived(_ text: String, visible: String, now: TimeInterval) -> String {
        guard confirmSeconds > 0 else {
            reset(text)
            return text
        }
        // Whether the reveal point is inside a word.
        let cutWord = shown.count > visible.count && shown.hasPrefix(visible) &&
            visible.last?.isWhitespace == false &&
            !shown[shown.index(shown.startIndex, offsetBy: visible.count)].isWhitespace
        var merged = Self.merge(visible: visible, endsInsideWord: cutWord, incoming: text)
        // The first letters of a word are not a word the reader has, so an
        // earlier state of the phrase takes them back.
        if merged.earlier, cutWord {
            let characters = Array(visible)
            let whole = String(characters[..<(Self.words(characters).last?.start ?? 0)])
            merged = Self.merge(visible: whole, incoming: text)
        }
        shown = merged.text
        if let correction = merged.correction {
            // The wait belongs to one correction. A different one starts again.
            let since = pending?.correction == correction ? pending?.since : nil
            pending = Pending(text: text, correction: correction, since: since ?? now)
        } else {
            pending = nil
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

    /// The letters of a word as written, without its marks.
    private static func letters(_ characters: [Character], _ words: [Word], _ index: Int) -> [Character] {
        let end = index + 1 < words.count ? words[index + 1].start : characters.count
        return characters[words[index].start..<end].filter { $0.isLetter || $0.isNumber }
    }

    /// The line's text for a snapshot, and the correction it leaves waiting
    /// (nil when the line shows the snapshot itself). `earlier`: the snapshot
    /// is an earlier state of the phrase and the visible text was kept.
    static func merge(
        visible: String, endsInsideWord: Bool = false, incoming: String
    ) -> (text: String, correction: Correction?, earlier: Bool) {
        guard !visible.isEmpty, !incoming.isEmpty, !incoming.hasPrefix(visible) else {
            return (incoming, nil, false)
        }
        let old = Array(visible), new = Array(incoming)
        let oldWords = words(old), newWords = words(new)
        let oldKeys = oldWords.map(\.key), newKeys = newWords.map(\.key)
        guard !oldKeys.isEmpty, !newKeys.isEmpty else { return (incoming, nil, false) }
        // The last word may be unfinished: the provider is still typing its
        // own, and the reveal point can be inside the line's.
        func same(_ i: Int, _ j: Int) -> Bool {
            oldKeys[i] == newKeys[j] ||
                (j == newKeys.count - 1 && oldKeys[i].hasPrefix(newKeys[j])) ||
                (endsInsideWord && i == oldKeys.count - 1 && newKeys[j].hasPrefix(oldKeys[i]))
        }
        var matched = 0
        var common = 0
        while common < min(oldKeys.count, newKeys.count), same(common, common) { common += 1 }
        let oldRest = oldKeys.count - common, newRest = newKeys.count - common
        guard oldRest <= longestRevision, newRest <= longestRevision else { return (incoming, nil, false) }
        // The last word both texts have in common, matching each word as
        // early as it can be: a repeated word at the live edge ("и" -> "и вот
        // и") is new speech, not the word already shown.
        matched = common
        var last: (old: Int, new: Int)? = common > 0 ? (common - 1, common - 1) : nil
        if oldRest > 0, newRest > 0 {
            var length = Array(repeating: Array(repeating: 0, count: newRest + 1), count: oldRest + 1)
            for i in stride(from: oldRest - 1, through: 0, by: -1) {
                for j in stride(from: newRest - 1, through: 0, by: -1) {
                    length[i][j] = same(common + i, common + j)
                        ? length[i + 1][j + 1] + 1
                        : max(length[i + 1][j], length[i][j + 1])
                }
            }
            var i = 0, j = 0
            while i < oldRest, j < newRest {
                if same(common + i, common + j), length[i][j] == length[i + 1][j + 1] + 1 {
                    last = (common + i, common + j)
                    matched += 1
                    i += 1
                    j += 1
                } else if length[i + 1][j] >= length[i][j + 1] {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        guard let last else { return (incoming, nil, false) }
        // A word or two that happen to be in both texts do not tie a new
        // phrase to the old one: up to the common word, each text must have
        // at least as many common words as words of its own.
        guard last.old + 1 - matched <= matched, last.new + 1 - matched <= matched else {
            return (incoming, nil, false)
        }
        // Nothing new after the common word, and the line shows more words
        // or more of that word: an earlier state of the phrase.
        let earlier = last.new == newKeys.count - 1 &&
            (last.old < oldKeys.count - 1 || oldKeys[last.old].count > newKeys[last.new].count)
        let text: String
        if earlier {
            text = visible
        } else if last.old < oldWords.count - 1, last.new < newWords.count - 1,
                  letters(old, oldWords, last.old) != letters(new, newWords, last.new) {
            // The common word is behind the live one and only its case
            // differs (the mark before it changed): it stays as shown.
            text = String(old[..<oldWords[last.old + 1].start] + new[newWords[last.new + 1].start...])
        } else {
            // The provider's marks on the common word are shown with its
            // new words.
            text = String(old[..<oldWords[last.old].start] + new[newWords[last.new].start...])
        }
        guard text != incoming else { return (incoming, nil, false) }
        // The common word itself is not part of the correction: while the
        // provider types it letter by letter the correction is the same.
        var before = oldKeys[..<last.old]
        var after = newKeys[..<last.new]
        while let a = before.first, let b = after.first, a == b {
            before.removeFirst()
            after.removeFirst()
        }
        while let a = before.last, let b = after.last, a == b {
            before.removeLast()
            after.removeLast()
        }
        // The words an earlier state lacks are part of what waits.
        let lacking = last.old + 1 < oldKeys.count ? ["\u{2026}"] + oldKeys[(last.old + 1)...] : []
        return (text, Correction(old: Array(before) + lacking, new: Array(after)), earlier)
    }
}

import AppKit

/// The system spelling dictionary of the word's script (Russian for Cyrillic,
/// English otherwise). Local; nothing leaves the Mac. A missing dictionary
/// counts the word as known, so nothing is offered on a guess.
@MainActor
final class SystemWordLexicon: DropWordLexicon {
    private let checker = NSSpellChecker.shared
    private lazy var available = Set(checker.availableLanguages)

    func isKnownWord(_ word: String) -> Bool {
        let language = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) } ? "ru" : "en"
        guard available.contains(language) || available.contains(where: { $0.hasPrefix(language + "_") }) else {
            return true
        }
        let miss = checker.checkSpelling(
            of: word, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        return miss.location == NSNotFound
    }
}

import Foundation
import NaturalLanguage

/// With the input language on Auto, a provider guesses the language of every
/// take, and some of its features work worse for it (ElevenLabs left Russian
/// fillers in until the language was set). After a few dictations in one
/// language the app offers once to set it; the user's click sets it, nothing
/// changes otherwise.
///
/// The language is read from the take's text on this Mac by the system
/// recognizer. Only the language code and a count are kept, never the text.
// WHY: .project-docs/decisions/2026-11-20-input-language-suggestion.md
struct InputLanguageSuggestion {
    /// Consecutive Auto dictations in one language before the offer.
    static let streakNeeded = 3
    /// Shorter takes ("ok", a name) say too little about the language.
    static let minimumLetters = 20
    static let minimumConfidence = 0.85

    private enum Key {
        static let streakCode = "inputLanguageSuggestion.streakCode"
        static let streakCount = "inputLanguageSuggestion.streakCount"
        static let offered = "inputLanguageSuggestion.offeredCodes"
    }

    private let defaults: UserDefaults
    private let detect: (String) -> String?

    init(defaults: UserDefaults = .standard, detect: @escaping (String) -> String? = InputLanguageSuggestion.detect) {
        self.defaults = defaults
        self.detect = detect
    }

    /// Counts one delivered take. Returns the language to offer when this
    /// take completes a streak for a language that was never offered before.
    /// A take with a chosen input language, or one whose language is unclear
    /// or outside the menu, changes nothing.
    func record(transcript: String, selectedLanguage: AppLanguage?) -> AppLanguage? {
        guard selectedLanguage == nil,
              let code = detect(transcript),
              let language = AppLanguage.all.first(where: { $0.code == code }) else { return nil }
        let count = defaults.string(forKey: Key.streakCode) == code ? defaults.integer(forKey: Key.streakCount) + 1 : 1
        defaults.set(code, forKey: Key.streakCode)
        defaults.set(min(count, Self.streakNeeded), forKey: Key.streakCount)
        var offered = defaults.stringArray(forKey: Key.offered) ?? []
        guard count >= Self.streakNeeded, !offered.contains(code) else { return nil }
        offered.append(code)
        defaults.set(offered, forKey: Key.offered)
        return language
    }

    /// The dominant language of `text` as an ISO 639-1 code, or `nil` when the
    /// text is short or the recognizer is unsure.
    static func detect(_ text: String) -> String? {
        guard text.unicodeScalars.filter(CharacterSet.letters.contains).count >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[language],
              confidence >= minimumConfidence else { return nil }
        // "zh-Hans" and "zh-Hant" are one menu entry.
        return language.rawValue.split(separator: "-").first.map(String.init)
    }

    /// The card that makes the offer. Clicking it sets the language; ignoring
    /// it keeps Auto, and the same language is not offered again.
    static func notification(for language: AppLanguage, now: Date = Date()) -> LocalNotificationEvent {
        LocalNotificationEvent(
            id: sourceID + ":" + language.code,
            source: sourceID, sourceName: "Input language",
            title: "Dictating in \(language.englishName)?",
            body: "Click to set \(language.englishName) as the input language. Auto stays if you don’t.",
            link: nil, timestamp: now, customDuration: 12, customTint: "#299FD6", customLogo: "whytap",
            inputLanguageCode: language.code
        )
    }

    static let sourceID = "builtin.input-language"
}

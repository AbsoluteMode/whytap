import Foundation

/// Opt-in wake word settings. Off unless the user turns it on: an always-on
/// microphone is never a default.
/// WHY: .project-docs/decisions/2026-11-11-wake-word.md
@MainActor
final class WakeWordPreferences {
    static let shared = WakeWordPreferences()

    static let enabledDefaultsKey = "com.sidekey.wakeword.enabled"
    static let phrasesDefaultsKey = "com.sidekey.wakeword.phrases"
    static let didChangeNotification = Notification.Name("com.sidekey.wakeword.didChange")

    /// "whytap" as the English model hears it; users add the spellings it
    /// hears in their own voice.
    static let defaultPhrases = ["why tap", "why tab"]
    static let maximumPhrases = 12
    /// Lower catches more and misfires more. 0.10 is where the user's own
    /// trials caught the phrase; the model card's 0.25 missed a lone phrase.
    static let threshold: Float = 0.10

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledDefaultsKey) }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: Self.enabledDefaultsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Normalized phrases the model can spell; never empty.
    var phrases: [String] {
        get {
            let stored = defaults.stringArray(forKey: Self.phrasesDefaultsKey) ?? Self.defaultPhrases
            let usable = Self.usablePhrases(stored)
            return usable.isEmpty ? Self.usablePhrases(Self.defaultPhrases) : usable
        }
        set {
            let usable = Self.usablePhrases(newValue)
            guard usable != phrases else { return }
            defaults.set(usable, forKey: Self.phrasesDefaultsKey)
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Text-field form: comma-separated, lowercase.
    var phrasesText: String {
        get { phrases.map { $0.lowercased() }.joined(separator: ", ") }
        set { phrases = Self.parse(newValue) }
    }

    static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }).map(String.init)
    }

    /// Entries of `text` the English model cannot spell (e.g. Cyrillic).
    static func rejectedEntries(in text: String) -> [String] {
        parse(text)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && WakeWordTokenizer.normalized($0) == nil }
    }

    static func usablePhrases(_ phrases: [String]) -> [String] {
        var result: [String] = []
        for phrase in phrases {
            guard let normalized = WakeWordTokenizer.normalized(phrase), !result.contains(normalized) else { continue }
            result.append(normalized)
            if result.count == maximumPhrases { break }
        }
        return result
    }
}

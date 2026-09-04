// Sources/Sidekey/Settings/VocabularyCache.swift
import Foundation

/// Reasons a user-entered term gets rejected. Mirrors the strictest provider
/// keyterm constraints so the user sees inline errors immediately.
enum VocabularyRejectionReason: Equatable {
    /// Empty after `.trimmingCharacters(in: .whitespacesAndNewlines)`.
    case empty
    /// Term length exceeds the 20-char cap.
    case tooLong
    /// Already present in the list (case-insensitive compare).
    case duplicate
    /// Adding would push the list over the 50-term cap.
    case tooMany
}

/// Result of an add-term attempt. Returned to callers so the SwiftUI view
/// can render an inline error next to the input field on rejection.
enum VocabularyAddResult: Equatable {
    case added
    case rejected(VocabularyRejectionReason)
}

/// Local store of the user's custom vocabulary terms (UserDefaults). The BYOK
/// drop path injects the terms at hotkey time; the island / Toolbox editor
/// edits the same list.
final class VocabularyCache {
    static let shared = VocabularyCache()

    /// Maximum terms allowed in a single list, aligned with the strictest
    /// provider (ElevenLabs Scribe keyterms) so the full list reaches every
    /// STT provider intact.
    static let maxTermCount = 50
    /// Maximum length of a single term in characters (ElevenLabs Scribe
    /// keyterm cap).
    static let maxTermLength = 20

    private let defaults: UserDefaults
    private let key = "sidekey.preferences.vocabularyTerms"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var terms: [String] { defaults.stringArray(forKey: key) ?? [] }

    func setTerms(_ terms: [String]) { defaults.set(terms, forKey: key) }

    /// Validates `raw` against the current list. Pure: does not mutate the
    /// store — callers append and `setTerms` on `.added`.
    static func validate(_ raw: String, against terms: [String]) -> VocabularyAddResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .rejected(.empty)
        }
        if trimmed.count > maxTermLength {
            return .rejected(.tooLong)
        }
        if terms.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .rejected(.duplicate)
        }
        if terms.count >= maxTermCount {
            return .rejected(.tooMany)
        }
        return .added
    }
}

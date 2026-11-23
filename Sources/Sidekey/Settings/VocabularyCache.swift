// Sources/Sidekey/Settings/VocabularyCache.swift
import Foundation

/// Reasons a user-entered term gets rejected. The list is one for every route;
/// each request sends the part its provider accepts (`VocabularyBudget`).
enum VocabularyRejectionReason: Equatable {
    /// Empty after `.trimmingCharacters(in: .whitespacesAndNewlines)`.
    case empty
    /// Term length exceeds the 50-char cap.
    case tooLong
    /// Already present in the list (case-insensitive compare).
    case duplicate
    /// Adding would push the list over the 1,000-term cap.
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

    /// The saved list is no longer capped by the strictest provider: each
    /// request takes the part its route accepts, in list order
    /// (`VocabularyBudget`). These caps only bound the stored list.
    // WHY: .project-docs/decisions/2026-11-23-vocabulary-route-budget.md
    static let maxTermCount = 1_000
    /// ElevenLabs recorded keyterms allow 50 characters; realtime routes skip
    /// longer terms per request.
    static let maxTermLength = 50

    /// Posted after every write so an open editor reloads a list changed
    /// elsewhere (a learning suggestion's Y, settings sync).
    static let didChangeNotification = Notification.Name("sidekey.vocabulary.didChange")

    private let defaults: UserDefaults
    private let key = "sidekey.preferences.vocabularyTerms"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var terms: [String] { defaults.stringArray(forKey: key) ?? [] }

    func setTerms(_ terms: [String]) {
        defaults.set(terms, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Validates against the stored list and appends on success.
    @discardableResult
    func add(_ raw: String) -> VocabularyAddResult {
        let current = terms
        let result = Self.validate(raw, against: current)
        guard result == .added else { return result }
        setTerms(current + [raw.trimmingCharacters(in: .whitespacesAndNewlines)])
        return .added
    }

    func remove(_ term: String) {
        setTerms(terms.filter { $0.caseInsensitiveCompare(term) != .orderedSame })
    }

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

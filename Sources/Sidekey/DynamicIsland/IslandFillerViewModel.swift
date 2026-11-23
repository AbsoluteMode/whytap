import Foundation

/// Drives the Filler chips editor. Unlike `IslandVocabularyViewModel`
/// this is fully synchronous — the term list is local (`FillerTermsStore`),
/// no network, so no loading/saving/error states.
@MainActor
final class IslandFillerViewModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { lastRejection = nil } }
    }
    @Published private(set) var terms: [String] = []
    @Published private(set) var lastRejection: FillerTermsStore.Rejection?

    private let store: FillerTermsStore

    init(store: FillerTermsStore = FillerTermsStore()) {
        self.store = store
        self.terms = store.terms()
    }

    /// Newest-first for display, filtered by the current query.
    var visibleTerms: [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = q.isEmpty
            ? Array(terms.reversed())
            : terms.filter { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return Array(base.prefix(12))
    }

    func submitCurrentQuery() {
        switch store.add(query) {
        case .added:
            query = ""
            terms = store.terms()
            lastRejection = nil
        case .rejected(let reason):
            lastRejection = reason
        }
    }

    func removeTerm(_ term: String) {
        store.remove(term)
        terms = store.terms()
        lastRejection = nil
    }
}

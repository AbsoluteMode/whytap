import Foundation

enum IslandVocabularyState: Equatable {
    case idle
    case loading
    case loaded
    case saving
    case error
}

/// Drives the inline vocabulary editor (island hover panel + Toolbox). The
/// terms live in the local `VocabularyCache`; every add/remove persists
/// immediately.
@MainActor
final class IslandVocabularyViewModel: ObservableObject {
    static let maxVisibleTerms = 12

    @Published var query = "" {
        didSet {
            if query != oldValue {
                lastRejection = nil
            }
        }
    }
    @Published private(set) var state: IslandVocabularyState = .idle
    @Published private(set) var terms: [String] = []
    @Published private(set) var lastRejection: VocabularyRejectionReason?

    private let vocabulary: VocabularyCache
    private var hasLoaded = false

    init(vocabulary: VocabularyCache = .shared) {
        self.vocabulary = vocabulary
    }

    var visibleTerms: [String] {
        let trimmedQuery = normalizedQuery
        let candidates: [String]

        if trimmedQuery.isEmpty {
            candidates = terms.reversed()
        } else {
            candidates = terms.filter {
                $0.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }

        return Array(candidates.prefix(Self.maxVisibleTerms))
    }

    @discardableResult
    func loadIfNeeded() async -> Bool {
        guard !hasLoaded else { return true }
        state = .loading
        terms = vocabulary.terms
        hasLoaded = true
        state = .loaded
        return true
    }

    func submitCurrentQuery() async {
        guard await loadIfNeeded() else { return }

        let raw = query
        switch appendTerm(raw) {
        case .added:
            query = ""
            await persistCurrentTerms()
        case .rejected(let reason):
            lastRejection = reason
        }
    }

    func removeTerm(_ term: String) async {
        guard await loadIfNeeded() else { return }

        guard let index = terms.firstIndex(of: term) else { return }
        terms.remove(at: index)
        lastRejection = nil
        await persistCurrentTerms()
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func appendTerm(_ raw: String) -> VocabularyAddResult {
        let result = VocabularyCache.validate(raw, against: terms)
        guard case .added = result else { return result }
        terms.append(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        lastRejection = nil
        return .added
    }

    private func persistCurrentTerms() async {
        state = .saving
        vocabulary.setTerms(terms)
        state = .loaded
    }
}

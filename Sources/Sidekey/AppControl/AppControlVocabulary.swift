import Foundation
import WhytapCaseKit

/// Adds Vocab terms for the application controls through `VocabularyCache.add`,
/// the path the island editor's rules and Drop learning use: the same
/// validation (50 characters, 1,000 terms, case-insensitive duplicates) and the
/// change notification an open Vocab editor reloads from. Additive and
/// retry-safe: a term already there is reported with its saved spelling, never
/// replaced. No read of the list and no removal here.
// WHY: .project-docs/decisions/2026-11-23-agent-vocab-add.md
@MainActor
struct AppControlVocabulary {
    static let operations: Set<String> = ["vocab_add"]
    static let maxBatch = 20

    let vocabulary: () -> VocabularyCache
    /// The speech account of the Drop route the next take uses, if any.
    let dropAccount: () -> ProviderAccount?

    func handle(_ operation: String, _ args: [String: AppControlValue]) -> AppControlResponse {
        guard operation == "vocab_add" else { return .failure("unknown_operation", "Unknown application-control operation.") }
        guard Set(args.keys) == ["terms"], let items = args["terms"]?.array,
              (1...Self.maxBatch).contains(items.count) else {
            return .failure("invalid_arguments", "Pass terms: 1–\(Self.maxBatch) words or short phrases.")
        }
        var raw: [String] = []
        for item in items {
            guard let text = item.string else { return .failure("invalid_arguments", "Each term must be a string.") }
            raw.append(text)
        }
        let store = vocabulary()
        // Check the whole batch first: one invalid term adds nothing.
        var planned = store.terms
        var results: [(term: String, result: String, saved: String)] = []
        for text in raw {
            let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.unicodeScalars.contains(where: { CharacterSet.newlines.union(.controlCharacters).contains($0) }) else {
                return Self.rejected(term, "is not one line")
            }
            switch VocabularyCache.validate(term, against: planned) {
            case .added:
                planned.append(term)
                results.append((term, "added", term))
            case .rejected(.duplicate):
                let saved = planned.first { $0.caseInsensitiveCompare(term) == .orderedSame } ?? term
                results.append((term, "existing", saved))
            case .rejected(.empty):
                return Self.rejected(term, "is empty")
            case .rejected(.tooLong):
                return Self.rejected(term, "is longer than \(VocabularyCache.maxTermLength) characters; use a shorter form")
            case .rejected(.tooMany):
                return .failure("vocab_full", "Vocab already holds \(VocabularyCache.maxTermCount) terms. Nothing was added; the user can remove some in the island's Vocab.")
            }
        }
        for entry in results where entry.result == "added" {
            guard store.add(entry.term) == .added else {
                return .failure("unconfirmed", "Vocab changed while adding; read it in the island and retry.")
            }
        }
        // Confirm from the saved list, not from the request.
        let saved = store.terms
        guard results.allSatisfy({ entry in saved.contains { $0 == entry.saved } }) else {
            return .failure("unconfirmed", "The saved Vocab does not contain the change.")
        }
        let transport = dropAccount().map(VocabularyTransport.realtime(for:))
        return .success(.object([
            "terms": .array(results.map { entry -> AppControlValue in
                var row: [String: AppControlValue] = ["term": .string(entry.saved), "result": .string(entry.result)]
                if let transport {
                    row["sentByCurrentDrop"] = .bool(VocabularyBudget.terms(saved, for: transport)
                        .contains { $0.caseInsensitiveCompare(entry.saved) == .orderedSame })
                }
                return .object(row)
            }),
            "count": .int(saved.count)
        ]))
    }

    private static func rejected(_ term: String, _ reason: String) -> AppControlResponse {
        let shown = term.count > 60 ? String(term.prefix(60)) + "…" : term
        return .failure("invalid_term", "\"\(shown)\" \(reason). Nothing was added.")
    }
}

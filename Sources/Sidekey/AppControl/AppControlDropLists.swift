import Foundation
import WhytapCaseKit

/// Adds entries to Drop's hand-filled lists for the application controls,
/// each through the store and checks the app itself uses:
/// - Vocab (`vocab_add`): `VocabularyCache.add`, the island editor's rules;
///   words dictation should spell right.
/// - Filler (`filler_add`): `FillerTermsStore.add`, the Filler editor's rules;
///   words Drop removes from a take.
/// The editors reload from the stores' change notifications and every take
/// reads the lists again. Additive and retry-safe: an entry already there is
/// reported with its saved form, never rewritten. No read, no removal.
/// External harnesses reach these only through `HarnessAccessGate`.
// WHY: .project-docs/decisions/2026-11-23-agent-drop-lists.md
@MainActor
struct AppControlDropLists {
    static let operations: Set<String> = ["vocab_add", "filler_add"]
    static let maxBatch = 20

    let vocabulary: () -> VocabularyCache
    let fillers: () -> FillerTermsStore

    private struct Row {
        let term: String
        let result: String
        let saved: String
    }

    func handle(_ operation: String, _ args: [String: AppControlValue]) -> AppControlResponse {
        guard Self.operations.contains(operation) else {
            return .failure("unknown_operation", "Unknown application-control operation.")
        }
        guard Set(args.keys) == ["terms"], let items = args["terms"]?.array, (1...Self.maxBatch).contains(items.count) else {
            return .failure("invalid_arguments", "Pass terms: 1–\(Self.maxBatch) entries.")
        }
        return addTerms(items, list: operation == "vocab_add" ? "Vocab" : "Filler")
    }

    private func addTerms(_ items: [AppControlValue], list: String) -> AppControlResponse {
        let vocab = list == "Vocab"
        var planned = vocab ? vocabulary().terms : fillers().terms()
        var rows: [Row] = []
        // Check the whole batch first: one invalid term adds nothing.
        for item in items {
            guard let text = item.string else { return .failure("invalid_arguments", "Each term must be a string.") }
            let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.oneLine(term) else { return Self.rejected(term, "is not one line") }
            let reason: VocabularyRejectionReason?
            if vocab {
                if case .rejected(let why) = VocabularyCache.validate(term, against: planned) { reason = why } else { reason = nil }
            } else {
                switch FillerTermsStore.validate(term, against: planned) {
                case .added: reason = nil
                case .rejected(.empty): reason = .empty
                case .rejected(.tooLong): reason = .tooLong
                case .rejected(.duplicate): reason = .duplicate
                case .rejected(.tooMany): reason = .tooMany
                }
            }
            switch reason {
            case nil:
                planned.append(term)
                rows.append(Row(term: term, result: "added", saved: term))
            case .duplicate?:
                let saved = planned.first { $0.caseInsensitiveCompare(term) == .orderedSame } ?? term
                rows.append(Row(term: term, result: "existing", saved: saved))
            case .empty?:
                return Self.rejected(term, "is empty")
            case .tooLong?:
                let limit = vocab ? VocabularyCache.maxTermLength : FillerTermsStore.maxTermLength
                return Self.rejected(term, "is longer than \(limit) characters; use a shorter form")
            case .tooMany?:
                let limit = vocab ? VocabularyCache.maxTermCount : FillerTermsStore.maxTermCount
                return .failure("list_full", "\(list) already holds \(limit) entries. Nothing was added; the user can remove some in the island's \(list).")
            }
        }
        // Access may have been turned off while the request waited. Nothing
        // suspends between this check and the writes.
        if rows.contains(where: { $0.result == "added" }),
           let stillAllowed = HarnessConsent.stillAllowed, !stillAllowed() {
            return .failure("access_denied", "The user has turned this tool's access to Whytap off. Do not retry.")
        }
        for row in rows where row.result == "added" {
            let added = vocab ? vocabulary().add(row.term) == .added : fillers().add(row.term) == .added
            guard added else { return .failure("unconfirmed", "\(list) changed while adding; retry.") }
        }
        // Confirm from the saved list, not from the request.
        let saved = vocab ? vocabulary().terms : fillers().terms()
        guard rows.allSatisfy({ row in saved.contains(row.saved) }) else {
            return .failure("unconfirmed", "The saved \(list) does not contain the change.")
        }
        return .success(.object([
            "terms": .array(rows.map { .object(["term": .string($0.saved), "result": .string($0.result)]) })
        ]))
    }

    /// One line: no line breaks or control characters. Format characters such
    /// as the zero-width non-joiner (U+200C) that Persian and other scripts
    /// need stay, as the stores and editors accept them.
    static func oneLine(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            scalar.properties.generalCategory == .control || CharacterSet.newlines.contains(scalar)
        }
    }

    private static func rejected(_ entry: String, _ reason: String) -> AppControlResponse {
        let shown = entry.count > 60 ? String(entry.prefix(60)) + "…" : entry
        return .failure("invalid_term", "\"\(shown)\" \(reason). Nothing was added.")
    }
}

import Foundation
import WhytapCaseKit

/// Adds entries to Drop's three lists for the application controls, each
/// through the store and checks the app itself uses:
/// - Vocab (`vocab_add`): `VocabularyCache.add`, the island editor's rules;
///   words dictation should spell right.
/// - Filler (`filler_add`): `FillerTermsStore.add`, the Filler editor's rules;
///   words Drop removes from a take.
/// - Replace (`replace_add`): `DropReplacementStore.add`, Drop learning's
///   rules; what Drop writes instead of a heard word.
/// The editors reload from the stores' change notifications and every take
/// reads the lists again. Additive and retry-safe: an entry already there is
/// reported with its saved form, never rewritten. No read, no removal.
// WHY: .project-docs/decisions/2026-11-23-agent-drop-lists.md
@MainActor
struct AppControlDropLists {
    static let operations: Set<String> = ["vocab_add", "filler_add", "replace_add"]
    static let maxBatch = 20

    let vocabulary: () -> VocabularyCache
    let fillers: () -> FillerTermsStore
    let replacements: () -> DropReplacementStore
    /// The speech account of the Drop route the next take uses, if any.
    let dropAccount: () -> ProviderAccount?

    private struct Row {
        let requested: String
        let result: String
        let saved: AppControlValue
    }

    func handle(_ operation: String, _ args: [String: AppControlValue]) -> AppControlResponse {
        let field = operation == "replace_add" ? "rules" : "terms"
        guard Set(args.keys) == [field], let items = args[field]?.array, (1...Self.maxBatch).contains(items.count) else {
            return .failure("invalid_arguments", "Pass \(field): 1–\(Self.maxBatch) entries.")
        }
        switch operation {
        case "vocab_add": return addTerms(items, list: "Vocab")
        case "filler_add": return addTerms(items, list: "Filler")
        case "replace_add": return addRules(items)
        default: return .failure("unknown_operation", "Unknown application-control operation.")
        }
    }

    // MARK: Vocab and Filler

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
                rows.append(Row(requested: term, result: "added", saved: .string(term)))
            case .duplicate?:
                let saved = planned.first { $0.caseInsensitiveCompare(term) == .orderedSame } ?? term
                rows.append(Row(requested: term, result: "existing", saved: .string(saved)))
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
        for row in rows where row.result == "added" {
            let added = vocab ? vocabulary().add(row.requested) == .added : fillers().add(row.requested) == .added
            guard added else { return .failure("unconfirmed", "\(list) changed while adding; retry.") }
        }
        // Confirm from the saved list, not from the request.
        let saved = vocab ? vocabulary().terms : fillers().terms()
        guard rows.allSatisfy({ row in saved.contains { .string($0) == row.saved } }) else {
            return .failure("unconfirmed", "The saved \(list) does not contain the change.")
        }
        let transport = vocab ? dropAccount().map(VocabularyTransport.realtime(for:)) : nil
        let sent = transport.map { VocabularyBudget.terms(saved, for: $0) }
        return .success(.object([
            "terms": .array(rows.map { row -> AppControlValue in
                var object: [String: AppControlValue] = ["term": row.saved, "result": .string(row.result)]
                if let sent, let term = row.saved.string {
                    object["sentByCurrentDrop"] = .bool(sent.contains { $0.caseInsensitiveCompare(term) == .orderedSame })
                }
                return .object(object)
            }),
            "count": .int(saved.count)
        ]))
    }

    // MARK: Replace

    private func addRules(_ items: [AppControlValue]) -> AppControlResponse {
        let store = replacements()
        var planned = store.replacements()
        var rows: [Row] = []
        for item in items {
            guard let object = item.object, Set(object.keys) == ["heard", "wanted"],
                  let heardText = object["heard"]?.string, let wantedText = object["wanted"]?.string else {
                return .failure("invalid_arguments", "Each rule is {heard, wanted}: what dictation writes and what to paste instead.")
            }
            let rule = DropReplacement(heard: heardText.trimmingCharacters(in: .whitespacesAndNewlines),
                                       wanted: wantedText.trimmingCharacters(in: .whitespacesAndNewlines))
            let shown = "\(rule.heard) → \(rule.wanted)"
            guard Self.oneLine(rule.heard), Self.oneLine(rule.wanted) else { return Self.rejected(shown, "is not one line") }
            switch DropReplacementStore.validate(rule, against: planned) {
            case .added:
                planned.append(rule)
                rows.append(Row(requested: shown, result: "added", saved: Self.value(rule)))
            case .rejected(.duplicate):
                // A rule for that word exists: keep it, whatever it writes.
                let saved = planned.first { $0.heard.caseInsensitiveCompare(rule.heard) == .orderedSame } ?? rule
                rows.append(Row(requested: shown, result: saved.wanted == rule.wanted ? "existing" : "different",
                                saved: Self.value(saved)))
            case .rejected(.empty):
                return Self.rejected(shown, "has an empty side")
            case .rejected(.identical):
                return Self.rejected(shown, "replaces a word with itself")
            case .rejected(.tooLong):
                return Self.rejected(shown, "is too long: heard is at most \(DropReplacementStore.maxHeardLength) characters and \(DropReplacementStore.maxHeardWords) words, wanted at most \(DropReplacementStore.maxWantedLength) characters")
            case .rejected(.tooMany):
                return .failure("list_full", "Replace already holds \(DropReplacementStore.maxCount) rules. Nothing was added.")
            }
        }
        for row in rows where row.result == "added" {
            guard let rule = Self.rule(row.saved), store.add(rule) == .added else {
                return .failure("unconfirmed", "Replace changed while adding; retry.")
            }
        }
        let saved = store.replacements()
        guard rows.allSatisfy({ row in Self.rule(row.saved).map(saved.contains) == true }) else {
            return .failure("unconfirmed", "The saved Replace list does not contain the change.")
        }
        return .success(.object([
            "rules": .array(rows.map { row in
                var object = row.saved.object ?? [:]
                object["result"] = .string(row.result)
                return .object(object)
            }),
            "count": .int(saved.count)
        ]))
    }

    private static func value(_ rule: DropReplacement) -> AppControlValue {
        .object(["heard": .string(rule.heard), "wanted": .string(rule.wanted)])
    }

    private static func rule(_ value: AppControlValue) -> DropReplacement? {
        guard let heard = value.object?["heard"]?.string, let wanted = value.object?["wanted"]?.string else { return nil }
        return DropReplacement(heard: heard, wanted: wanted)
    }

    // MARK: Shared

    private static func oneLine(_ text: String) -> Bool {
        !text.unicodeScalars.contains { CharacterSet.newlines.union(.controlCharacters).contains($0) }
    }

    private static func rejected(_ entry: String, _ reason: String) -> AppControlResponse {
        let shown = entry.count > 60 ? String(entry.prefix(60)) + "…" : entry
        return .failure("invalid_term", "\"\(shown)\" \(reason). Nothing was added.")
    }
}

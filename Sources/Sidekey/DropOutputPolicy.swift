import Foundation

/// The selected mode is a contract for the whole take, including recovery and
/// Retry. Smart never substitutes the raw transcript after a cleanup failure.
/// WHY: .project-docs/decisions/2026-10-19-strict-drop-modes.md
struct DropOutputPolicy {
    let mode: TranscriptionMode

    /// What reached the paste step, plus which user rules changed it. The
    /// learning step needs both to tell its own edits from the user's.
    struct Prepared: Equatable {
        let text: String
        let firedReplacements: [DropReplacement]
        let firedFillers: [String]
    }

    @MainActor
    func prepare(
        rawText: String,
        fillerTerms: [String],
        replacements: [DropReplacement] = [],
        preservingMarkdown: () -> Bool = { false },
        cleanup: () async throws -> String
    ) async throws -> String {
        try await prepareDetailed(
            rawText: rawText, fillerTerms: fillerTerms, replacements: replacements,
            preservingMarkdown: preservingMarkdown, cleanup: cleanup
        ).text
    }

    /// Order: Smart cleanup -> Replace (one pass) -> Filler -> punctuation.
    /// Replace runs before Filler so a rule can never resurrect a cut filler
    /// and Filler sees the user's spelling.
    /// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
    @MainActor
    func prepareDetailed(
        rawText: String,
        fillerTerms: [String],
        replacements: [DropReplacement] = [],
        preservingMarkdown: () -> Bool = { false },
        cleanup: () async throws -> String
    ) async throws -> Prepared {
        try Task.checkCancellation()
        let output: String
        switch mode {
        case .fast: output = rawText
        case .smart: output = try await cleanup()
        }
        try Task.checkCancellation()
        let replaced = DropReplaceFilter.apply(output, rules: replacements)
        // Fillers that were really cut: collected on the same (masked) text
        // the filter sees, so a term inside protected code is not counted.
        var firedFillers: [String] = []
        let filter: (String) -> String = { text in
            firedFillers = DropFillerFilter.matchedTerms(in: text, terms: fillerTerms)
            return DropFillerFilter.apply(text, removing: fillerTerms)
        }
        let markdown = mode == .smart && preservingMarkdown()
        let withoutFillers = markdown
            ? SmartMarkdownProtection.filtering(replaced.text, apply: filter) : filter(replaced.text)
        // Both modes: a provider can leave a space before a mark ("слово ?").
        // Run on the real text, not the masked one, so a mark right after
        // inline code is tightened while code bytes and links stay intact.
        let filtered = DropPunctuationSpacing.apply(
            withoutFillers,
            protecting: markdown ? SmartMarkdownProtection.codeRanges(in: withoutFillers) : []
        )
        if filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard mode == .fast else { throw OpenRouterLLMError.emptyContent }
            return Prepared(text: rawText, firedReplacements: [], firedFillers: [])
        }
        return Prepared(text: filtered, firedReplacements: replaced.fired, firedFillers: firedFillers)
    }

    /// Provider bodies and URLs can include dictated content or credentials.
    /// Only fixed copy and the numeric HTTP status reach the island or log.
    static func failureMessage(for error: Error) -> String {
        switch error as? OpenRouterLLMError {
        case .notConfigured, .missingKey, .missingBaseURL, .invalidBaseURL, .missingModel:
            return "Set up Smart in API & Models"
        case .unexpectedStatus(let status, _):
            return "Smart failed (\(status))"
        case .emptyContent:
            return "Smart returned no text"
        default:
            return "Smart unavailable"
        }
    }

    static func requiresConfiguration(for error: Error) -> Bool {
        switch error as? OpenRouterLLMError {
        case .notConfigured, .missingKey, .missingBaseURL, .invalidBaseURL, .missingModel:
            return true
        case .unexpectedStatus(let status, _):
            return [400, 401, 402, 403, 404].contains(status)
        default:
            return false
        }
    }
}

/// Retained only in memory until Retry succeeds or a new take discards it.
struct DropProcessingRetry {
    let rawText: String
    let targetApp: String?
    let targetPID: pid_t?
    let mode: TranscriptionMode
}

import Foundation

/// How a request carries the Vocab list. One saved list; each request takes the
/// part its provider accepts, in list order, when it is built. A term that does
/// not fit is left out of that request only.
/// WHY: .project-docs/decisions/2026-11-22-drop-edit-learning.md
enum VocabularyTransport: Equatable, Sendable {
    /// `keyterm` query parameters: about 500 tokens for all terms (Nova-3).
    case deepgram
    /// Realtime `keyterms` query parameters (Scribe Live): 50 terms.
    case elevenLabsRealtime
    /// Recorded audio `keyterms` form fields: 1,000 terms, 50 characters, 5 words.
    case elevenLabsBatch
    /// `context.terms` in the start message: about 8,000 tokens for the context.
    case soniox
    /// Terms joined into the transcription `prompt` (OpenAI Realtime protocol).
    case openAIPrompt
    /// No vocabulary reaches the model (On this Mac, batch recovery, Retry).
    case none

    /// The realtime transport of a speech account.
    static func realtime(for account: ProviderAccount) -> VocabularyTransport {
        switch account {
        case .deepgram: return .deepgram
        case .elevenLabs: return .elevenLabsRealtime
        case .soniox: return .soniox
        case .openAI, .server: return .openAIPrompt
        case .thisMac, .openRouter, .anthropic: return .none
        }
    }
}

enum VocabularyBudget {
    enum Unit: Equatable, Sendable { case terms, tokens }

    struct Usage: Equatable, Sendable {
        let used: Int
        let limit: Int
        let unit: Unit
        var isFull: Bool { used >= limit }
    }

    /// Conservative token estimate for a term: a token is at most three UTF-8
    /// bytes, so Cyrillic (two bytes a letter) counts about 1.5 letters a token.
    static func estimatedTokens(_ term: String) -> Int {
        max(1, Int((Double(term.utf8.count) / 3).rounded(.up)))
    }

    /// Margin under the documented limits; an over-limit Deepgram request can
    /// fail mid-stream, which would cost the take.
    static let deepgramTokenBudget = 450
    static let elevenLabsRealtimeTermLimit = 50
    static let elevenLabsRealtimeTermLength = 20
    static let sonioxTokenBudget = 7_000
    static let openAIPromptTokenBudget = 800
    /// Percent-encoded query bytes for terms; Cyrillic grows six times in a URL.
    static let queryByteBudget = 8_000

    /// The part of `list` this transport sends, in list order.
    static func terms(_ list: [String], for transport: VocabularyTransport) -> [String] {
        if transport == .elevenLabsBatch { return RecordedMeetingTranscriber.elevenLabsKeyterms(list) }
        guard transport != .none else { return [] }
        var seen = Set<String>()
        var accepted: [String] = []
        var tokens = 0
        var queryBytes = 0
        for raw in list {
            let term = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, !term.contains("\n"), seen.insert(term.lowercased()).inserted else { continue }
            let cost = estimatedTokens(term)
            switch transport {
            case .deepgram:
                let bytes = encodedQueryBytes(name: "keyterm", value: term)
                guard tokens + cost <= deepgramTokenBudget, queryBytes + bytes <= queryByteBudget else { continue }
                tokens += cost; queryBytes += bytes
            case .elevenLabsRealtime:
                let bytes = encodedQueryBytes(name: "keyterms", value: term)
                guard term.count <= elevenLabsRealtimeTermLength,
                      accepted.count < elevenLabsRealtimeTermLimit,
                      queryBytes + bytes <= queryByteBudget else { continue }
                queryBytes += bytes
            case .soniox:
                guard term.count <= 100, tokens + cost <= sonioxTokenBudget else { continue }
                tokens += cost
            case .openAIPrompt:
                // ", " between terms.
                let joined = cost + (accepted.isEmpty ? 0 : 1)
                guard tokens + joined <= openAIPromptTokenBudget else { continue }
                tokens += joined
            case .elevenLabsBatch, .none:
                continue
            }
            accepted.append(term)
        }
        return accepted
    }

    /// Whether `candidate` would be sent on this transport if appended.
    static func accepts(_ candidate: String, appendedTo list: [String], on transport: VocabularyTransport) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return terms(list + [trimmed], for: transport)
            .contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    /// What the drop shows when the list is full for the current route:
    /// terms for ElevenLabs, estimated tokens for the others.
    static func usage(_ list: [String], on transport: VocabularyTransport) -> Usage? {
        let sent = terms(list, for: transport)
        switch transport {
        case .elevenLabsRealtime:
            return Usage(used: sent.count, limit: elevenLabsRealtimeTermLimit, unit: .terms)
        case .elevenLabsBatch:
            return Usage(used: sent.count, limit: 1_000, unit: .terms)
        case .deepgram:
            return Usage(used: sent.map(estimatedTokens).reduce(0, +), limit: deepgramTokenBudget, unit: .tokens)
        case .soniox:
            return Usage(used: sent.map(estimatedTokens).reduce(0, +), limit: sonioxTokenBudget, unit: .tokens)
        case .openAIPrompt:
            let used = sent.map(estimatedTokens).reduce(0, +) + max(0, sent.count - 1)
            return Usage(used: used, limit: openAIPromptTokenBudget, unit: .tokens)
        case .none:
            return nil
        }
    }

    private static func encodedQueryBytes(name: String, value: String) -> Int {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: name, value: value)]
        return (components.percentEncodedQuery?.utf8.count ?? value.utf8.count * 6) + 1
    }
}

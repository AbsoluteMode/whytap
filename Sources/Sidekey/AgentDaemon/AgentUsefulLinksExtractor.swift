import Foundation

/// Pulls a trailing actionable JSON fence off the agent's prose and returns it
/// as a `UsefulActionsBlock` alongside the cleaned answer text.
///
/// The primary contract is `useful.actions` (typed link / path / copy items).
/// For backward compatibility the extractor still understands the legacy
/// `useful.links` fence — both the full `UIBlock` form and a compact
/// `{"links": [...]}` object — and folds those links into all-`link`
/// `ActionItem`s so downstream only ever deals with a single block type.
///
/// The type name is kept (`AgentUsefulLinksExtractor`) so existing call sites
/// stay untouched; only the produced block type widened from links to actions.
enum AgentUsefulLinksExtractor {
    struct Extraction: Equatable {
        let answer: String
        let block: UsefulActionsBlock
    }

    static func extract(from text: String) -> Extraction? {
        guard let fence = trailingJSONFence(in: text),
              let block = usefulActionsBlock(from: fence.json) else {
            return nil
        }
        let answer = String(text[..<fence.openingLowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Extraction(answer: answer, block: block)
    }

    private struct JSONFence {
        let openingLowerBound: String.Index
        let json: String
    }

    /// Compact `useful.actions` object: items without the enclosing kind /
    /// schemaVersion envelope. The agent sometimes emits just the payload.
    private struct CompactUsefulActions: Decodable {
        let items: [ActionItem]
    }

    /// Compact legacy `useful.links` object (kept for backward compatibility).
    private struct CompactUsefulLinks: Decodable {
        let links: [UsefulLink]
    }

    private static func trailingJSONFence(in text: String) -> JSONFence? {
        let trimmedEnd = text.lastIndex { !$0.isWhitespace }.map { text.index(after: $0) } ?? text.startIndex
        guard trimmedEnd > text.startIndex else { return nil }
        let visible = text[..<trimmedEnd]
        guard visible.hasSuffix("```") else { return nil }

        let beforeClosing = visible.dropLast(3)
        guard let opening = beforeClosing.range(of: "```", options: .backwards) else { return nil }
        let body = beforeClosing[opening.upperBound...]
        // Accept ANY info string on the opening fence, not just ```json.
        // Claude emits ```json; Codex emits ```useful.actions — it echoes the
        // block kind as the language tag. The old code hard-matched "json" /
        // bare "{" and silently dropped Codex's fence, leaving raw JSON in the
        // answer. Now: a bare "{" is the body as-is; otherwise the first line
        // is the (ignored) info string and the JSON object follows after the
        // first newline.
        let json: Substring
        if body.hasPrefix("{") {
            json = body
        } else if let newline = body.firstIndex(of: "\n") {
            let rest = body[body.index(after: newline)...]
            guard rest.drop(while: { $0.isWhitespace }).hasPrefix("{") else { return nil }
            json = rest
        } else {
            return nil
        }

        return JSONFence(
            openingLowerBound: opening.lowerBound,
            json: String(json).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func usefulActionsBlock(from json: String) -> UsefulActionsBlock? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()

        // Primary contract: a full useful.actions UIBlock.
        if let block = try? decoder.decode(UIBlock.self, from: data),
           case .usefulActions(let actions) = block {
            return actions
        }
        // Backward compatibility: a full useful.links UIBlock folds into
        // all-link action items.
        if let block = try? decoder.decode(UIBlock.self, from: data),
           case .usefulLinks(let links) = block {
            return actionsBlock(fromLinks: links.links)
        }
        // Compact useful.actions: bare items list without the kind envelope.
        if let compact = try? decoder.decode(CompactUsefulActions.self, from: data) {
            return UsefulActionsBlock(items: compact.items)
        }
        // Compact legacy useful.links: bare links list folds into link items.
        if let compact = try? decoder.decode(CompactUsefulLinks.self, from: data) {
            return actionsBlock(fromLinks: compact.links)
        }
        return nil
    }

    /// Maps legacy `UsefulLink`s into a `UsefulActionsBlock` of `.link` items,
    /// preserving url / description / provider.
    private static func actionsBlock(fromLinks links: [UsefulLink]) -> UsefulActionsBlock {
        UsefulActionsBlock(
            items: links.map { link in
                .link(url: link.url, description: link.description, provider: link.provider)
            }
        )
    }
}

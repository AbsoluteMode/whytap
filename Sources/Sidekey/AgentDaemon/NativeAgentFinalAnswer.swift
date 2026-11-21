import Foundation

/// The only successful completion of a native Agent turn. Presentation is
/// validated locally even when an endpoint ignores strict tool schemas.
/// WHY: .project-docs/decisions/2026-10-22-native-agent.md (Structured completion)
struct NativeAgentFinalAnswer {
    static let toolName = "finish_answer"
    /// Text the user asked to use: shown first as an Insert card that pastes
    /// into the field they came from. Required in the strict schema so the
    /// model decides every turn; a missing value (endpoints that ignore strict
    /// schemas) means none. WHY: .project-docs/decisions/2026-11-22-agent-insert-card.md
    static let insertField = "insert_text"
    static let actionWarning = " Earlier file edits or commands may have completed; check before retrying."
    enum Status: String { case answered, unverified, needs_clarification }
    let status: Status
    let answer: String
    /// The explicit insert_text card, also first in `actions`; nil when none.
    let insert: ActionItem?
    let actions: UsefulActionsBlock

    var visibleText: String {
        switch status {
        case .answered: return answer
        case .unverified: return "Couldn’t verify\n\n" + answer
        case .needs_clarification: return "Clarification needed\n\n" + answer
        }
    }

    static var definition: [String: Any] {
        let string: [String: Any] = ["type": "string"]
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        let source = object(["title": string, "url": string])
        let path = object(["type": ["type": "string", "enum": ["path"]], "path": string, "description": string])
        let copy = object(["type": ["type": "string", "enum": ["copy"]], "text": string, "description": string])
        return ["name": toolName, "strict": true,
                "description": "Finish the turn with the requested answer and at most 20 cards across sources and actions. Call alone, after all evidence and actions have completed. Does not open or execute cards.",
                "parameters": object([
                    "status": ["type": "string", "enum": ["answered", "unverified", "needs_clarification"],
                               "description": "Use unverified when evidence cannot confirm the requested fact; needs_clarification when essential user information is missing."],
                    "answer": ["type": "string", "description": "Direct, nonempty answer rendered as Markdown in a ~320pt panel. Lead with a plain conclusion. Use compact tables, numbered steps, fenced code and at most one NOTE or WARNING callout where useful. Explain uncertainty when applicable. Put links in sources."],
                    "sources": ["type": "array", "items": source, "description": "Supporting public HTTP(S) links with short titles; empty when no sources are needed."],
                    insertField: ["type": "string", "description": "Ready-to-paste plain text shown first as the Insert card, which pastes into the field the user came from and replaces their selection there. The complete result when the user gave text (selected or in the request) and asked to rewrite, shorten, translate, fix or reformat it, or asked for a message or reply to send; the one exact shell command when they asked how to install, update, run or configure something. No Markdown fence, quotes or commentary. Empty string when nothing is meant to be pasted."],
                    "actions": ["type": "array", "items": ["anyOf": [path, copy]],
                                "description": "Verified absolute paths, or further commands and snippets beyond insert_text, with short descriptions; empty when none are needed."]
                ])]
    }

    init(arguments: [String: Any]) throws {
        guard Set(arguments.keys).subtracting([Self.insertField]) == ["status", "answer", "sources", "actions"],
              let rawStatus = arguments["status"] as? String, let status = Status(rawValue: rawStatus),
              let answer = arguments["answer"] as? String,
              let sources = arguments["sources"] as? [[String: Any]],
              let actions = arguments["actions"] as? [[String: Any]],
              sources.count + actions.count <= 20 else { throw Self.invalid() }
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 32_000, Self.hasAnswerContent(text, hasSources: !sources.isEmpty) else { throw Self.invalid() }
        let insert: String
        switch arguments[Self.insertField] {
        case nil, is NSNull: insert = ""
        case let value as String: insert = Self.pasteText(value)
        default: throw Self.invalid()
        }
        guard insert.count <= 32_000 else { throw Self.invalid() }
        var links: [ActionItem] = []
        var items: [ActionItem] = insert.isEmpty ? [] : [.copy(text: insert, description: nil)]
        for source in sources {
            guard Set(source.keys) == ["title", "url"],
                  let title = source["title"] as? String, let raw = source["url"] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  raw.count <= 4096, !raw.contains(where: { $0.isWhitespace }),
                  let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil else { throw Self.invalid() }
            links.append(.link(url: url, description: String(title.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(UsefulLink.maxDescriptionLength)), provider: nil))
        }
        for action in actions {
            guard let type = action["type"] as? String,
                  let description = action["description"] as? String else { throw Self.invalid() }
            let label = String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(UsefulLink.maxDescriptionLength))
            switch type {
            case "path":
                guard Set(action.keys) == ["type", "path", "description"], let path = action["path"] as? String,
                      path.hasPrefix("/"), !path.hasPrefix("//"), path.count <= 4096,
                      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw Self.invalid() }
                items.append(.path(path: path, description: label.isEmpty ? nil : label))
            case "copy":
                guard Set(action.keys) == ["type", "text", "description"], let text = action["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 32_000 else { throw Self.invalid() }
                items.append(.copy(text: text, description: label.isEmpty ? nil : label))
            default: throw Self.invalid()
            }
        }
        self.status = status
        self.answer = text
        self.insert = insert.isEmpty ? nil : .copy(text: insert, description: nil)
        // The requested result and actions come before supporting links.
        self.actions = NativeAgentAnswerArtifacts.merging(nil, UsefulActionsBlock(items: items + links))
    }

    /// Plain paste text: surrounding whitespace removed and one enclosing
    /// Markdown fence unwrapped, so a fenced command does not paste backticks.
    static func pasteText(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines = text.components(separatedBy: "\n")
        guard lines.count >= 3, let first = lines.first, first.hasPrefix("```"), !first.dropFirst(3).contains("`"),
              lines.last?.trimmingCharacters(in: .whitespaces) == "```" else { return text }
        lines.removeFirst(); lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func invalid(actionsAttempted: Bool = false) -> NativeAgentError {
        .message("The model didn’t provide a valid structured answer."
            + (actionsAttempted ? actionWarning : " Try again."))
    }

    /// A conservative format check, not a semantic verifier. Rejects URL lists
    /// and common source-only headings; factual correctness still needs evidence.
    private static func hasAnswerContent(_ text: String, hasSources: Bool) -> Bool {
        var remainder = text.replacingOccurrences(of: #"\[[^\]\n]*\]\(https?://[^\s]+\)"#, with: "", options: [.regularExpression, .caseInsensitive])
        remainder = remainder.replacingOccurrences(of: #"https?://[^\s<>]+"#, with: "", options: [.regularExpression, .caseInsensitive])
        let hasLinks = hasSources || remainder != text
        let headings: Set<String> = ["", "source", "sources", "links", "linksforverification", "seelinks", "seelinksbelow", "seesources",
                                     "источник", "источники", "ссылки", "ссылкидляпроверки", "смотриссылки", "смссылки"]
        return remainder.components(separatedBy: .newlines).contains { line in
            let content = line.replacingOccurrences(of: #"^\s*(?:[-*#>]+\s*|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            let words = content.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            if words.isEmpty {
                return !content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.controlCharacters)).isEmpty
            }
            // Without links, a word such as "Sources" can itself be a valid
            // requested translation. Do not turn a format check into a grader.
            return !hasLinks || !headings.contains(String(String.UnicodeScalarView(words)))
        }
    }
}

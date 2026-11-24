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
    static let actionWarning = " Earlier file edits, commands or Whytap changes may have completed; check before retrying."
    enum Status: String { case answered, unverified, needs_clarification, done }
    /// The model's explicit sign that the turn's confirmed Whytap changes are
    /// its whole result. Offered only with the whytap tool; the provider
    /// accepts it only when a change was confirmed and none failed.
    /// WHY: .project-docs/decisions/2026-11-24-agent-step-drops.md
    static let doneStatus = Status.done.rawValue
    let status: Status
    let answer: String
    /// Status `done` with nothing written and no cards: show no text.
    var showsOnlyChanges: Bool { status == .done }
    /// The explicit insert_text card, also first in `actions`; nil when none.
    let insert: ActionItem?
    let actions: UsefulActionsBlock

    var visibleText: String {
        switch status {
        case .answered, .done: return answer
        case .unverified: return "Couldn’t verify\n\n" + answer
        case .needs_clarification: return "Clarification needed\n\n" + answer
        }
    }

    static var definition: [String: Any] { definition(appChanges: false) }

    /// `appChanges`: the turn has the whytap tool, so status `done` is offered.
    static func definition(appChanges: Bool) -> [String: Any] {
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
                    "status": ["type": "string",
                               "enum": ["answered", "unverified", "needs_clarification"] + (appChanges ? [doneStatus] : []),
                               "description": "Use unverified when evidence cannot confirm the requested fact; needs_clarification when essential user information is missing."
                                + (appChanges ? " Use done only when this turn's confirmed Whytap changes are everything the user asked for and you have nothing to add: answer is then an empty string, with no sources, insert_text or actions, and the app shows the changes itself." : "")],
                    "answer": ["type": "string", "description": (appChanges ? "Empty only with status done. Otherwise a direct, " : "Direct, ") + "nonempty answer rendered as Markdown in a ~320pt panel. Lead with a plain conclusion. Use compact tables, numbered steps, fenced code and at most one NOTE or WARNING callout where useful. Explain uncertainty when applicable. Put links in sources."],
                    "sources": ["type": "array", "items": source, "description": "Supporting public HTTP(S) links with short titles; empty when no sources are needed."],
                    insertField: ["type": "string", "description": "Ready-to-paste plain text shown first as the Insert card, which pastes into the field the user came from and replaces their selection there. The complete result when the user gave text (selected or in the request) and asked to rewrite, shorten, translate, fix or reformat it, or asked for a message or reply to send; the one exact shell command when they asked how to install, update, run or configure something. No Markdown fence, quotes or commentary. Empty string when nothing is meant to be pasted."],
                    "actions": ["type": "array", "items": ["anyOf": [path, copy]],
                                "description": "Verified absolute paths, or further commands and snippets beyond insert_text, with short descriptions; empty when none are needed."]
                ])]
    }

    /// `openAICitations`: the turn ran on OpenAI (directly or an `openai/`
    /// model on OpenRouter), whose built-in search can leave its citation
    /// markup in the text; other providers' output is never touched.
    init(arguments: [String: Any], openAICitations: Bool = true) throws {
        let clean: (String) -> String = { openAICitations ? Self.withoutProviderCitationMarks($0) : $0 }
        guard Set(arguments.keys).subtracting([Self.insertField]) == ["status", "answer", "sources", "actions"],
              let rawStatus = arguments["status"] as? String, var status = Status(rawValue: rawStatus),
              let answer = arguments["answer"] as? String,
              let sources = arguments["sources"] as? [[String: Any]],
              let actions = arguments["actions"] as? [[String: Any]],
              sources.count + actions.count <= 20 else { throw Self.invalid() }
        let text = clean(answer).trimmingCharacters(in: .whitespacesAndNewlines)
        let insertField = (arguments[Self.insertField] as? String).map(clean) ?? arguments[Self.insertField]
        // `done` means no text at all. With text it is an ordinary answer:
        // what the model wrote is never dropped.
        if status == .done, !text.isEmpty { status = .answered }
        if status == .done {
            let insertEmpty = (insertField as? String).map { Self.pasteText($0).isEmpty } ?? true
            guard sources.isEmpty, actions.isEmpty, insertEmpty else { throw Self.invalid() }
        } else {
            guard !text.isEmpty, text.count <= 32_000, Self.hasAnswerContent(text, hasSources: !sources.isEmpty) else { throw Self.invalid() }
        }
        let insert: String
        switch insertField {
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
                guard Set(action.keys) == ["type", "text", "description"], let raw = action["text"] as? String,
                      !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, raw.count <= 32_000 else { throw Self.invalid() }
                let text = clean(raw)
                // A copy card that was only a citation mark is dropped; the answer stays.
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
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
    /// OpenAI's built-in search can leave its citation markup in model text:
    /// "\u{E200}cite\u{E202}turn0search0\u{E201}" (private-use characters
    /// that render as "citeturn0search0"), one or more `turn<n><kind><n>`
    /// references. It is removed, with the spaces before it, only where it
    /// annotates prose: after whitespace or at a line start, before the line
    /// end, whitespace or punctuation, and outside every literal span (fenced
    /// code with backticks or tildes, also in a blockquote or list, and
    /// indented code, as `MarkdownCodeLines` finds them; inline code between equal backtick runs in one paragraph; single
    /// (also multiline), double (with escapes), curly and guillemet quotes). The same bytes inside a word, path, URL or literal stay, as does
    /// any other private-use glyph or sequence.
    /// WHY: .project-docs/decisions/2026-11-22-openai-agent-probe-responses.md
    static func withoutProviderCitationMarks(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{E200}"), let regex = citationMarkup else { return text }
        let string = text as NSString
        let literal = literalRanges(in: text)
        var result = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: string.length)).reversed() {
            let mark = match.range(at: 1)
            guard !literal.contains(where: { NSIntersectionRange($0, mark).length > 0 }) else { continue }
            result = result.replacingCharacters(in: match.range, with: "") as NSString
        }
        return result as String
    }

    private static let citationMarkup = try? NSRegularExpression(
        pattern: "(?:^|[ \\t]+)(\u{E200}cite(?:\u{E202}turn[0-9]+[a-z]+[0-9]+)+\u{E201})(?=$|[\\s.,;:!?)\\]])",
        options: [.anchorsMatchLines])

    /// Literal spans of Markdown and shell text, in UTF-16 ranges.
    static func literalRanges(in text: String) -> [NSRange] {
        let string = text as NSString
        // Fenced and indented code lines and leaf block starts, after
        // Markdown's container rules.
        let structure = MarkdownCodeLines.structure(of: string)
        let blocks = structure.code

        // Delimiters are searched with the code lines blanked out, so one
        // inside a block never pairs with one outside it.
        let masked = NSMutableString(string: text)
        for block in blocks {
            masked.replaceCharacters(in: block, with: String(repeating: " ", count: block.length))
        }
        let search = masked as NSString
        var ranges = blocks
        // Inline code pairs only within one leaf block (paragraph, list item
        // or quote paragraph).
        let starts = structure.blockStarts + [string.length]
        for (start, end) in zip(starts, starts.dropFirst()) where end > start {
            ranges += inlineCode(in: search, range: NSRange(location: start, length: end - start))
        }
        // Quoted text in Markdown or a shell command may span lines whatever
        // they start with, but never a blank line (LF, CRLF or CR).
        let lineBreak = "(?:\\r\\n?|\\n)"
        let patterns = [
            // Shell-style single quotes; an apostrophe inside a word stays inside.
            "(?<![\\p{L}\\p{N}])'(?:[^'\\r\\n]|\(lineBreak)(?![ \\t]*\(lineBreak))|(?<=[\\p{L}\\p{N}])'(?=[\\p{L}\\p{N}]))*'(?![\\p{L}\\p{N}])",
            // Double quotes with backslash escapes.
            "(?<![\\p{L}\\p{N}])\"(?:[^\"\\\\\\r\\n]|\\\\.|\(lineBreak)(?![ \\t]*\(lineBreak)))*\"(?![\\p{L}\\p{N}])",
            "“[^”\\r\\n]*”", "‘(?:[^’\\r\\n]|(?<=[\\p{L}\\p{N}])’(?=[\\p{L}\\p{N}]))*’", "«[^»\\r\\n]*»",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            ranges += regex.matches(in: search as String, range: NSRange(location: 0, length: string.length)).map(\.range)
        }
        return ranges
    }

    /// Code spans: a backtick run up to the next run of the same length. A
    /// backslash outside a span escapes the next character, so after an odd
    /// number of backslashes a backtick opens nothing.
    private static func inlineCode(in string: NSString, range: NSRange) -> [NSRange] {
        let backtick: unichar = 0x60, backslash: unichar = 0x5C
        let end = NSMaxRange(range)
        func runEnd(_ index: Int) -> Int {
            var cursor = index
            while cursor < end, string.character(at: cursor) == backtick { cursor += 1 }
            return cursor
        }
        var spans: [NSRange] = []
        var index = range.location
        while index < end {
            let current = string.character(at: index)
            if current == backslash { index += 2; continue }
            guard current == backtick else { index += 1; continue }
            let openEnd = runEnd(index), length = openEnd - index
            var cursor = openEnd, close: Int?
            while cursor < end {
                guard string.character(at: cursor) == backtick else { cursor += 1; continue }
                let closeEnd = runEnd(cursor)
                if closeEnd - cursor == length { close = closeEnd; break }
                cursor = closeEnd
            }
            if let close {
                spans.append(NSRange(location: index, length: close - index))
                index = close
            } else {
                index = openEnd
            }
        }
        return spans
    }

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

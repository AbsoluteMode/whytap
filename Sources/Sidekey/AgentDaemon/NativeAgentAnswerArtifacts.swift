import Foundation

/// Presentation fallback for completed answers, never a tool or an authorization.
/// Keeps the existing actions renderer and keyboard controls independent of
/// whether a validated final included every card. No network or file I/O.
enum NativeAgentAnswerArtifacts {
    static func merging(_ existing: UsefulActionsBlock?, _ incoming: UsefulActionsBlock) -> UsefulActionsBlock {
        ordered((existing?.items ?? []) + incoming.items)
    }

    /// Deduplicates (the first occurrence wins) and puts Insert-ready text
    /// (a rewrite, a command) first, so the preselected card is Insert; paths
    /// and links keep their order after it.
    /// WHY: .project-docs/decisions/2026-11-22-agent-insert-card.md
    private static func ordered(_ all: [ActionItem]) -> UsefulActionsBlock {
        var seen = Set<String>()
        let items = all.filter { seen.insert(identity($0)).inserted }
        return UsefulActionsBlock(items: items.filter(isInsert) + items.filter { !isInsert($0) })
    }

    private static func isInsert(_ item: ActionItem) -> Bool {
        if case .copy = item { return true }
        return false
    }

    /// Fence languages whose single command line becomes an Insert card.
    static let shellFenceLanguages: Set<String> = ["bash", "sh", "zsh", "shell", "fish", "console", "terminal"]
    static let maxInferredCommands = 3

    /// `insert` is the final's explicit insert_text card: it stays first. The
    /// answer's own shell commands come next, in answer order, ahead of copy
    /// alternatives the model listed: an answer that leads with a command
    /// (when a lax endpoint dropped insert_text) preselects that command.
    static func collect(from answer: String, existing: UsefulActionsBlock? = nil, insert: ActionItem? = nil,
                        homeDirectory: String = NSHomeDirectory()) -> UsefulActionsBlock? {
        let text = String(answer.prefix(32_000))
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var candidates: [(NSRange, ActionItem)] = []
        var excluded: [NSRange] = []
        var occupied: [NSRange] = []
        func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
            ranges.contains { NSIntersectionRange(range, $0).length > 0 }
        }
        func matches(_ pattern: String) -> [NSTextCheckingResult] {
            Array(((try? NSRegularExpression(pattern: pattern).matches(in: text, range: full)) ?? []).prefix(100))
        }
        func path(_ raw: String, decodePercent: Bool = false) -> ActionItem? {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
            if value.hasPrefix("file://"), let url = URL(string: value),
               url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { value = url.path }
            else if decodePercent { value = value.removingPercentEncoding ?? value }
            if value.hasPrefix("~/") { value = homeDirectory + String(value.dropFirst()) }
            guard value.hasPrefix("/"), !value.hasPrefix("//"),
                  !value.contains("://"), !value.contains(where: { $0.isNewline }),
                  !value.contains(" && "), !value.contains(" | "), !value.contains("; "),
                  value.range(of: #"\s--?[A-Za-z]"#, options: .regularExpression) == nil else { return nil }
            let name = (value as NSString).lastPathComponent
            return .path(path: value, description: name.isEmpty ? value : name)
        }
        // Code/config examples aren't source links. A fence containing only a
        // path/URL remains a copyable value and can also get its usual card.
        // A shell fence holding exactly one command line is the command to run:
        // it becomes an Insert card even when the model left insert_text empty.
        var commands = 0
        for opening in matches(#"(?m)^[ \t]{0,3}(`{3,}|~{3,})([^\n]*)\n"#) {
            guard !overlaps(opening.range, excluded) else { continue }
            let marker = ns.substring(with: opening.range(at: 1))
            let pattern = #"(?m)^[ \t]{0,3}"# + NSRegularExpression.escapedPattern(for: String(marker.prefix(1)))
                + "{\(marker.count),}" + #"[ \t]*\r?$"#
            let bodyStart = NSMaxRange(opening.range)
            let closing = (try? NSRegularExpression(pattern: pattern))?
                .firstMatch(in: text, range: NSRange(location: bodyStart, length: ns.length - bodyStart))
            let bodyEnd = closing?.range.location ?? ns.length
            let fence = NSRange(location: opening.range.location,
                                length: (closing.map { NSMaxRange($0.range) } ?? ns.length) - opening.range.location)
            excluded.append(fence)
            let language = ns.substring(with: opening.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard closing != nil else { continue }
            let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if shellFenceLanguages.contains(language) {
                if commands < maxInferredCommands, let command = singleCommand(body) {
                    commands += 1
                    candidates.append((fence, .copy(text: command, description: nil)))
                }
                continue
            }
            guard ["", "text", "plaintext", "path"].contains(language) else { continue }
            if let item = path(body) { candidates.append((fence, item)) }
            else if let url = webURL(body) { candidates.append((fence, link(url))) }
        }
        // A code span is either a single returned value or code, never a set
        // of links found inside a shell command. Handle it before detection.
        for span in matches(#"(?<!`)(`+)([^`\r\n]+)\1(?!`)"#) {
            guard !overlaps(span.range, excluded) else { continue }
            excluded.append(span.range)
            let value = ns.substring(with: span.range(at: 2))
            if let url = webURL(value) { candidates.append((span.range, link(url))) }
            else if let item = path(value) { candidates.append((span.range, item)) }
        }
        for opening in matches(#"\[([^\]\r\n]{1,120})\]\("#) {
            guard !overlaps(opening.range, excluded + occupied) else { continue }
            let start = NSMaxRange(opening.range)
            var index = start, depth = 1
            var end: Int?
            var angle = false
            var quote: unichar?
            // Match the actual Markdown delimiter, not the first ')' in a
            // Wikipedia-style target. Quotes/angle targets may contain ')'.
            while index < ns.length {
                let char = ns.character(at: index)
                if char == 10 || char == 13 { break }
                if char == 92 { index += 2; continue }
                if let active = quote { if char == active { quote = nil } }
                else if angle { if char == 62 { angle = false } }
                else if char == 60 { angle = true }
                else if (char == 34 || char == 39), index > start,
                        (ns.character(at: index - 1) == 32 || ns.character(at: index - 1) == 9) { quote = char }
                else if char == 40 { depth += 1 }
                else if char == 41 { depth -= 1; if depth == 0 { end = index; break } }
                index += 1
            }
            guard let end else { continue }
            let range = NSRange(location: opening.range.location, length: end + 1 - opening.range.location)
            occupied.append(range)
            var target = ns.substring(with: NSRange(location: start, length: end - start))
            if let title = target.range(of: #"\s+["'][^"']*["']$"#, options: .regularExpression) {
                target.removeSubrange(title)
            }
            target = target.trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
            target = target.replacingOccurrences(of: "\\(", with: "(").replacingOccurrences(of: "\\)", with: ")")
            if let url = webURL(target) {
                candidates.append((range, link(url, label: ns.substring(with: opening.range(at: 1)))))
            } else if let item = path(target, decodePercent: true) { candidates.append((range, item)) }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            // Markdown cells can touch their pipe delimiters. Mask the raw
            // pipes for detection while keeping UTF-16 ranges in the answer.
            let detectorText = text.replacingOccurrences(of: "|", with: " ")
            detector.enumerateMatches(in: detectorText, range: full) { match, _, stop in
                guard let match else { return }
                if candidates.count >= 100 { stop.pointee = true; return }
                let alreadyCovered = overlaps(match.range, excluded + occupied)
                if match.url?.isFileURL != true { occupied.append(match.range) }
                guard !alreadyCovered, let detected = match.url,
                      let scheme = detected.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
                var raw = ns.substring(with: match.range)
                let prefix = ns.substring(to: match.range.location)
                let wrapping = String(prefix.reversed().prefix { "*_~".contains($0) }.reversed())
                if !wrapping.isEmpty, raw.hasSuffix(String(wrapping.reversed())) { raw = String(raw.dropLast(wrapping.count)) }
                let target = raw.lowercased().hasPrefix("\(scheme)://") ? raw : "\(scheme)://" + raw
                if let url = webURL(target) { candidates.append((match.range, link(url))) }
            }
        }
        for match in matches(#"["“«]((?:/|~/|file://)[^"”»\r\n]+)["”»]"#) {
            guard !overlaps(match.range, excluded + occupied) else { continue }
            let range = match.range(at: 1)
            if let item = path(ns.substring(with: range)) {
                candidates.append((match.range, item)); occupied.append(match.range)
            }
        }
        // Unquoted paths are conservative. Space-containing paths are supported
        // in code spans, quotes and Markdown destinations without guessing where
        // the surrounding sentence ends.
        for match in matches(#"(?<![\p{L}\p{N}_:/])(?:~/|/(?:Users|Volumes|Applications|Library|System|private|tmp|var|opt|usr|etc|home)/)[^\s`<>"'\[\]{}]+"#) {
            guard !overlaps(match.range, excluded + occupied) else { continue }
            let value = ns.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}»”"))
            if let item = path(value) { candidates.append((match.range, item)) }
        }
        var seen = Set<String>()
        let inferred = candidates.sorted { $0.0.location < $1.0.location }.map(\.1)
            .filter { seen.insert(identity($0)).inserted }
        let explicit = existing?.items ?? []
        // A command the model also listed keeps its explicit metadata.
        let metadata = Dictionary(explicit.map { (identity($0), $0) }, uniquingKeysWith: { first, _ in first })
        let answerCommands = inferred.filter(isInsert).map { metadata[identity($0)] ?? $0 }
        let block = ordered((insert.map { [$0] } ?? []) + answerCommands + explicit + inferred.filter { !isInsert($0) })
        return block.items.isEmpty ? nil : block
    }

    /// The one command line of a shell fence, without a `$ `/`% ` prompt.
    /// Comments and blank lines are ignored; several commands, a line
    /// continuation or a heredoc mean a script, which gets no card.
    static func singleCommand(_ body: String) -> String? {
        let lines = body.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard lines.count == 1, var command = lines.first else { return nil }
        for prompt in ["$ ", "% "] where command.hasPrefix(prompt) {
            command = String(command.dropFirst(prompt.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !command.isEmpty, command.count <= 2_000, !command.hasSuffix("\\"), !command.contains("<<") else { return nil }
        return command
    }

    private static func webURL(_ text: String) -> URL? {
        guard !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func identity(_ item: ActionItem) -> String {
        guard let url = webURL(item.insertText), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return item.insertText }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.string ?? item.insertText
    }

    private static func link(_ url: URL, label: String? = nil) -> ActionItem {
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = label.isEmpty ? (url.host ?? url.absoluteString) : label
        return .link(url: url, description: String(description.prefix(UsefulLink.maxDescriptionLength)), provider: nil)
    }
}

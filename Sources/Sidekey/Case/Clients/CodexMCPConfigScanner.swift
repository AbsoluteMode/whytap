import Foundation

/// What `~/.codex/config.toml` says about one MCP server name, read without a
/// TOML library. Only the plain form `codex mcp add` writes is ever reported
/// as a table:
///
///     [mcp_servers.whytap]          # any key quoting, spaces, a comment
///     command = "/path/to/whytap"
///     args = ["mcp"]
///
/// Every other way TOML can define that server (an inline table, dotted keys,
/// an array of tables, a repeated header or key, a line this reader cannot
/// follow) is `.uncertain`. Comments and multi-line strings are removed first,
/// so text inside them never reads as a table. Callers treat
/// `.uncertain` as someone else's server: `codex mcp add` replaces an entry by
/// name, so refusing is safe and overwriting is not.
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
enum CodexMCPEntry: Equatable {
    case absent
    /// `command`/`args` nil when the key is missing. `argsReadable` is false
    /// when `args` is present but not a plain array of plain strings.
    case table(command: String?, args: [String]?, argsReadable: Bool)
    case uncertain
}

enum CodexMCPConfigScanner {
    static func entry(named name: String, in text: String) -> CodexMCPEntry {
        guard text.contains(name) else { return .absent }
        guard let clean = withoutCommentsAndMultilineStrings(text.replacingOccurrences(of: "\r\n", with: "\n")) else {
            return .uncertain // an unterminated string: nothing after it can be trusted
        }
        let lines = clean.components(separatedBy: "\n")
        /// nil: the current header could not be read.
        var table: [String]? = []
        var inTarget = false
        var targetHeaders = 0
        var defined = false
        var command: String?
        var commandSeen = false
        var args: [String]?
        var argsSeen = false
        var argsReadable = true

        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            guard let stripped = stripComment(raw) else {
                if raw.contains(name) { return .uncertain }
                continue
            }
            let line = stripped.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                let isArray = line.hasPrefix("[[")
                let wellFormed = isArray ? (line.hasSuffix("]]") && line.count >= 4) : line.hasSuffix("]")
                let inner = isArray ? line.dropFirst(2).dropLast(2) : line.dropFirst().dropLast()
                guard wellFormed, let path = keyPath(String(inner)) else {
                    if raw.contains(name) { return .uncertain }
                    table = nil
                    inTarget = false
                    continue
                }
                table = path
                inTarget = false
                if path.count >= 2, path[0] == "mcp_servers", path[1] == name {
                    if isArray { return .uncertain }
                    defined = true
                    if path.count == 2 {
                        targetHeaders += 1
                        if targetHeaders > 1 { return .uncertain }
                        inTarget = true
                    }
                }
                continue
            }

            // key = value, the value possibly spanning lines ([ ... ] / { ... }).
            guard let equals = firstUnquoted("=", in: line) else {
                if raw.contains(name) { return .uncertain }
                continue
            }
            let keyText = String(line[..<equals])
            var value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            var depth = nesting(value)
            while let open = depth, open > 0, index < lines.count {
                guard let next = stripComment(lines[index]) else { return .uncertain }
                index += 1
                value += "\n" + next
                depth = nesting(value)
            }
            guard depth == 0 else {
                if keyText.contains(name) || value.contains(name) { return .uncertain }
                continue
            }
            guard let key = keyPath(keyText), let current = table else {
                if keyText.contains(name) || value.contains(name) { return .uncertain }
                continue
            }
            let full = current + key
            if full.first == "mcp_servers", full.count == 1 {
                // `mcp_servers = { ... }`: an inline table of every server.
                if value.contains(name) { return .uncertain }
                continue
            }
            guard full.count >= 2, full[0] == "mcp_servers", full[1] == name else { continue }
            // Keys of our own sub-tables (`[mcp_servers.whytap.env]`) are not
            // the server's command; plain keys directly inside our header are.
            // Any other way of defining this server is not the form codex writes.
            if !inTarget, current.count > 2, current[0] == "mcp_servers", current[1] == name { continue }
            guard inTarget, key.count == 1 else { return .uncertain }
            switch key[0] {
            case "command":
                if commandSeen { return .uncertain }
                commandSeen = true
                command = basicOrLiteralString(value)
            case "args":
                if argsSeen { return .uncertain }
                argsSeen = true
                args = stringArray(value)
                argsReadable = args != nil
            default:
                break
            }
        }
        guard defined else { return .absent }
        return .table(command: command, args: args, argsReadable: argsReadable)
    }

    /// The text with `#` comments removed and each multi-line string replaced
    /// by a one-line placeholder string; nil when any string is left open.
    static func withoutCommentsAndMultilineStrings(_ text: String) -> String? {
        let chars = Array(text)
        var out = ""
        var i = 0
        func starts(_ s: String, at index: Int) -> Bool {
            let pattern = Array(s)
            return index + pattern.count <= chars.count && Array(chars[index..<index + pattern.count]) == pattern
        }
        while i < chars.count {
            let ch = chars[i]
            if starts("\"\"\"", at: i) || starts("'''", at: i) {
                let quote = ch
                let delimiter = String(repeating: quote, count: 3)
                var j = i + 3
                var closed = false
                while j < chars.count {
                    if quote == "\"", chars[j] == "\\" { j += 2; continue }
                    if starts(delimiter, at: j) {
                        j += 3
                        // Up to two more quotes belong to the string's content.
                        var extra = 0
                        while extra < 2, j < chars.count, chars[j] == quote { j += 1; extra += 1 }
                        closed = true
                        break
                    }
                    j += 1
                }
                guard closed else { return nil }
                out += "\"<multi-line string>\""
                i = j
                continue
            }
            if ch == "\"" || ch == "'" {
                var j = i + 1
                var closed = false
                while j < chars.count, chars[j] != "\n" {
                    if ch == "\"", chars[j] == "\\" { j += 2; continue }
                    if chars[j] == ch { closed = true; break }
                    j += 1
                }
                guard closed else { return nil }
                out += String(chars[i...j])
                i = j + 1
                continue
            }
            if ch == "#" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            out.append(ch)
            i += 1
        }
        return out
    }

    /// The line without its `#` comment; nil when a string is left open.
    static func stripComment(_ line: String) -> String? {
        var out = ""
        var quote: Character?
        var escaped = false
        for ch in line {
            if let q = quote {
                out.append(ch)
                if q == "\"" {
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == q { quote = nil }
                } else if ch == q { quote = nil }
                continue
            }
            if ch == "#" { return out }
            if ch == "\"" || ch == "'" { quote = ch }
            out.append(ch)
        }
        return quote == nil ? out : nil
    }

    /// A dotted TOML key: bare segments or quoted ones, spaces around dots.
    /// nil for anything else, including escapes inside basic-string keys.
    static func keyPath(_ text: String) -> [String]? {
        var segments: [String] = []
        var rest = Substring(text)
        while true {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = rest.first else { return nil }
            if first == "\"" || first == "'" {
                let body = rest.dropFirst()
                guard let close = body.firstIndex(of: first) else { return nil }
                let segment = body[..<close]
                if first == "\"", segment.contains("\\") { return nil }
                segments.append(String(segment))
                rest = body[body.index(after: close)...]
            } else {
                let bare = rest.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
                guard !bare.isEmpty else { return nil }
                segments.append(String(bare))
                rest = rest.dropFirst(bare.count)
            }
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.isEmpty { return segments }
            guard rest.first == "." else { return nil }
            rest = rest.dropFirst()
        }
    }

    /// Bracket depth of `[`/`{` outside strings; nil for unbalanced closers.
    private static func nesting(_ value: String) -> Int? {
        var depth = 0
        var quote: Character?
        var escaped = false
        for ch in value {
            if let q = quote {
                if q == "\"" {
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == q { quote = nil }
                } else if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case "[", "{": depth += 1
            case "]", "}":
                depth -= 1
                if depth < 0 { return nil }
            default: break
            }
        }
        return quote == nil ? depth : nil
    }

    private static func firstUnquoted(_ target: Character, in line: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for i in line.indices {
            let ch = line[i]
            if let q = quote {
                if q == "\"" {
                    if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == q { quote = nil }
                } else if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == target { return i }
        }
        return nil
    }

    /// A whole value that is one basic string without escapes or one literal string.
    static func basicOrLiteralString(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count >= 2, let first = v.first, first == "\"" || first == "'", v.last == first else { return nil }
        let body = v.dropFirst().dropLast()
        guard !body.contains(first), !(first == "\"" && body.contains("\\")) else { return nil }
        return String(body)
    }

    /// `["a", 'b']`, possibly across lines with a trailing comma.
    static func stringArray(_ value: String) -> [String]? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.hasPrefix("["), v.hasSuffix("]") else { return nil }
        let inner = v.dropFirst().dropLast()
        var items: [String] = []
        var current = ""
        var quote: Character?
        for ch in inner {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { quote = ch; current.append(ch); continue }
            if ch == "," { items.append(current); current = ""; continue }
            current.append(ch)
        }
        guard quote == nil else { return nil }
        items.append(current)
        var values = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if values == [""] { return [] }                          // `[]`
        if values.count > 1, values.last == "" { values.removeLast() } // one trailing comma
        var strings: [String] = []
        for item in values {
            guard let string = basicOrLiteralString(item) else { return nil }
            strings.append(string)
        }
        return strings
    }
}

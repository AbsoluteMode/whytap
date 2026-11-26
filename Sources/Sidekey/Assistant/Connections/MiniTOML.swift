import Foundation

/// Just enough TOML to read `[mcp_servers.*]` from Codex's config.toml:
/// tables (dotted and quoted names), `key = value` with basic and literal
/// strings, booleans, numbers, arrays (also across lines, with comments and a
/// trailing comma) and inline tables. A line it cannot read (a multi-line
/// string, an array of tables) marks its table unreadable, so an importer can
/// refuse that entry instead of offering it with a setting missing.
enum MiniTOML {
    struct Document {
        /// Table path → key → value. Inline tables become nested `.object`s.
        var tables: [[String]: [String: MCPValue]] = [[]: [:]]
        /// Tables with at least one line that was not understood.
        var unreadable: Set<[String]> = []
    }

    static func parse(_ text: String) -> [[String]: [String: MCPValue]] { document(text).tables }

    static func document(_ text: String) -> Document {
        var document = Document()
        var current: [String] = []
        let lines = text.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty { continue }
            if line.hasPrefix("[[") {
                var scanner = Scanner(line, at: 2)
                current = (scanner.keyPath() ?? ["\u{0}unreadable"])
                document.unreadable.insert(current)
                continue
            }
            if line.hasPrefix("[") {
                var scanner = Scanner(line, at: 1)
                guard let path = scanner.keyPath(), scanner.skip("]"), scanner.atEnd else {
                    current = ["\u{0}unreadable"]; document.unreadable.insert(current); continue
                }
                current = path
                if document.tables[current] == nil { document.tables[current] = [:] }
                continue
            }
            if line.contains("\"\"\"") || line.contains("'''") {
                document.unreadable.insert(current)
                // Skip to the end of the multi-line string.
                let marker = line.contains("\"\"\"") ? "\"\"\"" : "'''"
                if line.components(separatedBy: marker).count == 2 {
                    while index < lines.count, !lines[index].contains(marker) { index += 1 }
                    index += 1
                }
                continue
            }
            // A value may continue on the next lines (an array).
            var joined = line
            var parsed: (key: [String], value: MCPValue)? = parseAssignment(joined)
            var extra = 0
            while parsed == nil, index < lines.count, extra < 500, bracketDepth(joined) > 0 {
                joined += " " + stripComment(lines[index]).trimmingCharacters(in: .whitespaces)
                index += 1; extra += 1
                parsed = parseAssignment(joined)
            }
            guard let (key, value) = parsed else { document.unreadable.insert(current); continue }
            // A dotted key `env.TOKEN = "x"` lands in the sub-table.
            let table = current + key.dropLast()
            document.tables[table, default: [:]][key.last!] = value
        }
        return document
    }

    private static func parseAssignment(_ line: String) -> ([String], MCPValue)? {
        var scanner = Scanner(line, at: 0)
        guard let key = scanner.keyPath(), scanner.skip("="), let value = scanner.value(), scanner.atEnd else { return nil }
        return (key, value)
    }

    /// Removes a `#` comment outside quotes.
    static func stripComment(_ line: String) -> String {
        var quote: Character?, escaped = false, result = ""
        for character in line {
            if let open = quote {
                if escaped { escaped = false }
                else if character == "\\" && open == "\"" { escaped = true }
                else if character == open { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "#" { break }
            result.append(character)
        }
        return result
    }

    /// Open `[` and `{` outside quotes.
    private static func bracketDepth(_ text: String) -> Int {
        var depth = 0, quote: Character?, escaped = false
        for character in text {
            if let open = quote {
                if escaped { escaped = false }
                else if character == "\\" && open == "\"" { escaped = true }
                else if character == open { quote = nil }
            } else if character == "\"" || character == "'" { quote = character }
            else if character == "[" || character == "{" { depth += 1 }
            else if character == "]" || character == "}" { depth -= 1 }
        }
        return depth
    }

    private struct Scanner {
        let characters: [Character]
        var index: Int

        init(_ text: String, at index: Int) { characters = Array(text); self.index = index }

        var atEnd: Bool { var copy = self; copy.spaces(); return copy.index >= copy.characters.count }

        mutating func spaces() { while index < characters.count, characters[index] == " " || characters[index] == "\t" { index += 1 } }

        mutating func skip(_ character: Character) -> Bool {
            spaces()
            guard index < characters.count, characters[index] == character else { return false }
            index += 1
            return true
        }

        mutating func keyPath() -> [String]? {
            var parts: [String] = []
            repeat {
                spaces()
                guard index < characters.count else { return nil }
                if characters[index] == "\"" || characters[index] == "'" {
                    guard let part = string() else { return nil }
                    parts.append(part)
                } else {
                    var part = ""
                    while index < characters.count, characters[index].isLetter || characters[index].isNumber
                            || characters[index] == "_" || characters[index] == "-" {
                        part.append(characters[index]); index += 1
                    }
                    guard !part.isEmpty else { return nil }
                    parts.append(part)
                }
                spaces()
            } while skip(".")
            return parts
        }

        mutating func string() -> String? {
            guard index < characters.count else { return nil }
            let quote = characters[index]
            index += 1
            var result = ""
            while index < characters.count {
                let character = characters[index]
                index += 1
                if character == quote { return result }
                if quote == "\"", character == "\\", index < characters.count {
                    let escaped = characters[index]
                    index += 1
                    switch escaped {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    case "\"": result.append("\"")
                    case "\\": result.append("\\")
                    default: result.append(escaped)
                    }
                } else { result.append(character) }
            }
            return nil
        }

        mutating func value() -> MCPValue? {
            spaces()
            guard index < characters.count else { return nil }
            switch characters[index] {
            case "\"", "'": return string().map(MCPValue.string)
            case "[":
                index += 1
                var items: [MCPValue] = []
                while true {
                    spaces()
                    if skip("]") { return .array(items) }
                    guard let item = value() else { return nil }
                    items.append(item)
                    spaces()
                    if skip(",") { continue }
                    return skip("]") ? .array(items) : nil
                }
            case "{":
                index += 1
                var object: [String: MCPValue] = [:]
                while true {
                    if skip("}") { return .object(object) }
                    guard let key = keyPath(), skip("="), let item = value() else { return nil }
                    object[key.joined(separator: ".")] = item
                    if skip(",") { continue }
                    return skip("}") ? .object(object) : nil
                }
            default:
                var token = ""
                while index < characters.count, !",]} #".contains(characters[index]) { token.append(characters[index]); index += 1 }
                if token == "true" { return .bool(true) }
                if token == "false" { return .bool(false) }
                return Double(token.replacingOccurrences(of: "_", with: "")).map(MCPValue.number)
            }
        }
    }
}

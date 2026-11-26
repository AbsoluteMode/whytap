import Foundation

/// Just enough TOML to read `[mcp_servers.*]` from Codex's config.toml:
/// tables (dotted and quoted names), `key = value` with basic and literal
/// strings, booleans, numbers, single-line arrays and inline tables. Lines it
/// cannot read (multi-line strings, arrays of tables) are skipped; a server
/// entry missing because of that shows up as not importable, never as a crash.
enum MiniTOML {
    /// Table path → key → value. Inline tables become nested `.object`s.
    static func parse(_ text: String) -> [[String]: [String: MCPValue]] {
        var tables: [[String]: [String: MCPValue]] = [[]: [:]]
        var current: [String] = []
        var multiline = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if multiline { if line.contains("\"\"\"") || line.contains("'''") { multiline = false }; continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[[") { current = ["\u{0}skip"]; continue }
            if line.hasPrefix("[") {
                var scanner = Scanner(line, at: 1)
                guard let path = scanner.keyPath(), scanner.skip("]") else { current = ["\u{0}skip"]; continue }
                current = path
                if tables[current] == nil { tables[current] = [:] }
                continue
            }
            if line.contains("\"\"\"") || line.contains("'''") {
                let count = line.components(separatedBy: "\"\"\"").count + line.components(separatedBy: "'''").count - 2
                if count % 2 == 1 { multiline = true }
                continue
            }
            guard current.first != "\u{0}skip" else { continue }
            var scanner = Scanner(line, at: 0)
            guard let key = scanner.keyPath(), scanner.skip("="), let value = scanner.value() else { continue }
            // A dotted key `env.TOKEN = "x"` lands in the sub-table.
            let table = current + key.dropLast()
            tables[table, default: [:]][key.last!] = value
        }
        return tables
    }

    private struct Scanner {
        let characters: [Character]
        var index: Int

        init(_ text: String, at index: Int) { characters = Array(text); self.index = index }

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

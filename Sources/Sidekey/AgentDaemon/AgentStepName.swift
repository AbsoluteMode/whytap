import Foundation

/// Turns a raw agent action into a short, human-readable step label for the
/// response pill. Codex streams the full shell command (wrapped as
/// `/bin/zsh -lc '<cmd>'`); Claude streams the tool name. Both map to the same
/// friendly verbs ("Searching", "Reading", "Running tests") so the user never
/// sees a raw command line. Unknown shell commands collapse to a generic
/// "Running a command"; unknown Claude tools keep their (already clean) name.
enum AgentStepName {
    static let genericShell = "Running a command"

    /// Friendly label for a Codex shell command (the full command line).
    static func forShellCommand(_ raw: String) -> String {
        let inner = stripShellWrapper(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let tokens = meaningfulTokens(inner)
        guard let head = tokens.first else { return genericShell }
        if tokens.count >= 2, let label = multiWordPhrase(head, tokens[1]) { return label }
        return verb(forCommand: head) ?? genericShell
    }

    // MARK: - Shell command parsing

    /// Strips the `…sh -lc '<cmd>'` wrapper Codex runs commands through, plus a
    /// leading `cd <dir> && ` hop, leaving the inner command we actually label.
    private static func stripShellWrapper(_ s: String) -> String {
        var cmd = s
        // `/bin/zsh -lc '...'`  |  `bash -lc "..."`  |  `sh -c '...'`
        if let re = try? NSRegularExpression(pattern: "^(?:/\\S+/)?(?:ba|z)?sh\\s+-[a-z]*c\\s+(.*)$"),
           let m = re.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
           let r = Range(m.range(at: 1), in: cmd) {
            cmd = stripOuterQuotes(String(cmd[r]).trimmingCharacters(in: .whitespaces))
        }
        // `cd <dir> && <cmd>`  |  `cd <dir> ; <cmd>`
        if let re = try? NSRegularExpression(pattern: "^cd\\s+\\S+\\s*(?:&&|;)\\s*(.*)$"),
           let m = re.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)),
           let r = Range(m.range(at: 1), in: cmd) {
            cmd = String(cmd[r]).trimmingCharacters(in: .whitespaces)
        }
        return cmd
    }

    private static func stripOuterQuotes(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, let l = s.last, f == l, f == "'" || f == "\"" else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// Tokenises and drops leading `sudo` / `command` / `env` and `VAR=value`
    /// assignments so the real program name lands first (basename-normalised).
    private static func meaningfulTokens(_ s: String) -> [String] {
        var tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while let first = tokens.first {
            if first == "sudo" || first == "command" || first == "env" {
                tokens.removeFirst()
                continue
            }
            if first.contains("="), !first.contains("/") {   // FOO=bar
                tokens.removeFirst()
                continue
            }
            break
        }
        if let first = tokens.first {
            tokens[0] = (first as NSString).lastPathComponent   // /usr/bin/grep -> grep
        }
        return tokens
    }

    private static func verb(forCommand head: String) -> String? {
        switch head.lowercased() {
        case "grep", "rg", "ag", "ack", "ripgrep": return "Searching"
        case "cat", "bat", "head", "tail", "less", "more": return "Reading"
        case "ls", "find", "fd", "tree", "stat": return "Browsing files"
        case "sed", "awk", "patch", "apply_patch", "tee": return "Editing"
        case "mkdir", "rmdir", "touch", "mv", "cp", "rm", "ln", "chmod", "chown": return "Managing files"
        case "pytest", "jest", "vitest", "rspec": return "Running tests"
        case "python", "python3", "node", "ruby", "deno", "bun", "php", "perl": return "Running"
        case "git": return "Git"
        case "curl", "wget", "http": return "Fetching"
        case "make", "npm", "yarn", "pnpm", "pip", "pip3", "brew", "bundle": return "Building"
        default: return nil
        }
    }

    /// Disambiguates toolchains whose first token alone is ambiguous
    /// (`swift test` vs `swift build`, `cargo run`, `go test`).
    private static func multiWordPhrase(_ head: String, _ second: String) -> String? {
        let toolchains: Set<String> = ["swift", "cargo", "go", "npm", "yarn", "pnpm",
                                       "bun", "deno", "dotnet", "mvn", "gradle"]
        guard toolchains.contains(head.lowercased()) else { return nil }
        switch second.lowercased() {
        case "test", "t": return "Running tests"
        case "build", "compile": return "Building"
        case "run", "exec", "start": return "Running"
        case "install", "add", "i": return "Building"
        default: return nil
        }
    }

    // MARK: - Codex plan / file items

    /// Deterministic progress text. Todo item wording is model-authored and can
    /// otherwise flash in an unrelated language inside the app chrome.
    static func forTodoList(_ items: [CodexTodoItem]) -> String {
        let done = items.filter(\.completed).count
        guard items.contains(where: { !$0.completed }) else {
            return "Plan complete (\(items.count)/\(items.count))"
        }
        let position = min(done + 1, items.count)
        return "Working on plan (\(position)/\(items.count))"
    }

    /// "Creating index.html" / "Editing 3 files" — basenames only.
    static func forFileChange(paths: [String], kind: String) -> String {
        let verb: String
        switch kind {
        case "add": verb = "Creating"
        case "delete": verb = "Deleting"
        default: verb = "Editing"
        }
        if paths.count == 1, let only = paths.first {
            return "\(verb) \((only as NSString).lastPathComponent)"
        }
        return "\(verb) \(paths.count) files"
    }

    // MARK: - Claude tool names

    /// Friendly label for a Claude tool call. Labels are app-owned; arbitrary
    /// model descriptions and raw tool identifiers never reach the app chrome.
    /// File names are basenames only — full user paths never reach the UI.
    static func forClaudeTool(_ name: String, input: ClaudeToolInput) -> String {
        switch name {
        case "Bash", "BashOutput", "KillShell", "KillBash":
            if let command = input.command, !command.isEmpty {
                return forShellCommand(command)
            }
            return genericShell
        case "Read", "NotebookRead":
            if let f = input.filePath, !f.isEmpty {
                return "Reading \((f as NSString).lastPathComponent)"
            }
            return "Reading"
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            if let f = input.filePath, !f.isEmpty {
                return "Editing \((f as NSString).lastPathComponent)"
            }
            return "Editing"
        case "Grep":
            if let p = input.pattern, !p.isEmpty {
                return "Searching \"\(StatusPhrase.clip(p, limit: 30))\""
            }
            return "Searching"
        case "Glob", "LS": return "Browsing files"
        case "WebFetch", "WebSearch": return "Searching the web"
        case "Task": return "Working"
        case "TaskCreate", "TaskUpdate", "TodoWrite": return "Planning"
        default: return "Working"
        }
    }
}

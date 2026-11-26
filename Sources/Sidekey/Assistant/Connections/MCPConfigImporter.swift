import Foundation

/// A source about to be added, with its secret values (which go to Keychain
/// and are then dropped). Keys of `secrets` are `SourceRecord.secretNames`.
struct SourceDraft: Equatable, Sendable {
    var name: String
    var kind: SourceKind
    var importedFrom: String?
    var transport: SourceTransport
    var environment: [SourceValue] = []
    var headers: [SourceValue] = []
    var secrets: [String: String] = [:]
    var proof: SourceProofCall?

    /// Secret names without a value yet (a `${VAR}` placeholder in the other
    /// app's config, or a token the user still has to paste).
    var missing: [String] {
        let names = environment.filter(\.secret).map(\.name) + headers.filter(\.secret).map { "header." + $0.name }
        let arguments: [String]
        if case .stdio(_, let list) = transport {
            arguments = list.compactMap { if case .secret(let name) = $0 { return name }; return nil }
        } else { arguments = [] }
        return (names + arguments).filter { (secrets[$0] ?? "").isEmpty }
    }
}

/// One MCP server found in another app's configuration.
struct SourceImportCandidate: Identifiable, Equatable, Sendable {
    var id: String { app + "/" + (scope ?? "") + "/" + name }
    var app: String
    var name: String
    /// A project folder for project-level entries.
    var scope: String?
    var draft: SourceDraft?
    /// Why it cannot be imported, or a caveat.
    var note: String?
    var summary: String
}

struct SourceImportScan: Equatable, Sendable {
    var candidates: [SourceImportCandidate] = []
    /// "Cursor: ~/.cursor/mcp.json isn't valid JSON." Files that do not exist are not problems.
    var problems: [String] = []
}

/// Reads MCP servers that Claude Code, Claude Desktop, Cursor, Codex and VS Code
/// already have on this Mac. Reads only the server entries (command, args,
/// env, url, headers); writes nothing back. Runs only when the user opens Add
/// source. WHY: .project-docs/decisions/2026-11-26-agent-sources.md
struct MCPConfigImporter {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    static let maxFileBytes = 32 * 1_048_576

    struct Location { let app: String; let path: String; let format: Format }
    enum Format { case claudeCode, mcpServers, codex, vscode }

    static let locations: [Location] = [
        .init(app: "Claude Code", path: ".claude.json", format: .claudeCode),
        .init(app: "Claude Desktop", path: "Library/Application Support/Claude/claude_desktop_config.json", format: .mcpServers),
        .init(app: "Cursor", path: ".cursor/mcp.json", format: .mcpServers),
        .init(app: "Codex", path: ".codex/config.toml", format: .codex),
        .init(app: "VS Code", path: "Library/Application Support/Code/User/mcp.json", format: .vscode),
    ]

    func scan() -> SourceImportScan {
        var scan = SourceImportScan()
        for location in Self.locations {
            let url = home.appendingPathComponent(location.path)
            let shown = "~/" + location.path
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxFileBytes,
                  let data = try? Data(contentsOf: url) else {
                scan.problems.append("\(location.app): couldn’t read \(shown).")
                continue
            }
            switch location.format {
            case .codex:
                guard let text = String(data: data, encoding: .utf8) else {
                    scan.problems.append("\(location.app): \(shown) isn’t text."); continue
                }
                scan.candidates += codex(MiniTOML.parse(text), app: location.app)
            case .claudeCode, .mcpServers, .vscode:
                guard let root = try? MCPValue.decode(data), root.object != nil else {
                    scan.problems.append("\(location.app): \(shown) isn’t valid JSON."); continue
                }
                if location.format == .vscode {
                    scan.candidates += servers(root["servers"], app: location.app, scope: nil)
                } else {
                    scan.candidates += servers(root["mcpServers"], app: location.app, scope: nil)
                }
                if location.format == .claudeCode {
                    for (path, project) in (root["projects"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                        scan.candidates += servers(project["mcpServers"], app: location.app, scope: path)
                    }
                }
            }
        }
        // The same server configured in two apps is offered once.
        var seen: [String: String] = [:]
        scan.candidates = scan.candidates.map { candidate in
            guard candidate.draft != nil else { return candidate }
            if let first = seen[candidate.summary] {
                var copy = candidate
                copy.draft = nil
                copy.note = "Same server as \(first)."
                return copy
            }
            seen[candidate.summary] = candidate.app + " · " + candidate.name
            return candidate
        }
        return scan
    }

    // MARK: - Formats

    private func servers(_ value: MCPValue?, app: String, scope: String?) -> [SourceImportCandidate] {
        (value?.object ?? [:]).sorted { $0.key < $1.key }.map { name, entry in
            Self.candidate(app: app, name: name, scope: scope, entry: entry)
        }
    }

    private func codex(_ tables: [[String]: [String: MCPValue]], app: String) -> [SourceImportCandidate] {
        let names = Set(tables.keys.filter { $0.count == 2 && $0[0] == "mcp_servers" }.map { $0[1] })
            .union(tables.keys.filter { $0.count == 3 && $0[0] == "mcp_servers" }.map { $0[1] })
        return names.sorted().map { name in
            var entry = tables[["mcp_servers", name]] ?? [:]
            for sub in ["env", "http_headers", "env_http_headers"] {
                if let table = tables[["mcp_servers", name, sub]] {
                    entry[sub] = .object((entry[sub]?.object ?? [:]).merging(table) { $1 })
                }
            }
            var headers = entry["http_headers"]?.object ?? [:]
            // Codex reads these headers from its own environment; we ask for the values.
            if let variable = entry["bearer_token_env_var"]?.string {
                headers["Authorization"] = .string("Bearer ${\(variable)}")
            }
            for (header, variable) in entry["env_http_headers"]?.object ?? [:] {
                headers[header] = .string("${\(variable.string ?? header)}")
            }
            var environment = entry["env"]?.object ?? [:]
            for variable in entry["env_vars"]?.array?.compactMap(\.string) ?? [] where environment[variable] == nil {
                environment[variable] = .string("${\(variable)}")
            }
            var normalized: [String: MCPValue] = [:]
            normalized["command"] = entry["command"]
            normalized["args"] = entry["args"]
            normalized["url"] = entry["url"]
            normalized["env"] = .object(environment)
            normalized["headers"] = .object(headers)
            return Self.candidate(app: app, name: name, scope: nil, entry: .object(normalized))
        }
    }

    // MARK: - One entry

    static func candidate(app: String, name: String, scope: String?, entry: MCPValue) -> SourceImportCandidate {
        let projectSuffix = scope.map { " (" + ($0 as NSString).lastPathComponent + ")" } ?? ""
        var candidate = SourceImportCandidate(app: app, name: name + projectSuffix, scope: scope, draft: nil, note: nil, summary: "")
        let type = entry["type"]?.string?.lowercased()
        let command = entry["command"]?.string
        let url = entry["url"]?.string ?? entry["serverUrl"]?.string
        if name.lowercased() == "whytap" || command?.contains("Whytap.app/") == true || command?.contains("whytap-mcp") == true {
            candidate.summary = command ?? url ?? name
            candidate.note = "This is Whytap’s own server."
            return candidate
        }
        var draft = SourceDraft(name: name, kind: .imported, importedFrom: app, transport: .http(url: ""))
        if type == "sse" || type == "ws" || (type == nil && url?.hasSuffix("/sse") == true && command == nil) {
            candidate.summary = url ?? name
            candidate.note = "Uses the older SSE transport, which Whytap doesn’t support yet."
            return candidate
        }
        if let command, !command.isEmpty, type == nil || type == "stdio" {
            let arguments = entry["args"]?.array?.compactMap(\.string) ?? []
            var secretIndex = 0
            var list: [SourceArgument] = []
            for (index, argument) in arguments.enumerated() {
                let previous = index > 0 ? arguments[index - 1] : nil
                if isSecretArgument(argument, previous: previous) {
                    secretIndex += 1
                    let secretName = "arg.\(secretIndex)"
                    list.append(.secret(secretName))
                    if !argument.contains("${") { draft.secrets[secretName] = argument }
                } else { list.append(.plain(argument)) }
            }
            draft.transport = .stdio(command: command, arguments: list)
            candidate.summary = ([command] + arguments.map { isSecretLooking($0) ? "••••" : $0 }).joined(separator: " ")
        } else if let url, !url.isEmpty {
            guard let parsed = URL(string: url), MCPHTTPTransport.isAllowed(parsed) else {
                candidate.summary = url
                candidate.note = MCPError.insecureURL.message
                return candidate
            }
            draft.transport = .http(url: url)
            candidate.summary = url
        } else {
            candidate.summary = name
            candidate.note = "Has no command or address Whytap can use."
            return candidate
        }
        for (key, value) in (entry["env"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let text = value.string ?? value.int.map(String.init) ?? value.bool.map({ $0 ? "true" : "false" }) else { continue }
            draft.environment.append(SourceValue(name: key, secret: true, value: nil))
            if !text.contains("${") { draft.secrets[key] = text }
        }
        for (key, value) in (entry["headers"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let text = value.string else { continue }
            draft.headers.append(SourceValue(name: key, secret: true, value: nil))
            if !text.contains("${") { draft.secrets["header." + key] = text }
        }
        if case .http = draft.transport, draft.headers.isEmpty {
            candidate.note = "Has no token in its settings. If it signs in through the browser, it won’t connect yet."
        } else if !draft.missing.isEmpty {
            candidate.note = "Needs a value for " + draft.missing.joined(separator: ", ") + " after import."
        }
        if case .stdio(_, let list) = draft.transport, list.contains(where: { if case .secret = $0 { return true }; return false }) {
            candidate.note = (candidate.note.map { $0 + " " } ?? "")
                + "A secret is passed on its command line, visible to local process listings (as it already was)."
        }
        candidate.draft = draft
        return candidate
    }

    private static let secretFlag = try! NSRegularExpression(
        pattern: #"^--?(api[-_]?key|token|access[-_]?token|auth[-_]?token|secret|client[-_]?secret|password|pat|bearer|header|authorization)$"#,
        options: [.caseInsensitive])
    private static let inlineSecret = try! NSRegularExpression(
        pattern: #"^--?[a-z-]*(key|token|secret|password|authorization)[a-z-]*=.+|^[A-Z0-9_]*(TOKEN|KEY|SECRET|PASSWORD|PAT)[A-Z0-9_]*=.+|^(Authorization|X-Api-Key)\s*:"#,
        options: [.caseInsensitive])

    static func isSecretLooking(_ argument: String) -> Bool {
        let prefixes = ["ghp_", "gho_", "ghu_", "ghs_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "xoxr-",
                        "sk-", "sk_live_", "pk_live_", "AKIA", "ya29.", "ATATT", "lin_api_", "ntn_", "secret_"]
        return prefixes.contains { argument.hasPrefix($0) }
            || argument.lowercased().hasPrefix("bearer ")
            || matches(inlineSecret, argument)
    }

    static func isSecretArgument(_ argument: String, previous: String?) -> Bool {
        if isSecretLooking(argument) { return true }
        guard let previous, !argument.hasPrefix("-") else { return false }
        return matches(secretFlag, previous)
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

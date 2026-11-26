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
        (environment.filter(\.secret).map(\.name) + headers.filter(\.secret).map { "header." + $0.name })
            .filter { (secrets[$0] ?? "").isEmpty }
    }

    /// The credential policy for this draft, or nil when it may be added.
    var credentialProblem: String? {
        switch transport {
        case .stdio(_, let arguments, _): return SourceCredentialPolicy.argumentsProblem(arguments)
        case .http(let address):
            return SourceCredentialPolicy.addressProblem(address, sendsSecrets: headers.contains(where: \.secret))
        case .folder: return nil
        }
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
                scan.candidates += codex(MiniTOML.document(text), app: location.app)
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

    /// Codex server keys Whytap carries over; any other key changes how the
    /// server runs or which tools it offers, so such an entry is not offered.
    static let codexKeys: Set<String> = ["command", "args", "env", "env_vars", "cwd", "url", "bearer_token_env_var",
                                         "http_headers", "env_http_headers", "enabled", "startup_timeout_sec",
                                         "tool_timeout_sec", "startup_timeout_ms"]

    private func codex(_ document: MiniTOML.Document, app: String) -> [SourceImportCandidate] {
        let tables = document.tables
        let names = Set(tables.keys.filter { $0.count >= 2 && $0[0] == "mcp_servers" }.map { $0[1] })
        return names.sorted().map { name in
            var entry = tables[["mcp_servers", name]] ?? [:]
            for sub in ["env", "http_headers", "env_http_headers"] {
                if let table = tables[["mcp_servers", name, sub]] {
                    entry[sub] = .object((entry[sub]?.object ?? [:]).merging(table) { $1 })
                }
            }
            let unreadable = document.unreadable.contains { $0.count >= 2 && $0[0] == "mcp_servers" && $0[1] == name }
            let unknown = entry.keys.filter { !Self.codexKeys.contains($0) }.sorted()
                + tables.keys.filter { $0.count > 3 && $0[0] == "mcp_servers" && $0[1] == name }.map { $0.joined(separator: ".") }
                + tables.keys.filter { $0.count == 3 && $0[0] == "mcp_servers" && $0[1] == name
                    && !["env", "http_headers", "env_http_headers"].contains($0[2]) }.map { $0[2] }
            if unreadable || !unknown.isEmpty {
                return SourceImportCandidate(app: app, name: name, scope: nil, draft: nil,
                    note: unreadable ? "Whytap couldn’t read all of its settings in config.toml, so it isn’t offered."
                        : "Uses \(unknown.joined(separator: ", ")), which Whytap can’t carry over yet.",
                    summary: entry["command"]?.string ?? entry["url"]?.string ?? name)
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
            normalized["cwd"] = entry["cwd"]
            normalized["env"] = .object(environment)
            normalized["headers"] = .object(headers)
            return Self.candidate(app: app, name: name, scope: nil, entry: .object(normalized))
        }
    }

    // MARK: - One entry

    /// Keys of a JSON server entry Whytap carries over or may ignore safely.
    static let jsonKeys: Set<String> = ["type", "command", "args", "env", "url", "serverUrl", "headers", "cwd",
                                        "disabled", "enabled", "autoApprove", "alwaysAllow", "timeout", "description",
                                        "transportType"]

    static func candidate(app: String, name: String, scope: String?, entry: MCPValue) -> SourceImportCandidate {
        let projectSuffix = scope.map { " (" + ($0 as NSString).lastPathComponent + ")" } ?? ""
        var candidate = SourceImportCandidate(app: app, name: name + projectSuffix, scope: scope, draft: nil, note: nil, summary: name)
        let type = (entry["type"]?.string ?? entry["transportType"]?.string)?.lowercased()
        let command = entry["command"]?.string
        let url = entry["url"]?.string ?? entry["serverUrl"]?.string
        func refuse(_ note: String, summary: SourceTransport? = nil) -> SourceImportCandidate {
            var copy = candidate
            if let summary { copy.summary = SourceCredentialPolicy.display(summary) }
            copy.draft = nil
            copy.note = note
            return copy
        }
        // What the preview shows is the same masked rendering as a saved source.
        let rawArguments = entry["args"]?.array
        let arguments = rawArguments?.compactMap(\.string) ?? []
        let shownTransport: SourceTransport? = command.map { .stdio(command: $0, arguments: arguments, directory: nil) }
            ?? url.map { .http(url: $0) }
        if let shownTransport { candidate.summary = SourceCredentialPolicy.display(shownTransport) }
        if name.lowercased() == "whytap" || command?.contains("Whytap.app/") == true || command?.contains("whytap-mcp") == true {
            return refuse("This is Whytap’s own server.")
        }
        guard let object = entry.object else { return refuse("Whytap couldn’t read this entry.") }
        let unknown = object.keys.filter { !jsonKeys.contains($0) }.sorted()
        guard unknown.isEmpty else { return refuse("Uses \(unknown.joined(separator: ", ")), which Whytap can’t carry over yet.") }
        if type == "sse" || type == "ws" || (type == nil && url?.hasSuffix("/sse") == true && command == nil) {
            return refuse("Uses the older SSE transport, which Whytap doesn’t support yet.")
        }
        var draft = SourceDraft(name: name, kind: .imported, importedFrom: app, transport: .http(url: ""))
        if let command, !command.isEmpty, type == nil || type == "stdio" {
            guard rawArguments == nil || rawArguments?.count == arguments.count else {
                return refuse("Its arguments aren’t all text, so Whytap can’t run it the same way.")
            }
            var directory = scope
            if let cwd = entry["cwd"] {
                guard let path = cwd.string, !path.isEmpty else { return refuse("Its working folder isn’t a path.") }
                let expanded = (path as NSString).expandingTildeInPath
                if expanded.hasPrefix("/") { directory = expanded }
                else if let scope { directory = (scope as NSString).appendingPathComponent(expanded) }
                else { return refuse("Its working folder is relative, so Whytap can’t run it the same way.") }
            }
            draft.transport = .stdio(command: command, arguments: arguments, directory: directory)
        } else if let url, !url.isEmpty {
            draft.transport = .http(url: url)
        } else {
            return refuse("Has no command or address Whytap can use.")
        }
        return complete()

        func complete() -> SourceImportCandidate {
            candidate.summary = SourceCredentialPolicy.display(draft.transport)
            for (key, value) in (entry["env"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let text = value.string ?? value.int.map(String.init) ?? value.bool.map({ $0 ? "true" : "false" }),
                      SourceCredentialPolicy.isPlainValueAcceptable(text) else {
                    return refuse("A value of \(key) can’t be carried over.")
                }
                draft.environment.append(SourceValue(name: key, secret: true, value: nil))
                if !text.contains("${") { draft.secrets[key] = text }
            }
            for (key, value) in (entry["headers"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let text = value.string, SourceCredentialPolicy.isPlainValueAcceptable(text) else {
                    return refuse("A value of the \(key) header can’t be carried over.")
                }
                draft.headers.append(SourceValue(name: key, secret: true, value: nil))
                if !text.contains("${") { draft.secrets["header." + key] = text }
            }
            if let problem = draft.credentialProblem { return refuse(problem) }
            if case .http = draft.transport, draft.headers.isEmpty {
                candidate.note = "Has no token in its settings. If it signs in through the browser, it won’t connect yet."
            } else if !draft.missing.isEmpty {
                candidate.note = "Needs a value for " + draft.missing.map(SourcesController.displayName).joined(separator: ", ") + " after import."
            }
            candidate.draft = draft
            return candidate
        }
    }
}

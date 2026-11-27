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
        if let problem = SourceCredentialPolicy.problem(transport, sendsSecrets: headers.contains(where: \.secret)) { return problem }
        let plain = (environment + headers).compactMap(\.value)
        return plain.allSatisfy(SourceCredentialPolicy.isPlainValueAcceptable) ? nil : "A value is too long or has line breaks."
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
    /// What the row shows, also for a refused entry: stored already redacted
    /// and rendered only through `SourceCredentialPolicy.display`.
    private(set) var preview: SourceTransport?
    var summary: String { preview.map(SourceCredentialPolicy.display) ?? "" }

    init(app: String, name: String, scope: String?, draft: SourceDraft?, note: String?, preview: SourceTransport?) {
        self.app = app; self.name = name; self.scope = scope; self.draft = draft; self.note = note
        self.preview = preview.map(SourceCredentialPolicy.redacted)
    }
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
    var home: URL
    /// False while the feature is gated off: `scan()` reads no configuration.
    /// WHY: .project-docs/decisions/2026-11-27-agent-sources-gated.md
    var isEnabled: Bool

    init(enabled: Bool = AgentSourcesGate.isEnabled, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        isEnabled = enabled
        self.home = home
    }
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
        guard isEnabled else { return scan }
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
            Self.candidate(app: app, name: name, scope: scope, parsed: Self.jsonEntry(entry, app: app), preview: Self.preview(entry))
        }
    }

    /// A server entry checked against what Whytap can run the same way. Any
    /// key, value type, transport or combination outside this shape is
    /// refused with a reason instead of being dropped or guessed.
    struct Entry: Equatable {
        var command: String?
        var arguments: [String] = []
        var environment: [String: String] = [:]
        var url: String?
        var headers: [String: String] = [:]
        var directory: String?
    }

    /// What the row can show even when the entry is refused.
    static func preview(_ value: MCPValue?) -> SourceTransport? {
        let arguments = (value?["args"]?.array ?? []).map { $0.string ?? "…" }
        if let command = value?["command"]?.string { return .stdio(command: command, arguments: arguments, directory: nil) }
        if let url = value?["url"]?.string ?? value?["serverUrl"]?.string { return .http(url: url) }
        return nil
    }

    struct Refusal: Error, Equatable { let reason: String }

    static func unsupported(_ keys: [String]) -> Refusal {
        Refusal(reason: "Uses \(keys.sorted().joined(separator: ", ")), which Whytap can’t carry over yet.")
    }

    static let sseReason = "Uses the older SSE transport, which Whytap doesn’t support yet."

    /// Keys of a JSON server entry (Claude Code, Claude Desktop, Cursor, VS
    /// Code). `description` is only a label; every other key is carried over.
    static let jsonKeys: Set<String> = ["type", "transportType", "command", "args", "env", "url", "serverUrl", "headers",
                                        "cwd", "disabled", "enabled", "description"]

    static func jsonEntry(_ value: MCPValue, app: String) -> Result<Entry, Refusal> {
        guard let object = value.object else { return .failure(Refusal(reason: "Whytap couldn’t read this entry.")) }
        let unknown = object.keys.filter { !jsonKeys.contains($0) }
        guard unknown.isEmpty else { return .failure(unsupported(unknown)) }
        if let disabled = object["disabled"] {
            guard let flag = disabled.bool else { return .failure(unreadable("disabled")) }
            if flag { return .failure(Refusal(reason: "It’s turned off in \(app).")) }
        }
        if let enabled = object["enabled"] {
            guard let flag = enabled.bool else { return .failure(unreadable("enabled")) }
            if !flag { return .failure(Refusal(reason: "It’s turned off in \(app).")) }
        }
        if let description = object["description"], description.string == nil { return .failure(unreadable("description")) }
        var type: String?
        for key in ["type", "transportType"] where object[key] != nil {
            guard let text = object[key]?.string else { return .failure(unreadable(key)) }
            type = text.lowercased()
        }
        if object["url"] != nil, object["serverUrl"] != nil { return .failure(Refusal(reason: "Has two addresses.")) }
        var entry = Entry()
        if let command = object["command"] {
            guard let text = command.string, !text.isEmpty else { return .failure(unreadable("command")) }
            entry.command = text
        }
        if let url = object["url"] ?? object["serverUrl"] {
            guard let text = url.string, !text.isEmpty else { return .failure(unreadable("url")) }
            entry.url = text
        }
        switch type {
        case nil:
            if entry.command == nil, entry.url?.hasSuffix("/sse") == true { return .failure(Refusal(reason: sseReason)) }
        case "stdio":
            guard entry.command != nil, entry.url == nil else { return .failure(Refusal(reason: "Its type is stdio but it has no command.")) }
        case "http", "streamable-http", "streamablehttp", "streamable_http":
            guard entry.url != nil, entry.command == nil else { return .failure(Refusal(reason: "Its type is http but it has no address.")) }
        case "sse", "ws", "websocket":
            return .failure(Refusal(reason: sseReason))
        case let other?:
            return .failure(Refusal(reason: "Uses the \(String(other.prefix(30))) transport, which Whytap doesn’t support."))
        }
        if entry.command != nil, entry.url != nil { return .failure(Refusal(reason: "Has both a command and an address.")) }
        if entry.command != nil {
            guard object["headers"] == nil else { return .failure(Refusal(reason: "Has headers but runs as a command.")) }
            if let args = object["args"] {
                guard let list = strings(args) else { return .failure(unreadable("args")) }
                entry.arguments = list
            }
            if let env = object["env"] {
                guard let map = stringMap(env) else { return .failure(unreadable("env")) }
                entry.environment = map
            }
            if let cwd = object["cwd"] {
                guard let path = cwd.string, !path.isEmpty else { return .failure(unreadable("cwd")) }
                entry.directory = path
            }
        } else if entry.url != nil {
            let local = ["args", "env", "cwd"].filter { object[$0] != nil }
            guard local.isEmpty else { return .failure(Refusal(reason: "Has \(local.joined(separator: ", ")) but connects to an address.")) }
            if let headers = object["headers"] {
                guard let map = stringMap(headers) else { return .failure(unreadable("headers")) }
                entry.headers = map
            }
        } else {
            return .failure(Refusal(reason: "Has no command or address Whytap can use."))
        }
        return .success(entry)
    }

    /// Codex server keys Whytap carries over. Timeouts, tool filters and any
    /// other key change how Codex runs the server, so such an entry is refused.
    static let codexKeys: Set<String> = ["command", "args", "env", "env_vars", "cwd", "url", "bearer_token_env_var",
                                         "http_headers", "env_http_headers", "enabled"]
    static let codexSubtables: Set<String> = ["env", "http_headers", "env_http_headers"]

    private func codex(_ document: MiniTOML.Document, app: String) -> [SourceImportCandidate] {
        let tables = document.tables
        let names = Set(tables.keys.filter { $0.count >= 2 && $0[0] == "mcp_servers" }.map { $0[1] })
            .union(document.unreadable.filter { $0.count >= 2 && $0[0] == "mcp_servers" }.map { $0[1] })
        return names.sorted().map { name in
            var raw = tables[["mcp_servers", name]] ?? [:]
            var conflict = false
            for sub in Self.codexSubtables {
                guard let table = tables[["mcp_servers", name, sub]] else { continue }
                if raw[sub] != nil { conflict = true }
                raw[sub] = .object(table)
            }
            let preview = Self.preview(.object(raw))
            let unreadable = document.unreadable.contains { $0.count >= 2 && $0[0] == "mcp_servers" && $0[1] == name }
            if unreadable {
                return Self.refused(app: app, name: name, scope: nil, preview: preview,
                                    "Whytap couldn’t read all of its settings in config.toml, so it isn’t offered.")
            }
            if conflict { return Self.refused(app: app, name: name, scope: nil, preview: preview, "Sets the same table twice.") }
            let nested = tables.keys.filter { $0.count >= 3 && $0[0] == "mcp_servers" && $0[1] == name
                && ($0.count > 3 || !Self.codexSubtables.contains($0[2])) }.map { $0.dropFirst(2).joined(separator: ".") }
            let unknown = raw.keys.filter { !Self.codexKeys.contains($0) } + nested
            if !unknown.isEmpty { return Self.refused(app: app, name: name, scope: nil, preview: preview, Self.unsupported(unknown).reason) }
            return Self.candidate(app: app, name: name, scope: nil, parsed: Self.codexEntry(raw, app: app), preview: preview)
        }
    }

    static func codexEntry(_ raw: [String: MCPValue], app: String) -> Result<Entry, Refusal> {
        if let enabled = raw["enabled"] {
            guard let flag = enabled.bool else { return .failure(unreadable("enabled")) }
            if !flag { return .failure(Refusal(reason: "It’s turned off in \(app).")) }
        }
        var entry = Entry()
        if let command = raw["command"] {
            guard let text = command.string, !text.isEmpty else { return .failure(unreadable("command")) }
            entry.command = text
        }
        if let url = raw["url"] {
            guard let text = url.string, !text.isEmpty else { return .failure(unreadable("url")) }
            entry.url = text
        }
        if entry.command != nil, entry.url != nil { return .failure(Refusal(reason: "Has both a command and an address.")) }
        if entry.command != nil {
            let remote = ["bearer_token_env_var", "http_headers", "env_http_headers"].filter { raw[$0] != nil }
            guard remote.isEmpty else { return .failure(Refusal(reason: "Has \(remote.joined(separator: ", ")) but runs as a command.")) }
            if let args = raw["args"] {
                guard let list = strings(args) else { return .failure(unreadable("args")) }
                entry.arguments = list
            }
            if let env = raw["env"] {
                guard let map = stringMap(env) else { return .failure(unreadable("env")) }
                entry.environment = map
            }
            if let names = raw["env_vars"] {
                guard let list = strings(names), list.allSatisfy(isVariableName) else { return .failure(unreadable("env_vars")) }
                // Codex passes these from its own environment; we ask for the values.
                for variable in list where entry.environment[variable] == nil { entry.environment[variable] = "${\(variable)}" }
            }
            if let cwd = raw["cwd"] {
                guard let path = cwd.string, !path.isEmpty else { return .failure(unreadable("cwd")) }
                entry.directory = path
            }
        } else if entry.url != nil {
            let local = ["args", "env", "env_vars", "cwd"].filter { raw[$0] != nil }
            guard local.isEmpty else { return .failure(Refusal(reason: "Has \(local.joined(separator: ", ")) but connects to an address.")) }
            if let headers = raw["http_headers"] {
                guard let map = stringMap(headers) else { return .failure(unreadable("http_headers")) }
                entry.headers = map
            }
            if let variable = raw["bearer_token_env_var"] {
                guard let name = variable.string, isVariableName(name) else { return .failure(unreadable("bearer_token_env_var")) }
                guard entry.headers["Authorization"] == nil else { return .failure(Refusal(reason: "Sets Authorization twice.")) }
                entry.headers["Authorization"] = "Bearer ${\(name)}"
            }
            if let mapped = raw["env_http_headers"] {
                guard let map = stringMap(mapped), map.values.allSatisfy(isVariableName) else {
                    return .failure(unreadable("env_http_headers"))
                }
                for (header, variable) in map {
                    guard entry.headers[header] == nil else { return .failure(Refusal(reason: "Sets \(header) twice.")) }
                    entry.headers[header] = "${\(variable)}"
                }
            }
        } else {
            return .failure(Refusal(reason: "Has no command or address Whytap can use."))
        }
        return .success(entry)
    }

    private static func unreadable(_ key: String) -> Refusal {
        Refusal(reason: "Its \(key) setting isn’t in a form Whytap can carry over.")
    }

    private static func strings(_ value: MCPValue) -> [String]? {
        guard let array = value.array else { return nil }
        let list = array.compactMap(\.string)
        return list.count == array.count ? list : nil
    }

    private static func stringMap(_ value: MCPValue) -> [String: String]? {
        guard let object = value.object else { return nil }
        let map = object.compactMapValues(\.string)
        return map.count == object.count ? map : nil
    }

    private static func isVariableName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    // MARK: - One entry

    static func refused(app: String, name: String, scope: String?, preview: SourceTransport?, _ reason: String) -> SourceImportCandidate {
        let projectSuffix = scope.map { " (" + ($0 as NSString).lastPathComponent + ")" } ?? ""
        return SourceImportCandidate(app: app, name: name + projectSuffix, scope: scope, draft: nil, note: reason, preview: preview)
    }

    /// The draft for a checked entry, or the entry refused with its reason.
    /// Both run the one credential policy; the preview is always masked.
    static func candidate(app: String, name: String, scope: String?, parsed: Result<Entry, Refusal>,
                          preview: SourceTransport? = nil) -> SourceImportCandidate {
        var shown = preview
        if shown == nil, case .success(let entry) = parsed {
            shown = entry.command.map { .stdio(command: $0, arguments: entry.arguments, directory: nil) } ?? entry.url.map { .http(url: $0) }
        }
        func refuse(_ reason: String) -> SourceImportCandidate { refused(app: app, name: name, scope: scope, preview: shown, reason) }
        let entry: Entry
        switch parsed {
        case .failure(let refusal): return refuse(refusal.reason)
        case .success(let value): entry = value
        }
        if name.lowercased() == "whytap" || entry.command?.contains("Whytap.app/") == true || entry.command?.contains("whytap-mcp") == true {
            return refuse("This is Whytap’s own server.")
        }
        var draft = SourceDraft(name: name, kind: .imported, importedFrom: app, transport: .http(url: ""))
        if let command = entry.command {
            var directory = scope
            if let path = entry.directory {
                let expanded = (path as NSString).expandingTildeInPath
                if expanded.hasPrefix("/") { directory = expanded }
                else if let scope { directory = (scope as NSString).appendingPathComponent(expanded) }
                else { return refuse("Its working folder is relative, so Whytap can’t run it the same way.") }
                directory = (directory! as NSString).standardizingPath
            }
            draft.transport = .stdio(command: command, arguments: entry.arguments, directory: directory)
            shown = draft.transport
        } else if let url = entry.url {
            draft.transport = .http(url: url)
        }
        // Every imported value is a secret: Keychain, never the manifest.
        for (key, text) in entry.environment.sorted(by: { $0.key < $1.key }) {
            guard isVariableName(key), SourceCredentialPolicy.isPlainValueAcceptable(text) else {
                return refuse("A value of \(isVariableName(key) ? key : "a variable") can’t be carried over.")
            }
            draft.environment.append(SourceValue(name: key, secret: true, value: nil))
            if !text.contains("${") { draft.secrets[key] = text }
        }
        for (key, text) in entry.headers.sorted(by: { $0.key < $1.key }) {
            guard key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }), !key.isEmpty,
                  SourceCredentialPolicy.isPlainValueAcceptable(text) else {
                return refuse("A header can’t be carried over.")
            }
            draft.headers.append(SourceValue(name: key, secret: true, value: nil))
            if !text.contains("${") { draft.secrets["header." + key] = text }
        }
        if let problem = draft.credentialProblem { return refuse(problem) }
        let projectSuffix = scope.map { " (" + ($0 as NSString).lastPathComponent + ")" } ?? ""
        var candidate = SourceImportCandidate(app: app, name: name + projectSuffix, scope: scope, draft: draft, note: nil, preview: shown)
        if case .http = draft.transport, draft.headers.isEmpty {
            candidate.note = "Has no token in its settings. If it signs in through the browser, it won’t connect yet."
        } else if !draft.missing.isEmpty {
            candidate.note = "Needs a value for " + draft.missing.map(SourcesController.displayName).joined(separator: ", ") + " after import."
        }
        return candidate
    }
}

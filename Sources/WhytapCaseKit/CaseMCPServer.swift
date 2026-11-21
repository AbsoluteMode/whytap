import Foundation

/// Minimal MCP server (JSON-RPC 2.0, newline-delimited) exposing only key and
/// project NAMES. It has no code path that requests or returns values.
/// Stdout carries JSON-RPC only; nothing here logs.
public final class CaseMCPServer {
    private let client: CaseBrokerCalling?
    private let executablePath: String

    /// `client == nil`: the app could not be located; tools answer with an error result.
    public init(client: CaseBrokerCalling?, executablePath: String) {
        self.client = client
        self.executablePath = executablePath
    }

    static func quoted(_ path: String) -> String {
        guard path.contains(where: { " \t'\"\\$`&;|<>()*?[]{}#~!".contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public var instructions: String {
        """
        Whytap Case keeps secrets on this Mac. You can see project and key names, never values.
        Find a needed key directly with case_list_keys(query: "name or description"); no need to list projects first.
        To use a known key, run in your terminal: \(Self.quoted(executablePath)) case run --only KEY_NAME '<command using $KEY_NAME>'
        Use single quotes so your shell does not expand $KEY_NAME; Case injects values and hides them in output.
        If several projects have that key, Case lists them: rerun with -p <project>, choosing by description or asking the user.
        Case keys are for commands you run. Whytap's own dictation, model and meeting provider keys are separate, in Whytap Settings → API & Models.
        Nothing here shows, copies, edits or deletes a key value.
        """
    }

    /// Reads lines until EOF. Never throws on a bad request.
    public func run(readLine: () -> String?, write: (String) -> Void) {
        while let line = readLine() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            if let reply = handle(line: line) { write(reply) }
        }
    }

    /// One request line -> optional reply line (no trailing newline).
    public func handle(line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data) else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let obj = any as? [String: Any], let method = obj["method"] as? String else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
        }
        let id = obj["id"]
        guard let id else { return nil } // notification: never reply
        let params = obj["params"] as? [String: Any] ?? [:]

        func ok(_ result: [String: Any]) -> String? { encode(["jsonrpc": "2.0", "id": id, "result": result]) }
        switch method {
        case "initialize":
            let version = params["protocolVersion"] as? String ?? "2025-06-18"
            return ok([
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "whytap-case", "version": "1.0"],
                "instructions": instructions
            ])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return encode(["jsonrpc": "2.0", "id": id,
                               "error": ["code": -32602, "message": "Invalid params"]])
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            return ok(callTool(name: name, arguments: args))
        default:
            return encode(["jsonrpc": "2.0", "id": id,
                           "error": ["code": -32601, "message": "Method not found"]])
        }
    }

    static var toolNames: Set<String> { Set(tools.compactMap { $0["name"] as? String }) }

    /// Names-only reads, so hosts may run them without asking: MCP's defaults
    /// (no annotations) mean destructive and open-world, and Codex refused to
    /// list key names without an approval it could not ask for. The broker
    /// still decides who may list what.
    // WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
    static let readOnlyAnnotations: [String: Any] = [
        "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false,
    ]

    static let tools: [[String: Any]] = [
        [
            "name": "case_list_projects",
            "description": "List Case projects (names, descriptions, key counts). Never returns values.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
            "annotations": readOnlyAnnotations,
        ],
        [
            "name": "case_list_keys",
            "description": "Find keys directly with query across key names, descriptions and project names; no need to list projects first. Optionally restrict project. Never returns values. An empty result means no key you may see matches, not that the key is missing everywhere.",
            "inputSchema": ["type": "object",
                            "properties": ["project": ["type": "string", "description": "Project name (optional)"],
                                           "query": ["type": "string", "description": "Words to find in key name, description or project (optional)"]]],
            "annotations": readOnlyAnnotations,
        ]
    ]

    /// Also called by the unified `whytap mcp` server (AppControlMCPServer):
    /// the same broker requests, the same registration/scope/approval checks.
    func callTool(name: String, arguments: [String: Any]) -> [String: Any] {
        let request: CaseBrokerRequest
        switch name {
        case "case_list_projects": request = .listProjects
        case "case_list_keys": request = .listKeys(project: arguments["project"] as? String)
        default: return textResult("Unknown tool.", isError: true)
        }
        guard let client else {
            // Only a helper outside an app bundle has no client: opening Whytap would not help.
            return textResult("Whytap is not available: this whytap command is outside the Whytap app. Use Whytap.app/Contents/Helpers/whytap of the installed app; an MCP entry must point there.", isError: true)
        }
        let response: CaseBrokerResponse
        do { response = try client.send(request) } catch {
            return textResult("Whytap Case is unavailable. Open the Whytap app, unlock Case and try again.", isError: true)
        }
        switch response {
        case .projects(let projects):
            if projects.isEmpty { return textResult("No projects.", isError: false) }
            return textResult(projects.map {
                "\(Self.oneLine($0.name)) — \(Self.oneLine($0.description)) (\($0.keyCount) keys)"
            }.joined(separator: "\n"), isError: false)
        case .keys(let keys):
            let terms = (arguments["query"] as? String ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
            let matching = keys.filter { key in
                let metadata = "\(key.name) \(key.description) \(key.project)"
                return terms.allSatisfy {
                    metadata.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            if matching.isEmpty {
                return textResult(terms.isEmpty ? "No keys." : "No matching keys. Try another query or omit project.", isError: false)
            }
            return textResult(matching.map {
                "\(Self.oneLine($0.name)) — \(Self.oneLine($0.description))"
                    + (arguments["project"] is String ? "" : " [\(Self.oneLine($0.project))]")
            }.joined(separator: "\n"), isError: false)
        case .denied(let reason):
            return textResult("Access denied: \(CaseCommand.describe(reason)). "
                + "Register this app in Whytap -> Case -> Connect.", isError: true)
        default:
            return textResult("Unexpected answer from the Whytap Case broker.", isError: true)
        }
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private func textResult(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let d = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return nil }
        return s
    }
}

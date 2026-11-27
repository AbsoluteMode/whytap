import Foundation

/// What a tool may be used for. Assigned in app code; the model never decides
/// on its own whether it may call something.
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md
enum SourceToolClass: String, Codable, CaseIterable, Sendable {
    /// Only retrieves information. The Agent may call it when you ask.
    case read
    /// Changes something on this Mac (Whytap To-do). Reserved for built-ins.
    case localWrite
    /// Creates, changes, sends or triggers something outside this Mac.
    case outward
    /// Deletes or irreversibly changes data.
    case destructive

    var label: String {
        switch self {
        case .read: return "Read"
        case .localWrite: return "Local change"
        case .outward: return "Changes things"
        case .destructive: return "Destructive"
        }
    }
}

/// Where a tool's class came from, shown in the Tools list.
enum SourceClassOrigin: String, Codable, Sendable {
    case preset, serverHint, model, nameRule, unknown, user
}

struct SourceToolDecision: Codable, Equatable, Sendable {
    var toolClass: SourceToolClass
    var origin: SourceClassOrigin
    /// `MCPToolInfo.pinHash` when the class was approved.
    var pinHash: String
    /// The tool changed since approval: unavailable until reviewed.
    var needsReview = false
}

/// A value the server needs: an environment variable, a header or a
/// command-line argument. Secret values live only in Keychain.
struct SourceValue: Codable, Equatable, Sendable {
    var name: String
    var secret: Bool
    /// Plain (non-secret) values only.
    var value: String?
}

enum SourceTransport: Codable, Equatable, Sendable {
    /// Arguments never hold a secret (`SourceCredentialPolicy`); `directory`
    /// is the working folder the other app used (a project), else home.
    case stdio(command: String, arguments: [String], directory: String?)
    case http(url: String)
    /// A folder on this Mac, searched by Whytap itself (no MCP).
    case folder(path: String)
}

enum SourceKind: String, Codable, Sendable {
    case github, jira, imported, custom, folder

    /// Built in, or a reviewed preset whose server enforces read-only
    /// (GitHub's X-MCP-Readonly, mcp-atlassian's READ_ONLY_MODE). Tools of
    /// any other server are usable only after the user approves them.
    var trustedOnConnect: Bool { self == .github || self == .jira || self == .folder }
}

/// A call that proves the source answers. Arguments are a JSON object.
struct SourceProofCall: Codable, Equatable, Sendable {
    var tool: String
    var arguments: MCPValue
}

/// One connected source. Secret values are not here: only their names.
struct SourceRecord: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: SourceKind
    var importedFrom: String?
    var transport: SourceTransport
    var environment: [SourceValue] = []
    var headers: [SourceValue] = []
    var enabled = true
    var tools: [MCPToolInfo] = []
    var decisions: [String: SourceToolDecision] = [:]
    var proof: SourceProofCall?
    /// The tools list was never fetched successfully.
    var neverConnected = true
    /// A folder source's selected folder: its real path and identity.
    var folder: FolderIdentity?
    var addedAt = Date()

    /// Keychain account for one of this source's secret values.
    static func keychainAccount(source id: String, name: String) -> String { "integration.\(id).\(name)" }

    var secretNames: [String] {
        environment.filter(\.secret).map(\.name) + headers.filter(\.secret).map { "header." + $0.name }
    }

    /// Tools the Agent may call automatically: approved Read tools.
    var readTools: [MCPToolInfo] {
        tools.filter { tool in
            guard let decision = decisions[tool.name] else { return false }
            return decision.toolClass == .read && !decision.needsReview && decision.pinHash == tool.pinHash
        }
    }

    /// Tools waiting for the user's approval: changed tools, and every Read
    /// tool of a server that is not trusted on connect.
    var pendingReviewCount: Int { decisions.values.filter(\.needsReview).count }

    var summary: String { SourceCredentialPolicy.display(transport) }
}

/// What Settings shows for a source right now.
enum SourceStatus: Equatable, Sendable {
    case off
    case connecting
    case ready(String)
    case warning(String)
    case failed(String)
    case needsValue([String])

    var text: String {
        switch self {
        case .off: return "Off"
        case .connecting: return "Connecting…"
        case .ready(let text), .warning(let text), .failed(let text): return text
        case .needsValue(let names): return "Needs a value for " + names.joined(separator: ", ")
        }
    }
}

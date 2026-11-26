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

enum SourceArgument: Codable, Equatable, Sendable {
    case plain(String)
    /// The argument's value is in Keychain under this name (`arg.N`).
    case secret(String)
}

enum SourceTransport: Codable, Equatable, Sendable {
    case stdio(command: String, arguments: [SourceArgument])
    case http(url: String)
    /// A folder on this Mac, searched by Whytap itself (no MCP).
    case folder(path: String)
}

enum SourceKind: String, Codable, Sendable {
    case github, jira, imported, custom, folder
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
    var addedAt = Date()

    /// Keychain account for one of this source's secret values.
    static func keychainAccount(source id: String, name: String) -> String { "integration.\(id).\(name)" }

    var secretNames: [String] {
        environment.filter(\.secret).map(\.name) + headers.filter(\.secret).map { "header." + $0.name }
            + argumentSecretNames
    }

    var argumentSecretNames: [String] {
        guard case .stdio(_, let arguments) = transport else { return [] }
        return arguments.compactMap { if case .secret(let name) = $0 { return name }; return nil }
    }

    /// Tools the Agent may call automatically: approved Read tools.
    var readTools: [MCPToolInfo] {
        tools.filter { tool in
            guard let decision = decisions[tool.name] else { return false }
            return decision.toolClass == .read && !decision.needsReview && decision.pinHash == tool.pinHash
        }
    }

    var changedToolCount: Int { decisions.values.filter(\.needsReview).count }

    var summary: String {
        switch transport {
        case .stdio(let command, let arguments):
            let shown = arguments.map { argument -> String in
                if case .plain(let value) = argument { return value }
                return "••••"
            }
            return ([command] + shown).joined(separator: " ")
        case .http(let url): return url
        case .folder(let path): return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Secrets passed in argv are visible to local process listings.
    var hasArgumentSecrets: Bool { !argumentSecretNames.isEmpty }
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

import Foundation

/// Command-line flags that apply the user's Agent settings to their own
/// Claude Code or Codex. Pure functions, so every combination is testable
/// without starting a CLI.
///
/// "Allow file edits and commands" never maps to a blanket bypass
/// (`bypassPermissions`, `--dangerously-bypass-approvals-and-sandbox`):
/// - On: the harness's own reviewed autonomy. Claude Code `auto` mode decides
///   each action with its classifier; Codex runs in its workspace-write sandbox
///   and its `auto_review` reviewer answers escalation requests. An action
///   neither approves is refused, not asked: Whytap has no approval prompt,
///   and an unanswered prompt would stall the turn.
/// - Off: reading, web search and Whytap's own tools only. Claude Code drops
///   its file-writing and command tools and refuses anything not pre-approved;
///   Codex runs read-only with no approvals.
/// Verified live with Claude Code 2.1.325 and codex-cli 0.171.0 (new and
/// resumed turns, and a Claude subagent under Off).
// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
enum AgentHarnessFlags {
    /// The MCP server name the Agent's Whytap tools are reached under. Matches
    /// the name Integrations → Coding tools registers, so a turn replaces that
    /// entry instead of adding a second copy.
    static let whytapServerName = "whytap"

    /// Claude Code tools that change files or run code. Removed under Off.
    static let claudeWriteTools = ["Bash", "PowerShell", "Monitor", "Edit", "Write", "NotebookEdit"]
    /// Claude Code tools Off still allows without asking.
    static let claudeReadTools = ["Read", "Grep", "Glob", "WebSearch", "WebFetch", "mcp__\(whytapServerName)"]

    static func claude(allowActions: Bool) -> [String] {
        if allowActions {
            return ["--permission-mode", "auto", "--permission-prompts", "none"]
        }
        return [
            "--permission-mode", "dontAsk",
            "--permission-prompts", "none",
            "--disallowedTools", claudeWriteTools.joined(separator: ","),
            "--allowedTools", claudeReadTools.joined(separator: ","),
        ]
    }

    /// `-c` overrides: valid on both `codex exec` and `codex exec resume`
    /// (`resume` takes no `-s`/`--approve-for-me`), so every turn carries the
    /// current policy, including a resumed one.
    static func codex(allowActions: Bool) -> [String] {
        if allowActions {
            return ["-c", #"sandbox_mode="workspace-write""#,
                    "-c", #"approval_policy="on-request""#,
                    "-c", #"approvals_reviewer="auto_review""#]
        }
        return ["-c", #"sandbox_mode="read-only""#,
                "-c", #"approval_policy="never""#]
    }

    /// `--mcp-config` for Claude Code: the running app's own helper under the
    /// Coding tools name. The user's other MCP servers still load.
    static func claudeMCPConfig(command: [String]) -> [String] {
        guard let executable = command.first else { return [] }
        let server: [String: Any] = ["type": "stdio", "command": executable, "args": Array(command.dropFirst())]
        guard let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": [whytapServerName: server]],
                                                     options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else { return [] }
        return ["--mcp-config", json]
    }

    /// The same server for Codex as `-c` TOML overrides.
    static func codexMCPConfig(command: [String]) -> [String] {
        guard let executable = command.first else { return [] }
        let args = command.dropFirst().map(tomlString).joined(separator: ",")
        return ["-c", "mcp_servers.\(whytapServerName).command=\(tomlString(executable))",
                "-c", "mcp_servers.\(whytapServerName).args=[\(args)]"]
    }

    /// A TOML basic string.
    static func tomlString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// The running app's helper started as `whytap mcp`, or nil outside a
    /// packaged app (tests, `swift run`).
    static var bundledWhytapMCPCommand: [String]? {
        WhytapBundledHelper.bundledHelperURL.map { [$0.path, "mcp"] }
    }
}

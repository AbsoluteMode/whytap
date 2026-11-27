import Foundation

/// Connected sources for the Agent (MCP servers, GitHub, Jira, folders) are
/// built and tested but hidden until the owner decides whether the feature
/// stays. This constant is the only switch; there is no user-visible toggle.
///
/// With it off: Settings shows no Sources section or Add source…, the Agent
/// gets no `source_call` tool and no source context, no MCP server process
/// starts, no Claude Code/Codex/Cursor/VS Code configuration is scanned,
/// `gh auth token` never runs, and nothing is read from or written to the
/// sources manifest in Application Support or the sources' Keychain items.
/// Tests turn the feature on per instance (`enabled: true`).
/// WHY: .project-docs/decisions/2026-11-27-agent-sources-gated.md
enum AgentSourcesGate {
    static let isEnabled = false
}

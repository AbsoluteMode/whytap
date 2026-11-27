import Foundation

/// Per-turn agent overrides chosen in Settings. A `nil` field means "send no
/// flag" (the CLI uses its own default). Codex controls are validated against
/// its model registry; absent capabilities leave controls to Codex.
/// Provider neutral: Claude ignores `serviceTier`.
struct AgentRunOptions: Equatable {
    var model: String?
    var effort: String?
    var serviceTier: String?
    var workingDirectory: URL?
    /// "Allow file edits and commands" (Features → Agent), mapped to each
    /// CLI's own permission flags by `AgentHarnessFlags`.
    var allowActions: Bool
    /// The running app's `whytap mcp` helper, added to a Claude Code or Codex
    /// turn so Whytap's tools (app control, screen capture) work without the
    /// Coding tools switch. `nil` outside a packaged app.
    var whytapMCPCommand: [String]?

    init(model: String? = nil, effort: String? = nil, serviceTier: String? = nil,
         workingDirectory: URL? = nil, allowActions: Bool = true,
         whytapMCPCommand: [String]? = nil) {
        self.model = model
        self.effort = effort
        self.serviceTier = serviceTier
        self.workingDirectory = workingDirectory
        self.allowActions = allowActions
        self.whytapMCPCommand = whytapMCPCommand
    }
}

import Foundation

enum CLIProviderID: String, Codable, CaseIterable {
    case claude
    case codex
}

/// Result of a Connect probe.
enum ConnectOutcome: Equatable {
    case connected(sessionID: String?)
    case notInstalled
    case notLoggedIn
    case billing
    case failed(code: String, message: String)
}

/// A provider that drives the user's own locally-installed agent CLI.
protocol CLIProvider {
    var id: CLIProviderID { get }
    var displayName: String { get }            // e.g. "Claude Code"
    var installURL: URL { get }                // docs link for the "not installed" notification
    /// The CLI session / thread id from the last completed turn. Nil until
    /// the first turn finishes. Used by AgentController for --resume continuity.
    var lastSessionID: String? { get }
    /// Locate the executable, or nil if not installed.
    func discoverBinary() -> URL?
    /// Run a short handshake; never throws — maps every failure to a ConnectOutcome.
    func probe() async -> ConnectOutcome
    /// Drive one turn. The returned stream yields AgentSSEEvent the pill already understands.
    func run(prompt: String, resumeSessionID: String?, options: AgentRunOptions) -> AsyncStream<AgentSSEEvent>
    /// Forward the user's permission decision to the running process.
    /// Providers that have no approval prompts implement this as a no-op.
    func respondToPermission(requestId: String, decision: PermissionDecision)
}

extension CLIProvider {
    /// Convenience: run with no overrides (inherit the CLI's own config).
    /// Keeps existing 2-arg call sites and tests working unchanged.
    func run(prompt: String, resumeSessionID: String?) -> AsyncStream<AgentSSEEvent> {
        run(prompt: prompt, resumeSessionID: resumeSessionID, options: AgentRunOptions())
    }
}

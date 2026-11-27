import Foundation

/// User-facing Agent messages shared by both harnesses. English, like the
/// rest of the app.
enum AgentHarnessMessages {
    /// The idle watchdog stopped a turn that produced nothing for too long.
    /// Application Support/whytap/agent could not be created.
    static let workspaceUnavailable = "Whytap couldn't prepare the Agent's folder in Application Support. Check free disk space, then try again."
    static let stalled = "The Agent stopped responding, so Whytap ended the request. Try again."
}

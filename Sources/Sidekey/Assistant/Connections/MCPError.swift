import Foundation

/// Why a source could not be reached or answered. Every case has one short
/// sentence for Settings and for the agent's tool result; none carries server
/// output, keys or request content, so these are safe to show anywhere.
enum MCPError: Error, Equatable, Sendable {
    /// The executable does not exist or is not executable.
    case commandNotFound(String)
    /// The process ended. `detail` is the last stderr line with known secret
    /// values masked; it is shown only in Settings, never logged.
    case exited(status: Int32, detail: String?)
    case timedOut(seconds: Int)
    case cancelled
    case unauthorized(status: Int)
    case httpStatus(Int)
    case sessionExpired
    case insecureURL
    case redirectRefused
    case invalidResponse
    case tooLarge(limit: Int)
    case unsupportedProtocol(String)
    case server(code: Int, message: String)
    case notConnected
    case missingSecret(String)
    case network
    case notAllowed

    var message: String {
        switch self {
        case .commandNotFound(let command):
            return "Couldn’t start: \(command) was not found. Install it or use its full path."
        case .exited(let status, let detail):
            let base = status == 0 ? "The server stopped." : "The server exited (status \(status))."
            guard let detail, !detail.isEmpty else { return base }
            return base + " " + detail
        case .timedOut(let seconds): return "The server didn’t answer within \(seconds) s."
        case .cancelled: return "Cancelled."
        case .unauthorized(let status):
            return "The server refused the credentials (HTTP \(status)). Check or replace the token. Browser sign-in isn’t supported yet."
        case .httpStatus(let status): return "The server answered HTTP \(status)."
        case .sessionExpired: return "The server ended the session."
        case .insecureURL: return "Use an https:// address (http:// only for this Mac)."
        case .redirectRefused: return "The server redirected to another address; Whytap doesn’t send credentials there."
        case .invalidResponse: return "The server sent something that isn’t MCP."
        case .tooLarge(let limit): return "The server sent more than \(limit / 1_048_576) MB at once."
        case .unsupportedProtocol(let version): return "The server speaks MCP \(version), which Whytap doesn’t support yet."
        case .server(_, let message): return "The server reported an error: " + String(message.prefix(200))
        case .notConnected: return "Not connected."
        case .missingSecret(let name): return "Add the value for \(name)."
        case .network: return "Couldn’t reach the server. Check the address and your connection."
        case .notAllowed: return "This tool isn’t allowed for the Agent."
        }
    }
}

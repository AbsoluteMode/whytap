import Foundation
@testable import Sidekey

extension MCPClient {
    /// Tests: list, then call under that list's epoch and pin, as the controller does.
    func callListed(_ name: String, arguments: MCPValue, timeout: TimeInterval, maxCharacters: Int) async throws -> MCPToolResult {
        let (tools, epoch) = try await listTools(timeout: 5)
        let pin = tools.first { $0.name == name }?.pinHash ?? ""
        return try await callTool(name, arguments: arguments, timeout: timeout, maxCharacters: maxCharacters,
                                  lease: SourceLease(), epoch: epoch, expectedPin: pin)
    }
}

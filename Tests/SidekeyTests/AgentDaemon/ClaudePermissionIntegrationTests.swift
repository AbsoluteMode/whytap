import XCTest
@testable import Sidekey

/// End-to-end guard against the real `claude` CLI. Opt-in: requires both a
/// `claude` binary AND `SIDEKEY_RUN_CLAUDE_INTEGRATION=1`, so routine
/// `swift test` skips it (no plan usage, no auth needed). Run explicitly:
///   SIDEKEY_RUN_CLAUDE_INTEGRATION=1 swift test --filter ClaudePermissionIntegrationTests
/// The island has no approval bar, so a turn must never stop to ask: with
/// `--permission-prompts none` an action the policy does not allow is refused
/// and the turn still ends. WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
final class ClaudePermissionIntegrationTests: XCTestCase {
    func testRealClaudeNeverWaitsForAnApproval() async throws {
        guard ProcessInfo.processInfo.environment["SIDEKEY_RUN_CLAUDE_INTEGRATION"] == "1",
              ClaudeBinaryLocator().locate() != nil else {
            throw XCTSkip("set SIDEKEY_RUN_CLAUDE_INTEGRATION=1 with claude installed")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = ClaudeCodeProvider()
        let stream = provider.run(
            prompt: "Run exactly this bash command and report output: curl -fsS -o /dev/null -w '%{http_code}' https://example.com",
            resumeSessionID: nil,
            options: AgentRunOptions(model: "haiku", effort: "low", workingDirectory: folder, allowActions: false))

        var sawPermission = false
        var sawDone = false
        for await event in stream {
            switch event {
            case .permissionRequest: sawPermission = true
            case .done: sawDone = true
            case .error(let code, let message, _): XCTFail("unexpected error \(code): \(message)")
            default: break
            }
        }
        XCTAssertFalse(sawPermission, "nothing may wait for an approval Whytap cannot show")
        XCTAssertTrue(sawDone)
        XCTAssertNotNil(provider.lastSessionID)
    }
}

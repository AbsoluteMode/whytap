import XCTest
@testable import Sidekey

/// End-to-end guard against the real `claude` CLI. Opt-in: requires both a
/// `claude` binary on PATH AND `SIDEKEY_RUN_CLAUDE_INTEGRATION=1`, so routine
/// `swift test` skips it (no credits spent, no auth needed). Run explicitly:
///   SIDEKEY_RUN_CLAUDE_INTEGRATION=1 swift test --filter ClaudePermissionIntegrationTests
final class ClaudePermissionIntegrationTests: XCTestCase {
    func testRealClaudeEmitsPermissionRequestAndHonoursAllow() async throws {
        guard ProcessInfo.processInfo.environment["SIDEKEY_RUN_CLAUDE_INTEGRATION"] == "1",
              ClaudeBinaryLocator().locate() != nil else {
            throw XCTSkip("set SIDEKEY_RUN_CLAUDE_INTEGRATION=1 with claude installed")
        }
        let provider = ClaudeCodeProvider()
        let stream = provider.run(
            prompt: "Run exactly this bash command and report output: curl -fsS -o /dev/null -w '%{http_code}' https://example.com",
            resumeSessionID: nil)

        var sawPermission = false
        var sawDone = false
        for await event in stream {
            switch event {
            case .permissionRequest(let id, _, _, let inputJSON):
                sawPermission = true
                provider.respondToPermission(requestId: id, decision: .allow(inputJSON: inputJSON))
            case .done:
                sawDone = true
            case .error(let code, let message, _):
                XCTFail("unexpected error \(code): \(message)")
            default:
                break
            }
        }
        XCTAssertTrue(sawPermission, "expected a can_use_tool ask for curl")
        XCTAssertTrue(sawDone)
        XCTAssertNotNil(provider.lastSessionID)
    }
}

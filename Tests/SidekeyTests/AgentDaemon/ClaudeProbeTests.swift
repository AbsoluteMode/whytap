import XCTest
@testable import Sidekey

final class ClaudeProbeTests: XCTestCase {
    private func provider(_ result: ProcessResult?, binary: URL? = URL(fileURLWithPath: "/x/claude")) -> ClaudeCodeProvider {
        ClaudeCodeProvider(locate: { binary }, runOneShot: { _, _ in result })
    }

    func testNotInstalledWhenNoBinary() async {
        let p = provider(nil, binary: nil)
        let outcome = await p.probe()
        XCTAssertEqual(outcome, .notInstalled)
    }

    /// `claude auth status --json` reports a live subscription login.
    func testConnectedWhenLoggedIn() async {
        let json = #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#
        let outcome = await provider(ProcessResult(stdout: json, stderr: "", exitCode: 0)).probe()
        XCTAssertEqual(outcome, .connected(sessionID: nil))
    }

    /// Logged out -> the user must run `claude login`; we must NOT report connected.
    func testNotLoggedInWhenLoggedOut() async {
        let json = #"{"loggedIn":false}"#
        let outcome = await provider(ProcessResult(stdout: json, stderr: "", exitCode: 0)).probe()
        XCTAssertEqual(outcome, .notLoggedIn)
    }

    /// The handshake must be a lightweight auth-status read, NOT a `-p` model
    /// round-trip. A model call bills tokens and, critically, uses whatever
    /// ANTHROPIC_* credential is in the environment (a stale inherited token in
    /// dev) -> it fails where `auth status` (keychain read) succeeds.
    func testProbeUsesAuthStatusNotModelCall() async {
        var captured: [String] = []
        let p = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/x/claude") },
            runOneShot: { _, args in
                captured = args
                return ProcessResult(stdout: #"{"loggedIn":true}"#, stderr: "", exitCode: 0)
            })
        _ = await p.probe()
        XCTAssertEqual(captured, ["auth", "status", "--json"])
        XCTAssertFalse(captured.contains("-p"))
    }

    /// Unparseable output falls back to the process exit code.
    func testFallsBackToExitCodeOnUnparseableOutput() async {
        let ok = await provider(ProcessResult(stdout: "not json", stderr: "", exitCode: 0)).probe()
        XCTAssertEqual(ok, .connected(sessionID: nil))

        let bad = await provider(ProcessResult(stdout: "", stderr: "boom", exitCode: 7)).probe()
        guard case .failed = bad else { return XCTFail("expected .failed, got \(bad)") }
    }
}

final class ClaudeChildEnvironmentTests: XCTestCase {
    /// The env handed to a spawned `claude` must drop both the Claude Code
    /// process markers (so claude never thinks it is nested) and ambient
    /// Anthropic credentials (so claude always authenticates with the user's
    /// own subscription login, never a stray key/proxy from the launcher).
    func testScrubsAnthropicAndClaudeCodeVars() {
        let parent = [
            "ANTHROPIC_API_KEY": "k",
            "ANTHROPIC_AUTH_TOKEN": "t",
            "ANTHROPIC_BASE_URL": "u",
            "ANTHROPIC_CUSTOM_HEADERS": "h",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_AGENT_FOO": "x",
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
        ]
        let env = ClaudeCodeProvider.childEnvironment(from: parent)
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_CUSTOM_HEADERS"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertNil(env["CLAUDE_AGENT_FOO"])
        // Unrelated vars are preserved.
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }
}

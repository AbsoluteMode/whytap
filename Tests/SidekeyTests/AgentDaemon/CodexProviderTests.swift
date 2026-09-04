import XCTest
@testable import Sidekey

final class CodexProviderTests: XCTestCase {
    func testNotInstalledWhenBinaryMissing() async {
        let provider = CodexProvider(locate: { nil }, runOneShot: { _, _ in nil })
        let outcome = await provider.probe()
        XCTAssertEqual(outcome, .notInstalled)
    }

    func testConnectedWhenLoggedInViaChatGPT() async {
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex") },
            runOneShot: { _, args in
                XCTAssertEqual(args, ["login", "status"])
                return ProcessResult(stdout: "Logged in using ChatGPT\n", stderr: "", exitCode: 0)
            })
        let outcome = await provider.probe()
        XCTAssertEqual(outcome, .connected(sessionID: nil))
    }

    func testNotLoggedInWhenStatusNonZero() async {
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            runOneShot: { _, _ in ProcessResult(stdout: "Not logged in", stderr: "", exitCode: 1) })
        let outcome = await provider.probe()
        XCTAssertEqual(outcome, .notLoggedIn)
    }

    func testNotLoggedInWhenBinaryErrorsOnConfig() async {
        // npm codex on a newer config emits a config error on stdout/stderr.
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            runOneShot: { _, _ in
                ProcessResult(stdout: "", stderr: "Error loading configuration: unknown variant", exitCode: 1)
            })
        let outcome = await provider.probe()
        XCTAssertEqual(outcome, .notLoggedIn)
    }

    func testRunYieldsNotInstalledErrorWhenBinaryMissing() async {
        let provider = CodexProvider(
            locate: { nil },
            runOneShot: { _, _ in nil },
            runStreaming: { _, _, _, _, _ in CodexProcessHandle.noop })
        var sawNotInstalled = false
        for await event in provider.run(prompt: "hi", resumeSessionID: nil) {
            if case .error(let code, _, _) = event, code == "not_installed" { sawNotInstalled = true }
        }
        XCTAssertTrue(sawNotInstalled)
    }
}

final class CodexChildEnvironmentTests: XCTestCase {
    /// The env handed to a spawned `codex` must drop every credential family
    /// that could silently switch billing off the user's ChatGPT subscription
    /// onto an inherited API key — critically `OPENAI_*` (codex's own key) and
    /// `DOPPLER_*` (the documented `doppler run` dev launcher injects secrets
    /// into the app's env). The Anthropic/Claude markers are dropped too so a
    /// dev session launched from Claude Code never leaks them sideways.
    func testScrubsBillingAndProviderCredentials() {
        let parent = [
            "OPENAI_API_KEY": "sk-1",
            "OPENAI_BASE_URL": "u",
            "DOPPLER_TOKEN": "dp.t",
            "DOPPLER_PROJECT": "sidekey",
            "ANTHROPIC_API_KEY": "k",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_AGENT_FOO": "x",
            "PATH": "/usr/bin",
            "HOME": "/Users/x",
        ]
        let env = CodexProvider.childEnvironment(from: parent)
        XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertNil(env["OPENAI_BASE_URL"])
        XCTAssertNil(env["DOPPLER_TOKEN"])
        XCTAssertNil(env["DOPPLER_PROJECT"])
        XCTAssertNil(env["ANTHROPIC_API_KEY"])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_ENTRYPOINT"])
        XCTAssertNil(env["CLAUDE_AGENT_FOO"])
        // Unrelated vars are preserved so codex still finds its binary + config.
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["HOME"], "/Users/x")
    }
}

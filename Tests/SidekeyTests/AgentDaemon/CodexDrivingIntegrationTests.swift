import XCTest
@testable import Sidekey

/// End-to-end guard against the real `codex` CLI. Opt-in: requires a codex
/// binary AND `SIDEKEY_RUN_CODEX_INTEGRATION=1`, so routine `swift test` skips
/// it (no OpenAI credits spent, no login needed). Run explicitly:
///   SIDEKEY_RUN_CODEX_INTEGRATION=1 swift test --filter CodexDrivingIntegrationTests
final class CodexDrivingIntegrationTests: XCTestCase {
    /// Drives a first turn (shell command, sandbox auto-run), then RESUMES with
    /// the captured thread_id. The resume turn is the path that exited 2 before
    /// the fix (`codex exec resume` rejects `-s`/`-C`; sandbox must go via `-c`).
    func testRealCodexDrivesAShellCommandThenResumes() async throws {
        guard ProcessInfo.processInfo.environment["SIDEKEY_RUN_CODEX_INTEGRATION"] == "1",
              CodexBinaryLocator().locate() != nil else {
            throw XCTSkip("set SIDEKEY_RUN_CODEX_INTEGRATION=1 with codex installed + logged in")
        }
        let provider = CodexProvider()

        // Turn 1: run a command (sandbox auto-run -> toolExecuting).
        var sawCommand = false
        var turn1Done = false
        for await event in provider.run(
            prompt: "Run exactly this shell command and report its output: echo codex-it-hello",
            resumeSessionID: nil
        ) {
            switch event {
            case .toolExecuting: sawCommand = true
            case .done: turn1Done = true
            case .error(let code, let message, _): XCTFail("turn 1 error \(code): \(message)")
            default: break
            }
        }
        XCTAssertTrue(sawCommand, "expected codex to run the echo command (toolExecuting)")
        XCTAssertTrue(turn1Done)
        let threadID = provider.lastSessionID
        XCTAssertNotNil(threadID, "thread_id should be captured after turn 1")

        // Turn 2: RESUME with the thread_id (regression guard for the exit-2 bug).
        var turn2Done = false
        for await event in provider.run(
            prompt: "Reply with exactly: resumed-ok",
            resumeSessionID: threadID
        ) {
            switch event {
            case .done: turn2Done = true
            case .error(let code, let message, _):
                XCTFail("turn 2 (resume) error \(code): \(message)")
            default: break
            }
        }
        XCTAssertTrue(turn2Done, "resume turn must complete (regression guard for the exit-2 bug)")
    }
}

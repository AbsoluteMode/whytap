import XCTest
@testable import Sidekey

/// The "Allow file edits and commands" flags against the user's real Claude
/// Code and Codex, through the providers Whytap runs. Opt-in: each turn is a
/// model request on the user's own plan. Run explicitly:
///   SIDEKEY_RUN_HARNESS_INTEGRATION=1 swift test --filter AgentHarnessIntegrationTests
/// Turns run in a temporary folder, never the Agent's real one.
/// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
final class AgentHarnessIntegrationTests: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["SIDEKEY_RUN_HARNESS_INTEGRATION"] == "1" else {
            throw XCTSkip("set SIDEKEY_RUN_HARNESS_INTEGRATION=1 with Claude Code and Codex installed and signed in")
        }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harness-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static let installedHelper = ["/Applications/Whytap.app/Contents/Helpers/whytap", "mcp"]

    private struct Turn {
        var tools: [String] = []
        var answer = ""
        var errors: [String] = []
        var done = false
    }

    private func drive(_ provider: any CLIProvider, _ prompt: String, resume: String? = nil,
                       options: AgentRunOptions) async -> Turn {
        var turn = Turn()
        for await event in provider.run(prompt: prompt, resumeSessionID: resume, options: options) {
            switch event {
            case .toolExecuting(let tool, _): turn.tools.append(tool)
            case .finalAnswer(let text): turn.answer = text
            case .error(let code, let message, _): turn.errors.append("\(code): \(message)")
            case .done: turn.done = true
            default: break
            }
        }
        return turn
    }

    private func options(_ folder: URL, model: String?, allowActions: Bool) -> AgentRunOptions {
        let helper = FileManager.default.isExecutableFile(atPath: Self.installedHelper[0]) ? Self.installedHelper : nil
        return AgentRunOptions(model: model, effort: "low", workingDirectory: folder,
                               allowActions: allowActions, whytapMCPCommand: helper)
    }

    private let writeRequest = "Create a file named made.txt in the current folder containing the word hi, using a file tool or a shell command. Then reply with one word: done or blocked."

    func testClaudeCodeOffBlocksWritesOnNewAndResumedTurnsAndOnAllowsThem() async throws {
        try requireOptIn()
        guard ClaudeBinaryLocator().locate() != nil else { throw XCTSkip("Claude Code is not installed") }
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("made.txt")
        let provider = ClaudeCodeProvider()

        let off = await drive(provider, writeRequest, options: options(folder, model: "haiku", allowActions: false))
        XCTAssertTrue(off.done, "\(off.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Off must not write")
        let session = try XCTUnwrap(provider.lastSessionID)

        let resumedOff = await drive(provider, "Try again with any tool you have.", resume: session,
                                     options: options(folder, model: "haiku", allowActions: false))
        XCTAssertTrue(resumedOff.done, "\(resumedOff.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Off must not write on resume")

        let on = await drive(provider, writeRequest, options: options(folder, model: "haiku", allowActions: true))
        XCTAssertTrue(on.done, "\(on.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "On writes inside the Agent's folder: \(on.answer)")
    }

    func testCodexOffBlocksWritesOnNewAndResumedTurnsAndOnAllowsThem() async throws {
        try requireOptIn()
        guard CodexBinaryLocator().locate() != nil else { throw XCTSkip("Codex is not installed") }
        let folder = try temporaryFolder()
        let file = folder.appendingPathComponent("made.txt")
        let provider = CodexProvider()

        let off = await drive(provider, writeRequest, options: options(folder, model: nil, allowActions: false))
        XCTAssertTrue(off.done, "\(off.errors)")
        XCTAssertTrue(off.errors.isEmpty, "config notices are not errors: \(off.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Off must not write")
        let thread = try XCTUnwrap(provider.lastSessionID)

        let resumedOff = await drive(provider, "Try again with any command you have.", resume: thread,
                                     options: options(folder, model: nil, allowActions: false))
        XCTAssertTrue(resumedOff.done, "\(resumedOff.errors)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Off must not write on resume")

        let on = await drive(provider, writeRequest, resume: thread,
                             options: options(folder, model: nil, allowActions: true))
        XCTAssertTrue(on.done, "\(on.errors)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "On writes inside the Agent's folder: \(on.answer)")
    }

    func testWhytapToolsAnswerOnBothHarnessesWithActionsOff() async throws {
        try requireOptIn()
        guard FileManager.default.isExecutableFile(atPath: Self.installedHelper[0]) else {
            throw XCTSkip("needs the installed Whytap.app helper")
        }
        let prompt = "Call the whytap MCP tool whytap_todo_list (load it with ToolSearch if needed) and reply with only the number of tasks."
        for provider in [ClaudeCodeProvider() as any CLIProvider, CodexProvider()] {
            if provider.discoverBinary() == nil { continue }
            let folder = try temporaryFolder()
            let turn = await drive(provider, prompt, options: options(folder, model: provider.id == .claude ? "haiku" : nil,
                                                                      allowActions: false))
            XCTAssertTrue(turn.done, "\(provider.displayName): \(turn.errors)")
            XCTAssertFalse(turn.answer.isEmpty, provider.displayName)
            XCTAssertTrue(turn.answer.contains(where: \.isNumber), "\(provider.displayName): \(turn.answer)")
        }
    }
}

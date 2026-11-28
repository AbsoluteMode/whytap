import XCTest
@testable import Sidekey

private final class NoopStdin: ClaudeStdinWriting {
    func writeLine(_ line: String) {}
    func closeStdin() {}
    func terminate() {}
    var processIdentifier: Int32? { nil }
}

/// The Agent's folder carries Whytap's instructions in WHYTAP.md, beside the
/// user's own memory file, and each harness request passes them to the CLI.
final class AgentHarnessInstructionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-instructions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private func workspace() throws -> URL {
        try AgentDaemonWorkingDirectory.ensure(appSupportDirectory: root)
    }

    /// The text with line breaks and indentation collapsed to single spaces.
    private func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    // MARK: - First run

    func testFirstRunWithEmptyMemoryGetsTheManagedFileAndLeavesMemoryEmpty() throws {
        let dir = try workspace()
        let file = try XCTUnwrap(AgentHarnessInstructions.install(in: dir))
        XCTAssertEqual(file.lastPathComponent, "WHYTAP.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(AgentHarnessInstructions.title))
        XCTAssertTrue(text.contains(dir.path), "names its own folder")
        // The user's memory stays theirs: empty, and CLAUDE.md is its alias.
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("AGENTS.md")), Data())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("CLAUDE.md").path), "AGENTS.md")
    }

    func testTheInstructionsSayWhoIsAnsweringWithoutClaimingToBeWhytap() {
        let text = flat(AgentHarnessInstructions.text(workspace: URL(fileURLWithPath: "/tmp/agent")))
        for marker in ["the user's own Claude Code or Codex", "signed in with the user's own account",
                       "Whytap has no servers, account, API key or model of its own",
                       "Yes, this is your Claude Code, started by Whytap",
                       "Claude Agent SDK", "Do not call yourself Whytap",
                       "Whytap does not use an SDK or an API of its own", "`claude -p` or `codex exec`"] {
            XCTAssertTrue(text.contains(marker), marker)
        }
        XCTAssertFalse(text.contains("You are Whytap"))
    }

    func testTheInstructionsCoverTheIslandToolsMemoryAndLeftovers() {
        let text = flat(AgentHarnessInstructions.text(workspace: URL(fileURLWithPath: "/tmp/agent")))
        for marker in ["320 points wide", "Markdown in a ~320pt panel", "\"useful.actions\"",
                       "become cards", "no approval prompt", "MCP server named `whytap`",
                       "AGENTS.md here is your memory", "within 15 minutes",
                       ".opencode-runtime/ and native-conversation.json",
                       "Whytap customization capabilities"] {
            XCTAssertTrue(text.contains(marker), marker)
        }
        XCTAssertEqual(AgentSessionStore.resumeWindow, 15 * 60, "the text names the resume window")
    }

    // MARK: - App update

    func testAnUpdateReplacesTheManagedFileAndKeepsTheUsersMemoryByteForByte() throws {
        let dir = try workspace()
        let memory = dir.appendingPathComponent("AGENTS.md")
        let notes = Data("# Мои заметки\n- Катя — дизайнер\n".utf8)
        try notes.write(to: memory)
        // An older Whytap's text, then a user edit to the managed file.
        let managed = dir.appendingPathComponent("WHYTAP.md")
        try Data("# Whytap instructions (older)\nmy edit\n".utf8).write(to: managed)

        // The updated app's next request.
        _ = try workspace()
        XCTAssertNotNil(AgentHarnessInstructions.install(in: dir))

        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8),
                       AgentHarnessInstructions.text(workspace: dir))
        XCTAssertEqual(try Data(contentsOf: memory), notes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: dir.appendingPathComponent("CLAUDE.md").path), "AGENTS.md")
    }

    func testAnUnchangedFileIsNotRewritten() throws {
        let dir = try workspace()
        let file = try XCTUnwrap(AgentHarnessInstructions.install(in: dir))
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: file.path)
        XCTAssertNotNil(AgentHarnessInstructions.install(in: dir))
        let date = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(date, past)
    }

    func testASymlinkedManagedFileIsReplacedAndItsTargetUntouched() throws {
        let dir = try workspace()
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("WHYTAP.md"), withDestinationURL: outside)
        let file = try XCTUnwrap(AgentHarnessInstructions.install(in: dir))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
    }

    // MARK: - Both harnesses

    func testClaudeCodeGetsTheFileAsAnAppendedSystemPrompt() async throws {
        let dir = try workspace()
        var captured: [String] = []
        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/claude") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, args, _, _, onExit in captured = args; onExit(0); return NoopStdin() })
        for await _ in provider.run(prompt: "Это мне сейчас Claude Code отвечает?", resumeSessionID: nil,
                                    options: AgentRunOptions(workingDirectory: dir)) {}
        XCTAssertEqual(value(after: "--append-system-prompt-file", in: captured),
                       dir.appendingPathComponent("WHYTAP.md").path)
        XCTAssertFalse(captured.contains("--system-prompt"), "never replaces Claude Code's own prompt")
        XCTAssertFalse(captured.contains { $0.contains("Это мне сейчас") }, "the request stays on stdin")
    }

    func testClaudeCodeResumedTurnAlsoCarriesTheFile() async throws {
        let dir = try workspace()
        var captured: [String] = []
        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/claude") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, args, _, _, onExit in captured = args; onExit(0); return NoopStdin() })
        for await _ in provider.run(prompt: "ещё", resumeSessionID: "s1",
                                    options: AgentRunOptions(workingDirectory: dir)) {}
        XCTAssertNotNil(value(after: "--append-system-prompt-file", in: captured))
        XCTAssertEqual(value(after: "--resume", in: captured), "s1")
    }

    func testCodexGetsTheTextAsDeveloperInstructionsOnNewAndResumedTurns() async throws {
        let dir = try workspace()
        for resume in [nil, "thread-1"] as [String?] {
            var captured: [String] = []
            let provider = CodexProvider(
                locate: { URL(fileURLWithPath: "/usr/local/bin/codex") },
                runStreaming: { _, args, _, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })
            for await _ in provider.run(prompt: "hi", resumeSessionID: resume,
                                        options: AgentRunOptions(workingDirectory: dir)) {}
            let expected = "developer_instructions="
                + AgentHarnessFlags.tomlString(AgentHarnessInstructions.text(workspace: dir))
            XCTAssertTrue(captured.contains(expected), "\(String(describing: resume))")
            XCTAssertFalse(captured.contains { $0.hasPrefix("model_instructions_file") },
                           "never replaces Codex's own prompt")
            // Still positional at the end: [thread] then stdin.
            XCTAssertEqual(captured.last, "-")
            if let resume { XCTAssertEqual(captured[captured.count - 2], resume) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("WHYTAP.md").path))
        }
    }

    // MARK: - Missing or unwritable folder

    func testAMissingFolderGetsTheInstructionsInline() throws {
        let missing = root.appendingPathComponent("gone", isDirectory: true)
        XCTAssertNil(AgentHarnessInstructions.install(in: missing))
        let claude = AgentHarnessInstructions.claudeFlags(workspace: missing)
        XCTAssertEqual(claude.first, "--append-system-prompt")
        XCTAssertEqual(claude.last, AgentHarnessInstructions.text(workspace: missing))
        let codex = AgentHarnessInstructions.codexFlags(workspace: missing)
        XCTAssertTrue(codex.last?.hasPrefix("developer_instructions=") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "nothing created")
    }

    func testAnUnwritableFolderGetsTheInstructionsInlineAndKeepsMemory() throws {
        let dir = try workspace()
        try Data("notes".utf8).write(to: dir.appendingPathComponent("AGENTS.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertNil(AgentHarnessInstructions.install(in: dir))
        XCTAssertEqual(AgentHarnessInstructions.claudeFlags(workspace: dir).first, "--append-system-prompt")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("AGENTS.md"), encoding: .utf8), "notes")
    }

    func testAStaleFileInAnUnwritableFolderIsNotPassed() throws {
        let dir = try workspace()
        try Data("# older text".utf8).write(to: dir.appendingPathComponent("WHYTAP.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let flags = AgentHarnessInstructions.claudeFlags(workspace: dir)
        XCTAssertEqual(flags, ["--append-system-prompt", AgentHarnessInstructions.text(workspace: dir)])
    }
}

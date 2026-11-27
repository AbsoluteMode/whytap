import XCTest
@testable import Sidekey

private final class NoopStdin: ClaudeStdinWriting {
    func writeLine(_ line: String) {}
    func closeStdin() {}
    func terminate() {}
    var processIdentifier: Int32? { nil }
}

private func hasFlag(_ args: [String], _ flag: String, _ value: String) -> Bool {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return false }
    return args[i + 1] == value
}

final class AgentRunOptionsMappingTests: XCTestCase {
    func testClaudeAppendsModelAndEffort() async {
        var captured: [String] = []
        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/claude") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, args, _, _, onExit in
                captured = args; onExit(0); return NoopStdin()
            })
        for await _ in provider.run(prompt: "hi", resumeSessionID: nil,
                                    options: AgentRunOptions(model: "opus", effort: "high")) {}
        XCTAssertTrue(hasFlag(captured, "--model", "opus"))
        XCTAssertTrue(hasFlag(captured, "--effort", "high"))
    }

    func testClaudeOmitsFlagsWhenOptionsEmpty() async {
        var captured: [String] = []
        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/claude") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, args, _, _, onExit in captured = args; onExit(0); return NoopStdin() })
        for await _ in provider.run(prompt: "hi", resumeSessionID: nil, options: AgentRunOptions()) {}
        XCTAssertFalse(captured.contains("--model"))
        XCTAssertFalse(captured.contains("--effort"))
    }

    func testCodexAppendsModelEffortAndServiceTier() async {
        var captured: [String] = []
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex") },
            runStreaming: { _, args, _, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })
        for await _ in provider.run(prompt: "hi", resumeSessionID: nil,
                                    options: AgentRunOptions(model: "gpt-5.4", effort: "high", serviceTier: "fast")) {}
        XCTAssertTrue(hasFlag(captured, "-m", "gpt-5.4"))
        XCTAssertTrue(captured.contains("model_reasoning_effort=high"))
        XCTAssertTrue(captured.contains("service_tier=fast"))
    }

    @MainActor
    func testRegistryResolvedOptionsReachNewAndResumedCodexTurns() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let settings = AgentSettingsStore(defaults: defaults, codexConfig: .init())
        settings.updateCodexCatalog([CodexModelOption(model: "new-agent", supportedReasoningEfforts: [.init(reasoningEffort: "ultra")], defaultReasoningEffort: "ultra", serviceTiers: [], isDefault: true)])
        settings.codexServiceTier = "fast"
        for resume in [nil, "test-thread"] as [String?] {
            var captured: [String] = []
            let provider = CodexProvider(locate: { URL(fileURLWithPath: "/usr/local/bin/codex") },
                runStreaming: { _, args, _, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })
            for await _ in provider.run(prompt: "hi", resumeSessionID: resume, options: settings.options(for: .codex)) {}
            XCTAssertTrue(hasFlag(captured, "-m", "new-agent"))
            XCTAssertTrue(captured.contains("model_reasoning_effort=ultra"))
            XCTAssertTrue(captured.contains("service_tier=default"))
            XCTAssertFalse(captured.contains("service_tier=fast"))
        }
    }

    // MARK: - cliServiceTier mapping

    func testCLIServiceTierMapping() {
        XCTAssertEqual(CodexProvider.cliServiceTier("priority"), "fast")
        XCTAssertEqual(CodexProvider.cliServiceTier("fast"), "fast")
        XCTAssertEqual(CodexProvider.cliServiceTier("flex"), "flex")
        XCTAssertEqual(CodexProvider.cliServiceTier("default"), "default")
        XCTAssertEqual(CodexProvider.cliServiceTier("standard"), "default")
    }

    func testCodexOmitsModelFlagsWhenOptionsEmpty() async {
        var captured: [String] = []
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex") },
            runStreaming: { _, args, _, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })
        for await _ in provider.run(prompt: "hi", resumeSessionID: nil, options: AgentRunOptions()) {}
        XCTAssertFalse(captured.contains("-m"))
        XCTAssertFalse(captured.contains(where: { $0.hasPrefix("model_reasoning_effort=") }))
        XCTAssertFalse(captured.contains(where: { $0.hasPrefix("service_tier=") }))
    }

    // MARK: - "Allow file edits and commands" → each CLI's own flags
    // WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md

    private func claudeArgs(_ options: AgentRunOptions, resume: String? = nil) async -> [String] {
        var captured: [String] = []
        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/claude") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, args, _, _, onExit in captured = args; onExit(0); return NoopStdin() })
        for await _ in provider.run(prompt: "hi", resumeSessionID: resume, options: options) {}
        return captured
    }

    private func codexArgs(_ options: AgentRunOptions, resume: String? = nil) async -> [String] {
        var captured: [String] = []
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            runStreaming: { _, args, _, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })
        for await _ in provider.run(prompt: "hi", resumeSessionID: resume, options: options) {}
        return captured
    }

    func testClaudeActionsOnUsesAutoModeNeverBypass() async {
        for resume in [nil, "s-1"] as [String?] {
            let args = await claudeArgs(AgentRunOptions(allowActions: true), resume: resume)
            XCTAssertTrue(hasFlag(args, "--permission-mode", "auto"), "\(args)")
            XCTAssertTrue(hasFlag(args, "--permission-prompts", "none"), "nothing is left waiting for an answer")
            XCTAssertFalse(args.contains("bypassPermissions"))
            XCTAssertFalse(args.contains("--disallowedTools"))
        }
    }

    func testClaudeActionsOffRemovesWriteAndCommandTools() async {
        for resume in [nil, "s-1"] as [String?] {
            let args = await claudeArgs(AgentRunOptions(allowActions: false), resume: resume)
            XCTAssertTrue(hasFlag(args, "--permission-mode", "dontAsk"), "\(args)")
            XCTAssertTrue(hasFlag(args, "--permission-prompts", "none"))
            XCTAssertTrue(hasFlag(args, "--disallowedTools", "Bash,PowerShell,Monitor,Edit,Write,NotebookEdit"))
            XCTAssertTrue(hasFlag(args, "--allowedTools", "Read,Grep,Glob,WebSearch,WebFetch,mcp__whytap"))
            XCTAssertFalse(args.contains("bypassPermissions"))
            XCTAssertFalse(args.contains("auto"))
        }
    }

    func testCodexActionsOnUsesWorkspaceSandboxAndAutoReviewOnNewAndResumedTurns() async {
        for resume in [nil, "t-1"] as [String?] {
            let args = await codexArgs(AgentRunOptions(allowActions: true), resume: resume)
            XCTAssertTrue(args.contains(#"sandbox_mode="workspace-write""#), "\(args)")
            XCTAssertTrue(args.contains(#"approval_policy="on-request""#))
            XCTAssertTrue(args.contains(#"approvals_reviewer="auto_review""#))
            XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
            XCTAssertFalse(args.contains("-s"), "codex exec resume rejects -s")
            XCTAssertFalse(args.contains("--approve-for-me"), "codex exec resume rejects it")
            XCTAssertEqual(args.last, "-")
            if let resume { XCTAssertEqual(args[args.count - 2], resume) }
        }
    }

    func testCodexActionsOffIsReadOnlyOnNewAndResumedTurns() async {
        for resume in [nil, "t-1"] as [String?] {
            let args = await codexArgs(AgentRunOptions(allowActions: false), resume: resume)
            XCTAssertTrue(args.contains(#"sandbox_mode="read-only""#), "\(args)")
            XCTAssertTrue(args.contains(#"approval_policy="never""#))
            XCTAssertFalse(args.contains(where: { $0.contains("workspace-write") || $0.contains("auto_review") }))
            XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        }
    }

    func testWhytapMCPServerJoinsBothHarnessesOnlyInAPackagedApp() async throws {
        let command = ["/Applications/Whytap.app/Contents/Helpers/whytap", "mcp"]
        let claude = await claudeArgs(AgentRunOptions(whytapMCPCommand: command))
        let index = try XCTUnwrap(claude.firstIndex(of: "--mcp-config"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(claude[index + 1].utf8)) as? [String: Any])
        let server = try XCTUnwrap((config["mcpServers"] as? [String: Any])?["whytap"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, command[0])
        XCTAssertEqual(server["args"] as? [String], ["mcp"])
        XCTAssertFalse(claude.contains("--strict-mcp-config"), "the user's own MCP servers still load")

        let codex = await codexArgs(AgentRunOptions(whytapMCPCommand: command), resume: "t-1")
        XCTAssertTrue(codex.contains(#"mcp_servers.whytap.command="/Applications/Whytap.app/Contents/Helpers/whytap""#), "\(codex)")
        XCTAssertTrue(codex.contains(#"mcp_servers.whytap.args=["mcp"]"#))

        let bare = await claudeArgs(AgentRunOptions())
        XCTAssertFalse(bare.contains("--mcp-config"))
        let bareCodex = await codexArgs(AgentRunOptions())
        XCTAssertFalse(bareCodex.contains(where: { $0.hasPrefix("mcp_servers.") }))
    }

    func testTOMLStringEscapesQuotesBackslashesAndControls() {
        XCTAssertEqual(AgentHarnessFlags.tomlString(#"/Users/a "b"/c\d"#), #""/Users/a \"b\"/c\\d""#)
        XCTAssertEqual(AgentHarnessFlags.tomlString("a\nb\u{1}"), #""a\nb\u0001""#)
    }

    @MainActor
    func testSettingsCarryActionsChoiceAndHelperToBothHarnesses() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: "agent.opencode.allowActions")
        let settings = AgentSettingsStore(defaults: defaults, codexConfig: .init(),
                                          whytapMCPCommand: { ["/x/whytap", "mcp"] })
        XCTAssertFalse(settings.allowActions, "an earlier Off carries over")
        for id in [CLIProviderID.claude, .codex] {
            XCTAssertFalse(settings.options(for: id).allowActions)
            XCTAssertEqual(settings.options(for: id).whytapMCPCommand, ["/x/whytap", "mcp"])
        }
        settings.allowActions = true
        XCTAssertTrue(defaults.bool(forKey: "agent.opencode.allowActions"))
        XCTAssertTrue(settings.options(for: .claude).allowActions)
    }
}

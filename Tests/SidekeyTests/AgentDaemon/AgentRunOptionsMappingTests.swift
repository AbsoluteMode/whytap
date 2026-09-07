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
            runStreaming: { _, args, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })
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
                runStreaming: { _, args, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })
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
            runStreaming: { _, args, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })
        for await _ in provider.run(prompt: "hi", resumeSessionID: nil, options: AgentRunOptions()) {}
        XCTAssertFalse(captured.contains("-m"))
        XCTAssertFalse(captured.contains(where: { $0.hasPrefix("model_reasoning_effort=") }))
        XCTAssertFalse(captured.contains(where: { $0.hasPrefix("service_tier=") }))
    }
}

import XCTest
@testable import Sidekey

@MainActor
final class AgentSettingsStoreTests: XCTestCase {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    private var models: [CodexModelOption] {
        [CodexModelOption(model: "new-model", supportedReasoningEfforts: [.init(reasoningEffort: "low"), .init(reasoningEffort: "ultra")], defaultReasoningEffort: "low", serviceTiers: [.init(id: "priority", name: "Fast")], isDefault: true),
         CodexModelOption(model: "small-model", supportedReasoningEfforts: [.init(reasoningEffort: "medium")], defaultReasoningEffort: "medium", serviceTiers: [])]
    }
    private func store(_ name: String = #function, config: CodexConfigSnapshot = .init()) -> AgentSettingsStore {
        let s = AgentSettingsStore(defaults: freshDefaults(name), codexConfig: config)
        s.updateCodexCatalog(models)
        return s
    }

    func testModelAndControlsRoundTripWithoutPinning() {
        let d = freshDefaults(#function)
        let s = AgentSettingsStore(defaults: d, codexConfig: .init())
        s.codexModel = "new-model"; s.codexEffort = "ultra"; s.codexServiceTier = "priority"
        let reloaded = AgentSettingsStore(defaults: d, codexConfig: .init())
        reloaded.updateCodexCatalog(models)
        XCTAssertEqual(reloaded.options(for: .codex), AgentRunOptions(model: "new-model", effort: "ultra", serviceTier: "priority"))
        XCTAssertEqual(d.string(forKey: "agent.codex.model"), "new-model")
    }

    func testStoredModelsIncludingSparkArePreserved() {
        let d = freshDefaults(#function)
        d.set("gpt-5.3-codex-spark", forKey: "agent.codex.model")
        let s = AgentSettingsStore(defaults: d, codexConfig: .init())
        XCTAssertEqual(s.codexModel, "gpt-5.3-codex-spark")
        XCTAssertEqual(d.string(forKey: "agent.codex.model"), "gpt-5.3-codex-spark")
    }

    func testChangingModelValidatesEffortAndSpeedWithoutErasingPreferences() {
        let s = store()
        s.codexEffort = "ULTRA"; s.codexServiceTier = "fast"
        XCTAssertEqual(s.options(for: .codex).effort, "ultra")
        XCTAssertEqual(s.options(for: .codex).serviceTier, "priority")
        s.codexModel = "small-model"
        XCTAssertEqual(s.options(for: .codex), AgentRunOptions(model: "small-model", effort: "medium", serviceTier: "default"))
        s.codexModel = "new-model"
        XCTAssertEqual(s.options(for: .codex).effort, "ultra")
    }

    func testResolutionUsesSavedThenConfigThenRegistryDefault() {
        let s = store(config: .init(model: "small-model"))
        XCTAssertEqual(s.selectedCodexModel, "small-model")
        s.codexModel = "new-model"
        XCTAssertEqual(s.selectedCodexModel, "new-model")
        s.codexModel = nil
        XCTAssertEqual(s.selectedCodexModel, "small-model")
        XCTAssertEqual(store("registry-default").selectedCodexModel, "new-model")
    }

    func testNormalOverridesFastConfigAndUnsupportedModelNeverInheritsFast() {
        let s = store(config: .init(serviceTier: "fast"))
        XCTAssertEqual(s.options(for: .codex).serviceTier, "priority")
        s.codexServiceTier = "default"
        XCTAssertEqual(s.options(for: .codex).serviceTier, "default")
        s.codexServiceTier = nil; s.codexModel = "small-model"
        XCTAssertEqual(s.options(for: .codex).serviceTier, "default")
    }

    func testUnknownModelPreservesPickButDoesNotInventCapabilities() {
        let s = store(); s.codexModel = "not-in-catalog"; s.codexEffort = "ultra"; s.codexServiceTier = "fast"
        XCTAssertEqual(s.options(for: .codex), AgentRunOptions(model: "not-in-catalog"))
    }

    func testCatalogOutageKeepsLastGoodModelsAndShowsError() async {
        let s = store()
        await s.refreshCodexCatalog(force: true, load: { throw CodexModelCatalogReader.Failure.timedOut })
        XCTAssertEqual(s.codexCatalog, models)
        XCTAssertNotNil(s.codexCatalogError)
        XCTAssertFalse(s.codexCatalogLoading)
    }

    func testUnavailableCatalogAndEmptyPreferencesLetCodexChoose() {
        let s = AgentSettingsStore(defaults: freshDefaults(#function), codexConfig: .init())
        XCTAssertEqual(s.options(for: .codex), AgentRunOptions())
    }

    func testClaudeSettingsRemainIndependent() {
        let d = freshDefaults(#function)
        d.set("opus", forKey: "agent.claude.model")
        let s = AgentSettingsStore(defaults: d, codexConfig: .init(), whytapMCPCommand: { nil })
        XCTAssertEqual(s.options(for: .claude), AgentRunOptions(model: "opus", effort: "low"))
        XCTAssertEqual(d.string(forKey: "agent.claude.model"), "opus", "loading never rewrites the pick")
        s.claudeEffort = "MAX"
        XCTAssertEqual(s.options(for: .claude).effort, "max")
        s.claudeEffort = "bogus"
        XCTAssertEqual(s.options(for: .claude).effort, "low")
    }

    // MARK: - Claude Code model catalog
    // WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md

    private static let claudeCatalog = ClaudeModelCatalog(models: [
        ClaudeModelOption(value: "default", displayName: "Default (recommended)", supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]),
        ClaudeModelOption(value: "sonnet", displayName: "Sonnet 5.5", supportedEffortLevels: ["low", "medium", "high", "xhigh", "max"]),
        ClaudeModelOption(value: "claude-haiku-4-5-20251001", displayName: "Haiku 4.5"),
        ClaudeModelOption(value: "claude-opus-4-6", displayName: "Opus 4.6", supportedEffortLevels: ["low", "medium", "high", "max"]),
    ], cliVersion: "2.1.325")

    func testNoClaudePickSendsNoModelSoClaudeCodeUsesItsOwnDefault() {
        let s = AgentSettingsStore(defaults: freshDefaults(#function), codexConfig: .init(), whytapMCPCommand: { nil })
        XCTAssertNil(s.options(for: .claude).model, "no hard-coded model")
        s.updateClaudeCatalog(Self.claudeCatalog)
        XCTAssertEqual(s.selectedClaudeOption?.value, "default")
        XCTAssertNil(s.options(for: .claude).model)
        XCTAssertEqual(s.options(for: .claude).effort, "low")
        s.claudeModel = "default"
        XCTAssertNil(s.options(for: .claude).model, "picking Claude Code's default sends no --model")
    }

    func testClaudePickIsSentVerbatimAndEffortFollowsTheModel() {
        let s = AgentSettingsStore(defaults: freshDefaults(#function), codexConfig: .init(), whytapMCPCommand: { nil })
        s.updateClaudeCatalog(Self.claudeCatalog)
        s.claudeEffort = "xhigh"
        s.claudeModel = "sonnet"
        XCTAssertEqual(s.options(for: .claude).model, "sonnet")
        XCTAssertEqual(s.options(for: .claude).effort, "xhigh")
        s.claudeModel = "claude-opus-4-6"
        XCTAssertEqual(s.options(for: .claude).effort, "low", "a level the model lacks falls back to Low")
        XCTAssertEqual(s.claudeEffort, "xhigh", "the pick is kept for a model that takes it")
        s.claudeModel = "claude-haiku-4-5-20251001"
        XCTAssertNil(s.options(for: .claude).effort, "no --effort for a model without reasoning levels")
    }

    func testSavedClaudeModelMissingFromCatalogIsKept() {
        let d = freshDefaults(#function)
        d.set("claude-retired-1", forKey: "agent.claude.model")
        let s = AgentSettingsStore(defaults: d, codexConfig: .init(), whytapMCPCommand: { nil })
        s.updateClaudeCatalog(Self.claudeCatalog)
        XCTAssertNil(s.selectedClaudeOption)
        XCTAssertEqual(s.options(for: .claude).model, "claude-retired-1")
        XCTAssertNil(s.options(for: .claude).effort, "the loaded list gives no evidence the model takes --effort")
    }

    func testSavedUnlistedClaudeModelDoesNotAssumeEffortSupport() {
        let d = freshDefaults(#function)
        let s = AgentSettingsStore(defaults: d, codexConfig: .init(), whytapMCPCommand: { nil })
        s.claudeModel = "saved-unlisted-fixture"
        s.claudeEffort = "xhigh"
        XCTAssertEqual(s.options(for: .claude).effort, "xhigh", "before discovery: the user's pick among Claude Code's levels")
        s.updateClaudeCatalog(.init(models: [
            ClaudeModelOption(value: "default", displayName: "Default", supportedEffortLevels: ["low"]),
            ClaudeModelOption(value: "fixture-no-effort", displayName: "Fixture"),
        ], cliVersion: nil))
        XCTAssertEqual(s.options(for: .claude).model, "saved-unlisted-fixture")
        XCTAssertNil(s.options(for: .claude).effort)
    }

    func testClaudeCatalogFailureKeepsTheLastGoodListAndSaysWhy() async {
        let s = AgentSettingsStore(defaults: freshDefaults(#function), codexConfig: .init(), whytapMCPCommand: { nil })
        await s.refreshClaudeCatalog(force: true, load: { Self.claudeCatalog })
        XCTAssertEqual(s.claudeCatalog.count, 4)
        XCTAssertEqual(s.claudeVersion, "2.1.325")
        await s.refreshClaudeCatalog(force: true, load: { throw ClaudeModelCatalogError.timedOut })
        XCTAssertEqual(s.claudeCatalog.count, 4)
        XCTAssertNotNil(s.claudeCatalogError)
        await s.refreshClaudeCatalog(force: true, load: { throw ClaudeModelCatalogError.notInstalled })
        XCTAssertEqual(s.claudeCatalogError, "Claude Code isn’t installed on this Mac.")
    }
}

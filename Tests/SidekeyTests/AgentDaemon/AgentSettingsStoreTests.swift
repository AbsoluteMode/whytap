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
        XCTAssertEqual(s.options(for: .claude).effort, "low")
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

    // MARK: - OpenCode model from the agent route

    private func routing(_ name: String) -> AIRoutingStore {
        AIRoutingStore(defaults: freshDefaults(name))
    }

    func test_opencode_model_comes_from_the_agent_route() {
        let r = routing(#function)
        r.setRoute(FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5"), for: .agent)
        let s = AgentSettingsStore(defaults: freshDefaults(#function + ".settings"), codexConfig: .init(), routing: r)
        XCTAssertEqual(s.options(for: .opencode).model, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(s.selectedOpenCodeModel, "anthropic/claude-sonnet-5.5")
    }

    func test_model_label_names_the_route_provider_and_model() {
        let r = routing(#function)
        r.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/anthropic/claude-sonnet-5.5"), for: .agent)
        let s = AgentSettingsStore(defaults: freshDefaults(#function + ".settings"), codexConfig: .init(), routing: r)
        XCTAssertEqual(s.selectedOpenCodeModelLabel, "OpenRouter · anthropic/claude-sonnet-5.5")
    }

    func test_model_label_is_nil_without_a_usable_agent_model() {
        let r = routing(#function)
        let s = AgentSettingsStore(defaults: freshDefaults(#function + ".settings"), codexConfig: .init(), routing: r)
        XCTAssertNil(s.selectedOpenCodeModelLabel)
    }

    func test_no_agent_route_means_no_model() {
        let r = routing(#function)
        let s = AgentSettingsStore(defaults: freshDefaults(#function + ".settings"), codexConfig: .init(), routing: r)
        XCTAssertNil(s.options(for: .opencode).model)
        XCTAssertNil(s.selectedOpenCodeModel)
    }

    func test_agent_route_on_another_provider_means_no_opencode_model() {
        let r = routing(#function)
        r.setRoute(FeatureRoute(account: .deepgram, model: "nova-3"), for: .agent)
        let s = AgentSettingsStore(defaults: freshDefaults(#function + ".settings"), codexConfig: .init(), routing: r)
        XCTAssertNil(s.selectedOpenCodeModel)
    }

    func test_agent_route_model_is_normalized_for_opencode() {
        let r = routing(#function)
        r.setRoute(FeatureRoute(account: .openRouter, model: "openrouter/anthropic/claude-sonnet-5.5"), for: .agent)
        let s = AgentSettingsStore(defaults: freshDefaults(#function + ".settings"), codexConfig: .init(), routing: r)
        XCTAssertEqual(s.selectedOpenCodeModel, "anthropic/claude-sonnet-5.5")
    }
    // MARK: - OpenCode model limits from the OpenRouter catalog

    private func catalogs(_ models: [CatalogModel]) throws -> ModelCatalogStore {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let stored = [ProviderAccount.openRouter.storageID: CatalogSnapshot(models: models, fetchedAt: Date())]
        try JSONEncoder().encode(stored).write(to: file)
        return ModelCatalogStore(fileURL: file)
    }

    private func agentOnOpenRouter(_ name: String, model: String, catalog: [CatalogModel]) throws -> AgentSettingsStore {
        let r = routing(name)
        r.setRoute(FeatureRoute(account: .openRouter, model: model), for: .agent)
        return AgentSettingsStore(defaults: freshDefaults(name + ".settings"), codexConfig: .init(), routing: r,
                                  catalogs: try catalogs(catalog))
    }

    func test_agent_options_carry_the_catalog_spec() throws {
        let s = try agentOnOpenRouter(#function, model: "anthropic/claude-sonnet-5.5", catalog: [
            CatalogModel(id: "anthropic/claude-sonnet-5.5", contextLength: 1_000_000, maxOutputTokens: 128_000,
                         supportsTools: true, supportsReasoning: true)])
        XCTAssertEqual(s.options(for: .opencode).openCodeModelSpec,
                       OpenCodeModelSpec(toolCall: true, reasoning: true, contextLimit: 1_000_000, outputLimit: 128_000))
    }

    func test_spec_falls_back_for_fields_the_catalog_omits() throws {
        let s = try agentOnOpenRouter(#function, model: "vendor/model", catalog: [
            CatalogModel(id: "vendor/model", contextLength: 200_000)])
        XCTAssertEqual(s.options(for: .opencode).openCodeModelSpec,
                       OpenCodeModelSpec(toolCall: true, reasoning: false, contextLimit: 200_000, outputLimit: 16_384))
    }

    /// An Agent route on Anthropic runs OpenCode's `anthropic` provider with
    /// the plain model id and the limits of the Anthropic catalog.
    func test_agent_route_on_anthropic_runs_the_anthropic_provider() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let stored = [ProviderAccount.anthropic.storageID: CatalogSnapshot(models: [
            CatalogModel(id: "claude-sonnet-5-5", uses: [.chat, .chatWithTools], contextLength: 1_000_000,
                         maxOutputTokens: 128_000, supportsTools: true, supportsReasoning: true)], fetchedAt: Date())]
        try JSONEncoder().encode(stored).write(to: file)
        let r = routing(#function)
        r.setRoute(FeatureRoute(account: .anthropic, model: "claude-sonnet-5-5"), for: .agent)
        let s = AgentSettingsStore(defaults: freshDefaults(#function + ".settings"), codexConfig: .init(), routing: r,
                                   catalogs: ModelCatalogStore(fileURL: file))
        let options = s.options(for: .opencode)
        XCTAssertEqual(options.model, "claude-sonnet-5-5")
        XCTAssertEqual(options.openCodeProvider, .anthropic)
        XCTAssertEqual(options.openCodeModelSpec,
                       OpenCodeModelSpec(toolCall: true, reasoning: true, contextLimit: 1_000_000, outputLimit: 128_000))
        XCTAssertEqual(s.selectedOpenCodeModelLabel, "Anthropic · claude-sonnet-5-5")

        r.setRoute(FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5"), for: .agent)
        XCTAssertEqual(s.options(for: .opencode).openCodeProvider, .openRouter)
    }

    func test_no_spec_without_context_length_or_catalog_entry() throws {
        let noContext = try agentOnOpenRouter(#function + "1", model: "vendor/model", catalog: [CatalogModel(id: "vendor/model")])
        XCTAssertNil(noContext.options(for: .opencode).openCodeModelSpec)
        let missing = try agentOnOpenRouter(#function + "2", model: "vendor/model", catalog: [])
        XCTAssertNil(missing.options(for: .opencode).openCodeModelSpec)
    }
}

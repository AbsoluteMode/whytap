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
        let s = AgentSettingsStore(defaults: d, codexConfig: .init())
        XCTAssertEqual(s.options(for: .claude), AgentRunOptions(model: "sonnet", effort: "low"))
        s.claudeEffort = "MAX"
        XCTAssertEqual(s.options(for: .claude).effort, "max")
        s.claudeEffort = "bogus"
        XCTAssertEqual(s.options(for: .claude).effort, "low")
    }
}

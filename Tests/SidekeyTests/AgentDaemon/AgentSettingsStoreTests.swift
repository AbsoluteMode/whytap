import XCTest
@testable import Sidekey

@MainActor
final class AgentSettingsStoreTests: XCTestCase {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testRoundTripsAcrossInstances() {
        let d = freshDefaults(#function)
        let s = AgentSettingsStore(defaults: d)
        s.claudeEffort = "high"
        s.codexServiceTier = "fast"
        let reloaded = AgentSettingsStore(defaults: d)
        XCTAssertEqual(reloaded.claudeEffort, "high")
        XCTAssertEqual(reloaded.codexServiceTier, "fast")
    }

    func testNilClearsTheKey() {
        let d = freshDefaults(#function)
        let s = AgentSettingsStore(defaults: d)
        s.codexModel = "gpt-5.4"
        s.codexModel = nil
        XCTAssertNil(AgentSettingsStore(defaults: d).codexModel)
    }

    func testMigratesStoredSparkModelsToGPT55() {
        let d = freshDefaults(#function)
        d.set("gpt-5.3-codex-spark", forKey: "agent.codex.model")
        let s = AgentSettingsStore(defaults: d)
        XCTAssertEqual(s.codexModel, "gpt-5.5")
        XCTAssertEqual(d.string(forKey: "agent.codex.model"), "gpt-5.5")
    }

    func testMigratesStoredClaudeModelsToSonnet() {
        let d = freshDefaults(#function)
        d.set("opus", forKey: "agent.claude.model")
        let s = AgentSettingsStore(defaults: d)
        XCTAssertEqual(s.claudeModel, "sonnet")
        XCTAssertEqual(d.string(forKey: "agent.claude.model"), "sonnet")
    }

    func testOptionsForProviderSplitsFields() {
        let d = freshDefaults(#function)
        let s = AgentSettingsStore(defaults: d)
        s.claudeModel = "sonnet"; s.claudeEffort = "high"
        s.codexModel = "gpt-5.5"; s.codexEffort = "xhigh"; s.codexServiceTier = "fast"
        let c = s.options(for: .claude)
        XCTAssertEqual(c.model, "sonnet")
        XCTAssertEqual(c.effort, "high")
        XCTAssertNil(c.serviceTier)
        let x = s.options(for: .codex)
        XCTAssertEqual(x.model, "gpt-5.5")
        XCTAssertEqual(x.effort, "xhigh")
        XCTAssertEqual(x.serviceTier, "fast")
    }

    func testCodexOptionsDefaultToGPT55WhenModelUnset() {
        let d = freshDefaults(#function)
        let s = AgentSettingsStore(defaults: d)
        let x = s.options(for: .codex)
        XCTAssertEqual(x.model, "gpt-5.5")
    }

    func testClaudeOptionsDefaultToSonnetWhenModelUnset() {
        let d = freshDefaults(#function)
        let s = AgentSettingsStore(defaults: d)
        let c = s.options(for: .claude)
        XCTAssertEqual(c.model, "sonnet")
    }

    // MARK: - Effort is always sent (stored -> Low, never the CLI config)

    func testClaudeOptionsDefaultEffortIsLow() {
        let store = AgentSettingsStore(defaults: freshDefaults(#function))
        XCTAssertEqual(store.options(for: .claude).effort, "low")
    }

    func testCodexOptionsDefaultEffortIsLow() {
        let store = AgentSettingsStore(defaults: freshDefaults(#function))
        XCTAssertEqual(store.options(for: .codex).effort, "low")
    }

    func testStoredEffortOverridesDefault() {
        let store = AgentSettingsStore(defaults: freshDefaults(#function))
        store.claudeEffort = "high"
        XCTAssertEqual(store.options(for: .claude).effort, "high")
    }

    func testStoredEffortIsCaseInsensitiveAndValidatedPerProvider() {
        let d = freshDefaults(#function)
        let s = AgentSettingsStore(defaults: d)
        // Case-insensitive, like the pickers.
        s.claudeEffort = "HIGH"
        XCTAssertEqual(s.options(for: .claude).effort, "high")
        // Unknown level -> Low, never sent raw.
        s.claudeEffort = "turbo"
        XCTAssertEqual(s.options(for: .claude).effort, "low")
        // Claude-only "max" is not a codex level; "minimal" is not ours.
        s.codexEffort = "max"
        XCTAssertEqual(s.options(for: .codex).effort, "low")
        s.codexEffort = "minimal"
        XCTAssertEqual(s.options(for: .codex).effort, "low")
        // "max" stays valid on the claude side.
        s.claudeEffort = "max"
        XCTAssertEqual(s.options(for: .claude).effort, "max")
    }
}

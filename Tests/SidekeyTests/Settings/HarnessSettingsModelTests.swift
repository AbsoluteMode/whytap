import XCTest
@testable import Sidekey

/// Keys & models → Models → Harness, through the user's steps.
/// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
@MainActor
final class HarnessSettingsModelTests: XCTestCase {
    private var outcomes: [CLIProviderID: ConnectOutcome] = [:]
    private var probed: [CLIProviderID] = []
    private var catalogLoads: [CLIProviderID] = []

    private func make(legacy: String? = nil) -> (HarnessSettingsModel, AgentProviderStore, AgentSettingsStore) {
        let suite = "HarnessSettingsModelTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        if let legacy { defaults.set(legacy, forKey: "agent.activeProvider") }
        let store = AgentProviderStore(defaults: defaults)
        let settings = AgentSettingsStore(defaults: defaults, codexConfig: .init(), whytapMCPCommand: { nil })
        let model = HarnessSettingsModel(
            store: store, settings: settings,
            probe: { [unowned self] id in self.probed.append(id); return self.outcomes[id] ?? .notInstalled },
            refreshClaude: { [unowned self] settings in
                self.catalogLoads.append(.claude)
                settings.updateClaudeCatalog(ClaudeModelCatalog(models: [
                    ClaudeModelOption(value: "default", displayName: "Default (recommended)", supportedEffortLevels: ["low", "high"]),
                    ClaudeModelOption(value: "haiku", displayName: "Haiku 5.5", supportedEffortLevels: ["low", "high"]),
                ], cliVersion: "2.1.325"))
            },
            refreshCodex: { [unowned self] settings in
                self.catalogLoads.append(.codex)
                settings.updateCodexCatalog([CodexModelOption(
                    model: "gpt-6", displayName: "GPT-6",
                    supportedReasoningEfforts: [.init(reasoningEffort: "low"), .init(reasoningEffort: "high")],
                    defaultReasoningEffort: "low",
                    serviceTiers: [.init(id: "priority", name: "Fast", description: "Faster, uses more of your plan")],
                    isDefault: true)])
            })
        return (model, store, settings)
    }

    func testAMigratedUserSeesTheAskAndNothingConnectsByItself() {
        let (model, store, _) = make(legacy: "opencode")
        XCTAssertNil(store.activeProvider)
        XCTAssertEqual(model.summaryParts, ["Not set up"])
        XCTAssertTrue(model.needsSetup(agentEnabled: false), "the one-time ask shows the setup contour")
        XCTAssertEqual(model.statusLine?.isProblem, true)
        XCTAssertTrue(probed.isEmpty, "no CLI is started until the user acts")
    }

    func testChoosingASignedInHarnessConnectsItAndLoadsItsModels() async {
        outcomes[.claude] = .connected(sessionID: nil)
        let (model, store, _) = make()
        await model.choose(.claude)
        XCTAssertEqual(store.activeProvider, .claude)
        XCTAssertEqual(catalogLoads, [.claude])
        XCTAssertEqual(model.summaryParts, ["Claude Code", "Default (recommended)", "Low"])
        XCTAssertEqual(model.statusLine?.text, "Ready · Claude Code 2.1.325")
        XCTAssertFalse(model.needsSetup(agentEnabled: true))
    }

    func testAFailedPickKeepsThePreviousHarnessAndSaysWhy() async {
        outcomes[.claude] = .connected(sessionID: nil)
        outcomes[.codex] = .notLoggedIn
        let (model, store, _) = make()
        await model.choose(.claude)
        await model.choose(.codex)
        XCTAssertEqual(store.activeProvider, .claude, "a pick that fails its check changes nothing")
        XCTAssertEqual(model.statusLine?.text, "Codex is signed out. Run codex login in Terminal, then check again.")
        XCTAssertEqual(model.statusLine?.isProblem, true)

        outcomes[.codex] = .connected(sessionID: nil)
        await model.refresh()
        XCTAssertEqual(store.activeProvider, .codex, "after signing in, Check again finishes the user's pick")
        XCTAssertEqual(model.summaryParts, ["Codex", "GPT-6", "Low"])
    }

    func testMissingCLIIsSaidPlainly() async {
        let (model, store, _) = make()
        await model.choose(.claude)
        XCTAssertNil(store.activeProvider)
        XCTAssertEqual(model.statusLine?.text, "Claude Code isn’t on this Mac. Install it, sign in, then check again.")
    }

    func testModelAndReasoningPicksShowInTheSummary() async {
        outcomes[.claude] = .connected(sessionID: nil)
        let (model, _, settings) = make()
        await model.choose(.claude)
        settings.claudeModel = "haiku"
        settings.claudeEffort = "high"
        XCTAssertEqual(model.summaryParts, ["Claude Code", "Haiku 5.5", "High"])
        XCTAssertEqual(settings.options(for: .claude).model, "haiku")
    }

    func testCodexFastModeFollowsTheModelsTierAndOffSendsDefault() async {
        outcomes[.codex] = .connected(sessionID: nil)
        let (model, _, settings) = make()
        await model.choose(.codex)
        XCTAssertEqual(model.fastTier?.id, "priority")
        XCTAssertFalse(model.fastModeOn)
        model.setFastMode(true)
        XCTAssertTrue(model.fastModeOn)
        XCTAssertEqual(settings.options(for: .codex).serviceTier, "priority")
        XCTAssertEqual(model.summaryParts.last, "Fast")
        model.setFastMode(false)
        XCTAssertEqual(settings.options(for: .codex).serviceTier, "default", "Off overrides a fast tier in the user's config")
        settings.updateCodexCatalog([CodexModelOption(model: "gpt-6", isDefault: true)])
        XCTAssertNil(model.fastTier, "no Fast switch for a model without the tier")
    }
}

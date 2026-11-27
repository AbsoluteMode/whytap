import XCTest
@testable import Sidekey

/// The harness choice and the move from the native agent.
/// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
@MainActor
final class AgentProviderStoreTests: XCTestCase {
    private func defaults(_ name: String = #function) -> UserDefaults {
        let suite = "AgentProviderStoreTests-\(name)-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testChoosingOneHarnessReplacesTheOtherAndPersists() {
        let d = defaults()
        let store = AgentProviderStore(defaults: d)
        store.markConnected(.claude)
        XCTAssertEqual(store.activeProvider, .claude)
        store.markConnected(.codex)
        XCTAssertEqual(store.activeProvider, .codex)
        XCTAssertEqual(AgentProviderStore(defaults: d).activeProvider, .codex)
        XCTAssertEqual(d.string(forKey: "agent.harness.active"), "codex")
    }

    func testOnlyClaudeCodeAndCodexCanBeChosen() {
        XCTAssertEqual(AgentProviderStore.harnesses, [.claude, .codex])
        let d = defaults()
        d.set("native", forKey: "agent.harness.active")
        XCTAssertNil(AgentProviderStore(defaults: d).activeProvider, "an unknown stored value is no harness")
        XCTAssertNil(d.string(forKey: "agent.harness.active"))
    }

    /// Every legacy state lands on "no harness"; an earlier connection asks
    /// once to choose, and the legacy key stays exactly as it was.
    func testMigrationMatrixNeverConnectsByItselfAndKeepsTheLegacyKey() {
        let cases: [(legacy: String?, needsSetup: Bool, asks: Bool)] = [
            (nil, false, false), ("opencode", false, true), ("native", false, true),
            ("claude", false, true), ("codex", false, true), ("unknown", false, false), (nil, true, true),
        ]
        for item in cases {
            let d = defaults("matrix-\(item.legacy ?? "nil")-\(item.needsSetup)")
            if let legacy = item.legacy { d.set(legacy, forKey: "agent.activeProvider") }
            if item.needsSetup { d.set(true, forKey: "agent.opencode.needsSetup") }
            let store = AgentProviderStore(defaults: d)
            XCTAssertNil(store.activeProvider, "\(item)")
            XCTAssertEqual(store.needsHarnessChoice, item.asks, "\(item)")
            XCTAssertEqual(d.string(forKey: "agent.activeProvider"), item.legacy, "legacy key untouched: \(item)")
            XCTAssertEqual(d.bool(forKey: "agent.opencode.needsSetup"), item.needsSetup)
        }
    }

    func testChoosingAHarnessEndsTheOneTimeAskButNeverWritesTheLegacyKey() {
        let d = defaults()
        d.set("opencode", forKey: "agent.activeProvider")
        d.set("anthropic/claude-sonnet", forKey: "agent.opencode.model")
        let store = AgentProviderStore(defaults: d)
        XCTAssertTrue(store.needsHarnessChoice)
        store.markConnected(.claude)
        XCTAssertFalse(store.needsHarnessChoice)
        XCTAssertFalse(AgentProviderStore(defaults: d).needsHarnessChoice)
        store.disconnect()
        XCTAssertNil(AgentProviderStore(defaults: d).activeProvider)
        XCTAssertFalse(AgentProviderStore(defaults: d).needsHarnessChoice, "the ask is one-time")
        // Rollback: an earlier build reads its own key and finds the native agent as it left it.
        XCTAssertEqual(d.string(forKey: "agent.activeProvider"), "opencode")
        XCTAssertEqual(d.string(forKey: "agent.opencode.model"), "anthropic/claude-sonnet")
    }

    func testAnUnknownStoredHarnessIsDropped() {
        let d = defaults()
        d.set("opencode", forKey: "agent.harness.active")
        XCTAssertNil(AgentProviderStore(defaults: d).activeProvider)
        XCTAssertNil(d.string(forKey: "agent.harness.active"))
    }

    func testReloadPicksUpASyncedChoice() {
        let d = defaults()
        d.set("opencode", forKey: "agent.activeProvider")
        let store = AgentProviderStore(defaults: d)
        d.set("codex", forKey: "agent.harness.active")
        store.reload()
        XCTAssertEqual(store.activeProvider, .codex)
        XCTAssertFalse(store.needsHarnessChoice)
    }
}

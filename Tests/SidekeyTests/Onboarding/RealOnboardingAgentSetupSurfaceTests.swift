import XCTest
@testable import Sidekey

/// The onboarding connect contract. Regression cover for the 1.18.9 report
/// "Codex CLI installed and signed in, but Whytap kept running / checking
/// Claude": the pane used to write the active provider only when all four
/// setup rows went green, and it did that for whichever provider happened to
/// be selected — which defaults to Claude.
/// WHY: docs/decisions/2026-08-02-onboarding-connect-is-probe-backed.md
@MainActor
final class RealOnboardingAgentSetupSurfaceTests: XCTestCase {
    private func freshStore(_ name: String) -> AgentProviderStore {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return AgentProviderStore(defaults: defaults)
    }

    /// Probes for a machine where the CLI is installed and signed in, but
    /// Homebrew / Node are absent — Codex from `/Applications/Codex.app`, or an
    /// nvm-managed npm prefix. Exactly the shape that could never connect.
    private func probes(
        brew: Bool = false,
        node: Bool = false,
        cli: Bool = true,
        outcome: ConnectOutcome = .connected(sessionID: nil)
    ) -> AgentSetupProbes {
        AgentSetupProbes(
            brewInstalled: { brew },
            nodeInstalled: { node },
            cliInstalled: { cli },
            probe: { outcome }
        )
    }

    /// Wait for the polled checklist to reach a settled state without
    /// depending on wall-clock timing.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func test_greenChecklistAloneNeverConnects() async {
        let store = freshStore(#function)
        let surface = RealOnboardingAgentSetupSurface(
            store: store,
            claudeProbes: probes(brew: true, node: true),
            codexProbes: probes(brew: true, node: true)
        )
        surface.start()
        await waitUntil { surface.allSatisfied }
        surface.stop()

        XCTAssertTrue(surface.allSatisfied, "checklist reached 4/4")
        XCTAssertNil(store.activeProvider,
                     "merely opening the pane must not claim an agent — Connect does")
        XCTAssertFalse(surface.isConnected)
    }

    func test_connectSucceedsWithoutHomebrewOrNode() async {
        let store = freshStore(#function)
        let surface = RealOnboardingAgentSetupSurface(
            store: store,
            claudeProbes: probes(),
            codexProbes: probes()
        )
        surface.provider = .codex

        let result = await surface.confirmConnection()

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(store.activeProvider, .codex,
                       "the probe decides; the brew/node rows only guide")
        XCTAssertTrue(surface.isConnected)
    }

    func test_connectingCodexReplacesAStuckClaude() async {
        let store = freshStore(#function)
        store.markConnected(.claude)
        let surface = RealOnboardingAgentSetupSurface(
            store: store,
            claudeProbes: probes(),
            codexProbes: probes()
        )
        XCTAssertEqual(surface.provider, .claude, "restores the connected agent")

        surface.provider = .codex
        let result = await surface.confirmConnection()

        XCTAssertEqual(result, .connected)
        XCTAssertEqual(store.activeProvider, .codex)
    }

    func test_refusedProbeDoesNotConnect() async {
        let store = freshStore(#function)
        let surface = RealOnboardingAgentSetupSurface(
            store: store,
            claudeProbes: probes(),
            codexProbes: probes(cli: true, outcome: .notLoggedIn)
        )
        surface.provider = .codex

        let result = await surface.confirmConnection()

        XCTAssertEqual(result, .notSignedIn)
        XCTAssertNil(store.activeProvider)
        XCTAssertFalse(surface.isConnected)
    }

    func test_missingBinaryReportsNotInstalled() async {
        let store = freshStore(#function)
        let surface = RealOnboardingAgentSetupSurface(
            store: store,
            claudeProbes: probes(),
            codexProbes: probes(cli: false, outcome: .notInstalled)
        )
        surface.provider = .codex

        let result = await surface.confirmConnection()
        XCTAssertEqual(result, .notInstalled)
        XCTAssertNil(store.activeProvider)
    }

    func test_pickIsRememberedAcrossSurfacesEvenWithoutConnecting() {
        let name = #function
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let first = RealOnboardingAgentSetupSurface(
            store: AgentProviderStore(defaults: defaults),
            claudeProbes: probes(),
            codexProbes: probes()
        )
        first.provider = .codex          // picked, never connected

        let second = RealOnboardingAgentSetupSurface(
            store: AgentProviderStore(defaults: defaults),
            claudeProbes: probes(),
            codexProbes: probes()
        )
        XCTAssertEqual(second.provider, .codex,
                       "reopening the pane must not snap back to the Claude default")
    }

    func test_disconnectKeepsThePickButDropsTheActiveAgent() {
        let store = freshStore(#function)
        store.markConnected(.codex)
        store.disconnect()

        XCTAssertNil(store.activeProvider)
        XCTAssertEqual(store.preferredProvider, .codex)
        XCTAssertEqual(
            RealOnboardingAgentSetupSurface(
                store: store, claudeProbes: probes(), codexProbes: probes()
            ).provider,
            .codex
        )
    }
}

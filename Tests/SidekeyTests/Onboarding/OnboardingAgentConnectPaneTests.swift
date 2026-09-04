import XCTest

/// Source-level guards for the onboarding Connect CTA. The pane is a SwiftUI
/// view with no headless harness, so the contract is pinned on its source the
/// same way `AgentModeViewTests` pins the Settings agent view.
/// WHY: docs/decisions/2026-08-02-onboarding-connect-is-probe-backed.md
final class OnboardingAgentConnectPaneTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Sidekey/Onboarding/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_connectRunsTheProbeNotTheChecklist() throws {
        let s = try source("OnboardingAgentConnectPane.swift")
        XCTAssertTrue(s.contains("await surface.confirmConnection()"),
                      "Connect goes through the provider probe")
        XCTAssertFalse(s.contains("if surface.allSatisfied {"),
                      "the four setup rows must not gate the connection — brew/node are guidance")
    }

    func test_connectedStateReflectsTheActiveProvider() throws {
        let s = try source("OnboardingAgentConnectPane.swift")
        XCTAssertTrue(s.contains("connectPressed && surface.isConnected"),
                      "\"connected\" means the selected provider really is the active agent")
    }

    func test_refusalGuidesToTheStepThatActuallyFailed() throws {
        let s = try source("OnboardingAgentConnectPane.swift")
        XCTAssertTrue(s.contains("guide(.cli)"), "not-installed points at the CLI step")
        XCTAssertTrue(s.contains("guide(.signedIn)"), "not-signed-in points at the sign-in step")
        XCTAssertTrue(s.contains("connectHint"), "the refusal is surfaced, not swallowed")
    }

    /// The regression itself: mirroring a green checklist must never write the
    /// active provider. That silent write claimed Claude (the chooser default)
    /// for anyone who merely opened the Agent tab, and the stuck value then
    /// outranked every later attempt to pick Codex.
    func test_checklistMirroringDoesNotConnect() throws {
        let s = try source("RealOnboardingAgentSetupSurface.swift")
        let apply = s.components(separatedBy: "private func apply(").last ?? ""
        XCTAssertFalse(apply.contains("markConnected"),
                       "apply() mirrors statuses only — connecting is an explicit user action")
        XCTAssertTrue(s.contains("func confirmConnection()"),
                      "the surface exposes the probe-backed connect the pane calls")
    }
}

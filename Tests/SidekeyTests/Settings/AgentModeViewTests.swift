import XCTest
@testable import Sidekey

@MainActor
final class AgentModeViewTests: XCTestCase {
    func test_agents_uses_mac_reskin_components() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/AgentModeView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("MacCard"))
        XCTAssertTrue(s.contains("MacRow"))
        XCTAssertTrue(s.contains("MacButton"))
        XCTAssertTrue(s.contains("MacPill"))
        XCTAssertTrue(s.contains("ProviderBrandIcon"))
        XCTAssertTrue(s.contains("agentBrandAssetName(id)"))
    }

    /// Each provider section embeds the setup guide while that provider is
    /// not connected (and hides it once it is).
    func test_agents_embeds_setup_guide_for_disconnected_providers() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/AgentModeView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("AgentSetupGuideView"))
        XCTAssertTrue(s.contains("store.activeProvider != .claude"))
        XCTAssertTrue(s.contains("store.activeProvider != .codex"))
    }

    func test_agents_exposes_capability_switch_for_disabled_hotkey_prompt() throws {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/AgentModeView.swift")
        let s = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(s.contains("Use Agent shortcuts"))
        XCTAssertTrue(s.contains("MacSwitch"))
        XCTAssertTrue(s.contains("onAgentToggle(newValue)"))
        XCTAssertTrue(s.contains("sidekeyCapabilityFlagsChanged"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "AgentModeViewTests", code: 1)
    }
}

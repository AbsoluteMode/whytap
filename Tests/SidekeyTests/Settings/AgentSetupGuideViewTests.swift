import XCTest
@testable import Sidekey

final class AgentSetupGuideContentTests: XCTestCase {
    func testClaudeGuideContent() {
        let c = AgentSetupGuideContent.claude
        XCTAssertEqual(c.providerName, "Claude Code")
        XCTAssertEqual(
            c.steps.map { $0.title },
            ["Homebrew installed", "Node.js installed", "Claude Code installed", "Signed in"]
        )
        XCTAssertEqual(
            c.steps[0].command,
            #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        )
        XCTAssertEqual(c.steps[0].link?.url, URL(string: "https://brew.sh"))
        XCTAssertEqual(c.steps[1].command, "brew install node")
        XCTAssertEqual(c.steps[1].link?.url, URL(string: "https://nodejs.org"))
        XCTAssertEqual(c.steps[2].command, "npm install -g @anthropic-ai/claude-code")
        // The install link reuses the provider's constant — no second hardcode.
        XCTAssertEqual(c.steps[2].link?.url, ClaudeCodeProvider().installURL)
        XCTAssertEqual(c.steps[3].command, "claude")
        XCTAssertTrue(c.steps[3].opensTerminal)
        XCTAssertFalse(c.steps[0].opensTerminal)
        XCTAssertFalse(c.steps[2].opensTerminal)
    }

    func testCodexGuideContent() {
        let c = AgentSetupGuideContent.codex
        XCTAssertEqual(c.providerName, "Codex")
        XCTAssertEqual(
            c.steps.map { $0.title },
            ["Homebrew installed", "Node.js installed", "Codex installed", "Signed in"]
        )
        XCTAssertEqual(c.steps[2].command, "npm install -g @openai/codex")
        XCTAssertEqual(c.steps[2].link?.url, CodexProvider().installURL)
        XCTAssertEqual(c.steps[3].command, "codex login")
        XCTAssertTrue(c.steps[3].opensTerminal)
    }

    /// Each step's status key path must point at its own snapshot field, in
    /// checklist order.
    func testStepStatusKeyPathsMapToSnapshotFields() {
        var snap = AgentSetupSnapshot()
        snap.homebrew = .satisfied
        snap.node = .unsatisfied
        snap.cli = .satisfied
        snap.signedIn = .unsatisfied
        let c = AgentSetupGuideContent.claude
        XCTAssertEqual(snap[keyPath: c.steps[0].status], .satisfied)
        XCTAssertEqual(snap[keyPath: c.steps[1].status], .unsatisfied)
        XCTAssertEqual(snap[keyPath: c.steps[2].status], .satisfied)
        XCTAssertEqual(snap[keyPath: c.steps[3].status], .unsatisfied)
    }

    func testStepIdsAreStableAndUnique() {
        for content in [AgentSetupGuideContent.claude, AgentSetupGuideContent.codex] {
            let ids = content.steps.map { $0.id }
            XCTAssertEqual(Set(ids).count, ids.count)
        }
    }
}

@MainActor
final class AgentSetupGuideViewTests: XCTestCase {
    private func guideSource() throws -> String {
        let url = try projectRoot()
            .appendingPathComponent("Sources/Sidekey/Settings/AgentSetupGuideView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func test_guide_copies_via_pasteboard_and_opens_links_via_workspace() throws {
        let s = try guideSource()
        XCTAssertTrue(s.contains("NSPasteboard.general"))
        XCTAssertTrue(s.contains("clearContents()"))
        XCTAssertTrue(s.contains("setString("))
        XCTAssertTrue(s.contains("NSWorkspace.shared.open"))
        // Open Terminal resolves the app, never runs shell commands itself.
        XCTAssertTrue(s.contains("com.apple.Terminal"))
    }

    func test_guide_polling_lifecycle_is_symmetric() throws {
        let s = try guideSource()
        XCTAssertTrue(s.contains(".onAppear { checklist.start() }"))
        XCTAssertTrue(s.contains(".onDisappear { checklist.stop() }"))
    }

    func test_guide_shows_ready_state_when_all_satisfied() throws {
        let s = try guideSource()
        XCTAssertTrue(s.contains("Ready — press Connect"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "AgentSetupGuideViewTests", code: 1)
    }
}

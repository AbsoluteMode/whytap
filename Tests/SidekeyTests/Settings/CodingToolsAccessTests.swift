import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

extension CodingToolsAccess {
    /// Claude Code on the Mac and connected's opposite by default: installed,
    /// no MCP entry; Codex missing. Answers live in memory only.
    static func fixed(_ presence: [CaseKnownClient: Presence] = [.claudeCode: .installed(configured: false),
                                                                 .codex: .notInstalled],
                      store: HarnessAccessStore? = nil,
                      connect: @escaping (CaseKnownClient) async -> [String] = { _ in [] }) -> CodingToolsAccess {
        let answers = store ?? HarnessAccessStore(persistence: nil)
        return CodingToolsAccess(store: { answers }, probe: Probe(presence: { presence[$0] ?? .notInstalled },
                                                                  connect: connect))
    }
}

/// Settings → Integrations → Coding tools: Claude Code and Codex are always
/// listed with one switch each. On writes Whytap's MCP entry and records Yes;
/// off records No and leaves the entry.
// WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
@MainActor
final class CodingToolsAccessTests: XCTestCase {
    /// A Mac whose client settings the fake owns: `connect` adds the entry
    /// unless told to fail, `presence` reads it back.
    private final class FakeMac {
        var installed: Set<CaseKnownClient> = [.claudeCode, .codex]
        var configured: Set<CaseKnownClient> = []
        var connectProblems: [String] = []
        var connectAddsEntry = true
        var connects: [CaseKnownClient] = []

        var probe: CodingToolsAccess.Probe {
            CodingToolsAccess.Probe(presence: { client in
                self.installed.contains(client) ? .installed(configured: self.configured.contains(client)) : .notInstalled
            }, connect: { client in
                self.connects.append(client)
                if self.connectAddsEntry { self.configured.insert(client) }
                return self.connectProblems
            })
        }
    }

    /// `withoutStore` is a build that has no access store.
    private func make(_ mac: FakeMac, store: HarnessAccessStore? = nil, withoutStore: Bool = false) async -> CodingToolsAccess {
        let answers = withoutStore ? nil : (store ?? HarnessAccessStore(persistence: nil))
        let tools = CodingToolsAccess(store: { answers }, probe: mac.probe, now: { Date(timeIntervalSince1970: 0) })
        await tools.refresh()
        return tools
    }

    func testTheOfferedToolsAreTheHarnessesTheGateKnows() {
        XCTAssertEqual(CodingToolsAccess.tools.map(\.displayName), ["Claude Code", "Codex"])
        for tool in CodingToolsAccess.tools {
            let identity = CodingToolsAccess.harnessClient(tool)!.identity
            XCTAssertTrue(CaseCallerResolver.knownAIApps.contains {
                $0.teamID == identity.teamID && $0.identifier == identity.signingIdentifier && $0.name == tool.displayName
            }, "\(tool) is the identity the access gate matches")
        }
    }

    func testOnAddsTheMCPEntryAndGivesAccess() async {
        let mac = FakeMac()
        let store = HarnessAccessStore(persistence: nil)
        let tools = await make(mac, store: store)
        XCTAssertFalse(tools.isConnected(.claudeCode))
        XCTAssertTrue(tools.subtitle(.claudeCode).hasPrefix("Not connected. Turn on to add Whytap’s MCP server to Claude Code"))
        await tools.set(.claudeCode, on: true)
        XCTAssertEqual(mac.connects, [.claudeCode])
        XCTAssertTrue(tools.isConnected(.claudeCode))
        XCTAssertEqual(store.decision(for: CodingToolsAccess.harnessClient(.claudeCode)!.identity), .allow,
                       "the same Yes the island records")
        XCTAssertTrue(tools.subtitle(.claudeCode).hasPrefix("Connected."))
        XCTAssertFalse(tools.isConnected(.codex), "only the tool switched on")
    }

    func testOffTakesAccessAwayAndLeavesTheEntry() async {
        let mac = FakeMac()
        mac.configured = [.codex]
        let store = HarnessAccessStore(persistence: nil)
        let tools = await make(mac, store: store)
        store.record(.allow, for: CodingToolsAccess.harnessClient(.codex)!, at: Date())
        XCTAssertTrue(tools.isConnected(.codex), "a Yes given in the island shows here")
        await tools.set(.codex, on: false)
        XCTAssertEqual(store.decision(for: CodingToolsAccess.harnessClient(.codex)!.identity), .deny)
        XCTAssertFalse(tools.isConnected(.codex))
        XCTAssertEqual(mac.connects, [], "nothing is written to Codex")
        XCTAssertTrue(mac.configured.contains(.codex), "the MCP entry stays; the gate refuses without a Yes")
    }

    func testAFailedConnectGivesNoAccessAndSaysWhy() async {
        let mac = FakeMac()
        mac.connectAddsEntry = false
        mac.connectProblems = ["Claude Code: couldn’t read ~/.claude.json"]
        let store = HarnessAccessStore(persistence: nil)
        let tools = await make(mac, store: store)
        await tools.set(.claudeCode, on: true)
        XCTAssertFalse(tools.isConnected(.claudeCode))
        XCTAssertNil(store.decision(for: CodingToolsAccess.harnessClient(.claudeCode)!.identity), "no Yes without the entry")
        XCTAssertTrue(tools.subtitle(.claudeCode).hasSuffix("\nClaude Code: couldn’t read ~/.claude.json"))

        mac.connectProblems = []
        await tools.set(.claudeCode, on: true)
        XCTAssertFalse(tools.isConnected(.claudeCode))
        XCTAssertTrue(tools.subtitle(.claudeCode).hasSuffix(CodingToolsAccess.notAddedProblem))
    }

    /// The person's own `whytap` entry is left as it is and still counts.
    func testAnEntryThePersonWroteCountsAsConnected() async {
        let mac = FakeMac()
        mac.configured = [.claudeCode]
        mac.connectProblems = ["Claude Code: Configured manually — Whytap left it as is"]
        let tools = await make(mac)
        await tools.set(.claudeCode, on: true)
        XCTAssertTrue(tools.isConnected(.claudeCode))
    }

    func testAToolNotOnThisMacIsGreyAndCannotBeSwitched() async {
        let mac = FakeMac()
        mac.installed = [.claudeCode]
        let tools = await make(mac)
        XCTAssertEqual(tools.presence[.codex], .notInstalled)
        XCTAssertFalse(tools.canSwitch(.codex))
        XCTAssertEqual(tools.subtitle(.codex), "Not installed on this Mac.")
        await tools.set(.codex, on: true)
        XCTAssertEqual(mac.connects, [], "nothing to connect")
        XCTAssertTrue(tools.canSwitch(.claudeCode))
    }

    func testWithoutTheAppsAccessStoreNothingCanBeSwitched() async {
        let mac = FakeMac()
        let tools = await make(mac, withoutStore: true)
        XCTAssertFalse(tools.canSwitch(.claudeCode))
        XCTAssertEqual(tools.subtitle(.claudeCode), "Not connected. Connect it in the installed Whytap app.")
        await tools.set(.claudeCode, on: true)
        XCTAssertEqual(mac.connects, [], "nothing is written without a place for the answer")
    }

    func testCheckingIsSaidUntilTheMacAnswered() {
        let tools = CodingToolsAccess(store: { nil }, probe: FakeMac().probe)
        XCTAssertEqual(tools.subtitle(.codex), "Checking whether Codex is on this Mac…")
        XCTAssertFalse(tools.canSwitch(.codex))
    }

    func testOtherAppsAnswersStayBelowTheTools() {
        let store = HarnessAccessStore(persistence: nil)
        store.record(.allow, for: CodingToolsAccess.harnessClient(.claudeCode)!, at: Date())
        let other = HarnessClient(identity: HarnessIdentity(teamID: "TEAM", signingIdentifier: "app.dictation"),
                                  name: "Dictation app", scope: .liveDictation)
        store.record(.deny, for: other, at: Date())
        XCTAssertEqual(HarnessAccessSettingsSection.otherRows(store.grants).map(\.name), ["Dictation app"])
    }

    func testRenderIntegrations() async throws {
        let directory = FeaturesFixture.renderDirectory
        let fixture = try await FeaturesFixture(.usual)
        defer { fixture.cleanUp() }
        for dark in [false, true] {
            let selection = SettingsWindowSelection(selectedTab: .integrations)
            try FeaturesFixture.render(fixture.shell(selection: selection), size: NSSize(width: 960, height: 760),
                                       dark: dark,
                                       to: directory?.appendingPathComponent("integrations-\(dark ? "dark" : "light").png"))
        }
    }
}

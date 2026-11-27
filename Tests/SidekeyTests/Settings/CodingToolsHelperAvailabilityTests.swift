import Foundation
import XCTest
@testable import Sidekey

/// No helper that runs, no new Yes (queue ticket 676): a blank command and an
/// entry naming a helper that is gone are not Whytap's working entry, and a
/// refused setup records nothing. The builder's fixture, plus Off for an
/// earlier Yes.
// WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
@MainActor
final class CodingToolsHelperAvailabilityTests: XCTestCase {
    func testAnEarlierYesCanStillBeTurnedOffWithoutAHelper() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coding-tools-nohelper-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        let setup = CaseClientSetup(
            helperURL: nil, binDir: root.appendingPathComponent("bin"), flavorName: "dev",
            connectors: [.codex: CodexCaseConnector(home: root, runner: runner, reader: runner,
                                                    locate: { root.appendingPathComponent("codex") })],
            builtInAgentAvailable: { false })
        let store = HarnessAccessStore(persistence: nil)
        let client = try XCTUnwrap(CodingToolsAccess.harnessClient(.codex))
        store.record(.allow, for: client, at: Date())
        let access = CodingToolsAccess(store: { store }, probe: .live(setup: setup))
        await access.refresh()
        XCTAssertEqual(access.presence[.codex], .installed(configured: false))
        XCTAssertTrue(access.canSwitch(.codex))
        await access.set(.codex, on: false)
        XCTAssertEqual(store.decision(for: client.identity), .deny)
    }

    func testMissingHelperNeverLetsAnEmptyCommandCountAsConnected() async throws {
        try await verifyUnusableHelper(configuredHelper: nil, command: "", customEntry: true)
    }

    func testASetupRefusalForAnUnavailableHelperDoesNotRecordConsent() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-helper-\(UUID())")
        try await verifyUnusableHelper(configuredHelper: missing, command: missing.path, customEntry: false)
    }

    private func verifyUnusableHelper(
        configuredHelper: URL?, command: String, customEntry: Bool
    ) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("coding-tools-helper-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let fakeClient = root.appendingPathComponent("test-client")
        let runner = FakeCommandRunner()
        let claudeConfig = root.appendingPathComponent(".claude.json")
        let bytes = try JSONSerialization.data(withJSONObject: [
            "mcpServers": ["whytap": ["command": command, "args": ["mcp"]]],
        ])
        try bytes.write(to: claudeConfig)
        runner.codexEntries["whytap"] = FakeCommandRunner.codexStdio("whytap", command: command, args: ["mcp"])
        let setup = CaseClientSetup(
            helperURL: configuredHelper, binDir: root.appendingPathComponent("bin"), flavorName: "dev",
            connectors: [
                .claudeCode: ClaudeCodeCaseConnector(home: root, socketPath: root.appendingPathComponent("sock").path,
                                                    runner: runner, locate: { fakeClient }),
                .codex: CodexCaseConnector(home: root, runner: runner, reader: runner, locate: { fakeClient }),
            ], builtInAgentAvailable: { false }
        )
        let store = HarnessAccessStore(persistence: nil)
        let access = CodingToolsAccess(store: { store }, probe: .live(setup: setup))
        await access.refresh()
        for client in [CaseKnownClient.claudeCode, .codex] {
            let harness = try XCTUnwrap(CodingToolsAccess.harnessClient(client))
            if customEntry {
                XCTAssertEqual(access.presence[client], .customEntry, client.displayName)
                XCTAssertFalse(access.canSwitch(client), client.displayName)
            }
            let refusal = await setup.connect(client.identity)
            XCTAssertEqual(refusal.problems, [CaseClientSetup.helperMissingMessage])
            await access.set(client, on: true)
            XCTAssertNil(store.decision(for: harness.identity), client.displayName)
            XCTAssertFalse(access.subtitle(client).hasPrefix("Connected."), client.displayName)
        }
        XCTAssertEqual(try Data(contentsOf: claudeConfig), bytes)
        XCTAssertTrue(runner.calls.isEmpty)
    }
}

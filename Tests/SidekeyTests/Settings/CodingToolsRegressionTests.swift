import Combine
import Foundation
import XCTest
@testable import Sidekey

/// Regressions the builder found on PR #507 (queue ticket 671): a Yes that
/// could not be taken back, an On overwriting a newer No, unusable entries
/// counted as connected, a stale answer after the seal went or a late save,
/// and an old presence read replacing a newer one.
// WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
@MainActor
final class CodingToolsRegressionTests: XCTestCase {
    func testExistingAllowRemainsRevocableWhenLocalEntryOrLocatorIsMissing() async throws {
        for tool in CodingToolsAccess.tools {
            let client = try XCTUnwrap(CodingToolsAccess.harnessClient(tool))
            for missing: CodingToolsAccess.Presence in [.notInstalled, .installed(configured: false)] {
                let store = HarnessAccessStore(persistence: nil)
                store.record(.allow, for: client, at: Date())
                let tools = CodingToolsAccess(store: { store }, probe: .init(presence: { _ in missing }, connect: { _ in [] }))
                await tools.refresh()

                XCTAssertEqual(store.decision(for: client.identity), .allow)
                XCTAssertTrue(tools.canSwitch(tool) && tools.isConnected(tool),
                              "\(tool) with \(missing): the existing Yes must have a visible Off action")
            }
        }
    }

    func testAnAllowedToolWithoutItsServerSaysSoAndHowToTakeItBack() async throws {
        let store = HarnessAccessStore(persistence: nil)
        store.record(.allow, for: try XCTUnwrap(CodingToolsAccess.harnessClient(.claudeCode)), at: Date())
        store.record(.allow, for: try XCTUnwrap(CodingToolsAccess.harnessClient(.codex)), at: Date())
        let tools = CodingToolsAccess(store: { store }, probe: .init(
            presence: { $0 == .claudeCode ? .notInstalled : .installed(configured: false) }, connect: { _ in [] }))
        await tools.refresh()
        XCTAssertEqual(tools.subtitle(.claudeCode),
                       "Not found on this Mac, but still allowed to use Whytap. Turn off to take that back.")
        XCTAssertEqual(tools.subtitle(.codex),
                       "Allowed to use Whytap, but Codex has no working whytap MCP server. Turn off and on again to add it.")
        await tools.set(.claudeCode, on: false)
        XCTAssertFalse(tools.isConnected(.claudeCode))
        XCTAssertFalse(tools.canSwitch(.claudeCode), "Off taken; On needs the tool on this Mac")
        XCTAssertEqual(tools.subtitle(.claudeCode), "Not installed on this Mac.")
    }

    func testNewerNoWinsWhileTheInstallationIsAwaitingItsResult() async throws {
        for tool in CodingToolsAccess.tools {
            let client = try XCTUnwrap(CodingToolsAccess.harnessClient(tool))
            let store = HarnessAccessStore(persistence: nil)
            var entryExists = false
            var finishSetup: CheckedContinuation<Void, Never>?
            let tools = CodingToolsAccess(store: { store }, probe: .init(
                presence: { _ in .installed(configured: entryExists) },
                connect: { _ in
                    await withCheckedContinuation { finishSetup = $0 }
                    entryExists = true
                    return []
                }))
            await tools.refresh()

            let setup = Task { await tools.set(tool, on: true) }
            while finishSetup == nil { await Task.yield() }
            store.record(.deny, for: client, at: Date())
            finishSetup?.resume()
            await setup.value

            XCTAssertEqual(store.decision(for: client.identity), .deny, "\(tool): the newer No should survive")
            XCTAssertFalse(tools.isConnected(tool))
        }
    }

    func testDisabledCodexEntryRemainsUntouchedAndDoesNotRecordYes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodingToolsProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeCommandRunner()
        let helper = root.appendingPathComponent("helper")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data(),
                                                      attributes: [.posixPermissions: 0o700]))
        runner.codexEntries["whytap"] = FakeCommandRunner.codexStdio(
            "whytap", command: helper.path, args: ["mcp"], settings: ["enabled": false])
        let connector = CodexCaseConnector(home: root, runner: runner, reader: runner, locate: { helper })
        let setup = CaseClientSetup(helperURL: helper, binDir: root.appendingPathComponent("bin"),
                                    flavorName: "dev", connectors: [.codex: connector], builtInAgentAvailable: { false })
        let store = HarnessAccessStore(persistence: nil)
        let tools = CodingToolsAccess(store: { store }, probe: .live(setup: setup))
        let client = try XCTUnwrap(CodingToolsAccess.harnessClient(.codex))
        await tools.refresh()
        await tools.set(.codex, on: true)

        XCTAssertFalse(tools.isConnected(.codex))
        XCTAssertNil(store.decision(for: client.identity))
        XCTAssertTrue(runner.calls.isEmpty, "Do not rewrite the manual entry")
    }

    func testUnusableClaudeEntryRemainsUntouchedAndDoesNotRecordYes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodingToolsProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data(),
                                                      attributes: [.posixPermissions: 0o700]))
        let runner = FakeCommandRunner()
        let connector = ClaudeCodeCaseConnector(home: root, socketPath: root.appendingPathComponent("sock").path,
                                               runner: runner, locate: { helper })
        let setup = CaseClientSetup(helperURL: helper, binDir: root.appendingPathComponent("bin"),
                                    flavorName: "dev", connectors: [.claudeCode: connector], builtInAgentAvailable: { false })
        let config = root.appendingPathComponent(".claude.json")
        for contents in [#"{"mcpServers":{"whytap":null}}"#, #"{"mcpServers":{"whytap":{}}}"#] {
            let original = Data(contents.utf8)
            try original.write(to: config)
            let store = HarnessAccessStore(persistence: nil)
            let tools = CodingToolsAccess(store: { store }, probe: .live(setup: setup))
            let client = try XCTUnwrap(CodingToolsAccess.harnessClient(.claudeCode))
            await tools.refresh()
            await tools.set(.claudeCode, on: true)
            XCTAssertFalse(tools.isConnected(.claudeCode), contents)
            XCTAssertNil(store.decision(for: client.identity), contents)
            XCTAssertEqual(try Data(contentsOf: config), original)
        }
        XCTAssertTrue(runner.calls.isEmpty, "Do not rewrite manual entries")
    }

    func testRefreshChecksAgainAfterStoredYesLosesItsMatchingSeal() async throws {
        let storeData = RegressionMemoryPersistence()
        let seal = RegressionMemorySeal()
        let writer = HarnessAccessStore(persistence: storeData, seal: seal)
        let client = try XCTUnwrap(CodingToolsAccess.harnessClient(.codex))
        XCTAssertTrue(writer.record(.allow, for: client, at: Date()))
        let store = HarnessAccessStore(persistence: storeData, seal: seal)
        let tools = CodingToolsAccess(store: { store }, probe: .init(
            presence: { _ in .installed(configured: true) }, connect: { _ in [] }))
        await tools.refresh()
        XCTAssertTrue(tools.isConnected(.codex))

        _ = seal.remove()
        await tools.refresh()
        XCTAssertFalse(tools.isConnected(.codex))
        XCTAssertNil(store.decision(for: client.identity))
    }

    func testSavedRevocationClearsThePublishedWarningEvenWithTheSameGrant() throws {
        let persistence = RegressionMemoryPersistence()
        let store = HarnessAccessStore(persistence: persistence)
        let tools = CodingToolsAccess(store: { store }, probe: .init(
            presence: { _ in .installed(configured: true) }, connect: { _ in [] }))
        let client = try XCTUnwrap(CodingToolsAccess.harnessClient(.codex))
        persistence.acceptsWrites = false
        XCTAssertFalse(store.record(.deny, for: client, at: Date()))
        XCTAssertTrue(store.hasUnsavedAnswers)
        var viewUpdates = 0
        let observation = tools.objectWillChange.sink { viewUpdates += 1 }

        withExtendedLifetime(observation) {
            persistence.acceptsWrites = true
            XCTAssertEqual(store.decision(for: client.identity), .deny)
            XCTAssertFalse(store.hasUnsavedAnswers)
            XCTAssertGreaterThan(viewUpdates, 0, "The Coding tools view observes this model, not the store")
        }
    }

    func testRefreshStartedBeforeConnectCannotReplaceItsNewerPresence() async throws {
        var configured = false
        var pauseNextClaudeRead = false
        var pendingRead: CheckedContinuation<CodingToolsAccess.Presence, Never>?
        let store = HarnessAccessStore(persistence: nil)
        let tools = CodingToolsAccess(store: { store }, probe: .init(
            presence: { tool in
                if tool == .claudeCode && pauseNextClaudeRead {
                    pauseNextClaudeRead = false
                    return await withCheckedContinuation { pendingRead = $0 }
                }
                return .installed(configured: configured)
            },
            connect: { _ in configured = true; return [] }))
        await tools.refresh()
        pauseNextClaudeRead = true
        let refresh = Task { await tools.refresh() }
        while pendingRead == nil { await Task.yield() }
        await tools.set(.claudeCode, on: true)
        XCTAssertTrue(tools.isConnected(.claudeCode))
        pendingRead?.resume(returning: .installed(configured: false))
        await refresh.value
        XCTAssertTrue(tools.isConnected(.claudeCode))
        XCTAssertEqual(tools.presence[.claudeCode], .installed(configured: true), "the older read was dropped")
        XCTAssertTrue(tools.subtitle(.claudeCode).hasPrefix("Connected."))
    }
}

private final class RegressionMemoryPersistence: HarnessAccessPersisting {
    var acceptsWrites = true
    var data: Data?
    func load() -> HarnessAccessStored { data.map(HarnessAccessStored.data) ?? .empty }
    func save(_ data: Data) -> Bool {
        guard acceptsWrites else { return false }
        self.data = data
        return true
    }
}

private final class RegressionMemorySeal: HarnessAccessSealing {
    var value: HarnessAccessSeal?
    func load() -> HarnessAccessSealState { value.map(HarnessAccessSealState.seal) ?? .missing }
    func save(_ value: HarnessAccessSeal) -> Bool { self.value = value; return true }
    func remove() -> Bool { value = nil; return true }
}

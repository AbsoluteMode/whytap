import Foundation
import XCTest
@testable import Sidekey

/// Entries Claude Code itself refuses (queue ticket 673): explicit `null`
/// fields, env and headers that aren't strings, ports past 65535 (also in
/// Codex). The builder's fixture, plus Codex's normalized `null` arguments
/// and the URL checks on their own.
// WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
@MainActor
final class CodingToolsClaudeSchemaTests: XCTestCase {
    func testCodexNormalizedNullArgumentsStillCount() throws {
        let fixture = FakeCommandRunner()
        let connector = CodexCaseConnector(home: FileManager.default.temporaryDirectory, runner: fixture,
                                           reader: fixture, locate: { URL(fileURLWithPath: "/usr/bin/true") })
        let result = #"{"name":"whytap","enabled":true,"transport":{"type":"stdio","command":"/usr/bin/true","args":null,"env":null,"env_vars":[],"cwd":null}}"#
        fixture.codexEntries["whytap"] = CaseCommandOutput(status: 0, stdout: Data(result.utf8), stderr: Data())
        XCTAssertTrue(connector.isConfigured())
    }

    func testWebURLs() {
        for good in ["http://127.0.0.1:9", "https://example.invalid/mcp", "https://example.invalid:65535/x"] {
            XCTAssertTrue(WhytapMCPEntry.isWebURL(good), good)
        }
        for bad in ["http://127.0.0.1:65536", "http://127.0.0.1:0", "invalid", "ftp://example.invalid", "https://", ""] {
            XCTAssertFalse(WhytapMCPEntry.isWebURL(bad), bad)
        }
        XCTAssertFalse(WhytapMCPEntry.isWebURL(nil))
    }

    func testClaudeDeclinesConsentForEntriesRejectedByItsTransportSchema() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhytapMalformedMCP-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data(),
                                                       attributes: [.posixPermissions: 0o700]))
        let runner = FakeCommandRunner()
        let config = root.appendingPathComponent(".claude.json")
        let connector = ClaudeCodeCaseConnector(home: root, socketPath: root.appendingPathComponent("sock").path,
                                                runner: runner, locate: { helper })
        let setup = CaseClientSetup(helperURL: helper, binDir: root.appendingPathComponent("bin"),
                                    flavorName: "dev", connectors: [.claudeCode: connector],
                                    builtInAgentAvailable: { false })
        let client = try XCTUnwrap(CodingToolsAccess.harnessClient(.claudeCode))
        for entry in [
            #"{"type":null,"command":"/usr/bin/true"}"#,
            #"{"type":"stdio","command":"/usr/bin/true","args":null}"#,
            #"{"type":"stdio","command":"/usr/bin/true","env":{"EXAMPLE":4}}"#,
            #"{"type":"stdio","command":"/usr/bin/true","env":null}"#,
            #"{"type":"http","url":"http://127.0.0.1:65536"}"#,
            #"{"type":"sse","url":"http://127.0.0.1:65536"}"#,
            #"{"type":"http","url":"http://127.0.0.1:9","headers":{"Example":4}}"#,
            #"{"type":"http","url":"http://127.0.0.1:9","headers":null}"#,
            #"{"type":"sse","url":"http://127.0.0.1:9","headers":{"Example":4}}"#,
            #"{"type":"sse","url":"http://127.0.0.1:9","headers":null}"#,
        ] {
            let original = Data((#"{"mcpServers":{"whytap":"# + entry + "}}").utf8)
            try original.write(to: config)
            let store = HarnessAccessStore(persistence: nil)
            let tools = CodingToolsAccess(store: { store }, probe: .live(setup: setup))
            await tools.refresh()
            XCTAssertEqual(tools.presence[.claudeCode], .installed(configured: false), entry)
            await tools.set(.claudeCode, on: true)
            XCTAssertNil(store.decision(for: client.identity), entry)
            XCTAssertFalse(tools.subtitle(.claudeCode).hasPrefix("Connected"), entry)
            XCTAssertEqual(try Data(contentsOf: config), original, entry)
        }
        XCTAssertTrue(runner.calls.isEmpty)
        for entry in [
            #"{"command":"/usr/bin/true"}"#,
            #"{"type":"stdio","command":"/usr/bin/true","args":[],"env":{"EXAMPLE":"value"}}"#,
            #"{"type":"http","url":"http://127.0.0.1:9","headers":{"Example":"value"}}"#,
            #"{"type":"sse","url":"http://127.0.0.1:9","headers":{"Example":"value"}}"#,
        ] {
            try Data((#"{"mcpServers":{"whytap":"# + entry + "}}").utf8).write(to: config)
            XCTAssertTrue(connector.isConfigured(), entry)
        }
    }

    func testCodexDeclinesConsentForAnOutOfRangeHTTPPort() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhytapBadCodexPort-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data(),
                                                       attributes: [.posixPermissions: 0o700]))
        let runner = FakeCommandRunner()
        let connector = CodexCaseConnector(home: root, runner: runner, reader: runner, locate: { helper })
        let setup = CaseClientSetup(helperURL: helper, binDir: root.appendingPathComponent("bin"),
                                    flavorName: "dev", connectors: [.codex: connector],
                                    builtInAgentAvailable: { false })
        let store = HarnessAccessStore(persistence: nil)
        let tools = CodingToolsAccess(store: { store }, probe: .live(setup: setup))
        let result = #"{"name":"whytap","enabled":true,"transport":{"type":"streamable_http","url":"http://127.0.0.1:65536"}}"#
        runner.codexEntries["whytap"] = CaseCommandOutput(status: 0, stdout: Data(result.utf8), stderr: Data())
        await tools.refresh()
        XCTAssertEqual(tools.presence[.codex], .installed(configured: false))
        await tools.set(.codex, on: true)
        let client = try XCTUnwrap(CodingToolsAccess.harnessClient(.codex))
        XCTAssertNil(store.decision(for: client.identity))
        XCTAssertFalse(tools.subtitle(.codex).hasPrefix("Connected"))
        XCTAssertTrue(runner.calls.isEmpty)
    }
}

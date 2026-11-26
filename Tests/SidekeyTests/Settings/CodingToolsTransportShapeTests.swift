import Foundation
import XCTest
@testable import Sidekey

/// A `whytap` entry counts only when its transport can start (queue ticket
/// 672): the builder's two shape fixtures, and On recording no Yes for an
/// entry that cannot start while leaving the person's file as it is.
// WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
@MainActor
final class CodingToolsTransportShapeTests: XCTestCase {
    func testOnRecordsNoYesForAClaudeEntryThatCannotStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhytapTransportOn-\(UUID())")
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
        for entry in [#"{"command":"   "}"#, #"{"type":"http","command":"/usr/bin/true"}"#,
                      #"{"type":"sse","url":"invalid"}"#, #"{"url":"https://example.invalid/mcp"}"#] {
            let original = Data((#"{"mcpServers":{"whytap":"# + entry + "}}").utf8)
            try original.write(to: config)
            let store = HarnessAccessStore(persistence: nil)
            let tools = CodingToolsAccess(store: { store }, probe: .live(setup: setup))
            await tools.refresh()
            XCTAssertEqual(tools.presence[.claudeCode], .installed(configured: false), entry)
            await tools.set(.claudeCode, on: true)
            XCTAssertFalse(tools.isConnected(.claudeCode), entry)
            XCTAssertNil(store.decision(for: try XCTUnwrap(CodingToolsAccess.harnessClient(.claudeCode)).identity), entry)
            XCTAssertNotNil(tools.problems[.claudeCode], entry)
            XCTAssertEqual(try Data(contentsOf: config), original, "the person's entry stays as it is")
        }
        XCTAssertTrue(runner.calls.isEmpty, "nothing rewritten")
    }

    func testOnRecordsNoYesForACodexEntryThatCannotStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhytapTransportOnCodex-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("helper")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data(),
                                                      attributes: [.posixPermissions: 0o700]))
        let runner = FakeCommandRunner()
        let connector = CodexCaseConnector(home: root, runner: runner, reader: runner, locate: { helper })
        let setup = CaseClientSetup(helperURL: helper, binDir: root.appendingPathComponent("bin"),
                                    flavorName: "dev", connectors: [.codex: connector], builtInAgentAvailable: { false })
        for transport: [String: Any] in [["type": "stdio", "command": " ", "args": []],
                                         ["type": "streamable_http", "url": "invalid"]] {
            let data = try JSONSerialization.data(withJSONObject: ["name": "whytap", "enabled": true, "transport": transport])
            runner.codexEntries["whytap"] = CaseCommandOutput(status: 0, stdout: data, stderr: Data())
            let store = HarnessAccessStore(persistence: nil)
            let tools = CodingToolsAccess(store: { store }, probe: .live(setup: setup))
            await tools.refresh()
            await tools.set(.codex, on: true)
            XCTAssertFalse(tools.isConnected(.codex), "\(transport)")
            XCTAssertNil(store.decision(for: try XCTUnwrap(CodingToolsAccess.harnessClient(.codex)).identity))
        }
        XCTAssertTrue(runner.calls.isEmpty, "nothing rewritten")
    }

    func testCodexDoesNotReportEmptyOrMalformedTransportsAsConfigured() throws {
        let temp = FileManager.default.temporaryDirectory
        let fixture = FakeCommandRunner()
        let connector = CodexCaseConnector(home: temp, runner: fixture, reader: fixture,
                                           locate: { URL(fileURLWithPath: "/usr/bin/true") })
        let unusable: [[String: Any]] = [
            ["type": "stdio", "command": "", "args": []],
            ["type": "stdio", "command": "   ", "args": []],
            ["type": "streamable_http", "url": ""],
            ["type": "streamable_http", "url": "invalid"],
            ["type": "unchecked"]
        ]
        for transport in unusable {
            let data = try JSONSerialization.data(withJSONObject: ["name": "whytap", "enabled": true, "transport": transport])
            fixture.codexEntries["whytap"] = CaseCommandOutput(status: 0, stdout: data, stderr: Data())
            XCTAssertFalse(connector.isConfigured(), "Unusable transport should not be shown as configured: \(transport)")
        }

        for transport: [String: Any] in [
            ["type": "stdio", "command": "/usr/bin/true", "args": []],
            ["type": "streamable_http", "url": "https://example.invalid/mcp"]
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["name": "whytap", "enabled": true, "transport": transport])
            fixture.codexEntries["whytap"] = CaseCommandOutput(status: 0, stdout: data, stderr: Data())
            XCTAssertTrue(connector.isConfigured(), "A custom command or URL remains recognized")
        }
    }

    func testClaudeOnlyRecognizesUsableShapeForEachTransport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhytapTransportShape-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connector = ClaudeCodeCaseConnector(home: root, socketPath: root.appendingPathComponent("socket").path,
                                               runner: FakeCommandRunner(),
                                               locate: { URL(fileURLWithPath: "/usr/bin/true") })
        let config = root.appendingPathComponent(".claude.json")
        let unusable: [[String: Any]] = [
            ["command": "   "],
            ["type": "stdio", "url": "https://example.invalid/mcp"],
            ["type": "stdio", "command": "/usr/bin/true", "args": "not an array"],
            ["type": "http", "command": "/usr/bin/true"],
            ["type": "http", "url": "invalid"],
            ["type": "unchecked", "command": "/usr/bin/true"]
        ]
        for entry in unusable {
            try JSONSerialization.data(withJSONObject: ["mcpServers": ["whytap": entry]]).write(to: config)
            XCTAssertFalse(connector.isConfigured(), "Unusable transport should not be shown as configured: \(entry)")
        }
        for entry: [String: Any] in [
            ["command": "/usr/bin/true"],
            ["type": "stdio", "command": "/usr/bin/true"],
            ["type": "http", "url": "https://example.invalid/mcp"],
            ["type": "sse", "url": "https://example.invalid/mcp"]
        ] {
            try JSONSerialization.data(withJSONObject: ["mcpServers": ["whytap": entry]]).write(to: config)
            XCTAssertTrue(connector.isConfigured(), "Working manual shape remains recognized")
        }
    }
}

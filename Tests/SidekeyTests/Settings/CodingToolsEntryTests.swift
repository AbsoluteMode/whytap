import Foundation
import XCTest
@testable import Sidekey

/// Connected means Whytap's own `whytap` entry (what Connect writes for this
/// app's helper) plus a Yes. Any other entry, working or not, is the person's:
/// Whytap does not judge it, records no Yes for it and leaves the file alone.
/// The entry lists include every shape the builder reported on tickets 671–673.
// WHY: .project-docs/decisions/2026-11-26-coding-tools-switches.md
@MainActor
final class CodingToolsEntryTests: XCTestCase {
    private var root: URL!
    private var helper: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CodingToolsEntry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        helper = root.appendingPathComponent("helper")
        XCTAssertTrue(FileManager.default.createFile(atPath: helper.path, contents: Data(),
                                                      attributes: [.posixPermissions: 0o700]))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func claude(_ runner: FakeCommandRunner) -> ClaudeCodeCaseConnector {
        ClaudeCodeCaseConnector(home: root, socketPath: root.appendingPathComponent("sock").path,
                                runner: runner, locate: { self.helper })
    }

    private func setup(_ client: CaseKnownClient, _ connector: CaseClientConnector) -> CaseClientSetup {
        CaseClientSetup(helperURL: helper, binDir: root.appendingPathComponent("bin"), flavorName: "dev",
                        connectors: [client: connector], builtInAgentAvailable: { false })
    }

    private func writeClaude(_ entry: String?) throws -> Data {
        let json = entry.map { #"{"mcpServers":{"whytap":"# + $0 + "}}" } ?? #"{"mcpServers":{}}"#
        let data = Data(json.utf8)
        try data.write(to: root.appendingPathComponent(".claude.json"))
        return data
    }

    // MARK: What counts as Whytap's own entry

    func testClaudeOnlyWhytapsOwnEntryIsOurs() throws {
        let connector = claude(FakeCommandRunner())
        let path = helper.path
        _ = try writeClaude(nil)
        XCTAssertEqual(connector.whytapEntry(helperPath: path), .none)
        for ours in [#"{"command":"\#(path)","args":["mcp"]}"#,
                     #"{"type":"stdio","command":"\#(path)","args":["mcp"],"env":{}}"#] {
            _ = try writeClaude(ours)
            XCTAssertEqual(connector.whytapEntry(helperPath: path), .ours, ours)
        }
        for custom in Self.claudeCustomEntries(helper: path) {
            _ = try writeClaude(custom)
            XCTAssertEqual(connector.whytapEntry(helperPath: path), .custom, custom)
        }
        try Data("not json".utf8).write(to: root.appendingPathComponent(".claude.json"))
        XCTAssertEqual(connector.whytapEntry(helperPath: path), .custom, "an unreadable file is not called ours")
    }

    func testCodexOnlyWhytapsOwnEntryIsOurs() {
        let runner = FakeCommandRunner()
        let connector = CodexCaseConnector(home: root, runner: runner, reader: runner, locate: { self.helper })
        let path = helper.path
        XCTAssertEqual(connector.whytapEntry(helperPath: path), .none)
        runner.codexEntries["whytap"] = FakeCommandRunner.codexStdio("whytap", command: path, args: ["mcp"])
        XCTAssertEqual(connector.whytapEntry(helperPath: path), .ours)
        for custom in Self.codexCustomEntries(helper: path) {
            runner.codexEntries["whytap"] = custom
            XCTAssertEqual(connector.whytapEntry(helperPath: path), .custom,
                           String(decoding: custom.stdout, as: UTF8.self))
        }
        XCTAssertTrue(runner.calls.isEmpty, "reading writes nothing")
    }

    func testCursorOnlyWhytapsOwnEntryIsOurs() throws {
        let connector = CursorCaseConnector(home: root, appInstalled: { true })
        let file = root.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertEqual(connector.whytapEntry(helperPath: helper.path), .none)
        try Data(#"{"mcpServers":{"whytap":{"command":"\#(helper.path)","args":["mcp"]}}}"#.utf8).write(to: file)
        XCTAssertEqual(connector.whytapEntry(helperPath: helper.path), .ours)
        try Data(#"{"mcpServers":{"whytap":{"url":"https://example.invalid/mcp"}}}"#.utf8).write(to: file)
        XCTAssertEqual(connector.whytapEntry(helperPath: helper.path), .custom)
    }

    // MARK: The switch with someone else's entry

    func testOnLeavesACustomClaudeEntryAloneAndRecordsNoYes() async throws {
        let runner = FakeCommandRunner()
        let live = setup(.claudeCode, claude(runner))
        let identity = try XCTUnwrap(CodingToolsAccess.harnessClient(.claudeCode)).identity
        for custom in Self.claudeCustomEntries(helper: helper.path) {
            let original = try writeClaude(custom)
            let store = HarnessAccessStore(persistence: nil)
            let tools = CodingToolsAccess(store: { store }, probe: .live(setup: live))
            await tools.refresh()
            XCTAssertEqual(tools.presence[.claudeCode], .customEntry, custom)
            XCTAssertFalse(tools.canSwitch(.claudeCode), custom)
            await tools.set(.claudeCode, on: true)
            XCTAssertNil(store.decision(for: identity), custom)
            XCTAssertFalse(tools.isConnected(.claudeCode), custom)
            XCTAssertFalse(tools.subtitle(.claudeCode).hasPrefix("Connected"), custom)
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".claude.json")), original, custom)
        }
        XCTAssertTrue(runner.calls.isEmpty, "nothing rewritten")
    }

    func testOnLeavesACustomCodexEntryAloneAndRecordsNoYes() async throws {
        let runner = FakeCommandRunner()
        let connector = CodexCaseConnector(home: root, runner: runner, reader: runner, locate: { self.helper })
        let live = setup(.codex, connector)
        let identity = try XCTUnwrap(CodingToolsAccess.harnessClient(.codex)).identity
        for custom in Self.codexCustomEntries(helper: helper.path) {
            runner.codexEntries["whytap"] = custom
            let store = HarnessAccessStore(persistence: nil)
            let tools = CodingToolsAccess(store: { store }, probe: .live(setup: live))
            await tools.refresh()
            XCTAssertEqual(tools.presence[.codex], .customEntry)
            await tools.set(.codex, on: true)
            XCTAssertNil(store.decision(for: identity))
            XCTAssertFalse(tools.isConnected(.codex))
        }
        XCTAssertTrue(runner.calls.isEmpty, "nothing rewritten")
    }

    func testOnWithWhytapsOwnEntryConnects() async throws {
        let runner = FakeCommandRunner()
        _ = try writeClaude(#"{"type":"stdio","command":"\#(helper.path)","args":["mcp"],"env":{}}"#)
        let store = HarnessAccessStore(persistence: nil)
        let tools = CodingToolsAccess(store: { store }, probe: .live(setup: setup(.claudeCode, claude(runner))))
        await tools.refresh()
        XCTAssertEqual(tools.presence[.claudeCode], .installed(configured: true))
        await tools.set(.claudeCode, on: true)
        XCTAssertTrue(tools.isConnected(.claudeCode))
        XCTAssertTrue(tools.subtitle(.claudeCode).hasPrefix("Connected."))
        XCTAssertFalse(runner.calls.contains { $0.arguments.starts(with: ["mcp", "add"]) }, "already there")
    }

    func testAYesWithACustomEntryCanBeTakenBack() async throws {
        let store = HarnessAccessStore(persistence: nil)
        let client = try XCTUnwrap(CodingToolsAccess.harnessClient(.codex))
        store.record(.allow, for: client, at: Date())
        let tools = CodingToolsAccess(store: { store }, probe: .init(presence: { _ in .customEntry }, connect: { _ in [] }))
        await tools.refresh()
        XCTAssertTrue(tools.isConnected(.codex))
        XCTAssertTrue(tools.canSwitch(.codex))
        XCTAssertEqual(tools.subtitle(.codex),
                       "Allowed to use Whytap. Codex has its own whytap MCP entry, which Whytap leaves as it is. Turn off to take the access back.")
        await tools.set(.codex, on: false)
        XCTAssertEqual(store.decision(for: client.identity), .deny)
        XCTAssertFalse(tools.canSwitch(.codex))
        XCTAssertEqual(tools.subtitle(.codex),
                       "Codex has its own whytap MCP entry, which Whytap leaves as it is. Remove it in Codex to connect here, or answer Yes when Codex asks for access.")
    }

    // MARK: Entries

    /// Working or not, none of these is what Whytap writes for `helper`.
    static func claudeCustomEntries(helper: String) -> [String] {
        [
            "null", "{}", #"{"command":"   "}"#, #"{"command":"/usr/bin/true"}"#,
            #"{"command":"\#(helper)","args":["case","mcp"]}"#,
            #"{"command":"\#(helper)","args":["mcp"],"env":{"X":"1"}}"#,
            #"{"type":null,"command":"\#(helper)","args":["mcp"]}"#,
            #"{"type":"stdio","command":"\#(helper)","args":null}"#,
            #"{"type":"stdio","url":"https://example.invalid/mcp"}"#,
            #"{"type":"stdio","command":"\#(helper)","args":"mcp"}"#,
            #"{"type":"stdio","command":"\#(helper)","args":["mcp"],"env":{"EXAMPLE":4}}"#,
            #"{"type":"http","command":"/usr/bin/true"}"#,
            #"{"type":"http","url":"invalid"}"#,
            #"{"type":"http","url":"http://127.0.0.1:65536"}"#,
            #"{"type":"sse","url":"http://127.0.0.1:9","headers":null}"#,
            #"{"type":"http","url":"https://example.invalid/mcp"}"#,
            #"{"type":"unchecked","command":"\#(helper)"}"#,
        ]
    }

    static func codexCustomEntries(helper: String) -> [CaseCommandOutput] {
        func raw(_ transport: [String: Any], enabled: Bool = true) -> CaseCommandOutput {
            let data = (try? JSONSerialization.data(withJSONObject: ["name": "whytap", "enabled": enabled,
                                                                       "transport": transport])) ?? Data()
            return CaseCommandOutput(status: 0, stdout: data, stderr: Data())
        }
        return [
            FakeCommandRunner.codexStdio("whytap", command: helper, args: ["mcp"], settings: ["enabled": false]),
            FakeCommandRunner.codexStdio("whytap", command: "/usr/bin/true", args: []),
            FakeCommandRunner.codexStdio("whytap", command: helper, args: ["case", "mcp"]),
            raw(["type": "stdio", "command": "", "args": []]),
            raw(["type": "stdio", "command": "   ", "args": []]),
            raw(["type": "streamable_http", "url": ""]),
            raw(["type": "streamable_http", "url": "invalid"]),
            raw(["type": "streamable_http", "url": "http://127.0.0.1:65536"]),
            raw(["type": "streamable_http", "url": "https://example.invalid/mcp"]),
            raw(["type": "unchecked"]),
            CaseCommandOutput(status: 1, stdout: Data(), stderr: Data("Error: something else\n".utf8)),
        ]
    }
}

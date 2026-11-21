import XCTest
@testable import Sidekey

/// The real `codex` CLI reads each fixture `config.toml` in a temporary HOME
/// (`codex mcp get <name> --json`, read-only); every changing command goes to a
/// fake runner and is only recorded. Skipped when Codex is not installed.
/// Fixtures include the builder's preservation checks (queue runs 7446, 44301).
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
final class CodexCLIConfigReadingTests: XCTestCase {
    private var codex: URL!

    override func setUpWithError() throws {
        guard let found = CodexBinaryLocator().locate() else { throw XCTSkip("Codex CLI is not installed") }
        codex = found
    }

    func test_foreign_whytap_servers_are_refused_without_changes() throws {
        let fixtures: [(String, String, CodexMCPEntry)] = [
            ("header comment", "[mcp_servers.whytap] # managed externally\ncommand = \"/usr/bin/true\"\n",
             .stdio(command: "/usr/bin/true", args: [])),
            ("inline table", "[mcp_servers]\nwhytap = { command = \"/usr/bin/true\" }\n",
             .stdio(command: "/usr/bin/true", args: [])),
            ("Unicode escape in the quoted key", "[mcp_servers.\"why\\u0074ap\"]\ncommand = \"/usr/bin/true\"\n",
             .stdio(command: "/usr/bin/true", args: [])),
            ("look-alike helper", "[mcp_servers.whytap]\ncommand = \"/opt/local/bin/whytap-metrics\"\nargs = [\"mcp\"]\n",
             .stdio(command: "/opt/local/bin/whytap-metrics", args: ["mcp"])),
            ("literal key, CRLF", "[mcp_servers.'whytap']\r\ncommand = \"npx\"\r\nargs = [\"-y\", \"other\"]\r\n",
             .stdio(command: "npx", args: ["-y", "other"])),
            ("dotted keys", "mcp_servers.whytap.command = \"npx\"\n", .stdio(command: "npx", args: [])),
            ("URL server", "[mcp_servers.whytap]\nurl = \"https://mcp.example.test/whytap\"\n", .other),
        ]
        for (label, toml, expected) in fixtures {
            let (home, helper) = try sandbox(toml)
            let runner = FakeCommandRunner()
            let connector = CodexCaseConnector(home: home, runner: runner, reader: SystemCaseCommandRunner(), locate: { self.codex })
            // Codex itself read the entry: the refusal is not a failed read.
            XCTAssertEqual(connector.entry("whytap", codex: codex), expected, label)
            XCTAssertThrowsError(try connector.install(helperPath: helper), label) { error in
                XCTAssertEqual(error as? CaseClientConnectorError, .foreignEntry, label)
            }
            XCTAssertTrue(runner.calls.isEmpty, "\(label): no changing CLI call")
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8), toml, label)
        }
    }

    func test_absent_and_our_own_entries_are_read_correctly() throws {
        // Nothing configured: one add.
        var (home, helper) = try sandbox("model = \"gpt\"\n# [mcp_servers.whytap] removed\n")
        var runner = FakeCommandRunner()
        XCTAssertEqual(CodexCaseConnector(home: home, runner: runner, locate: { self.codex }).entry("whytap", codex: codex), .absent)
        try CodexCaseConnector(home: home, runner: runner, reader: SystemCaseCommandRunner(), locate: { self.codex })
            .install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"]])

        // Our own entry (older `app mcp`) with our older `case` entry: replaced, then migrated.
        (home, helper) = try sandbox(nil)
        let toml = "[mcp_servers.\"whytap\"] # Whytap\ncommand = \"\(helper)\"\nargs = [\"app\", \"mcp\"]\n"
            + "[mcp_servers.case]\ncommand = '\(helper)'\nargs = [\n  \"case\",\n  \"mcp\",\n]\n"
        try toml.write(to: home.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        runner = FakeCommandRunner()
        try CodexCaseConnector(home: home, runner: runner, reader: SystemCaseCommandRunner(), locate: { self.codex })
            .install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "whytap"],
                                                      ["mcp", "add", "whytap", "--", helper, "mcp"],
                                                      ["mcp", "remove", "case"]])
    }

    /// A temporary HOME with `.codex/config.toml` and a stand-in helper file,
    /// so the helper path resolves like a real one.
    private func sandbox(_ toml: String?) throws -> (URL, String) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-read-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let codexDir = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        if let toml { try toml.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8) }
        let helper = home.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        return (home, helper.resolvingSymlinksInPath().path)
    }
}

import XCTest
@testable import Sidekey

/// `codex mcp add` replaces a server by name, so Connect must recognise every
/// TOML form that already defines `whytap` (or `case`) and refuse anything it
/// cannot read as our own plain entry, before any CLI runs. Temporary HOME and
/// a fake runner only: no real configuration is read or written.
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
final class CodexMCPConfigScannerTests: XCTestCase {
    private let helper = "/Applications/Whytap.app/Contents/Helpers/whytap"

    // MARK: The builder's two regressions (queue run 7446), verbatim

    func test_builder_codex_preserves_foreign_whytap_table_with_header_comment() throws {
        try assertRefusedWithoutCLI("[mcp_servers.whytap] # managed by a different tool\nurl = \"https://mcp.example.test/whytap\"\n")
    }

    func test_builder_codex_preserves_foreign_whytap_inline_table() throws {
        try assertRefusedWithoutCLI("[mcp_servers]\nwhytap = { url = \"https://mcp.example.test/whytap\" }\n")
    }

    // MARK: Other valid TOML forms of a foreign `whytap`

    func test_every_foreign_form_is_refused_before_the_cli_runs() throws {
        let foreign = [
            // header spellings
            "[mcp_servers.\"whytap\"]\ncommand = \"npx\"\nargs = [\"-y\", \"other\"]\n",
            "[mcp_servers.'whytap']\ncommand = \"npx\"\n",
            "[ mcp_servers . whytap ]\ncommand = \"npx\"\n",
            "[\"mcp_servers\".whytap]\t# note\ncommand = \"npx\"\n",
            "[mcp_servers.whytap]\r\ncommand = \"npx\"\r\nargs = [\"mcp\"]\r\n",
            "  [mcp_servers.whytap]   \n  command   =   \"uvx\"  # comment\n",
            // url-only / missing command
            "[mcp_servers.whytap]\nurl = \"https://mcp.example.test/whytap\"\n",
            "[mcp_servers.whytap]\n",
            // inline tables and dotted keys
            "mcp_servers.whytap = { command = \"npx\" }\n",
            "mcp_servers = { whytap = { command = \"npx\" } }\n",
            "[mcp_servers]\n\"whytap\" = { command = \"npx\" }\n",
            "[mcp_servers]\nwhytap.command = \"npx\"\n",
            "mcp_servers.whytap.command = \"npx\"\n",
            "[mcp_servers]\nwhytap = {\n  command = \"npx\",\n}\n",
            // sub-tables and arrays of tables only
            "[mcp_servers.whytap.env]\nX = \"1\"\n",
            "[[mcp_servers.whytap]]\ncommand = \"npx\"\n",
            // our command in a form codex does not write: still refused
            "[mcp_servers]\nwhytap = { command = \"\(helper)\", args = [\"mcp\"] }\n",
            // our helper, but args unreadable or another subcommand
            "[mcp_servers.whytap]\ncommand = \"\(helper)\"\nargs = \"mcp\"\n",
            "[mcp_servers.whytap]\ncommand = \"\(helper)\"\nargs = [\"case\", \"run\"]\n",
            // repeated header or key
            "[mcp_servers.whytap]\ncommand = \"\(helper)\"\nargs = [\"mcp\"]\n[mcp_servers.whytap]\ncommand = \"npx\"\n",
            "[mcp_servers.whytap]\ncommand = \"\(helper)\"\ncommand = \"npx\"\n",
            // escapes, multi-line and unterminated strings
            "[mcp_servers.whytap]\ncommand = \"C:\\\\npx\"\n",
            "[mcp_servers.whytap]\ncommand = \"\"\"\n\(helper)\"\"\"\nargs = [\"mcp\"]\n",
            "[mcp_servers.other]\nx = \"\"\"\n[mcp_servers.whytap]\n",
            "[mcp_servers.other]\nx = \"open\n[mcp_servers.whytap]\ncommand = \"\(helper)\"\n",
            // a header this reader cannot parse
            "[mcp_servers.whytap.\"a\\\"b\"]\nX = 1\n",
        ]
        for config in foreign {
            try assertRefusedWithoutCLI(config)
        }
    }

    // MARK: What still connects

    func test_our_plain_entry_in_every_spelling_is_replaced() throws {
        let ours = [
            "[mcp_servers.whytap]\ncommand = \"\(helper)\"\nargs = [\"mcp\"]\n",
            "[mcp_servers.\"whytap\"] # added by Whytap\ncommand = '\(helper)'\nargs = [ \"app\" , \"mcp\" ]\n",
            "[mcp_servers.whytap]\r\ncommand = \"/Applications/Whytap Beta.app/Contents/Helpers/whytap-beta\"\r\nargs = [\r\n  \"mcp\",\r\n]\r\n",
            "[mcp_servers.whytap]\ncommand = \"\(helper)\"\nargs = [\"mcp\"]\nstartup_timeout_sec = 20\n[mcp_servers.whytap.env]\nLANG = \"en_US.UTF-8\"\n",
            "[mcp_servers.whytap]\ncommand = \"\(helper)\"\n",
        ]
        for config in ours {
            let runner = try install(config)
            XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "whytap"],
                                                          ["mcp", "add", "whytap", "--", helper, "mcp"]], config)
        }
    }

    func test_mentions_elsewhere_do_not_block_connect() throws {
        let unrelated = [
            "# [mcp_servers.whytap] was removed\nmodel = \"gpt\"\n",
            "[mcp_servers.other]\ncommand = \"npx\"\nargs = [\n  \"whytap\",\n  \"--flag\",\n]\n",
            "[mcp_servers.whytap-old]\ncommand = \"npx\"\n",
            "[profiles.whytap]\nmodel = \"gpt\"\n",
            "note = \"mcp_servers.whytap\"\n",
            "[mcp_servers.other]\ndescription = \"\"\"\n[mcp_servers.whytap]\ncommand = \"npx\"\n\"\"\"\n",
            "[profiles.p]\ninstructions = '''\n# not a comment, whytap\n'''\n",
        ]
        for config in unrelated {
            let runner = try install(config)
            XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"]], config)
        }
    }

    // MARK: The older `case` entry is removed only in our plain form

    func test_older_case_entry_is_removed_only_when_plainly_ours() throws {
        let ours = "[mcp_servers.case] # Whytap\ncommand = \"\(helper)\"\nargs = [\"case\", \"mcp\"]\n"
        XCTAssertEqual(try install(ours).calls.map(\.arguments),
                       [["mcp", "add", "whytap", "--", helper, "mcp"], ["mcp", "remove", "case"]])
        XCTAssertEqual(try uninstall(ours).calls.map(\.arguments), [["mcp", "remove", "case"]])

        for foreign in [
            "[mcp_servers]\ncase = { command = \"\(helper)\", args = [\"case\", \"mcp\"] }\n",
            "[mcp_servers.case]\ncommand = \"npx\"\n",
            "[mcp_servers.case]\nurl = \"https://example.test\"\n",
            "[mcp_servers.case]\ncommand = \"\(helper)\"\nargs = [\"case\", \"run\"]\n",
        ] {
            XCTAssertEqual(try install(foreign).calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"]], foreign)
            XCTAssertTrue(try uninstall(foreign).calls.isEmpty, foreign)
        }
    }

    func test_unreadable_config_is_refused_without_cli() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: url)
        let runner = FakeCommandRunner()
        let connector = CodexCaseConnector(home: home, runner: runner, locate: { URL(fileURLWithPath: "/usr/local/bin/codex") })
        XCTAssertThrowsError(try connector.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .unreadableConfig(".codex/config.toml"))
        }
        try connector.uninstall()
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func test_scanner_reports_plain_table_fields() {
        XCTAssertEqual(CodexMCPConfigScanner.entry(named: "whytap", in: "model = \"x\"\n"), .absent)
        XCTAssertEqual(CodexMCPConfigScanner.entry(named: "whytap", in: "[mcp_servers.whytap]\ncommand = 'a'\nargs = ['mcp']\n"),
                       .table(command: "a", args: ["mcp"], argsReadable: true))
        XCTAssertEqual(CodexMCPConfigScanner.entry(named: "whytap", in: "[mcp_servers.whytap]\nargs = [1]\n"),
                       .table(command: nil, args: nil, argsReadable: false))
        XCTAssertEqual(CodexMCPConfigScanner.entry(named: "whytap", in: "[mcp_servers]\nwhytap = {}\n"), .uncertain)
    }

    // MARK: Claude Code and Cursor: unreadable or odd JSON is refused too

    func test_claude_unreadable_or_odd_user_config_is_refused_without_cli() throws {
        for config in [
            "{ not json",
            #"{"mcpServers":["whytap"]}"#,
            #"{"mcpServers":{"whytap":"npx whytap"}}"#,
            #"{"mcpServers":{"whytap":{"type":"http","url":"https://mcp.example.test/whytap"}}}"#,
            #"{"mcpServers":{"whytap":{"command":"/Applications/Whytap.app/Contents/Helpers/whytap","args":"mcp"}}}"#,
            #"{"mcpServers":{"whytap":{"command":"/Applications/Whytap.app/Contents/Helpers/whytap","args":["case","run"]}}}"#,
        ] {
            let home = try temporaryHome()
            try write(config, to: home.appendingPathComponent(".claude.json"))
            let runner = FakeCommandRunner()
            let connector = ClaudeCodeCaseConnector(home: home, socketPath: "/tmp/s.sock", runner: runner,
                                                    locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
            XCTAssertThrowsError(try connector.install(helperPath: helper), config)
            XCTAssertTrue(runner.calls.isEmpty, config)
        }
    }

    func test_cursor_odd_servers_object_is_never_replaced() throws {
        for config in [#"{"mcpServers":["whytap"]}"#,
                       #"{"mcpServers":{"whytap":{"command":"/Applications/Whytap.app/Contents/Helpers/whytap","args":7}}}"#] {
            let home = try temporaryHome()
            let url = home.appendingPathComponent(".cursor/mcp.json")
            try write(config, to: url)
            XCTAssertThrowsError(try CursorCaseConnector(home: home, appInstalled: { true }).install(helperPath: helper), config)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), config)
        }
    }

    // MARK: Helpers

    private func assertRefusedWithoutCLI(_ config: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let home = try temporaryHome()
        try write(config, to: home.appendingPathComponent(".codex/config.toml"))
        let runner = FakeCommandRunner()
        let connector = CodexCaseConnector(home: home, runner: runner, locate: { URL(fileURLWithPath: "/usr/local/bin/codex") })
        XCTAssertThrowsError(try connector.install(helperPath: helper), config, file: file, line: line) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .foreignEntry, config, file: file, line: line)
        }
        XCTAssertTrue(runner.calls.isEmpty, "no CLI call for: \(config)", file: file, line: line)
    }

    private func install(_ config: String) throws -> FakeCommandRunner {
        let home = try temporaryHome()
        try write(config, to: home.appendingPathComponent(".codex/config.toml"))
        let runner = FakeCommandRunner()
        try CodexCaseConnector(home: home, runner: runner, locate: { URL(fileURLWithPath: "/usr/local/bin/codex") })
            .install(helperPath: helper)
        return runner
    }

    private func uninstall(_ config: String) throws -> FakeCommandRunner {
        let home = try temporaryHome()
        try write(config, to: home.appendingPathComponent(".codex/config.toml"))
        let runner = FakeCommandRunner()
        try CodexCaseConnector(home: home, runner: runner, locate: { URL(fileURLWithPath: "/usr/local/bin/codex") }).uninstall()
        return runner
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

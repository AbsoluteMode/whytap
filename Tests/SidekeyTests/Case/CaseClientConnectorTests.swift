import XCTest
@testable import Sidekey

/// Client configs are the user's real files: every test here uses a temporary
/// HOME and a fake process runner, never ~/.claude.json, ~/.codex or ~/.cursor.
final class CaseClientConnectorTests: XCTestCase {
    private let helper = "/Applications/Whytap.app/Contents/Helpers/whytap"
    private let socket = "/Users/test/Library/Application Support/com.rootwise.sidekey/case-broker.sock"

    // MARK: Claude Code

    func test_claude_connector_runs_mcp_add_with_helper_path_and_no_secrets() throws {
        let home = try temporaryHome()
        let runner = FakeCommandRunner()
        let claude = URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner, locate: { claude })

        try connector.install(helperPath: helper)

        XCTAssertEqual(runner.calls.count, 1, "nothing configured yet: a single add")
        let call = try XCTUnwrap(runner.calls.first)
        XCTAssertEqual(call.executable, claude)
        XCTAssertEqual(call.arguments, ["mcp", "add", "-s", "user", "whytap", "--", helper, "mcp"])
        // The child gets only what it needs to find its own config, never a value or token.
        XCTAssertEqual(Set(call.environment.keys), ["HOME", "PATH", "LANG"])
        XCTAssertEqual(call.environment["HOME"], home.path)
        XCTAssertTrue(call.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") ?? false)
        let everything = (call.arguments + Array(call.environment.values)).joined(separator: " ")
        XCTAssertFalse(everything.contains("fixture-secret"))
        XCTAssertFalse(everything.localizedCaseInsensitiveContains("token"))
        // Without a sandboxed settings.json nothing else is written.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }

    /// A Claude Code connected by an earlier build has a Case-only `case`
    /// entry: Connect adds the one `whytap` server, then removes that entry.
    func test_claude_connect_migrates_the_older_case_entry_to_the_one_server() throws {
        let home = try temporaryHome()
        try write(#"{"mcpServers":{"case":{"command":"\#(helper)","args":["case","mcp"]}}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        let runner = FakeCommandRunner()
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertFalse(connector.isConfigured(), "only the old Case-only entry")

        try connector.install(helperPath: helper)

        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["mcp", "add", "-s", "user", "whytap", "--", helper, "mcp"],
            ["mcp", "remove", "-s", "user", "case"],
        ])
    }

    /// The README's older line added `whytap` -> `app mcp` by hand: Connect
    /// replaces it with the one server, which keeps every application tool.
    func test_claude_reinstall_replaces_our_existing_whytap_entry() throws {
        let home = try temporaryHome()
        try write(#"{"mcpServers":{"whytap":{"type":"stdio","command":"/Applications/Whytap.app/Contents/Helpers/whytap","args":["app","mcp"]}}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        let runner = FakeCommandRunner()
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertTrue(connector.isConfigured())

        try connector.install(helperPath: helper)

        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["mcp", "remove", "-s", "user", "whytap"],
            ["mcp", "add", "-s", "user", "whytap", "--", helper, "mcp"],
        ])
    }

    /// A failed cleanup of the old entry does not fail Connect: that entry
    /// still works (`case mcp` is kept) and only repeats the Case tools.
    func test_claude_failed_cleanup_of_the_old_entry_keeps_the_connection() throws {
        let home = try temporaryHome()
        try write(#"{"mcpServers":{"case":{"command":"\#(helper)","args":["case","mcp"]}}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        let runner = FakeCommandRunner()
        runner.failingArguments = ["mcp", "remove", "-s", "user", "case"]
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertNoThrow(try connector.install(helperPath: helper))
        XCTAssertEqual(runner.calls.first?.arguments, ["mcp", "add", "-s", "user", "whytap", "--", helper, "mcp"])
    }

    func test_claude_sandbox_gets_socket_path_preserving_settings() throws {
        let home = try temporaryHome()
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let original = #"""
        {"model":"opus","permissions":{"allow":["Bash(ls:*)"]},
         "sandbox":{"enabled":true,"network":{"allowUnixSockets":["/tmp/other.sock"],"allowedDomains":["github.com"]}}}
        """#
        try write(original, to: settingsURL)
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: FakeCommandRunner(),
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })

        try connector.install(helperPath: helper)
        try connector.install(helperPath: helper) // idempotent

        let json = try readJSON(settingsURL)
        XCTAssertEqual(json["model"] as? String, "opus")
        XCTAssertEqual((json["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash(ls:*)"])
        let sandbox = try XCTUnwrap(json["sandbox"] as? [String: Any])
        XCTAssertEqual(sandbox["enabled"] as? Bool, true)
        let network = try XCTUnwrap(sandbox["network"] as? [String: Any])
        XCTAssertEqual(network["allowUnixSockets"] as? [String], ["/tmp/other.sock", socket])
        XCTAssertEqual(network["allowedDomains"] as? [String], ["github.com"])
        // The previous file is kept next to it.
        XCTAssertEqual(try String(contentsOf: settingsURL.appendingPathExtension("bak"), encoding: .utf8), original)

        try connector.uninstall(helperPath: helper)
        let after = try readJSON(settingsURL)
        let afterNetwork = try XCTUnwrap((after["sandbox"] as? [String: Any])?["network"] as? [String: Any])
        XCTAssertEqual(afterNetwork["allowUnixSockets"] as? [String], ["/tmp/other.sock"])
    }

    func test_claude_sandbox_disabled_leaves_settings_untouched() throws {
        let home = try temporaryHome()
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let original = #"{"sandbox":{"enabled":false},"model":"opus"}"#
        try write(original, to: settingsURL)
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: FakeCommandRunner(),
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })

        try connector.install(helperPath: helper)

        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settingsURL.appendingPathExtension("bak").path))
    }

    func test_claude_broken_settings_are_not_overwritten() throws {
        let home = try temporaryHome()
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        try write("{ not json", to: settingsURL)
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: FakeCommandRunner(),
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })

        XCTAssertThrowsError(try connector.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .unreadableConfig(".claude/settings.json"))
        }
        XCTAssertEqual(try String(contentsOf: settingsURL, encoding: .utf8), "{ not json")
    }

    func test_claude_missing_or_failing_cli_is_reported() throws {
        let home = try temporaryHome()
        let missing = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: FakeCommandRunner(), locate: { nil })
        XCTAssertFalse(missing.isInstalled())
        XCTAssertThrowsError(try missing.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .clientNotFound)
        }

        let runner = FakeCommandRunner()
        runner.status = 1
        let failing = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                              locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertThrowsError(try failing.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .commandFailed(status: 1))
        }

        let throwing = FakeCommandRunner()
        throwing.error = CaseClientConnectorError.timedOut
        let hanging = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: throwing,
                                              locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertThrowsError(try hanging.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .timedOut)
        }
    }

    /// Disconnect removes only the old Case-only entry. The `whytap` server
    /// stays: it is the general Whytap server, and without a registration the
    /// broker already refuses its Case tools.
    func test_claude_uninstall_removes_only_the_old_case_entry() throws {
        let home = try temporaryHome()
        let runner = FakeCommandRunner()
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        try connector.uninstall(helperPath: helper)
        XCTAssertTrue(runner.calls.isEmpty, "nothing to remove")

        try write(#"{"mcpServers":{"whytap":{"command":"\#(helper)","args":["mcp"]}}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        try connector.uninstall(helperPath: helper)
        XCTAssertTrue(runner.calls.isEmpty, "the one server stays")

        try write(#"{"mcpServers":{"case":{"command":"\#(helper)","args":["case","mcp"]},"whytap":{"command":"\#(helper)","args":["mcp"]},"other":{}}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        try connector.uninstall(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "-s", "user", "case"]])
    }

    // MARK: Codex

    func test_codex_connector_reads_through_codex_then_adds_without_touching_its_config() throws {
        let home = try temporaryHome()
        let configURL = home.appendingPathComponent(".codex/config.toml")
        let config = "sandbox_mode = \"workspace-write\"\n"
        try write(config, to: configURL)
        let runner = FakeCommandRunner()
        let codex = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        let connector = codexConnector(home, runner, codex)

        XCTAssertFalse(connector.isConfigured())
        runner.reads.removeAll()
        try connector.install(helperPath: helper)
        XCTAssertEqual(runner.reads, [["mcp", "get", "whytap", "--json"], ["mcp", "get", "case", "--json"]],
                       "Codex's own parser answers; Whytap never parses config.toml")
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"]])
        XCTAssertEqual(runner.calls.first?.executable, codex)
        XCTAssertEqual(Set(runner.calls[0].environment.keys), ["HOME", "PATH", "LANG"])
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), config, "Codex config is changed only by codex itself")
    }

    func test_codex_connect_migrates_our_older_case_entry() throws {
        let runner = FakeCommandRunner()
        runner.codexEntries["case"] = FakeCommandRunner.codexStdio("case", command: helper, args: ["case", "mcp"])
        try codexConnector(try temporaryHome(), runner).install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"],
                                                      ["mcp", "remove", "case"]])
    }

    func test_codex_replaces_only_our_own_whytap_entry() throws {
        for args in [["mcp"], ["app", "mcp"], ["case", "mcp"]] {
            let runner = FakeCommandRunner()
            runner.codexEntries["whytap"] = FakeCommandRunner.codexStdio("whytap", command: helper, args: args)
            let connector = codexConnector(try temporaryHome(), runner)
            XCTAssertTrue(connector.isConfigured())
            try connector.install(helperPath: helper)
            XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "whytap"],
                                                          ["mcp", "add", "whytap", "--", helper, "mcp"]], "\(args)")
        }
    }

    /// The helper reached through a symlink (the `whytap` command Case installs
    /// in ~/.local/bin) is the same helper.
    func test_codex_entry_naming_our_helper_through_a_symlink_is_ours() throws {
        let home = try temporaryHome()
        let real = home.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try write("#!/bin/sh\n", to: real)
        let link = home.appendingPathComponent("bin/whytap")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let runner = FakeCommandRunner()
        runner.codexEntries["whytap"] = FakeCommandRunner.codexStdio("whytap", command: link.path, args: ["app", "mcp"])
        try codexConnector(home, runner).install(helperPath: real.path)
        XCTAssertEqual(runner.calls.first?.arguments, ["mcp", "remove", "whytap"])
    }

    func test_codex_disconnect_removes_only_our_older_case_entry() throws {
        let runner = FakeCommandRunner()
        runner.codexEntries["whytap"] = FakeCommandRunner.codexStdio("whytap", command: helper, args: ["mcp"])
        let connector = codexConnector(try temporaryHome(), runner)
        try connector.uninstall(helperPath: helper)
        XCTAssertTrue(runner.calls.isEmpty, "the one server stays on disconnect")

        runner.codexEntries["case"] = FakeCommandRunner.codexStdio("case", command: helper, args: ["case", "mcp"])
        try connector.uninstall(helperPath: nil)
        XCTAssertTrue(runner.calls.isEmpty, "without our helper path nothing can be proved ours")
        try connector.uninstall(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "case"]])
    }

    /// Codex itself unescapes `[mcp_servers."why\u0074ap"]` to `whytap`, so a
    /// foreign server spelled that way is found (builder queue run 44301).
    func test_codex_reads_names_through_codex_so_escaped_keys_are_found() throws {
        let runner = FakeCommandRunner()
        runner.codexEntries["whytap"] = FakeCommandRunner.codexStdio("whytap", command: "/usr/bin/true", args: [])
        try assertCodexRefusedWithoutChanges(runner)
    }

    func test_codex_lookalike_helper_names_are_foreign() throws {
        for command in ["/opt/local/bin/whytap-metrics", "/usr/local/bin/whytap", "whytap",
                        "/Users/x/Downloads/Whytap.app/Contents/Helpers/whytap",
                        "/Applications/Whytap Beta.app/Contents/Helpers/whytap-beta",
                        "/Applications/Whytap.app/Contents/Helpers/whytap/../whytap-metrics",
                        helper + "-metrics", ""] {
            let runner = FakeCommandRunner()
            runner.codexEntries["whytap"] = FakeCommandRunner.codexStdio("whytap", command: command, args: ["mcp"])
            try assertCodexRefusedWithoutChanges(runner, command)
        }
    }

    func test_codex_anything_it_cannot_prove_ours_is_refused_without_changes() throws {
        let uncertain: [(String, CaseCommandOutput)] = [
            ("url server", FakeCommandRunner.codexURL("whytap")),
            ("our helper, another subcommand", FakeCommandRunner.codexStdio("whytap", command: helper, args: ["case", "run"])),
            ("our helper, no args", FakeCommandRunner.codexStdio("whytap", command: helper, args: [])),
            ("empty answer", CaseCommandOutput(status: 0, stdout: Data(), stderr: Data())),
            ("not JSON", CaseCommandOutput(status: 0, stdout: Data("whytap  /usr/bin/true".utf8), stderr: Data())),
            ("another name", FakeCommandRunner.codexStdio("whytap2", command: helper, args: ["mcp"])),
            ("odd args", CaseCommandOutput(status: 0, stdout: Data(#"{"name":"whytap","transport":{"type":"stdio","command":"x","args":[1]}}"#.utf8), stderr: Data())),
            ("broken config", CaseCommandOutput(status: 1, stdout: Data(), stderr: Data("Error: failed to load bootstrap configuration\n".utf8))),
            ("other wording", CaseCommandOutput(status: 1, stdout: Data(), stderr: Data("error: server whytap not found".utf8))),
            ("truncated", CaseCommandOutput(status: 0, stdout: FakeCommandRunner.codexStdio("whytap", command: helper, args: ["mcp"]).stdout,
                                            stderr: Data(), truncated: true)),
        ]
        for (label, output) in uncertain {
            let runner = FakeCommandRunner()
            runner.codexEntries["whytap"] = output
            try assertCodexRefusedWithoutChanges(runner, label)
        }
        // A read that cannot run at all.
        let failing = FakeCommandRunner()
        failing.readError = CaseClientConnectorError.timedOut
        try assertCodexRefusedWithoutChanges(failing, "read failed")
    }

    func test_codex_foreign_or_unprovable_case_entry_is_left_alone() throws {
        for output in [FakeCommandRunner.codexStdio("case", command: "/opt/local/bin/whytap-metrics", args: ["case", "mcp"]),
                       FakeCommandRunner.codexStdio("case", command: "npx", args: ["case-mcp-server"]),
                       FakeCommandRunner.codexURL("case"),
                       FakeCommandRunner.codexStdio("case", command: helper, args: ["case", "run"]),
                       CaseCommandOutput(status: 1, stdout: Data(), stderr: Data("Error: boom".utf8))] {
            let runner = FakeCommandRunner()
            runner.codexEntries["case"] = output
            let connector = codexConnector(try temporaryHome(), runner)
            try connector.install(helperPath: helper)
            try connector.uninstall(helperPath: helper)
            XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"]])
        }
    }

    func test_codex_without_its_cli_changes_nothing() throws {
        let runner = FakeCommandRunner()
        let connector = CodexCaseConnector(home: try temporaryHome(), runner: runner, reader: runner, locate: { nil })
        XCTAssertThrowsError(try connector.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .clientNotFound)
        }
        try connector.uninstall(helperPath: helper)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(runner.reads.isEmpty)
    }

    func test_codex_answer_parser() {
        XCTAssertEqual(CodexMCPEntry.parse(FakeCommandRunner.codexNotFound("whytap"), name: "whytap"), .absent)
        XCTAssertEqual(CodexMCPEntry.parse(FakeCommandRunner.codexNotFound("case"), name: "whytap"), .uncertain)
        XCTAssertEqual(CodexMCPEntry.parse(FakeCommandRunner.codexStdio("whytap", command: "/a", args: ["mcp"]), name: "whytap"),
                       .stdio(command: "/a", args: ["mcp"]))
        XCTAssertEqual(CodexMCPEntry.parse(FakeCommandRunner.codexURL("whytap"), name: "whytap"), .other)
    }

    private func codexConnector(_ home: URL, _ runner: FakeCommandRunner,
                                _ codex: URL = URL(fileURLWithPath: "/usr/local/bin/codex")) -> CodexCaseConnector {
        CodexCaseConnector(home: home, runner: runner, reader: runner, locate: { codex })
    }

    private func assertCodexRefusedWithoutChanges(_ runner: FakeCommandRunner, _ label: String = "",
                                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let connector = codexConnector(try temporaryHome(), runner)
        XCTAssertThrowsError(try connector.install(helperPath: helper), label, file: file, line: line) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .foreignEntry, label, file: file, line: line)
        }
        XCTAssertTrue(runner.calls.isEmpty, "no changing CLI call: \(label)", file: file, line: line)
        XCTAssertEqual(runner.reads, [["mcp", "get", "whytap", "--json"]], label, file: file, line: line)
    }

    // MARK: Cursor

    func test_cursor_connector_preserves_other_servers() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".cursor/mcp.json")
        let original = #"{"mcpServers":{"github":{"command":"gh-mcp","args":["--stdio"],"env":{"X":"1"}}},"other":true}"#
        try write(original, to: url)
        let connector = CursorCaseConnector(home: home, appInstalled: { true })

        try connector.install(helperPath: helper)

        let json = try readJSON(url)
        XCTAssertEqual(json["other"] as? Bool, true)
        let servers = try XCTUnwrap(json["mcpServers"] as? [String: Any])
        let github = try XCTUnwrap(servers["github"] as? [String: Any])
        XCTAssertEqual(github["command"] as? String, "gh-mcp")
        XCTAssertEqual(github["args"] as? [String], ["--stdio"])
        XCTAssertEqual(github["env"] as? [String: String], ["X": "1"])
        let entry = try XCTUnwrap(servers["whytap"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, helper)
        XCTAssertEqual(entry["args"] as? [String], ["mcp"])
        XCTAssertEqual(Set(entry.keys), ["command", "args"], "no env, no token")
        XCTAssertNil(servers["case"])
        XCTAssertEqual(try String(contentsOf: url.appendingPathExtension("bak"), encoding: .utf8), original)
        XCTAssertTrue(connector.isConfigured())

        try connector.uninstall(helperPath: helper)
        let after = try readJSON(url)
        let afterServers = try XCTUnwrap(after["mcpServers"] as? [String: Any])
        XCTAssertNotNil(afterServers["whytap"], "the one server stays on disconnect")
        XCTAssertNotNil(afterServers["github"])
        XCTAssertEqual(after["other"] as? Bool, true)
    }

    func test_cursor_connect_migrates_and_disconnect_removes_the_older_case_entry() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".cursor/mcp.json")
        let legacy = #"{"command":"/Applications/Whytap.app/Contents/Helpers/whytap","args":["case","mcp"]}"#
        try write(#"{"mcpServers":{"case":\#(legacy),"github":{"command":"gh-mcp"}}}"#, to: url)
        let connector = CursorCaseConnector(home: home, appInstalled: { true })

        try connector.install(helperPath: helper)
        var servers = try XCTUnwrap(try readJSON(url)["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["case"], "migrated in the same write")
        XCTAssertEqual((servers["whytap"] as? [String: Any])?["args"] as? [String], ["mcp"])
        XCTAssertNotNil(servers["github"])

        // A config still holding only the old entry (connected by an earlier build).
        try write(#"{"mcpServers":{"case":\#(legacy)}}"#, to: url)
        try connector.uninstall(helperPath: helper)
        servers = try XCTUnwrap(try readJSON(url)["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["case"])
    }

    func test_cursor_creates_missing_file_and_refuses_broken_one() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".cursor/mcp.json")
        let connector = CursorCaseConnector(home: home, appInstalled: { false })
        XCTAssertFalse(connector.isInstalled())
        try connector.uninstall(helperPath: helper) // no file: nothing to do, nothing created
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        try connector.install(helperPath: helper)
        let servers = try XCTUnwrap(try readJSON(url)["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["whytap"])

        try write("[1, 2", to: url)
        XCTAssertThrowsError(try connector.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .unreadableConfig(".cursor/mcp.json"))
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[1, 2")
    }

    // MARK: Foreign entries (Claude Code, Cursor)

    /// Every foreign `whytap` form is refused with zero CLI calls and the
    /// file left byte for byte: a JSON-escaped key, a look-alike helper, a URL
    /// server, odd fields.
    func test_foreign_whytap_entries_are_refused_without_changes() throws {
        let foreign = [
            #"{"mcpServers":{"whytap":{"command":"npx","args":["-y","some-other-whytap"]}}}"#,
            #"{"mcpServers":{"why\u0074ap":{"command":"/usr/bin/true","args":[]}}}"#,
            #"{"mcpServers":{"whytap":{"command":"/opt/local/bin/whytap-metrics","args":["mcp"]}}}"#,
            #"{"mcpServers":{"whytap":{"command":"/Users/x/Downloads/Whytap.app/Contents/Helpers/whytap","args":["mcp"]}}}"#,
            #"{"mcpServers":{"whytap":{"command":"whytap","args":["mcp"]}}}"#,
            #"{"mcpServers":{"whytap":{"command":"\#(helper)"}}}"#,
            #"{"mcpServers":{"whytap":{"command":"\#(helper)","args":"mcp"}}}"#,
            #"{"mcpServers":{"whytap":{"command":"\#(helper)","args":["case","run"]}}}"#,
            #"{"mcpServers":{"whytap":{"type":"http","url":"https://mcp.example.test/whytap"}}}"#,
            #"{"mcpServers":{"whytap":{"type":"sse","command":"\#(helper)","args":["mcp"]}}}"#,
            #"{"mcpServers":{"whytap":"npx whytap"}}"#,
        ]
        for config in foreign {
            let home = try temporaryHome()
            let claudeURL = home.appendingPathComponent(".claude.json")
            try write(config, to: claudeURL)
            let runner = FakeCommandRunner()
            let claude = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                 locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
            XCTAssertThrowsError(try claude.install(helperPath: helper), config) { error in
                XCTAssertEqual(error as? CaseClientConnectorError, .foreignEntry, config)
                XCTAssertTrue((error as? CaseClientConnectorError)?.userMessage.contains("“whytap”") ?? false)
            }
            try claude.uninstall(helperPath: helper)
            XCTAssertTrue(runner.calls.isEmpty, "Claude Code: no CLI call for \(config)")
            XCTAssertEqual(try String(contentsOf: claudeURL, encoding: .utf8), config)

            let cursorURL = home.appendingPathComponent(".cursor/mcp.json")
            try write(config, to: cursorURL)
            let cursor = CursorCaseConnector(home: home, appInstalled: { true })
            XCTAssertThrowsError(try cursor.install(helperPath: helper), config) { error in
                XCTAssertEqual(error as? CaseClientConnectorError, .foreignEntry, config)
            }
            try cursor.uninstall(helperPath: helper)
            XCTAssertEqual(try String(contentsOf: cursorURL, encoding: .utf8), config, "Cursor: left exactly as it was")
        }
    }

    func test_unreadable_or_odd_json_configs_are_refused_without_changes() throws {
        for config in ["{ not json", #"{"mcpServers":["whytap"]}"#] {
            let home = try temporaryHome()
            try write(config, to: home.appendingPathComponent(".claude.json"))
            let runner = FakeCommandRunner()
            let claude = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                 locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
            XCTAssertThrowsError(try claude.install(helperPath: helper), config) { error in
                XCTAssertEqual(error as? CaseClientConnectorError, .unreadableConfig(".claude.json"), config)
            }
            XCTAssertTrue(runner.calls.isEmpty, config)

            let cursorURL = home.appendingPathComponent(".cursor/mcp.json")
            try write(config, to: cursorURL)
            XCTAssertThrowsError(try CursorCaseConnector(home: home, appInstalled: { true }).install(helperPath: helper), config)
            XCTAssertEqual(try String(contentsOf: cursorURL, encoding: .utf8), config)
        }
    }

    /// Another server that happens to be named `case`, or a look-alike of ours,
    /// is not ours: Connect adds `whytap` beside it and never removes it.
    func test_foreign_case_entries_are_left_alone() throws {
        for entry in [#"{"command":"npx","args":["-y","case-mcp-server"]}"#,
                      #"{"command":"/opt/local/bin/whytap-metrics","args":["case","mcp"]}"#,
                      #"{"command":"/Users/x/Downloads/Whytap.app/Contents/Helpers/whytap","args":["case","mcp"]}"#,
                      #"{"command":"\#(helper)","args":["case","run"]}"#] {
            let config = #"{"mcpServers":{"case":\#(entry)}}"#
            let home = try temporaryHome()
            try write(config, to: home.appendingPathComponent(".claude.json"))
            let runner = FakeCommandRunner()
            let claude = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                 locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
            try claude.install(helperPath: helper)
            try claude.uninstall(helperPath: helper)
            XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "-s", "user", "whytap", "--", helper, "mcp"]], entry)

            let cursorURL = home.appendingPathComponent(".cursor/mcp.json")
            try write(config, to: cursorURL)
            let cursor = CursorCaseConnector(home: home, appInstalled: { true })
            try cursor.install(helperPath: helper)
            try cursor.uninstall(helperPath: helper)
            let servers = try XCTUnwrap(try readJSON(cursorURL)["mcpServers"] as? [String: Any])
            XCTAssertNotNil(servers["case"], entry)
            XCTAssertNotNil(servers["whytap"], entry)
        }
    }

    func test_ownership_is_the_exact_helper_path_and_a_whytap_subcommand() throws {
        XCTAssertTrue(CaseMCPEntryOwnership.isOurServer(command: helper, args: ["mcp"], helperPath: helper))
        XCTAssertTrue(CaseMCPEntryOwnership.isOurServer(command: helper, args: ["app", "mcp"], helperPath: helper))
        XCTAssertTrue(CaseMCPEntryOwnership.isOurServer(command: helper, args: ["case", "mcp"], helperPath: helper))
        XCTAssertTrue(CaseMCPEntryOwnership.isOurServer(command: "/Applications/./Whytap.app/Contents/Helpers/whytap",
                                                        args: ["mcp"], helperPath: helper))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: helper, args: nil, helperPath: helper))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: helper, args: ["case", "run"], helperPath: helper))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: "/opt/local/bin/whytap-metrics", args: ["mcp"], helperPath: helper))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: "/x/whytap-dev", args: ["mcp"], helperPath: helper))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: "whytap", args: ["mcp"], helperPath: helper))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: "", args: ["mcp"], helperPath: helper))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: helper, args: ["mcp"], helperPath: "whytap"))
        XCTAssertTrue(CaseMCPEntryOwnership.isOurs(command: helper, args: ["case", "mcp"], helperPath: helper))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurs(command: helper, args: ["mcp"], helperPath: helper), "legacy is only case mcp")
        XCTAssertFalse(CaseMCPEntryOwnership.isOurs(command: helper, args: nil, helperPath: helper))
    }

    // MARK: Symlinked configs

    func test_symlinked_config_is_written_through_the_link() throws {
        let home = try temporaryHome()
        // ~/.cursor/mcp.json -> ~/dotfiles/cursor-mcp.json (a dotfiles repo)
        let real = home.appendingPathComponent("dotfiles/cursor-mcp.json")
        let original = #"{"mcpServers":{"github":{"command":"gh-mcp"}}}"#
        try write(original, to: real)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: real.path)
        let link = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try CursorCaseConnector(home: home, appInstalled: { true }).install(helperPath: helper)

        let attributes = try FileManager.default.attributesOfItem(atPath: link.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, "the link stays a link")
        let servers = try XCTUnwrap(try readJSON(real)["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["whytap"], "the real file got the entry")
        XCTAssertNotNil(servers["github"])
        let mode = try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o640, "permission bits kept")
        // The backup holds the real file's content, next to the real file.
        XCTAssertEqual(try String(contentsOf: real.appendingPathExtension("bak"), encoding: .utf8), original)
    }

    // MARK: CLI installer

    func test_cli_installer_refuses_to_replace_regular_file() throws {
        let home = try temporaryHome()
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let helperURL = home.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try write("#!/bin/sh\n", to: helperURL)
        try write("user's own script", to: bin.appendingPathComponent("whytap"))

        XCTAssertThrowsError(try CaseCLIInstaller.install(flavorName: "prod", helperURL: helperURL, binDir: bin)) { error in
            XCTAssertEqual(error as? CaseCLIInstallerError, .occupied(bin.appendingPathComponent("whytap").path))
        }
        XCTAssertEqual(try String(contentsOf: bin.appendingPathComponent("whytap"), encoding: .utf8), "user's own script")
    }

    func test_cli_installer_names_per_flavor_and_repoints_its_own_symlink() throws {
        let home = try temporaryHome()
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true) // does not exist yet
        let helperURL = home.appendingPathComponent("Whytap.app/Contents/Helpers/whytap")
        try write("#!/bin/sh\n", to: helperURL)

        XCTAssertEqual(try CaseCLIInstaller.commandName(flavorName: "prod"), "whytap")
        XCTAssertEqual(try CaseCLIInstaller.commandName(flavorName: "beta"), "whytap-beta")
        XCTAssertEqual(try CaseCLIInstaller.commandName(flavorName: "dev"), "whytap-dev")
        XCTAssertThrowsError(try CaseCLIInstaller.commandName(flavorName: "case"))

        let link = try CaseCLIInstaller.install(flavorName: "beta", helperURL: helperURL, binDir: bin)
        XCTAssertEqual(link.lastPathComponent, "whytap-beta")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helperURL.path)

        // A stale link of ours (an older app location) is repointed.
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Old/Whytap.app/Contents/Helpers/whytap")
        try CaseCLIInstaller.install(flavorName: "beta", helperURL: helperURL, binDir: bin)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), helperURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bin.appendingPathComponent("whytap").path),
                       "beta never takes the prod name")

        // A directory with that name is not ours either.
        let dirBin = home.appendingPathComponent("bin2", isDirectory: true)
        try FileManager.default.createDirectory(at: dirBin.appendingPathComponent("whytap-dev"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try CaseCLIInstaller.install(flavorName: "dev", helperURL: helperURL, binDir: dirBin))
    }

    func test_cli_flavor_name_for_dev_builds() {
        XCTAssertEqual(CaseCLIInstaller.flavorName(flavor: .prod, allowsPackagedUpdates: true), "prod")
        XCTAssertEqual(CaseCLIInstaller.flavorName(flavor: .beta, allowsPackagedUpdates: true), "beta")
        XCTAssertEqual(CaseCLIInstaller.flavorName(flavor: .beta, allowsPackagedUpdates: false), "dev")
        XCTAssertEqual(CaseCLIInstaller.flavorName(flavor: .prod, allowsPackagedUpdates: false), "dev")
    }

    // MARK: Helpers

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-connector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

final class FakeCommandRunner: CaseCommandRunning, CaseCommandReading {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
    }

    var calls: [Call] = []
    var status: Int32 = 0
    var error: Error?
    /// This one command exits with status 1; every other uses `status`.
    var failingArguments: [String]?

    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandResult {
        calls.append(Call(executable: executable, arguments: arguments, environment: environment))
        if let error { throw error }
        if arguments == failingArguments { return CaseCommandResult(status: 1) }
        return CaseCommandResult(status: status)
    }

    // MARK: Read-only `codex mcp get <name> --json`, in Codex 0.170's format

    /// Answers by server name; a name not listed is Codex's "not found".
    var codexEntries: [String: CaseCommandOutput] = [:]
    var reads: [[String]] = []
    var readError: Error?

    func read(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandOutput {
        reads.append(arguments)
        if let readError { throw readError }
        let name = arguments.count > 2 ? arguments[2] : ""
        return codexEntries[name] ?? Self.codexNotFound(name)
    }

    static func codexNotFound(_ name: String) -> CaseCommandOutput {
        CaseCommandOutput(status: 1, stdout: Data(), stderr: Data("Error: No MCP server named '\(name)' found.\n".utf8))
    }

    static func codexStdio(_ name: String, command: String, args: [String]) -> CaseCommandOutput {
        let object: [String: Any] = [
            "name": name, "enabled": true, "disabled_reason": NSNull(),
            "transport": ["type": "stdio", "command": command, "args": args, "env": NSNull(), "env_vars": [String](), "cwd": NSNull()],
            "enabled_tools": NSNull(), "disabled_tools": NSNull(), "startup_timeout_sec": NSNull(), "tool_timeout_sec": NSNull(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        return CaseCommandOutput(status: 0, stdout: data + Data("\n".utf8), stderr: Data())
    }

    static func codexURL(_ name: String) -> CaseCommandOutput {
        let object: [String: Any] = ["name": name, "enabled": true,
                                     "transport": ["type": "streamable_http", "url": "https://mcp.example.test/\(name)"]]
        return CaseCommandOutput(status: 0, stdout: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), stderr: Data())
    }
}

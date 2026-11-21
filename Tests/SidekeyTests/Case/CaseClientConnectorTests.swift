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
        try write(#"{"mcpServers":{"case":{"command":"/old/whytap","args":["case","mcp"]}}}"#,
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
        try write(#"{"mcpServers":{"case":{"command":"/old/whytap","args":["case","mcp"]}}}"#,
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

        try connector.uninstall()
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
        try connector.uninstall()
        XCTAssertTrue(runner.calls.isEmpty, "nothing to remove")

        try write(#"{"mcpServers":{"whytap":{"command":"\#(helper)","args":["mcp"]}}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        try connector.uninstall()
        XCTAssertTrue(runner.calls.isEmpty, "the one server stays")

        try write(#"{"mcpServers":{"case":{"command":"/old/whytap","args":["case","mcp"]},"whytap":{"command":"\#(helper)","args":["mcp"]},"other":{}}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        try connector.uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "-s", "user", "case"]])
    }

    // MARK: Codex

    func test_codex_connector_adds_and_removes_without_touching_sandbox() throws {
        let home = try temporaryHome()
        let configURL = home.appendingPathComponent(".codex/config.toml")
        let config = "sandbox_mode = \"workspace-write\"\n"
        try write(config, to: configURL)
        let runner = FakeCommandRunner()
        let codex = URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex")
        let connector = CodexCaseConnector(home: home, runner: runner, locate: { codex })

        try connector.install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"]])
        XCTAssertEqual(runner.calls.first?.executable, codex)
        XCTAssertEqual(try String(contentsOf: configURL, encoding: .utf8), config, "Codex config is changed only by codex itself")

        // An earlier build's Case-only entry: the one server is added, the old entry removed.
        try write(config + "\n[mcp_servers.case]\ncommand = \"\(helper)\"\nargs = [\"case\", \"mcp\"]\n", to: configURL)
        XCTAssertFalse(connector.isConfigured())
        runner.calls.removeAll()
        try connector.install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"],
                                                      ["mcp", "remove", "case"]])

        // Our own `whytap` entry is replaced so a moved app is picked up.
        try write(config + "\n[mcp_servers.whytap]\ncommand = \"\(helper)\"\nargs = [\"app\", \"mcp\"]\n", to: configURL)
        XCTAssertTrue(connector.isConfigured())
        runner.calls.removeAll()
        try connector.install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "whytap"],
                                                      ["mcp", "add", "whytap", "--", helper, "mcp"]])
        runner.calls.removeAll()
        try connector.uninstall()
        XCTAssertTrue(runner.calls.isEmpty, "the one server stays on disconnect")

        try write(config + "\n[mcp_servers.case]\ncommand = \"\(helper)\"\n", to: configURL)
        try connector.uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "remove", "case"]])
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

        try connector.uninstall()
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
        try connector.uninstall()
        servers = try XCTUnwrap(try readJSON(url)["mcpServers"] as? [String: Any])
        XCTAssertNil(servers["case"])
    }

    func test_cursor_creates_missing_file_and_refuses_broken_one() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".cursor/mcp.json")
        let connector = CursorCaseConnector(home: home, appInstalled: { false })
        XCTAssertFalse(connector.isInstalled())
        try connector.uninstall() // no file: nothing to do, nothing created
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

    // MARK: Foreign entries

    func test_foreign_whytap_entry_is_reported_not_replaced() throws {
        let home = try temporaryHome()
        let runner = FakeCommandRunner()
        let foreign = #"{"mcpServers":{"whytap":{"command":"npx","args":["-y","some-other-whytap"]}}}"#

        // Claude Code
        try write(foreign, to: home.appendingPathComponent(".claude.json"))
        let claude = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                             locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertThrowsError(try claude.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .foreignEntry)
            XCTAssertTrue((error as? CaseClientConnectorError)?.userMessage.contains("“whytap”") ?? false)
        }
        try claude.uninstall()
        XCTAssertTrue(runner.calls.isEmpty, "another server named whytap is never removed or replaced")

        // Codex
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try write("[mcp_servers.whytap]\ncommand = \"uvx\"\nargs = [\"whytap-server\"]\n", to: codexConfig)
        let codex = CodexCaseConnector(home: home, runner: runner, locate: { URL(fileURLWithPath: "/usr/local/bin/codex") })
        XCTAssertThrowsError(try codex.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .foreignEntry)
        }
        try codex.uninstall()
        XCTAssertTrue(runner.calls.isEmpty)

        // Cursor
        let cursorURL = home.appendingPathComponent(".cursor/mcp.json")
        try write(foreign, to: cursorURL)
        let cursor = CursorCaseConnector(home: home, appInstalled: { true })
        XCTAssertThrowsError(try cursor.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .foreignEntry)
        }
        try cursor.uninstall()
        XCTAssertEqual(try String(contentsOf: cursorURL, encoding: .utf8), foreign, "left exactly as it was")
    }

    /// Another server that happens to be named `case` is not ours: Connect adds
    /// the `whytap` server beside it and never removes it.
    func test_foreign_case_entry_is_left_alone() throws {
        let home = try temporaryHome()
        let runner = FakeCommandRunner()
        let foreign = #"{"mcpServers":{"case":{"command":"npx","args":["-y","case-mcp-server"]}}}"#

        try write(foreign, to: home.appendingPathComponent(".claude.json"))
        let claude = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                             locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        try claude.install(helperPath: helper)
        try claude.uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "-s", "user", "whytap", "--", helper, "mcp"]])

        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try write("[mcp_servers.case]\ncommand = \"uvx\"\nargs = [\"case-server\"]\n", to: codexConfig)
        runner.calls.removeAll()
        let codex = CodexCaseConnector(home: home, runner: runner, locate: { URL(fileURLWithPath: "/usr/local/bin/codex") })
        try codex.install(helperPath: helper)
        try codex.uninstall()
        XCTAssertEqual(runner.calls.map(\.arguments), [["mcp", "add", "whytap", "--", helper, "mcp"]])

        let cursorURL = home.appendingPathComponent(".cursor/mcp.json")
        try write(foreign, to: cursorURL)
        let cursor = CursorCaseConnector(home: home, appInstalled: { true })
        try cursor.install(helperPath: helper)
        try cursor.uninstall()
        let servers = try XCTUnwrap(try readJSON(cursorURL)["mcpServers"] as? [String: Any])
        XCTAssertEqual((servers["case"] as? [String: Any])?["command"] as? String, "npx")
        XCTAssertNotNil(servers["whytap"])
    }

    func test_our_entry_from_a_moved_or_other_flavor_app_is_replaced() throws {
        let home = try temporaryHome()
        let cursorURL = home.appendingPathComponent(".cursor/mcp.json")
        try write(#"{"mcpServers":{"whytap":{"command":"/Users/x/Downloads/Whytap.app/Contents/Helpers/whytap","args":["mcp"]}}}"#,
                  to: cursorURL)
        try CursorCaseConnector(home: home, appInstalled: { true }).install(helperPath: helper)
        let entry = try XCTUnwrap((try readJSON(cursorURL)["mcpServers"] as? [String: Any])?["whytap"] as? [String: Any])
        XCTAssertEqual(entry["command"] as? String, helper)

        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        try write("[mcp_servers.whytap]\ncommand = \"/Applications/Whytap Beta.app/Contents/Helpers/whytap-beta\"\nargs = [\"mcp\"]\n",
                  to: codexConfig)
        let runner = FakeCommandRunner()
        try CodexCaseConnector(home: home, runner: runner, locate: { URL(fileURLWithPath: "/usr/local/bin/codex") })
            .install(helperPath: helper)
        XCTAssertEqual(runner.calls.map(\.arguments).first, ["mcp", "remove", "whytap"])
    }

    func test_ownership_recognises_only_whytap_helpers_serving_whytap_commands() {
        XCTAssertTrue(CaseMCPEntryOwnership.isOurServer(command: helper, args: ["mcp"]))
        XCTAssertTrue(CaseMCPEntryOwnership.isOurServer(command: helper, args: ["app", "mcp"]))
        XCTAssertTrue(CaseMCPEntryOwnership.isOurServer(command: "/x/whytap-dev", args: ["case", "mcp"]))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: helper, args: ["case", "run"]))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: "/usr/bin/node", args: ["mcp"]))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurServer(command: "", args: ["mcp"]))
        XCTAssertTrue(CaseMCPEntryOwnership.isOurs(command: helper, args: ["case", "mcp"]))
        XCTAssertFalse(CaseMCPEntryOwnership.isOurs(command: helper, args: ["mcp"]), "the legacy check is only for case mcp")
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

final class FakeCommandRunner: CaseCommandRunning {
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
}

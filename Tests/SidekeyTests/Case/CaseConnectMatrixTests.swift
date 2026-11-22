import XCTest
@testable import Sidekey

/// Connect and Disconnect change an MCP entry only when it is exactly what
/// Whytap writes now or wrote before. Matrix: the `whytap` entry absent /
/// canonical / written by an earlier Whytap / customized in any way, and our
/// older `case` entry canonical / customized, for Connect and Disconnect, in
/// Claude Code, Codex and Cursor. An earlier Whytap's `whytap` is replaced by
/// `<helper> mcp`. A customized `whytap` stops Connect with "Configured
/// manually — Whytap left it as is", changes nothing and keeps `case` (it may
/// be the host's only working Case server).
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md,
// .project-docs/decisions/2026-11-22-connect-replaces-older-whytap-entries.md
final class CaseConnectMatrixTests: XCTestCase {
    private let helper = "/Applications/Whytap.app/Contents/Helpers/whytap"
    private let exodiaHelper = "/Applications/Exodia.app/Contents/Helpers/whytap"
    private let betaHelper = "/Applications/Whytap-Beta.app/Contents/Helpers/whytap"
    private let devHelper = "/Users/test/whytap/build/dev/Whytap Dev.app/Contents/Helpers/whytap"
    private let socket = "/Users/test/Library/Application Support/com.rootwise.sidekey/case-broker.sock"
    private let secret = "synthetic-value-4821"

    /// Every form of `whytap` that is neither `<helper> mcp` nor a plain entry
    /// an earlier Whytap of this flavor wrote.
    private var customizedWhytap: [(String, String, CaseCommandOutput)] {
        let stdio = { (args: [String], settings: [String: Any], transport: [String: Any]) in
            FakeCommandRunner.codexStdio("whytap", command: self.helper, args: args, settings: settings, transportSettings: transport)
        }
        return [
            ("env value", #"{"command":"\#(helper)","args":["mcp"],"env":{"TOKEN":"\#(secret)"}}"#,
             stdio(["mcp"], [:], ["env": ["TOKEN": secret]])),
            ("older app mcp with env", #"{"command":"\#(helper)","args":["app","mcp"],"env":{"TOKEN":"\#(secret)"}}"#,
             stdio(["app", "mcp"], [:], ["env": ["TOKEN": secret]])),
            ("older app mcp, disabled", #"{"command":"\#(helper)","args":["app","mcp"],"disabled":true}"#,
             stdio(["app", "mcp"], ["enabled": false], [:])),
            ("older app mcp with an extra argument", #"{"command":"\#(helper)","args":["app","mcp","--verbose"]}"#,
             stdio(["app", "mcp", "--verbose"], [:], [:])),
            ("another subcommand", #"{"command":"\#(helper)","args":["app","status"]}"#, stdio(["app", "status"], [:], [:])),
            ("the beta app's helper", #"{"command":"\#(betaHelper)","args":["app","mcp"]}"#,
             FakeCommandRunner.codexStdio("whytap", command: betaHelper, args: ["app", "mcp"])),
            ("a dev build's helper", #"{"command":"\#(devHelper)","args":["mcp"]}"#,
             FakeCommandRunner.codexStdio("whytap", command: devHelper, args: ["mcp"])),
            ("another spelling of the path", #"{"command":"/Applications/./Whytap.app/Contents/Helpers/whytap","args":["mcp"]}"#,
             FakeCommandRunner.codexStdio("whytap", command: "/Applications/./Whytap.app/Contents/Helpers/whytap", args: ["mcp"])),
            ("disabled", #"{"command":"\#(helper)","args":["mcp"],"disabled":true}"#, stdio(["mcp"], ["enabled": false], [:])),
            ("empty tool allowlist", #"{"command":"\#(helper)","args":["mcp"],"alwaysAllow":[]}"#, stdio(["mcp"], ["enabled_tools": [String]()], [:])),
            ("timeout", #"{"command":"\#(helper)","args":["mcp"],"timeout":45}"#, stdio(["mcp"], ["startup_timeout_sec": 45], [:])),
            ("someone else's", #"{"command":"npx","args":["-y","other-whytap"]}"#,
             FakeCommandRunner.codexStdio("whytap", command: "npx", args: ["-y", "other-whytap"])),
        ]
    }

    private var canonicalCaseJSON: String { #"{"command":"\#(helper)","args":["case","mcp"]}"# }
    private var customizedCaseJSON: String { #"{"command":"\#(helper)","args":["case","mcp"],"env":{"TOKEN":"\#(secret)"}}"# }
    private var canonicalCaseCodex: CaseCommandOutput {
        FakeCommandRunner.codexStdio("case", command: helper, args: ["case", "mcp"])
    }
    private var customizedCaseCodex: CaseCommandOutput {
        FakeCommandRunner.codexStdio("case", command: helper, args: ["case", "mcp"], settings: ["enabled_tools": [String]()])
    }

    // MARK: Connect

    func test_connect_adds_whytap_and_retires_a_canonical_case_entry() throws {
        try claude(whytap: nil, caseEntry: canonicalCaseJSON, connect: true,
                   expect: [add, ["mcp", "remove", "-s", "user", "case"]], error: nil, label: "absent")
        try codex(whytap: nil, caseEntry: canonicalCaseCodex, connect: true,
                  expect: [codexAdd, ["mcp", "remove", "case"]], error: nil, label: "absent")
        try cursor(whytap: nil, caseEntry: canonicalCaseJSON, connect: true, expectWhytapAdded: true,
                   expectCaseKept: false, error: nil, label: "absent")
    }

    func test_connect_leaves_a_canonical_whytap_and_retires_a_canonical_case_entry() throws {
        let json = #"{"command":"\#(helper)","args":["mcp"]}"#
        try claude(whytap: json, caseEntry: canonicalCaseJSON, connect: true,
                   expect: [["mcp", "remove", "-s", "user", "case"]], error: nil, label: "canonical")
        try claude(whytap: #"{"type":"stdio","command":"\#(helper)","args":["mcp"],"env":{}}"#, caseEntry: nil, connect: true,
                   expect: [], error: nil, label: "canonical as Claude writes it")
        try codex(whytap: FakeCommandRunner.codexStdio("whytap", command: helper, args: ["mcp"]), caseEntry: canonicalCaseCodex,
                  connect: true, expect: [["mcp", "remove", "case"]], error: nil, label: "canonical")
        try cursor(whytap: json, caseEntry: canonicalCaseJSON, connect: true, expectWhytapAdded: false,
                   expectCaseKept: false, error: nil, label: "canonical")
    }

    /// Builder reviews 3–8: whatever the person set, Connect changes nothing,
    /// keeps `case` and reports the one line.
    func test_connect_leaves_every_customized_whytap_and_keeps_case() throws {
        for (label, json, codexOutput) in customizedWhytap {
            try claude(whytap: json, caseEntry: canonicalCaseJSON, connect: true, expect: [], error: .configuredManually, label: label)
            try codex(whytap: codexOutput, caseEntry: canonicalCaseCodex, connect: true, expect: [], error: .configuredManually, label: label)
            try cursor(whytap: json, caseEntry: canonicalCaseJSON, connect: true, expectWhytapAdded: false,
                       expectCaseKept: true, error: .configuredManually, label: label)
        }
    }

    func test_connect_keeps_a_customized_case_entry() throws {
        try claude(whytap: nil, caseEntry: customizedCaseJSON, connect: true, expect: [add], error: nil, label: "customized case")
        try codex(whytap: nil, caseEntry: customizedCaseCodex, connect: true, expect: [codexAdd], error: nil, label: "customized case")
        try cursor(whytap: nil, caseEntry: customizedCaseJSON, connect: true, expectWhytapAdded: true,
                   expectCaseKept: true, error: nil, label: "customized case")
    }

    // MARK: Entries an earlier Whytap wrote

    /// Plain `whytap` entries earlier builds wrote: `app mcp` (the plugin and
    /// README line), `case mcp`, and the same flavor's Exodia-era path.
    private var earlierWhytap: [(String, String, CaseCommandOutput)] {
        [
            ("app mcp", #"{"command":"\#(helper)","args":["app","mcp"]}"#,
             FakeCommandRunner.codexStdio("whytap", command: helper, args: ["app", "mcp"])),
            ("app mcp as Claude writes it", #"{"type":"stdio","command":"\#(helper)","args":["app","mcp"],"env":{}}"#,
             FakeCommandRunner.codexStdio("whytap", command: helper, args: ["app", "mcp"])),
            ("case mcp under whytap", #"{"command":"\#(helper)","args":["case","mcp"]}"#,
             FakeCommandRunner.codexStdio("whytap", command: helper, args: ["case", "mcp"])),
            ("Exodia.app path, app mcp", #"{"command":"\#(exodiaHelper)","args":["app","mcp"]}"#,
             FakeCommandRunner.codexStdio("whytap", command: exodiaHelper, args: ["app", "mcp"])),
            ("Exodia.app path, mcp", #"{"command":"\#(exodiaHelper)","args":["mcp"]}"#,
             FakeCommandRunner.codexStdio("whytap", command: exodiaHelper, args: ["mcp"])),
        ]
    }

    /// The reported case: `whytap` -> `app mcp` and `case` -> `case mcp`
    /// become one `whytap` -> `<helper> mcp`.
    func test_connect_replaces_an_earlier_whytap_and_removes_case() throws {
        for (label, json, codexOutput) in earlierWhytap {
            try claude(whytap: json, caseEntry: canonicalCaseJSON, connect: true,
                       expect: [removeWhytap, add, removeCase], error: nil, label: label)
            try codex(whytap: codexOutput, caseEntry: canonicalCaseCodex, connect: true,
                      expect: [codexAdd, ["mcp", "remove", "case"]], error: nil, label: label)
            try cursor(whytap: json, caseEntry: canonicalCaseJSON, connect: true, expectWhytapAdded: true,
                       expectCaseKept: false, error: nil, label: label)
        }
    }

    func test_connect_replaces_an_earlier_whytap_without_a_case_entry() throws {
        for (label, json, codexOutput) in earlierWhytap {
            try claude(whytap: json, caseEntry: nil, connect: true, expect: [removeWhytap, add], error: nil, label: label)
            try codex(whytap: codexOutput, caseEntry: nil, connect: true, expect: [codexAdd], error: nil, label: label)
            try cursor(whytap: json, caseEntry: nil, connect: true, expectWhytapAdded: true,
                       expectCaseKept: false, error: nil, label: label)
        }
    }

    /// `case` with the person's own env is theirs: `whytap` is still replaced,
    /// `case` stays exactly as it was.
    func test_connect_replaces_an_earlier_whytap_but_keeps_a_case_entry_with_env() throws {
        let (label, json, codexOutput) = earlierWhytap[0]
        try claude(whytap: json, caseEntry: customizedCaseJSON, connect: true,
                   expect: [removeWhytap, add], error: nil, label: label)
        try codex(whytap: codexOutput, caseEntry: customizedCaseCodex, connect: true, expect: [codexAdd], error: nil, label: label)
        try cursor(whytap: json, caseEntry: customizedCaseJSON, connect: true, expectWhytapAdded: true,
                   expectCaseKept: true, error: nil, label: label)
    }

    /// An earlier `case` entry at the Exodia-era path is ours too.
    func test_connect_removes_a_case_entry_at_the_exodia_path() throws {
        let caseJSON = #"{"command":"\#(exodiaHelper)","args":["case","mcp"]}"#
        let caseCodex = FakeCommandRunner.codexStdio("case", command: exodiaHelper, args: ["case", "mcp"])
        try claude(whytap: nil, caseEntry: caseJSON, connect: true, expect: [add, removeCase], error: nil, label: "Exodia case")
        try codex(whytap: nil, caseEntry: caseCodex, connect: true, expect: [codexAdd, ["mcp", "remove", "case"]],
                  error: nil, label: "Exodia case")
        try cursor(whytap: nil, caseEntry: caseJSON, connect: true, expectWhytapAdded: true,
                   expectCaseKept: false, error: nil, label: "Exodia case")
    }

    /// Beta and prod are different apps; a dev build owns only its own path.
    /// The beta app adopts the Exodia-Beta path, never the prod app's entries.
    func test_flavors_and_dev_builds_adopt_only_their_own_entries() throws {
        let prodAppMCP = #"{"command":"\#(helper)","args":["app","mcp"]}"#
        let prodCodex = FakeCommandRunner.codexStdio("whytap", command: helper, args: ["app", "mcp"])
        for other in [betaHelper, devHelper] {
            try claude(whytap: prodAppMCP, caseEntry: canonicalCaseJSON, connect: true, expect: [],
                       error: .configuredManually, label: "prod entry, \(other)", helperPath: other)
            try codex(whytap: prodCodex, caseEntry: canonicalCaseCodex, connect: true, expect: [],
                      error: .configuredManually, label: "prod entry, \(other)", helperPath: other)
            try cursor(whytap: prodAppMCP, caseEntry: canonicalCaseJSON, connect: true, expectWhytapAdded: false,
                       expectCaseKept: true, error: .configuredManually, label: "prod entry, \(other)", helperPath: other)
        }
        let exodiaBeta = "/Applications/Exodia-Beta.app/Contents/Helpers/whytap"
        let betaJSON = #"{"command":"\#(exodiaBeta)","args":["app","mcp"]}"#
        try claude(whytap: betaJSON, caseEntry: nil, connect: true,
                   expect: [removeWhytap, ["mcp", "add", "-s", "user", "whytap", "--", betaHelper, "mcp"]],
                   error: nil, label: "Exodia-Beta entry, beta app", helperPath: betaHelper)
        try codex(whytap: FakeCommandRunner.codexStdio("whytap", command: exodiaBeta, args: ["app", "mcp"]), caseEntry: nil,
                  connect: true, expect: [["mcp", "add", "whytap", "--", betaHelper, "mcp"]],
                  error: nil, label: "Exodia-Beta entry, beta app", helperPath: betaHelper)
        try cursor(whytap: betaJSON, caseEntry: nil, connect: true, expectWhytapAdded: true, expectCaseKept: false,
                   error: nil, label: "Exodia-Beta entry, beta app", helperPath: betaHelper)
    }

    /// After a replacement the hosts hold exactly the canonical entry, and a
    /// second Connect runs no changing command and writes no file.
    func test_repeat_connect_changes_nothing() throws {
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".cursor/mcp.json")
        try write(#"{"mcpServers":{"whytap":\#(earlierWhytap[0].1),"case":\#(canonicalCaseJSON)}}"#, to: url)
        let connector = CursorCaseConnector(home: home, appInstalled: { true })
        try connector.install(helperPath: helper)
        let once = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try connector.install(helperPath: helper)
        XCTAssertEqual(try Data(contentsOf: url), once)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
                       attributes[.modificationDate] as? Date)
        XCTAssertEqual(try servers(url).keys.sorted(), ["whytap"])

        let canonical = #"{"type":"stdio","command":"\#(helper)","args":["mcp"],"env":{}}"#
        try claude(whytap: canonical, caseEntry: nil, connect: true, expect: [], error: nil, label: "second Connect")
        try codex(whytap: FakeCommandRunner.codexStdio("whytap", command: helper, args: ["mcp"]), caseEntry: nil,
                  connect: true, expect: [], error: nil, label: "second Connect")
    }

    /// Claude Code cannot replace a name: if adding the new entry fails after
    /// the earlier one was removed, the earlier one is added back as it was.
    func test_claude_puts_the_earlier_entry_back_when_the_add_fails() throws {
        let home = try temporaryHome()
        try write(#"{"mcpServers":{"whytap":{"command":"\#(helper)","args":["app","mcp"]},"case":\#(canonicalCaseJSON)}}"#,
                  to: home.appendingPathComponent(".claude.json"))
        let runner = FakeCommandRunner()
        runner.failingArguments = add
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        XCTAssertThrowsError(try connector.install(helperPath: helper)) { error in
            XCTAssertEqual(error as? CaseClientConnectorError, .commandFailed(status: 1))
        }
        XCTAssertEqual(runner.calls.map(\.arguments),
                       [removeWhytap, add, ["mcp", "add", "-s", "user", "whytap", "--", helper, "app", "mcp"]],
                       "earlier entry restored, case kept")

        let refused = FakeCommandRunner()
        refused.failingArguments = removeWhytap
        XCTAssertThrowsError(try ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: refused,
                                                         locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
            .install(helperPath: helper))
        XCTAssertEqual(refused.calls.map(\.arguments), [removeWhytap], "nothing else when the remove fails")
    }

    // MARK: Disconnect

    func test_disconnect_removes_only_a_canonical_case_entry_and_never_whytap() throws {
        let whytapForms: [(String, String?, CaseCommandOutput?)] =
            [("absent", nil, nil), ("canonical", #"{"command":"\#(helper)","args":["mcp"]}"#,
                                    FakeCommandRunner.codexStdio("whytap", command: helper, args: ["mcp"]))]
            + customizedWhytap.map { ($0.0, $0.1, $0.2) } + earlierWhytap.map { ($0.0, $0.1, $0.2) }
        for (label, json, codexOutput) in whytapForms {
            try claude(whytap: json, caseEntry: canonicalCaseJSON, connect: false,
                       expect: [["mcp", "remove", "-s", "user", "case"]], error: nil, label: label)
            try claude(whytap: json, caseEntry: customizedCaseJSON, connect: false, expect: [], error: nil, label: label)
            try codex(whytap: codexOutput, caseEntry: canonicalCaseCodex, connect: false,
                      expect: [["mcp", "remove", "case"]], error: nil, label: label)
            try codex(whytap: codexOutput, caseEntry: customizedCaseCodex, connect: false, expect: [], error: nil, label: label)
            try cursor(whytap: json, caseEntry: canonicalCaseJSON, connect: false, expectWhytapAdded: false,
                       expectCaseKept: false, error: nil, label: label)
            try cursor(whytap: json, caseEntry: customizedCaseJSON, connect: false, expectWhytapAdded: false,
                       expectCaseKept: true, error: nil, label: label)
        }
    }

    // MARK: Hosts

    private var add: [String] { ["mcp", "add", "-s", "user", "whytap", "--", helper, "mcp"] }
    private let removeWhytap = ["mcp", "remove", "-s", "user", "whytap"]
    private let removeCase = ["mcp", "remove", "-s", "user", "case"]
    private var codexAdd: [String] { ["mcp", "add", "whytap", "--", helper, "mcp"] }

    private func claude(whytap: String?, caseEntry: String?, connect: Bool, expect: [[String]],
                        error expected: CaseClientConnectorError?, label: String, helperPath: String? = nil,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let helper = helperPath ?? self.helper
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".claude.json")
        var servers: [String] = []
        if let whytap { servers.append(#""whytap":\#(whytap)"#) }
        if let caseEntry { servers.append(#""case":\#(caseEntry)"#) }
        try write(#"{"mcpServers":{\#(servers.joined(separator: ","))}}"#, to: url)
        let before = try Data(contentsOf: url)
        let runner = FakeCommandRunner()
        let connector = ClaudeCodeCaseConnector(home: home, socketPath: socket, runner: runner,
                                                locate: { URL(fileURLWithPath: "/usr/local/bin/claude") })
        try run(connect ? { try connector.install(helperPath: helper) } : { try connector.uninstall(helperPath: helper) },
                expected: expected, label: "Claude Code \(label)", file: file, line: line)
        XCTAssertEqual(runner.calls.map(\.arguments), expect, "Claude Code \(label)", file: file, line: line)
        assertNoValue(runner, "Claude Code \(label)", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: url), before, "only claude writes its file", file: file, line: line)
    }

    private func codex(whytap: CaseCommandOutput?, caseEntry: CaseCommandOutput?, connect: Bool, expect: [[String]],
                       error expected: CaseClientConnectorError?, label: String, helperPath: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let helper = helperPath ?? self.helper
        let runner = FakeCommandRunner()
        if let whytap { runner.codexEntries["whytap"] = whytap }
        if let caseEntry { runner.codexEntries["case"] = caseEntry }
        let connector = CodexCaseConnector(home: try temporaryHome(), runner: runner, reader: runner,
                                           locate: { URL(fileURLWithPath: "/usr/local/bin/codex") })
        try run(connect ? { try connector.install(helperPath: helper) } : { try connector.uninstall(helperPath: helper) },
                expected: expected, label: "Codex \(label)", file: file, line: line)
        XCTAssertEqual(runner.calls.map(\.arguments), expect, "Codex \(label)", file: file, line: line)
        assertNoValue(runner, "Codex \(label)", file: file, line: line)
    }

    private func cursor(whytap: String?, caseEntry: String?, connect: Bool, expectWhytapAdded: Bool, expectCaseKept: Bool,
                        error expected: CaseClientConnectorError?, label: String, helperPath: String? = nil,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let helper = helperPath ?? self.helper
        let home = try temporaryHome()
        let url = home.appendingPathComponent(".cursor/mcp.json")
        var entries: [String] = [#""github":{"command":"gh-mcp"}"#]
        if let whytap { entries.append(#""whytap":\#(whytap)"#) }
        if let caseEntry { entries.append(#""case":\#(caseEntry)"#) }
        try write(#"{"mcpServers":{\#(entries.joined(separator: ","))}}"#, to: url)
        let before = try Data(contentsOf: url)
        let beforeServers = try servers(url)
        let connector = CursorCaseConnector(home: home, appInstalled: { true })
        try run(connect ? { try connector.install(helperPath: helper) } : { try connector.uninstall(helperPath: helper) },
                expected: expected, label: "Cursor \(label)", file: file, line: line)
        let after = try servers(url)
        if !expectWhytapAdded && (expectCaseKept || caseEntry == nil) {
            XCTAssertEqual(try Data(contentsOf: url), before, "Cursor \(label): file unchanged", file: file, line: line)
        }
        if expectWhytapAdded {
            XCTAssertEqual(after["whytap"] as? NSDictionary, ["command": helper, "args": ["mcp"]] as NSDictionary,
                           "Cursor \(label)", file: file, line: line)
        } else {
            XCTAssertEqual(after["whytap"] as? NSDictionary, beforeServers["whytap"] as? NSDictionary,
                           "Cursor \(label): whytap as it was", file: file, line: line)
        }
        XCTAssertEqual(after["case"] != nil, expectCaseKept && caseEntry != nil, "Cursor \(label): case", file: file, line: line)
        if expectCaseKept, caseEntry != nil {
            XCTAssertEqual(after["case"] as? NSDictionary, beforeServers["case"] as? NSDictionary, file: file, line: line)
        }
        XCTAssertNotNil(after["github"], file: file, line: line)
    }

    private func run(_ action: () throws -> Void, expected: CaseClientConnectorError?, label: String,
                     file: StaticString, line: UInt) throws {
        if let expected {
            XCTAssertThrowsError(try action(), label, file: file, line: line) { error in
                XCTAssertEqual(error as? CaseClientConnectorError, expected, label, file: file, line: line)
            }
        } else {
            XCTAssertNoThrow(try action(), label, file: file, line: line)
        }
    }

    private func assertNoValue(_ runner: FakeCommandRunner, _ label: String, file: StaticString, line: UInt) {
        XCTAssertFalse(runner.calls.flatMap(\.arguments).joined(separator: " ").contains(secret),
                       "\(label): no configured value on a command line", file: file, line: line)
    }

    private func servers(_ url: URL) throws -> [String: Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["mcpServers"] as? [String: Any])
    }

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("case-matrix-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

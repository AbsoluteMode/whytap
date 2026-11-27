import XCTest
@testable import Sidekey

/// Import from this Mac: present, absent and broken files of each app.
final class MCPConfigImporterTests: XCTestCase {
    private func home(_ files: [String: String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-" + UUID().uuidString)
        for (path, contents) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testNoConfigFilesMeansNothingFoundAndNoProblems() throws {
        let scan = MCPConfigImporter(home: try home([:])).scan()
        XCTAssertEqual(scan, SourceImportScan())
    }

    func testClaudeCodeUserAndProjectServersWithSecretsMovedToKeychainDraft() throws {
        let claude = """
        {"numStartups": 40, "oauthAccount": {"emailAddress": "someone@example.com"},
         "mcpServers": {
           "github": {"type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-github"],
                      "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_realtoken123"}},
           "linear": {"type": "http", "url": "https://mcp.linear.app/mcp"},
           "legacy": {"type": "sse", "url": "https://example.com/sse"},
           "whytap": {"type": "stdio", "command": "/Applications/Whytap.app/Contents/Helpers/whytap", "args": ["mcp"]},
           "argsecret": {"command": "/usr/local/bin/srv", "args": ["--token", "abc123", "--verbose"]},
           "placeholder": {"type": "http", "url": "https://api.example.com/mcp", "headers": {"Authorization": "Bearer ${API_TOKEN}"}}
         },
         "projects": {"/Users/me/code/app": {"mcpServers": {"db": {"command": "uvx", "args": ["db-mcp"], "env": {"DB_URL": "postgres://u:p@h/db"}}}}}}
        """
        let scan = MCPConfigImporter(home: try home([".claude.json": claude])).scan()
        XCTAssertTrue(scan.problems.isEmpty)
        let byName = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.name, $0) })
        let github = try XCTUnwrap(byName["github"]?.draft)
        XCTAssertEqual(github.transport, .stdio(command: "npx", arguments: ["-y", "@modelcontextprotocol/server-github"], directory: nil))
        XCTAssertEqual(github.environment, [SourceValue(name: "GITHUB_PERSONAL_ACCESS_TOKEN", secret: true, value: nil)])
        XCTAssertEqual(github.secrets["GITHUB_PERSONAL_ACCESS_TOKEN"], "ghp_realtoken123")
        XCTAssertEqual(github.importedFrom, "Claude Code")
        XCTAssertFalse(byName["github"]!.summary.contains("ghp_"), "The import list never shows a secret")
        XCTAssertNotNil(byName["linear"]?.draft)
        XCTAssertTrue(byName["linear"]?.note?.contains("browser") == true)
        XCTAssertNil(byName["legacy"]?.draft)
        XCTAssertTrue(byName["legacy"]?.note?.contains("SSE") == true)
        XCTAssertNil(byName["whytap"]?.draft)
        // A secret on the command line is neither shown nor launched: the entry is refused with the reason.
        XCTAssertNil(byName["argsecret"]?.draft)
        XCTAssertEqual(byName["argsecret"]?.note, SourceCredentialPolicy.argumentReason)
        XCTAssertEqual(byName["argsecret"]?.summary, "/usr/local/bin/srv --token •••• --verbose")
        XCTAssertEqual(byName["placeholder"]?.draft?.missing, ["header.Authorization"])
        let project = try XCTUnwrap(byName["db (app)"])
        XCTAssertEqual(project.scope, "/Users/me/code/app")
        XCTAssertEqual(project.draft?.secrets["DB_URL"], "postgres://u:p@h/db")
        XCTAssertEqual(project.draft?.transport, .stdio(command: "uvx", arguments: ["db-mcp"], directory: "/Users/me/code/app"),
                       "A project server runs in its project folder, as in Claude Code")
        XCTAssertFalse(scan.candidates.contains { $0.summary.contains("someone@example.com") })
    }

    func testBrokenFilesAreNamedAndOtherAppsStillImport() throws {
        let scan = MCPConfigImporter(home: try home([
            ".cursor/mcp.json": "{ not json",
            "Library/Application Support/Claude/claude_desktop_config.json": #"{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents"]}}}"#,
        ])).scan()
        XCTAssertEqual(scan.problems, ["Cursor: ~/.cursor/mcp.json isn’t valid JSON."])
        XCTAssertEqual(scan.candidates.map(\.app), ["Claude Desktop"])
    }

    func testCodexTOMLWithEnvTableBearerVariableAndInlineTables() throws {
        let toml = """
        model = "gpt-5"
        [mcp_servers.github]
        command = "docker"
        args = ["run", "-i", "--rm", "-e", "GITHUB_PERSONAL_ACCESS_TOKEN", "ghcr.io/github/github-mcp-server"]
        [mcp_servers.github.env]
        GITHUB_PERSONAL_ACCESS_TOKEN = "github_pat_abc"

        [mcp_servers.remote]
        url = "https://api.githubcopilot.com/mcp/"
        bearer_token_env_var = "GITHUB_PAT"
        http_headers = { "X-MCP-Readonly" = "true" }

        [mcp_servers."quoted.name"]
        command = 'uvx'
        args = ['mcp-atlassian'] # trailing comment
        env = { JIRA_URL = "https://x.atlassian.net", JIRA_API_TOKEN = "atl" }
        """
        let scan = MCPConfigImporter(home: try home([".codex/config.toml": toml])).scan()
        let byName = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.name, $0) })
        XCTAssertEqual(byName["github"]?.draft?.secrets["GITHUB_PERSONAL_ACCESS_TOKEN"], "github_pat_abc")
        let remote = try XCTUnwrap(byName["remote"]?.draft)
        XCTAssertEqual(remote.transport, .http(url: "https://api.githubcopilot.com/mcp/"))
        XCTAssertEqual(remote.missing, ["header.Authorization"], "Codex reads the token from its environment; we ask for it")
        XCTAssertEqual(remote.secrets["header.X-MCP-Readonly"], "true")
        let quoted = try XCTUnwrap(byName["quoted.name"]?.draft)
        XCTAssertEqual(quoted.transport, .stdio(command: "uvx", arguments: ["mcp-atlassian"], directory: nil))
        XCTAssertEqual(quoted.secrets["JIRA_API_TOKEN"], "atl")
    }

    func testVSCodeServersWithInputPlaceholdersNeedAValue() throws {
        let json = #"{"inputs": [{"id": "tok", "type": "promptString", "password": true}], "servers": {"gh": {"type": "http", "url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": "Bearer ${input:tok}"}}, "local": {"command": "node", "args": ["server.js"]}}}"#
        let scan = MCPConfigImporter(home: try home(["Library/Application Support/Code/User/mcp.json": json])).scan()
        XCTAssertEqual(scan.candidates.map(\.name), ["gh", "local"])
        XCTAssertEqual(scan.candidates[0].draft?.missing, ["header.Authorization"])
        XCTAssertEqual(scan.candidates[1].draft?.transport, .stdio(command: "node", arguments: ["server.js"], directory: nil))
    }

    func testTheSameServerInTwoAppsIsOfferedOnce() throws {
        let entry = #"{"mcpServers": {"fs": {"command": "npx", "args": ["-y", "server-fs"]}}}"#
        let scan = MCPConfigImporter(home: try home([".cursor/mcp.json": entry,
                                                     "Library/Application Support/Claude/claude_desktop_config.json": entry])).scan()
        XCTAssertEqual(scan.candidates.filter { $0.draft != nil }.count, 1)
        XCTAssertEqual(scan.candidates.first { $0.draft == nil }?.note, "Same server as Claude Desktop · fs.")
    }

    func testInsecureRemoteAddressIsNotImported() throws {
        let scan = MCPConfigImporter(home: try home([".cursor/mcp.json": #"{"mcpServers": {"x": {"url": "http://example.com/mcp"}}}"#])).scan()
        XCTAssertNil(scan.candidates.first?.draft)
        XCTAssertEqual(scan.candidates.first?.note, MCPError.insecureURL.message)
    }

    // MARK: - Builder review regressions

    /// Point 1: the builder's sentinel never reaches a preview, a draft or a launch.
    func testTheBuildersArgvSentinelIsMaskedAndNotImported() throws {
        let json = #"{"mcpServers": {"probe": {"command": "/usr/local/bin/probe", "args": ["--token", "synthetic_value_for_secret_redaction_check"]}}}"#
        let scan = MCPConfigImporter(home: try home([".cursor/mcp.json": json])).scan()
        let probe = try XCTUnwrap(scan.candidates.first)
        XCTAssertNil(probe.draft)
        XCTAssertEqual(probe.note, SourceCredentialPolicy.argumentReason)
        XCTAssertFalse(probe.summary.contains("synthetic_value_for_secret_redaction_check"))
        XCTAssertFalse("\(scan)".contains("synthetic_value_for_secret_redaction_check"), "No field of the scan keeps it")
    }

    func testCredentialsInARemoteAddressAreRefusedAndMasked() throws {
        let json = #"{"mcpServers": {"q": {"url": "https://mcp.example.com/mcp?api_key=s3cr3t"}, "u": {"url": "https://user:pw@mcp.example.com/mcp"}, "loop": {"url": "http://127.0.0.1:8080/mcp", "headers": {"Authorization": "Bearer abc"}}, "plainloop": {"url": "http://localhost:8080/mcp"}}}"#
        let scan = MCPConfigImporter(home: try home([".cursor/mcp.json": json])).scan()
        let byName = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.name, $0) })
        for name in ["q", "u"] {
            XCTAssertNil(byName[name]?.draft, name)
            XCTAssertEqual(byName[name]?.note, SourceCredentialPolicy.addressReason, name)
        }
        XCTAssertFalse(byName["q"]!.summary.contains("s3cr3t"))
        XCTAssertFalse(byName["u"]!.summary.contains("pw"))
        XCTAssertNil(byName["loop"]?.draft, "A secret header never goes over plain http, even to this Mac")
        XCTAssertEqual(byName["loop"]?.note, SourceCredentialPolicy.plainHTTPReason)
        XCTAssertNotNil(byName["plainloop"]?.draft, "Plain http on this Mac without credentials is allowed")
    }

    /// Point 5: Codex multi-line arrays survive; what Whytap can't carry is refused with a reason.
    func testCodexMultilineArgumentsAndWorkingFolderArePreserved() throws {
        let toml = """
        [mcp_servers.fs]
        command = "npx"
        args = [
          "-y",          # package runner
          "@modelcontextprotocol/server-filesystem",
          "/Users/me/Documents",
        ]
        cwd = "/Users/me/work"
        """
        let scan = MCPConfigImporter(home: try home([".codex/config.toml": toml])).scan()
        let fs = try XCTUnwrap(scan.candidates.first?.draft)
        XCTAssertEqual(fs.transport, .stdio(command: "npx", arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Documents"],
                                            directory: "/Users/me/work"))
    }

    func testCodexEntriesWithUnknownKeysOrUnreadableValuesAreNotOffered() throws {
        let toml = #"""
        [mcp_servers.filtered]
        command = "srv"
        enabled_tools = ["search"]

        [mcp_servers.multi]
        command = "srv"
        args = ["""
        a
        """]

        [mcp_servers.ok]
        command = "srv"
        """#
        let scan = MCPConfigImporter(home: try home([".codex/config.toml": toml])).scan()
        let byName = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.name, $0) })
        XCTAssertNil(byName["filtered"]?.draft)
        XCTAssertEqual(byName["filtered"]?.note, "Uses enabled_tools, which Whytap can’t carry over yet.")
        XCTAssertNil(byName["multi"]?.draft)
        XCTAssertTrue(byName["multi"]?.note?.contains("couldn’t read") == true)
        XCTAssertNotNil(byName["ok"]?.draft)
    }

    func testJSONEntriesKeepTheirWorkingFolderAndRefuseUnknownKeys() throws {
        let json = #"{"mcpServers": {"a": {"command": "srv", "cwd": "~/proj"}, "b": {"command": "srv", "cwd": "rel"}, "c": {"command": "srv", "envFile": ".env"}}}"#
        let scan = MCPConfigImporter(home: try home([".cursor/mcp.json": json])).scan()
        let byName = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.name, $0) })
        XCTAssertEqual(byName["a"]?.draft?.transport,
                       .stdio(command: "srv", arguments: [], directory: ("~/proj" as NSString).expandingTildeInPath))
        XCTAssertNil(byName["b"]?.draft, "A relative folder without a project can't be run the same way")
        XCTAssertNil(byName["c"]?.draft)
        XCTAssertEqual(byName["c"]?.note, "Uses envFile, which Whytap can’t carry over yet.")
    }

    func testMiniTOMLMultilineArraysAndUnreadableTables() {
        let document = MiniTOML.document(#"""
        [t]
        a = [
          "x", # one
          'y',
        ]
        b = """
        long
        """
        [[arr]]
        k = 1
        """#)
        XCTAssertEqual(document.tables[["t"]]?["a"], MCPValue.array([.string("x"), .string("y")]))
        XCTAssertTrue(document.unreadable.contains(["t"]))
        XCTAssertTrue(document.unreadable.contains(["arr"]))
    }

    func testSecretLookingArguments() {
        XCTAssertEqual(SourceCredentialPolicy.secretArgumentIndices(["ghp_abcdef"]), [0])
        XCTAssertEqual(SourceCredentialPolicy.secretArgumentIndices(["--api-key=xyz"]), [0])
        XCTAssertEqual(SourceCredentialPolicy.secretArgumentIndices(["-e", "GITHUB_TOKEN=xyz"]), [1])
        XCTAssertEqual(SourceCredentialPolicy.secretArgumentIndices(["--header", "Authorization: Bearer x"]), [1])
        XCTAssertEqual(SourceCredentialPolicy.secretArgumentIndices(["--token", "abc"]), [1])
        XCTAssertEqual(SourceCredentialPolicy.secretArgumentIndices(["-y", "--root", "/Users/me/Documents"]), [])
        XCTAssertEqual(SourceCredentialPolicy.secretArgumentIndices(["-e", "GITHUB_PERSONAL_ACCESS_TOKEN"]), [],
                       "Naming a variable passes no value")
    }
}

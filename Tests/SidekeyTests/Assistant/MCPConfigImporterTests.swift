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
        XCTAssertEqual(github.transport, .stdio(command: "npx", arguments: [.plain("-y"), .plain("@modelcontextprotocol/server-github")]))
        XCTAssertEqual(github.environment, [SourceValue(name: "GITHUB_PERSONAL_ACCESS_TOKEN", secret: true, value: nil)])
        XCTAssertEqual(github.secrets["GITHUB_PERSONAL_ACCESS_TOKEN"], "ghp_realtoken123")
        XCTAssertEqual(github.importedFrom, "Claude Code")
        XCTAssertFalse(byName["github"]!.summary.contains("ghp_"), "The import list never shows a secret")
        XCTAssertNotNil(byName["linear"]?.draft)
        XCTAssertTrue(byName["linear"]?.note?.contains("browser") == true)
        XCTAssertNil(byName["legacy"]?.draft)
        XCTAssertTrue(byName["legacy"]?.note?.contains("SSE") == true)
        XCTAssertNil(byName["whytap"]?.draft)
        let argsecret = try XCTUnwrap(byName["argsecret"]?.draft)
        XCTAssertEqual(argsecret.transport, .stdio(command: "/usr/local/bin/srv", arguments: [.plain("--token"), .secret("arg.1"), .plain("--verbose")]))
        XCTAssertEqual(argsecret.secrets["arg.1"], "abc123")
        XCTAssertTrue(byName["argsecret"]?.note?.contains("process listings") == true)
        XCTAssertEqual(byName["placeholder"]?.draft?.missing, ["header.Authorization"])
        let project = try XCTUnwrap(byName["db (app)"])
        XCTAssertEqual(project.scope, "/Users/me/code/app")
        XCTAssertEqual(project.draft?.secrets["DB_URL"], "postgres://u:p@h/db")
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
        XCTAssertEqual(quoted.transport, .stdio(command: "uvx", arguments: [.plain("mcp-atlassian")]))
        XCTAssertEqual(quoted.secrets["JIRA_API_TOKEN"], "atl")
    }

    func testVSCodeServersWithInputPlaceholdersNeedAValue() throws {
        let json = #"{"inputs": [{"id": "tok", "type": "promptString", "password": true}], "servers": {"gh": {"type": "http", "url": "https://api.githubcopilot.com/mcp/", "headers": {"Authorization": "Bearer ${input:tok}"}}, "local": {"command": "node", "args": ["server.js"]}}}"#
        let scan = MCPConfigImporter(home: try home(["Library/Application Support/Code/User/mcp.json": json])).scan()
        XCTAssertEqual(scan.candidates.map(\.name), ["gh", "local"])
        XCTAssertEqual(scan.candidates[0].draft?.missing, ["header.Authorization"])
        XCTAssertEqual(scan.candidates[1].draft?.transport, .stdio(command: "node", arguments: [.plain("server.js")]))
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

    func testSecretLookingArguments() {
        XCTAssertTrue(MCPConfigImporter.isSecretArgument("ghp_abcdef", previous: nil))
        XCTAssertTrue(MCPConfigImporter.isSecretArgument("--api-key=xyz", previous: nil))
        XCTAssertTrue(MCPConfigImporter.isSecretArgument("GITHUB_TOKEN=xyz", previous: "-e"))
        XCTAssertTrue(MCPConfigImporter.isSecretArgument("Authorization: Bearer x", previous: "--header"))
        XCTAssertFalse(MCPConfigImporter.isSecretArgument("-y", previous: nil))
        XCTAssertFalse(MCPConfigImporter.isSecretArgument("/Users/me/Documents", previous: "--root"))
        XCTAssertFalse(MCPConfigImporter.isSecretArgument("GITHUB_PERSONAL_ACCESS_TOKEN", previous: "-e"))
    }
}

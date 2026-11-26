import XCTest
@testable import Sidekey

/// The Add source form's own rules: custom server parsing and service tiles.
final class AddSourceFormTests: XCTestCase {
    func testCustomCommandKeepsQuotedArgumentsAndPutsEveryValueInSecrets() throws {
        let draft = try AddSourceSheet.customDraft(name: " Notes ", remote: false,
                                                   command: #"npx -y "@scope/server name" --root '/Users/me/My Notes'"#,
                                                   url: "", values: "API_TOKEN=abc=def\n\nOTHER=1").get()
        XCTAssertEqual(draft.name, "Notes")
        XCTAssertEqual(draft.transport, .stdio(command: "npx", arguments: [.plain("-y"), .plain("@scope/server name"),
                                                                           .plain("--root"), .plain("/Users/me/My Notes")]))
        XCTAssertEqual(draft.environment.map(\.name), ["API_TOKEN", "OTHER"])
        XCTAssertTrue(draft.environment.allSatisfy(\.secret))
        XCTAssertEqual(draft.secrets, ["API_TOKEN": "abc=def", "OTHER": "1"])
    }

    func testCustomRemoteNeedsHTTPSAndValidHeaders() throws {
        XCTAssertThrowsError(try AddSourceSheet.customDraft(name: "", remote: true, command: "", url: "http://example.com/mcp", values: "").get())
        XCTAssertThrowsError(try AddSourceSheet.customDraft(name: "", remote: true, command: "", url: "https://x.dev/mcp", values: "no colon").get())
        let draft = try AddSourceSheet.customDraft(name: "", remote: true, command: "", url: "https://x.dev/mcp",
                                                   values: "Authorization: Bearer t:1").get()
        XCTAssertEqual(draft.secrets["header.Authorization"], "Bearer t:1")
        XCTAssertThrowsError(try AddSourceSheet.customDraft(name: "", remote: false, command: "  ", url: "", values: "").get())
    }

    func testGitHubTileIsReadOnlyAndJiraNeedsSiteAndEmail() {
        let github = SourcePreset.github.draft(token: " ghp_x \n", fields: [:])
        XCTAssertEqual(github.secrets["header.Authorization"], "Bearer ghp_x")
        XCTAssertTrue(github.headers.contains(SourceValue(name: "X-MCP-Readonly", secret: false, value: "true")))
        XCTAssertTrue(github.missing.isEmpty)
        XCTAssertEqual(SourcePreset.github.tokenURL.host, "github.com")
        XCTAssertTrue(SourcePreset.github.tokenURL.absoluteString.contains("contents=read"))
        XCTAssertEqual(SourcePreset.jira.validate(token: "t", fields: ["site": "", "email": "a@b.c"]), "Enter your Jira site address.")
        XCTAssertNil(SourcePreset.jira.validate(token: "t", fields: ["site": "team.atlassian.net", "email": "a@b.c"]))
        let jira = SourcePreset.jira.draft(token: "t", fields: ["site": "team.atlassian.net", "email": "a@b.c"])
        XCTAssertTrue(jira.environment.contains(SourceValue(name: "JIRA_URL", secret: false, value: "https://team.atlassian.net")))
        XCTAssertTrue(jira.environment.contains(SourceValue(name: "READ_ONLY_MODE", secret: false, value: "true")))
        XCTAssertEqual(jira.secrets, ["JIRA_API_TOKEN": "t"])
    }
}

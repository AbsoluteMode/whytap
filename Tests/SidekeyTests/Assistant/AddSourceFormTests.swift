import XCTest
@testable import Sidekey

/// The Add source form's own rules: custom server parsing and service tiles.
final class AddSourceFormTests: XCTestCase {
    func testCustomCommandKeepsQuotedArgumentsAndPutsEveryValueInSecrets() throws {
        let draft = try AddSourceSheet.customDraft(name: " Notes ", remote: false,
                                                   command: #"npx -y "@scope/server name" --root '/Users/me/My Notes'"#,
                                                   url: "", values: "API_TOKEN=abc=def\n\nOTHER=1").get()
        XCTAssertEqual(draft.name, "Notes")
        XCTAssertEqual(draft.transport, .stdio(command: "npx", arguments: ["-y", "@scope/server name", "--root", "/Users/me/My Notes"],
                                               directory: nil))
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
        XCTAssertNotNil(SourcePreset.jira.validate(token: "t", fields: ["site": "", "email": "a@b.c"]))
        XCTAssertNil(SourcePreset.jira.validate(token: "t", fields: ["site": "team.atlassian.net", "email": "a@b.c"]))
        let jira = SourcePreset.jira.draft(token: "t", fields: ["site": "team.atlassian.net", "email": "a@b.c"])
        XCTAssertTrue(jira.environment.contains(SourceValue(name: "JIRA_URL", secret: false, value: "https://team.atlassian.net")))
        XCTAssertTrue(jira.environment.contains(SourceValue(name: "READ_ONLY_MODE", secret: false, value: "true")))
        XCTAssertEqual(jira.secrets, ["JIRA_API_TOKEN": "t"])
    }

    // MARK: - Builder review regressions (point 1)

    func testCustomCommandWithASecretArgumentIsRefused() {
        for command in ["srv --token abc", "srv --api-key=abc", "srv ghp_abcdef", "srv -H 'Authorization: Bearer x'",
                        "srv --token synthetic_value_for_secret_redaction_check"] {
            guard case .failure(let problem) = AddSourceSheet.customDraft(name: "", remote: false, command: command, url: "", values: "") else {
                return XCTFail(command)
            }
            XCTAssertEqual(problem.message, SourceCredentialPolicy.argumentReason, command)
        }
    }

    func testCustomRemoteRefusesCredentialsInTheAddressAndSecretsOverPlainHTTP() {
        func problem(_ url: String, _ values: String = "") -> String? {
            if case .failure(let problem) = AddSourceSheet.customDraft(name: "", remote: true, command: "", url: url, values: values) {
                return problem.message
            }
            return nil
        }
        XCTAssertEqual(problem("https://x.dev/mcp?api_key=abc"), SourceCredentialPolicy.addressReason)
        XCTAssertEqual(problem("https://u:p@x.dev/mcp"), SourceCredentialPolicy.addressReason)
        XCTAssertEqual(problem("http://127.0.0.1:9/mcp", "Authorization: Bearer t"), SourceCredentialPolicy.plainHTTPReason)
        XCTAssertNil(problem("http://127.0.0.1:9/mcp"))
        XCTAssertNotNil(problem("https://x.dev/mcp", "Bad Header: v"), "Header names are tokens")
        XCTAssertNotNil(problem("https://x.dev/mcp", "X-A: " + String(repeating: "a", count: 3000)))
    }

    func testJiraSiteAndEmailValidation() {
        for bad in ["http://team.atlassian.net", "https://team.atlassian.net/wiki", "https://u:p@team.atlassian.net",
                    "https://team.atlassian.net?x=1", "localhost", "team atlassian.net", "https://team.atlassian.net#x"] {
            XCTAssertNil(SourcePreset.jiraSite(bad), bad)
            XCTAssertNotNil(SourcePreset.jira.validate(token: "t", fields: ["site": bad, "email": "a@b.c"]), bad)
        }
        XCTAssertEqual(SourcePreset.jiraSite(" https://Team.atlassian.net/ "), "https://team.atlassian.net")
        for bad in ["", "a", "a@b", "a b@c.d", "a@b.c\nx"] {
            XCTAssertNotNil(SourcePreset.jira.validate(token: "t", fields: ["site": "team.atlassian.net", "email": bad]), bad)
        }
        XCTAssertNotNil(SourcePreset.jira.validate(token: "with space", fields: ["site": "team.atlassian.net", "email": "a@b.c"]))
        XCTAssertNotNil(SourcePreset.github.validate(token: "line\nbreak", fields: [:]))
    }
}

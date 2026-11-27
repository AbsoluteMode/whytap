import Foundation

/// Service tiles in Add source: the easiest route that exists today without
/// Whytap servers (plan §1.1). Browser sign-in (OAuth) is a later iteration.
enum SourcePreset: String, CaseIterable, Identifiable, Sendable {
    case github, jira

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: return "GitHub"
        case .jira: return "Jira"
        }
    }

    var subtitle: String {
        switch self {
        case .github: return "Issues, pull requests and code, read-only. Uses GitHub’s own MCP server."
        case .jira: return "Issues and projects, read-only. Runs the open-source mcp-atlassian server (needs uv)."
        }
    }

    /// Opens the service's token page with read-only access prefilled.
    var tokenURL: URL {
        switch self {
        case .github:
            // Fine-grained token, read-only permissions, 90 days. Checked 2026-11-26:
            // https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
            return URL(string: "https://github.com/settings/personal-access-tokens/new?name=Whytap&description=Read-only%20access%20for%20the%20Whytap%20Agent&expires_in=90&contents=read&issues=read&pull_requests=read&metadata=read")!
        case .jira:
            return URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
        }
    }

    /// Plain fields the tile asks for before the token.
    var fields: [(name: String, placeholder: String)] {
        switch self {
        case .github: return []
        case .jira: return [("site", "https://your-team.atlassian.net"), ("email", "you@company.com")]
        }
    }

    static let githubURL = "https://api.githubcopilot.com/mcp/"

    /// The source for these values. `fields` keys match `fields`.
    func draft(token: String, fields: [String: String]) -> SourceDraft {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .github:
            // X-MCP-Readonly makes GitHub's server offer read tools only, so even
            // a broad token cannot be used to write through Whytap.
            return SourceDraft(name: "GitHub", kind: .github, transport: .http(url: Self.githubURL),
                               headers: [SourceValue(name: "Authorization", secret: true, value: nil),
                                         SourceValue(name: "X-MCP-Readonly", secret: false, value: "true")],
                               secrets: ["header.Authorization": "Bearer " + token],
                               proof: SourceProofCall(tool: "get_me", arguments: .object([:])))
        case .jira:
            return SourceDraft(name: "Jira", kind: .jira, transport: .stdio(command: "uvx", arguments: ["mcp-atlassian"], directory: nil),
                               environment: [SourceValue(name: "JIRA_URL", secret: false, value: Self.jiraSite(fields["site"] ?? "") ?? ""),
                                             SourceValue(name: "JIRA_USERNAME", secret: false,
                                                         value: (fields["email"] ?? "").trimmingCharacters(in: .whitespaces)),
                                             SourceValue(name: "JIRA_API_TOKEN", secret: true, value: nil),
                                             SourceValue(name: "READ_ONLY_MODE", secret: false, value: "true")],
                               secrets: ["JIRA_API_TOKEN": token],
                               proof: SourceProofCall(tool: "jira_search", arguments: .object([
                                "jql": .string("updated >= -7d ORDER BY updated DESC"), "limit": .number(5)])))
        }
    }

    /// A Jira site as an https address of a host and optional port: no credentials,
    /// path, query or fragment, so the token goes only to that site.
    static func jiraSite(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return nil }
        return "https://" + host + (url.port.map { ":\($0)" } ?? "")
    }

    static func isEmail(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces)
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return value.count <= 254 && parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !value.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" })
    }

    func validate(token: String, fields: [String: String]) -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Paste the token." }
        guard trimmed.count <= 2048, !trimmed.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else {
            return "That doesn’t look like a token: paste it without spaces or line breaks."
        }
        switch self {
        case .github: return nil
        case .jira:
            guard Self.jiraSite(fields["site"] ?? "") != nil else {
                return "Enter your Jira site as https://your-team.atlassian.net (no path or extra parts)."
            }
            return Self.isEmail(fields["email"] ?? "") ? nil : "Enter the e-mail of your Atlassian account."
        }
    }
}

/// The GitHub CLI's existing sign-in, offered as one click when present.
enum GitHubCLISignIn {
    /// `gh auth token` through the login shell; nil when gh is missing or signed out.
    static func token() async -> String? {
        await Task.detached(priority: .utility) {
            guard let gh = LoginShellWhich.resolve("gh"), gh.hasPrefix("/") else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gh)
            process.arguments = ["auth", "token"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let token = String(decoding: data.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty || token.contains(" ") ? nil : token
        }.value
    }
}

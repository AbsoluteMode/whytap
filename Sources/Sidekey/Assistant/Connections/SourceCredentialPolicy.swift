import Foundation

/// One credential rule for every way a source is added (import, tile,
/// custom form), for what Settings shows and for what is launched: a secret
/// lives only in Keychain and reaches a server only through its process
/// environment or an HTTPS header. A command line or address that carries a
/// secret is not accepted; the reason says what to change.
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md (Credentials)
enum SourceCredentialPolicy {
    static let argumentReason = "Passes a secret on its command line. Whytap gives secrets to a server only through environment variables; set the server up to read it from one."
    static let addressReason = "Its address contains a credential. Whytap keeps credentials in Keychain and sends them only in headers."
    static let plainHTTPReason = "Sends credentials over plain http. Use an https:// address."
    static let insecureReason = MCPError.insecureURL.message

    private static let secretFlag = try! NSRegularExpression(
        pattern: #"^--?[a-z0-9_-]*(api[-_]?key|token|secret|password|passwd|pat|bearer|header|authorization|auth|credential|cookie|session)[a-z0-9_-]*$"#,
        options: [.caseInsensitive])
    private static let inlineSecret = try! NSRegularExpression(
        pattern: #"^--?[a-z0-9_-]*(key|token|secret|password|passwd|authorization|auth|credential|cookie)[a-z0-9_-]*=.+|^[A-Z0-9_]*(TOKEN|KEY|SECRET|PASSWORD|PASSWD|PAT|AUTH|CREDENTIAL|COOKIE)[A-Z0-9_]*=.+|^(authorization|proxy-authorization|x-api-key|api-key|cookie)\s*:"#,
        options: [.caseInsensitive])
    private static let prefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-",
                                   "xoxr-", "xapp-", "sk-", "sk_live_", "rk_live_", "pk_live_", "AKIA", "ASIA", "ya29.", "ATATT",
                                   "lin_api_", "ntn_", "secret_", "npm_", "pypi-", "hf_", "eyJ"]
    private static let secretQueryKeys = try! NSRegularExpression(
        pattern: #"(key|token|secret|password|passwd|auth|signature|sig|credential|session|code)"#, options: [.caseInsensitive])

    /// A value that is a credential by its shape.
    static func isSecretLooking(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return prefixes.contains { trimmed.hasPrefix($0) }
            || trimmed.lowercased().hasPrefix("bearer ") || trimmed.lowercased().hasPrefix("basic ")
            || matches(inlineSecret, trimmed)
    }

    /// Positions of arguments that are, or follow a flag that announces, a secret.
    /// The same test decides what is masked in a preview and what is refused.
    static func secretArgumentIndices(_ arguments: [String]) -> Set<Int> {
        var found = Set<Int>()
        for (index, argument) in arguments.enumerated() {
            if isSecretLooking(argument) { found.insert(index); continue }
            if index > 0, !argument.hasPrefix("-"), matches(secretFlag, arguments[index - 1]),
               !arguments[index - 1].contains("=") { found.insert(index) }
        }
        return found
    }

    static func argumentsProblem(_ arguments: [String]) -> String? {
        secretArgumentIndices(arguments).isEmpty ? nil : argumentReason
    }

    /// Whether this address may be used, given whether secret headers go with it.
    static func addressProblem(_ address: String, sendsSecrets: Bool) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), url.host != nil else { return insecureReason }
        if url.user != nil || url.password != nil { return addressReason }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in components?.queryItems ?? [] {
            if matches(secretQueryKeys, item.name) || isSecretLooking(item.value ?? "") { return addressReason }
        }
        if url.pathComponents.contains(where: { isSecretLooking($0) }) || url.fragment.map(isSecretLooking) == true {
            return addressReason
        }
        guard MCPHTTPTransport.isAllowed(url) else { return insecureReason }
        if scheme == "http", sendsSecrets { return plainHTTPReason }
        return nil
    }

    /// What Settings and the import list show: secrets masked by the same test.
    static func display(_ transport: SourceTransport) -> String {
        switch transport {
        case .stdio(let command, let arguments, let directory):
            let secret = secretArgumentIndices(arguments)
            let shown = arguments.enumerated().map { secret.contains($0.offset) ? "••••" : $0.element }
            return ([command] + shown).joined(separator: " ")
                + (directory.map { " (in " + ($0 as NSString).abbreviatingWithTildeInPath + ")" } ?? "")
        case .http(let address): return displayAddress(address)
        case .folder(let path): return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    static func displayAddress(_ address: String) -> String {
        guard addressProblem(address, sendsSecrets: false) == addressReason,
              let url = URL(string: address), let host = url.host else { return address }
        return (url.scheme ?? "https") + "://" + host + "/…"
    }

    /// A plain value a source sends in an environment variable or header:
    /// one line, bounded.
    static func isPlainValueAcceptable(_ value: String) -> Bool {
        value.count <= 2048 && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

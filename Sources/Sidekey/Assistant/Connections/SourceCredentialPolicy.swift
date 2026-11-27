import Foundation

/// One credential rule for every way a source is added (import, tile,
/// custom form), for what Settings shows and for what is launched: a secret
/// lives only in Keychain and reaches a server only through its process
/// environment or an HTTPS header. A command line or address that carries a
/// secret is not accepted; the reason says what to change.
///
/// Every surface goes through this type: `problem(_:sendsSecrets:)` decides
/// (import, custom form, tiles, `add`, launch), `display(_:)` is the only
/// preview of a command or address, and one per-argument test
/// (`isCredentialArgument`) drives both.
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md (Credentials)
enum SourceCredentialPolicy {
    static let argumentReason = "Passes a secret on its command line. Whytap gives secrets to a server only through environment variables; set the server up to read it from one."
    static let addressReason = "Its address contains a credential. Whytap keeps credentials in Keychain and sends them only in headers."
    static let plainHTTPReason = "Sends credentials over plain http. Use an https:// address."
    static let insecureReason = MCPError.insecureURL.message
    static let masked = "••••"

    /// Words that make a flag, variable or query key name a credential name.
    static let credentialWords: Set<String> = ["key", "apikey", "token", "secret", "password", "passwd", "pass", "pwd", "pat",
                                               "bearer", "header", "authorization", "auth", "credential", "credentials",
                                               "cookie", "session", "signature", "sig", "jwt", "otp"]
    private static let prefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "glpat-", "xoxb-", "xoxp-", "xoxa-",
                                   "xoxr-", "xapp-", "sk-", "sk_live_", "rk_live_", "pk_live_", "AKIA", "ASIA", "ya29.", "ATATT",
                                   "lin_api_", "ntn_", "secret_", "npm_", "pypi-", "hf_", "eyJ"]
    private static let headerNames: Set<String> = ["authorization", "proxy-authorization", "x-api-key", "api-key", "cookie"]

    // MARK: - Names and values

    /// `--api-key`, `GITHUB_TOKEN`, `access_token`, `X-Auth`: split into words
    /// on `-`, `_`, `.` and case changes, then compared whole (so `--path`
    /// and `MONKEY` are not credentials).
    static func isCredentialName(_ name: String) -> Bool {
        var words: [String] = [], current = ""
        var previousLower = false
        for character in name.trimmingCharacters(in: CharacterSet(charactersIn: "-")) {
            if character == "-" || character == "_" || character == "." || character == " " {
                if !current.isEmpty { words.append(current.lowercased()) }
                current = ""; previousLower = false; continue
            }
            if character.isUppercase, previousLower, !current.isEmpty { words.append(current.lowercased()); current = "" }
            current.append(character)
            previousLower = character.isLowercase
        }
        if !current.isEmpty { words.append(current.lowercased()) }
        if words.contains(where: credentialWords.contains) { return true }
        // "apikey", "accesstoken" written as one word.
        let joined = words.joined()
        return ["apikey", "accesstoken", "authtoken", "secretkey", "privatekey", "clientsecret", "password"].contains { joined.contains($0) }
    }

    /// A value that is a credential by its shape: a known token prefix, an
    /// authorization scheme, `NAME=value` or `--name=value` with a credential
    /// name, a credential header line, or an address carrying a credential.
    static func isSecretLooking(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if prefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("bearer ") || lower.hasPrefix("basic ") || lower.hasPrefix("token ") { return true }
        if let colon = trimmed.firstIndex(of: ":"), headerNames.contains(trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()) {
            return true
        }
        if let equals = trimmed.firstIndex(of: "="), equals != trimmed.startIndex {
            let name = String(trimmed[..<equals]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let rest = trimmed[trimmed.index(after: equals)...]
            if !rest.isEmpty, !name.isEmpty, !name.contains(" "), isCredentialName(name) { return true }
            if !rest.isEmpty, isSecretLooking(String(rest)) { return true }
        }
        if trimmed.contains("://"), addressCarriesCredential(trimmed) { return true }
        return false
    }

    /// A standalone flag that announces a credential as the next argument.
    static func isCredentialFlag(_ argument: String) -> Bool {
        guard argument.hasPrefix("-"), !argument.contains("="), argument.count > 1 else { return false }
        if argument == "-H" { return true }
        return isCredentialName(argument)
    }

    /// The one per-argument test: masked in every preview and refused at
    /// every setup and launch.
    static func isCredentialArgument(_ arguments: [String], at index: Int) -> Bool {
        let argument = arguments[index]
        if isSecretLooking(argument) { return true }
        return index > 0 && !argument.hasPrefix("-") && isCredentialFlag(arguments[index - 1])
    }

    static func secretArgumentIndices(_ arguments: [String]) -> Set<Int> {
        Set(arguments.indices.filter { isCredentialArgument(arguments, at: $0) })
    }

    // MARK: - Addresses

    /// User info, a credential-named query key, a credential-looking query
    /// value, fragment or path part.
    static func addressCarriesCredential(_ address: String) -> Bool {
        guard let components = URLComponents(string: address) else { return false }
        if components.user != nil || components.password != nil { return true }
        for item in components.queryItems ?? [] {
            if isCredentialName(item.name) || isSecretLooking(item.value ?? "") || isLongOpaque(item.value ?? "") { return true }
        }
        if let fragment = components.fragment, isSecretLooking(fragment) || fragment.contains("=") { return true }
        return components.path.split(separator: "/").contains { isSecretLooking(String($0)) }
    }

    /// 32+ characters of letters, digits and token punctuation, as in an API key.
    private static func isLongOpaque(_ value: String) -> Bool {
        value.count >= 32 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.~+/=".contains($0)) }
    }

    // MARK: - The rule

    /// Why this transport may not be added or launched, or nil.
    static func problem(_ transport: SourceTransport, sendsSecrets: Bool) -> String? {
        switch transport {
        case .stdio(let command, let arguments, _):
            return isSecretLooking(command) || !secretArgumentIndices(arguments).isEmpty ? argumentReason : nil
        case .http(let address): return addressProblem(address, sendsSecrets: sendsSecrets)
        case .folder: return nil
        }
    }

    /// Whether this address may be used, given whether secret headers go with it.
    static func addressProblem(_ address: String, sendsSecrets: Bool) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), url.host != nil else { return insecureReason }
        if addressCarriesCredential(address) { return addressReason }
        guard MCPHTTPTransport.isAllowed(url) else { return insecureReason }
        if scheme == "http", sendsSecrets { return plainHTTPReason }
        return nil
    }

    // MARK: - The only preview

    /// What Settings and the import list show for a command or address:
    /// credentials masked by the same test that refuses them.
    static func display(_ transport: SourceTransport) -> String {
        switch redacted(transport) {
        case .stdio(let command, let arguments, let directory):
            return ([command] + arguments).joined(separator: " ")
                + (directory.map { " (in " + ($0 as NSString).abbreviatingWithTildeInPath + ")" } ?? "")
        case .http(let address): return address
        case .folder(let path): return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// The transport with every credential replaced by the mask: what a
    /// refused import keeps for its preview, so no copy of the value remains.
    static func redacted(_ transport: SourceTransport) -> SourceTransport {
        switch transport {
        case .stdio(let command, let arguments, let directory):
            let secret = secretArgumentIndices(arguments)
            return .stdio(command: isSecretLooking(command) ? masked : command,
                          arguments: arguments.enumerated().map { secret.contains($0.offset) ? masked : $0.element },
                          directory: directory)
        case .http(let address): return .http(url: displayAddress(address))
        case .folder: return transport
        }
    }

    static func displayAddress(_ address: String) -> String {
        guard addressCarriesCredential(address) else { return address }
        guard let url = URL(string: address), let host = url.host else { return masked }
        return (url.scheme ?? "https") + "://" + host + "/…"
    }

    /// A plain value a source sends in an environment variable or header:
    /// one line, bounded.
    static func isPlainValueAcceptable(_ value: String) -> Bool {
        value.count <= 2048 && !value.contains(where: { $0.isNewline || $0 == "\0" })
    }
}

/// Known secret values of one source, masked out of everything a server
/// wrote before it reaches Settings, the manifest or a model: tool results,
/// error results, proof summaries, error and exit text, and tool metadata.
/// Values shorter than `minimumLength` are not masked (they would garble
/// ordinary text); the raw, JSON-escaped and percent-encoded forms are.
struct SourceSecretMask: Sendable {
    static let minimumLength = 6
    private let needles: [String]

    init(_ values: [String]) {
        var found = Set<String>()
        for value in values {
            var forms = [value]
            // "Bearer abc…": the token alone is a secret too.
            if let space = value.firstIndex(of: " ") { forms.append(String(value[value.index(after: space)...])) }
            for form in forms where form.count >= Self.minimumLength {
                found.insert(form)
                if let data = try? JSONEncoder().encode(form), let json = String(data: data, encoding: .utf8) {
                    found.insert(String(json.dropFirst().dropLast()))
                }
                if let encoded = form.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { found.insert(encoded) }
            }
        }
        // Longest first, so a value containing another is masked whole.
        needles = found.sorted { $0.count > $1.count }
    }

    var isEmpty: Bool { needles.isEmpty }

    func callAsFunction(_ text: String) -> String {
        needles.reduce(text) { $0.replacingOccurrences(of: $1, with: SourceCredentialPolicy.masked) }
    }

    func contains(_ text: String) -> Bool { needles.contains { text.contains($0) } }

    /// Every string and key of a decoded message, masked.
    func value(_ value: MCPValue) -> MCPValue {
        guard !isEmpty else { return value }
        switch value {
        case .string(let text): return .string(self(text))
        case .array(let items): return .array(items.map(self.value))
        case .object(let object):
            var masked: [String: MCPValue] = [:]
            for (key, item) in object { masked[self(key)] = self.value(item) }
            return .object(masked)
        default: return value
        }
    }

    func result(_ result: MCPToolResult) -> MCPToolResult {
        MCPToolResult(text: self(result.text), isError: result.isError, shortened: result.shortened)
    }

    func error(_ error: MCPError) -> MCPError {
        switch error {
        case .exited(let status, let detail): return .exited(status: status, detail: detail.map { self($0) })
        case .server(let code, let message): return .server(code: code, message: self(message))
        case .unsupportedProtocol(let version): return .unsupportedProtocol(self(version))
        case .commandNotFound(let command): return .commandNotFound(self(command))
        default: return error
        }
    }

    /// A tool as the server described it, with known values masked from its
    /// title, description and schema. A tool whose name carries one is dropped.
    func tool(_ tool: MCPToolInfo) -> MCPToolInfo? {
        guard !isEmpty else { return tool }
        if contains(tool.name) || tool.name.contains(SourceCredentialPolicy.masked) { return nil }
        var copy = tool
        copy.title = tool.title.map { self($0) }
        copy.description = self(tool.description)
        let schema = tool.inputSchema.canonicalJSON
        if contains(schema) {
            copy.inputSchema = (try? MCPValue.decode(Data(self(schema).utf8))) ?? .object(["type": .string("object")])
        }
        return copy
    }
}

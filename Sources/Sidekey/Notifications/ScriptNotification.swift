import Foundation

enum NotifyPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BuildConfig.bundleID, isDirectory: true)
            .appendingPathComponent("notifications", isDirectory: true)
    }
    static var sources: URL { root.appendingPathComponent("sources", isDirectory: true) }
    static var logos: URL { root.appendingPathComponent("logos", isDirectory: true) }
}

/// Local executable configuration, written by the user's chosen coding agent.
/// Credentials belong in Keychain and are read by the script, never this file.
struct NotifyScript: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var command: [String]
    var enabled: Bool = true
    var intervalSeconds: Double? = nil
    var tint: String? = nil
    var logo: String? = nil
    var duration: Double? = nil

    init(id: String, name: String, command: [String], enabled: Bool = true,
         intervalSeconds: Double? = nil, tint: String? = nil, logo: String? = nil,
         duration: Double? = nil) {
        self.id = id; self.name = name; self.command = command; self.enabled = enabled
        self.intervalSeconds = intervalSeconds; self.tint = tint; self.logo = logo; self.duration = duration
    }

    enum CodingKeys: String, CodingKey { case id, name, command, enabled, intervalSeconds, tint, logo, duration }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode([String].self, forKey: .command)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intervalSeconds = try c.decodeIfPresent(Double.self, forKey: .intervalSeconds)
        tint = try c.decodeIfPresent(String.self, forKey: .tint)
        logo = try c.decodeIfPresent(String.self, forKey: .logo)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
    }

    func validate() throws {
        guard id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$", options: .regularExpression) != nil,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              let executable = command.first, executable.hasPrefix("/"),
              command.count <= 64, command.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 8192 }),
              intervalSeconds.map({ $0.isFinite && (5...86400).contains($0) }) ?? true
        else { throw NotifyError.invalidConfiguration }
    }
}

struct NotifyPayload: Decodable {
    var title: String?
    var body: String?
    var id: String?
    var tint: String?
    var logo: String?
    var duration: Double?
    var link: String?
}

struct LocalNotificationEvent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let source: String
    let sourceName: String
    let title: String
    let body: String
    let link: URL?
    let timestamp: Date
    var customDuration: TimeInterval?
    var customTint: String?
    var customLogo: String?
    var read: Bool = false
    /// Internal navigation, never accepted from script output or an OS URL.
    /// Optional so older notification histories still decode.
    var meetingID: UUID? = nil
    /// Internal action of the app's own input-language offer: a click sets
    /// this language. Never accepted from script output or an OS URL.
    // WHY: .project-docs/decisions/2026-11-20-input-language-suggestion.md
    var inputLanguageCode: String? = nil

    var canActivate: Bool { meetingID != nil || inputLanguageCode != nil || link != nil }

    var resolvedDuration: TimeInterval { customDuration ?? 8 }

    static func make(_ payload: NotifyPayload, script: NotifyScript, now: Date = Date()) throws -> Self {
        // Old icon-only scripts may omit text. Keep those sources working as
        // cards using their source name; legacy presentation fields are ignored.
        let title = (payload.title ?? script.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200, (payload.body?.count ?? 0) <= 8000,
              (payload.id?.utf8.count ?? 0) <= 256 else { throw NotifyError.invalidOutput }
        let tint = payload.tint ?? script.tint ?? "#299FD6"
        guard tint.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw NotifyError.invalidOutput }
        let duration = payload.duration ?? script.duration ?? 8
        guard duration.isFinite else { throw NotifyError.invalidOutput }
        let logo = payload.logo ?? script.logo ?? "bell.fill"
        guard logo.count <= 80, !logo.contains("/"), !logo.hasPrefix("."), !logo.contains("\0") else { throw NotifyError.invalidOutput }
        var link: URL?
        if let raw = payload.link {
            guard raw.count <= 2048, !raw.contains(where: { $0.isNewline }), let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  ["https", "http", "tg", "slack", "linear", "github", "mailto", "codex", "claude"].contains(scheme),
                  !["http", "https"].contains(scheme) || url.host != nil,
                  scheme != "codex" || Self.isCodexSessionLink(url),
                  scheme != "claude" || Self.isClaudeCodeSessionLink(url)
            else { throw NotifyError.invalidOutput }
            link = url
        }
        return Self(id: script.id + ":" + (payload.id ?? UUID().uuidString), source: script.id,
                    sourceName: script.name, title: title, body: payload.body ?? "", link: link,
                    timestamp: now, customDuration: min(60, max(2, duration)), customTint: tint, customLogo: logo)
    }

    private static func isCodexSessionLink(_ url: URL) -> Bool {
        // Only navigate to an existing session; don't allow plugin installs,
        // prefilled prompts or other Codex actions from notification output.
        let id = String(url.path.dropFirst())
        return url.host == "threads" && url.user == nil && url.password == nil && url.port == nil
            && url.query == nil && url.fragment == nil
            && id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$", options: .regularExpression) != nil
            && id != "new"
    }

    private static func isClaudeCodeSessionLink(_ url: URL) -> Bool {
        // Claude Desktop's existing-session OS entry point. Its native session
        // ID differs from the CLI/hook ID; integrations must resolve that mapping.
        guard url.host == "code", url.path == "/continue", url.user == nil,
              url.password == nil, url.port == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1, items[0].name == "session", let id = items[0].value
        else { return false }
        return id.range(of: "^local_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$",
                        options: .regularExpression) != nil
    }
}

enum NotifyError: Error { case invalidConfiguration, invalidOutput, historyUnavailable }

/// Bounded streaming decoder. It never retains arbitrary process output or logs it.
struct NotifyLineDecoder {
    static let maxLineBytes = 65536
    private var buffer = Data()
    private var discarding = false
    mutating func append(_ data: Data) -> [Result<NotifyPayload, Error>] {
        var result: [Result<NotifyPayload, Error>] = []
        for byte in data {
            if byte == 10 {
                if discarding { result.append(.failure(NotifyError.invalidOutput)) }
                else if !buffer.isEmpty { result.append(Result { try JSONDecoder().decode(NotifyPayload.self, from: buffer) }) }
                buffer.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if buffer.count < Self.maxLineBytes { buffer.append(byte) }
                else { buffer.removeAll(keepingCapacity: true); discarding = true }
            }
        }
        return result
    }
    mutating func finish() -> [Result<NotifyPayload, Error>] { append(Data([10])) }
}

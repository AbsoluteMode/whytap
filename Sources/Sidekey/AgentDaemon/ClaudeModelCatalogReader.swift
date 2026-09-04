import Foundation

/// The Claude model choices for the picker. Each option's `token` is the CLI
/// ALIAS (`opus`/`sonnet`/`haiku`) — which Claude Code always resolves to the
/// latest version of that family — and `label` carries the real version that
/// alias currently resolves to (e.g. "Opus 4.8"), read from the binary.
struct ClaudeModelCatalog: Equatable {
    var options: [ClaudeModelOption]
    /// Family alias to pre-select (derived from the user's current default).
    var defaultAlias: String?

    init(options: [ClaudeModelOption] = [], defaultAlias: String? = nil) {
        self.options = options
        self.defaultAlias = defaultAlias
    }
}

/// Derives the always-latest model list straight from the chosen `claude`
/// binary: the versioned tokens (`claude-opus-4-8`, ...) are embedded in it, so
/// we read the highest version per family and present it as an alias + label.
/// Re-derived whenever the binary changes, so it never goes stale. Read-only;
/// never makes a model call. We cannot fetch a live model registry — the client
/// never talks to Anthropic directly and the
/// subscription OAuth exposes no `/v1/models`; the local binary IS the registry.
struct ClaudeModelCatalogReader {
    /// Returns every `claude-<family>-<major>-<minor>` token embedded in the
    /// binary. Default greps the binary; injectable for tests.
    var scanTokens: (URL) -> [String] = ClaudeModelCatalogReader.defaultScan
    /// The user's current default model token (from `~/.claude.json`), used only
    /// to pre-select the matching family.
    var currentModel: () -> String? = { ClaudeConfigReader().read().currentModel }

    static let families = ["opus", "sonnet", "haiku"]

    func read(binary: URL?) -> ClaudeModelCatalog {
        guard let binary else { return ClaudeModelCatalog() }
        return Self.build(tokens: scanTokens(binary), current: currentModel())
    }

    static func build(tokens: [String], current: String?) -> ClaudeModelCatalog {
        // Highest (major, minor) per family.
        var best: [String: (major: Int, minor: Int)] = [:]
        for token in tokens {
            guard let p = parse(token) else { continue }
            if let cur = best[p.family] {
                if (p.major, p.minor) > (cur.major, cur.minor) { best[p.family] = (p.major, p.minor) }
            } else {
                best[p.family] = (p.major, p.minor)
            }
        }
        var options: [ClaudeModelOption] = []
        for family in families {
            if let v = best[family] {
                options.append(ClaudeModelOption(
                    token: family,                                       // the alias
                    label: "\(family.capitalized) \(v.major).\(v.minor)"))
            }
        }
        let defaultAlias = parse(current ?? "")?.family ?? options.first?.token
        return ClaudeModelCatalog(options: options, defaultAlias: defaultAlias)
    }

    /// Parse a versioned token. Ignores date-form variants like
    /// `claude-opus-4-20250514` (minor >= 100) so they never win "highest".
    static func parse(_ token: String) -> (family: String, major: Int, minor: Int)? {
        guard let re = try? NSRegularExpression(pattern: "claude-(opus|sonnet|haiku)-([0-9]+)-([0-9]+)"),
              let m = re.firstMatch(in: token, range: NSRange(token.startIndex..., in: token))
        else { return nil }
        let ns = token as NSString
        let family = ns.substring(with: m.range(at: 1))
        guard let major = Int(ns.substring(with: m.range(at: 2))),
              let minor = Int(ns.substring(with: m.range(at: 3))),
              minor < 100 else { return nil }
        return (family, major, minor)
    }

    static func defaultScan(_ binary: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        process.arguments = ["-aoE", "claude-(opus|sonnet|haiku)-[0-9]+-[0-9]+", binary.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return [] }
        // Drain before reaping (grep output can exceed the pipe buffer).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
    }
}

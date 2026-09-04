import Foundation

struct ClaudeBinaryLocator {
    /// A semantic version (major.minor.patch), comparable so we can pick newest.
    struct SemVer: Comparable, Equatable {
        let major: Int
        let minor: Int
        let patch: Int
        static func < (a: SemVer, b: SemVer) -> Bool {
            (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
    }

    /// Legacy fixed install locations, highest priority first. Used as a
    /// fallback when no Claude Desktop-managed install is present.
    static let knownPaths: [String] = [
        "\(NSHomeDirectory())/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(NSHomeDirectory())/.local/bin/claude",
    ]

    /// Claude Desktop keeps an auto-updated copy here, one versioned subdir per
    /// release: `.../claude-code/<version>/claude.app/Contents/MacOS/claude`.
    /// This is normally the newest claude on the machine — and the one that
    /// knows the latest models (e.g. opus 4.8), which is why we prefer it.
    static let desktopManagedDir =
        "\(NSHomeDirectory())/Library/Application Support/Claude/claude-code"

    var fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var listDirectory: (String) -> [String] = {
        (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
    }
    /// Report a binary's `--version` string (e.g. "2.1.160 (Claude Code)").
    var versionOf: (URL) -> String? = ClaudeBinaryLocator.defaultVersionOf
    /// Resolve via a login shell so we pick up nvm/asdf/custom PATH.
    var loginShellWhich: () -> String? = ClaudeBinaryLocator.defaultLoginShellWhich

    /// Pick the newest claude on the machine. The highest Claude Desktop-managed
    /// version (read straight from the path — no spawn) wins, unless a legacy
    /// install reports an even higher `--version`.
    func locate() -> URL? {
        let desktop = newestDesktopManaged()
        let legacy = legacyLocate()
        switch (desktop, legacy) {
        case let (desktop?, legacy?):
            if let lv = versionOf(legacy).flatMap(Self.parseSemVer), lv > desktop.version {
                return legacy
            }
            return desktop.url
        case let (desktop?, nil):
            return desktop.url
        case let (nil, legacy?):
            return legacy
        case (nil, nil):
            return nil
        }
    }

    /// Highest-version Claude Desktop-managed binary that exists, version parsed
    /// from the path segment (no process spawn).
    func newestDesktopManaged() -> (url: URL, version: SemVer)? {
        listDirectory(Self.desktopManagedDir)
            .compactMap { name -> (url: URL, version: SemVer)? in
                guard let version = Self.parseSemVer(name) else { return nil }
                let path = "\(Self.desktopManagedDir)/\(name)/claude.app/Contents/MacOS/claude"
                return fileExists(path) ? (URL(fileURLWithPath: path), version) : nil
            }
            .max { $0.version < $1.version }
    }

    /// The pre-existing fixed-path / login-shell resolution.
    func legacyLocate() -> URL? {
        for path in Self.knownPaths where fileExists(path) {
            return URL(fileURLWithPath: path)
        }
        if let resolved = loginShellWhich() {
            return URL(fileURLWithPath: resolved)
        }
        return nil
    }

    /// Parse a leading `N.N.N` from a string like "2.1.160" or
    /// "2.1.160 (Claude Code)". Returns nil when there is no such prefix.
    static func parseSemVer(_ s: String) -> SemVer? {
        let head = s.trimmingCharacters(in: .whitespaces)
        guard let re = try? NSRegularExpression(pattern: "^([0-9]+)\\.([0-9]+)\\.([0-9]+)"),
              let m = re.firstMatch(in: head, range: NSRange(head.startIndex..., in: head))
        else { return nil }
        let ns = head as NSString
        func group(_ i: Int) -> Int { Int(ns.substring(with: m.range(at: i))) ?? 0 }
        return SemVer(major: group(1), minor: group(2), patch: group(3))
    }

    static func defaultVersionOf(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    static func defaultLoginShellWhich() -> String? {
        LoginShellWhich.resolve("claude")
    }
}

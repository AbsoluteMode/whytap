import Foundation

/// One selectable Claude model: the CLI token passed to `--model` and a human
/// label carrying the version, e.g. token "claude-opus-4-7" / label "Opus 4.7".
struct ClaudeModelOption: Equatable {
    let token: String
    let label: String
}

/// The Claude fields the Settings picker mirrors from `~/.claude.json`.
struct ClaudeConfigSnapshot: Equatable {
    var currentModel: String?           // the "model" field token, pre-selected in the picker
    var models: [ClaudeModelOption]     // highest version per family (+ current if not the max)

    init(currentModel: String? = nil, models: [ClaudeModelOption] = []) {
        self.currentModel = currentModel
        self.models = models
    }
}

/// Best-effort reader for `~/.claude.json` (Claude Code's state file). Mirrors
/// the user's current default model and the available Claude model versions so
/// the Agents settings picker can show real names. Never throws; read-only.
struct ClaudeConfigReader {
    var path: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")

    func read() -> ClaudeConfigSnapshot {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return ClaudeConfigSnapshot()
        }
        return Self.parse(text)
    }

    static func parse(_ text: String) -> ClaudeConfigSnapshot {
        let current = Self.firstCaptured(
            in: text, pattern: "\"model\"\\s*:\\s*\"(claude-[a-z]+-[0-9]+-[0-9]+)\"")

        // Highest (major, minor) seen per family.
        var best: [String: (major: Int, minor: Int)] = [:]
        for groups in Self.allCaptured(in: text, pattern: "claude-(sonnet|opus|haiku)-([0-9]+)-([0-9]+)") {
            guard groups.count == 3, let major = Int(groups[1]), let minor = Int(groups[2]) else { continue }
            let family = groups[0]
            if let cur = best[family] {
                if (major, minor) > (cur.major, cur.minor) { best[family] = (major, minor) }
            } else {
                best[family] = (major, minor)
            }
        }

        var models: [ClaudeModelOption] = []
        for family in ["opus", "sonnet", "haiku"] {
            if let v = best[family] {
                models.append(Self.option(family: family, major: v.major, minor: v.minor))
            }
        }
        // Always include the user's current model even if it is not the family
        // max, so the picker shows it pre-selected without a phantom selection.
        if let current, !models.contains(where: { $0.token == current }),
           let parsed = Self.parseToken(current) {
            models.insert(Self.option(family: parsed.family, major: parsed.major, minor: parsed.minor), at: 0)
        }
        return ClaudeConfigSnapshot(currentModel: current, models: models)
    }

    private static func option(family: String, major: Int, minor: Int) -> ClaudeModelOption {
        ClaudeModelOption(token: "claude-\(family)-\(major)-\(minor)",
                          label: "\(family.capitalized) \(major).\(minor)")
    }

    private static func parseToken(_ token: String) -> (family: String, major: Int, minor: Int)? {
        guard let g = allCaptured(in: token, pattern: "claude-(sonnet|opus|haiku)-([0-9]+)-([0-9]+)").first,
              g.count == 3, let major = Int(g[1]), let minor = Int(g[2]) else { return nil }
        return (g[0], major, minor)
    }

    private static func firstCaptured(in text: String, pattern: String) -> String? {
        allCaptured(in: text, pattern: pattern).first?.first
    }

    /// For each regex match, returns the array of capture-group strings (groups 1..n).
    private static func allCaptured(in text: String, pattern: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { match in
            (1..<match.numberOfRanges).compactMap { i -> String? in
                let r = match.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }
}

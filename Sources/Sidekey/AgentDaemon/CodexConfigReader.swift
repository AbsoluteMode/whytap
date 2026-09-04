import Foundation

/// The Codex fields the Settings UI mirrors for display pre-fill.
struct CodexConfigSnapshot: Equatable {
    var model: String?
    var serviceTier: String?   // service_tier

    init(model: String? = nil, serviceTier: String? = nil) {
        self.model = model
        self.serviceTier = serviceTier
    }
}

/// Best-effort reader for `~/.codex/config.toml`. Parses top-level
/// `key = "value"` lines only (first occurrence wins; `[section]` headers and
/// `#` comments are skipped). Never throws -- any failure yields an empty
/// snapshot so the UI falls back to its own defaults. Read-only: never writes.
struct CodexConfigReader {
    var path: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/config.toml")

    func read() -> CodexConfigSnapshot {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return CodexConfigSnapshot()
        }
        return Self.parse(text)
    }

    static func parse(_ text: String) -> CodexConfigSnapshot {
        var snap = CodexConfigSnapshot()
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            switch key {
            case "model" where snap.model == nil: snap.model = value
            case "service_tier" where snap.serviceTier == nil: snap.serviceTier = value
            default: break
            }
        }
        return snap
    }
}

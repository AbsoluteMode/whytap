import Foundation

/// Locates the user's `codex` CLI (OpenAI Codex). Mirrors ClaudeBinaryLocator:
/// known install locations first, then a login-shell `command -v codex` so we
/// pick up nvm/asdf/npm-global PATHs that a GUI app does not inherit.
struct CodexBinaryLocator {
    /// Known install locations, highest priority first. The Codex.app bundle
    /// ships a newer binary than the npm global install, so prefer it.
    static let knownPaths: [String] = [
        "/Applications/Codex.app/Contents/Resources/codex",
        "\(NSHomeDirectory())/.npm-global/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "\(NSHomeDirectory())/.local/bin/codex",
        "\(NSHomeDirectory())/.codex/bin/codex",
    ]

    var fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    /// Resolve via a login shell so we pick up nvm/asdf/npm-global PATH. Returns nil on failure.
    var loginShellWhich: () -> String? = CodexBinaryLocator.defaultLoginShellWhich

    func locate() -> URL? {
        for path in Self.knownPaths where fileExists(path) {
            return URL(fileURLWithPath: path)
        }
        if let resolved = loginShellWhich() {
            return URL(fileURLWithPath: resolved)
        }
        return nil
    }

    static func defaultLoginShellWhich() -> String? {
        LoginShellWhich.resolve("codex")
    }
}

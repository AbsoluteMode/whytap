import Foundation

/// Resolves a command's path via the user's login shell
/// (`$SHELL -lc "command -v <cmd>"`), so nvm/asdf/npm-global/Homebrew PATH
/// entries that a GUI app does not inherit are picked up. Extracted from
/// `ClaudeBinaryLocator`/`CodexBinaryLocator` so the agent setup checklist
/// reuses the exact same resolution for brew/node instead of duplicating it.
enum LoginShellWhich {
    static func resolve(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v \(command)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain before reaping so a chatty shell rc can never fill the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let out = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }
}

/// Detects the developer tools the agent setup checklist verifies before the
/// CLI itself: Homebrew and Node.js. Mirrors the binary locators' strategy —
/// fixed install paths first (cheap file check), then a login-shell
/// `command -v` fallback for nvm/custom-prefix installs.
struct DevToolDetector {
    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
    static let nodePaths = ["/opt/homebrew/bin/node", "/usr/local/bin/node"]

    var fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    var loginShellWhich: (String) -> String? = { LoginShellWhich.resolve($0) }

    func brewInstalled() -> Bool { installed(Self.brewPaths, command: "brew") }
    func nodeInstalled() -> Bool { installed(Self.nodePaths, command: "node") }

    private func installed(_ knownPaths: [String], command: String) -> Bool {
        if knownPaths.contains(where: fileExists) { return true }
        return loginShellWhich(command) != nil
    }
}

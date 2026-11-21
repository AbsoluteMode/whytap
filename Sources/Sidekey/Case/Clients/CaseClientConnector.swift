import Foundation

/// Adds Whytap's one MCP server to an AI client's own settings when it is
/// connected in Case, and cleans up the older Case-only entry.
/// Only the helper path goes into a client config: never a value or token.
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
protocol CaseClientConnector {
    var displayName: String { get }
    /// The client is present on this Mac (used to offer it for registration).
    func isInstalled() -> Bool
    /// Points the client's `whytap` MCP entry at `helperPath mcp` (application
    /// tools plus the names-only Case tools); replaces an existing entry of
    /// ours (`mcp`, `app mcp`, `case mcp`) so a moved app is picked up. Another
    /// server named `whytap` is never replaced: `.foreignEntry` is thrown.
    /// Our older `case` entry is then removed, best effort: if it stays, it
    /// still works (`whytap case mcp` is kept) and only repeats the Case tools.
    func install(helperPath: String) throws
    /// Removes our older `case` entry. The `whytap` entry stays: it is the
    /// general Whytap server (also added by the plugin and the README line),
    /// and without a registration the broker already refuses its Case tools.
    /// Nothing to remove (or only another server named `case`) is not an error.
    func uninstall() throws
}

/// The entry Connect writes, and the Case-only entry earlier builds wrote.
enum WhytapMCPEntry {
    static let name = "whytap"
    static let arguments = ["mcp"]
    static let legacyName = "case"
}

enum CaseClientConnectorError: Error, Equatable {
    case clientNotFound
    case commandFailed(status: Int32)
    case timedOut
    /// Path relative to HOME; the file is left as it was.
    case unreadableConfig(String)
    case writeFailed(String)
    /// The client already has an MCP server named `whytap` that is not Whytap's.
    case foreignEntry

    var userMessage: String {
        switch self {
        case .clientNotFound: return "app not found"
        case .commandFailed(let status): return "command failed (\(status))"
        case .timedOut: return "command timed out"
        case .unreadableConfig(let path): return "couldn’t read ~/\(path)"
        case .writeFailed(let path): return "couldn’t write ~/\(path)"
        case .foreignEntry:
            return "another MCP server named “whytap” already exists; rename or remove it, then connect again"
        }
    }
}

// MARK: Running client CLIs

struct CaseCommandResult: Equatable {
    let status: Int32
}

/// Seam for the client CLIs (`claude`, `codex`). Output is discarded: it is
/// never shown, stored or logged.
protocol CaseCommandRunning {
    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandResult
}

struct SystemCaseCommandRunner: CaseCommandRunning {
    var timeout: TimeInterval = 30

    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw CaseClientConnectorError.clientNotFound
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            throw CaseClientConnectorError.timedOut
        }
        return CaseCommandResult(status: process.terminationStatus)
    }
}

/// The minimal environment for a client CLI: enough to find its own config
/// and runtime (node next to an npm-installed `claude`), nothing inherited.
enum CaseClientEnvironment {
    static func make(home: URL, executable: URL) -> [String: String] {
        let standard = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let own = executable.deletingLastPathComponent().path
        let path = ([own] + standard.filter { $0 != own }).joined(separator: ":")
        return ["HOME": home.path, "PATH": path, "LANG": "en_US.UTF-8"]
    }
}

/// Whether an existing MCP entry is Whytap's: the `whytap` helper of any
/// install or flavor (`whytap`, `whytap-beta`, `whytap-dev`). The legacy
/// `case` entry serves `case mcp`; the `whytap` entry serves `mcp` or, when a
/// person added it by hand from older instructions, `app mcp` or `case mcp`.
/// Anything else belongs to someone else and is left alone.
enum CaseMCPEntryOwnership {
    static func isOurs(command: String?, args: [String]?) -> Bool {
        isOurHelper(command) && (args == nil || args == ["case", "mcp"])
    }

    static func isOurs(_ entry: Any?) -> Bool {
        guard let entry = entry as? [String: Any], let args = readableArgs(entry) else { return false }
        return isOurs(command: entry["command"] as? String, args: args)
    }

    static func isOurServer(command: String?, args: [String]?) -> Bool {
        isOurHelper(command) && (args == nil || [WhytapMCPEntry.arguments, ["app", "mcp"], ["case", "mcp"]].contains(args!))
    }

    static func isOurServer(_ entry: Any?) -> Bool {
        guard let entry = entry as? [String: Any], let args = readableArgs(entry) else { return false }
        return isOurServer(command: entry["command"] as? String, args: args)
    }

    /// `.some(nil)`: no `args`; `.some(list)`: a list of strings; nil: `args`
    /// is something else, which is never ours.
    private static func readableArgs(_ entry: [String: Any]) -> [String]?? {
        guard let raw = entry["args"] else { return .some(nil) }
        guard let list = raw as? [String] else { return nil }
        return .some(list)
    }

    /// A Codex entry is ours only in the plain form `codex mcp add` writes;
    /// absent, unreadable or any other form is not.
    static func isOurServer(_ entry: CodexMCPEntry) -> Bool {
        guard case .table(let command, let args, let readable) = entry, readable else { return false }
        return isOurServer(command: command, args: args)
    }

    static func isOurs(_ entry: CodexMCPEntry) -> Bool {
        guard case .table(let command, let args, let readable) = entry, readable else { return false }
        return isOurs(command: command, args: args)
    }

    private static func isOurHelper(_ command: String?) -> Bool {
        guard let command, !command.isEmpty else { return false }
        let name = URL(fileURLWithPath: command).lastPathComponent
        return name == "whytap" || name.hasPrefix("whytap-")
    }
}

// MARK: JSON config files

/// Reads and rewrites a user's JSON config, keeping every other key. A file
/// that is not a JSON object is never overwritten. The previous file is kept
/// as `<name>.bak`; the new one replaces it atomically. A symlinked config (a
/// dotfiles repo) is written through the link: the real file is replaced and
/// backed up next to itself, the link stays, permission bits are kept.
struct CaseJSONConfigFile {
    let home: URL
    /// Relative to HOME, e.g. `.cursor/mcp.json`.
    let relativePath: String

    var url: URL { home.appendingPathComponent(relativePath) }

    /// nil when the file does not exist.
    func read() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CaseClientConnectorError.unreadableConfig(relativePath) }
        return object
    }

    func write(_ object: [String: Any]) throws {
        let fm = FileManager.default
        do {
            let data = try JSONSerialization.data(withJSONObject: object,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // WHY: docs/decisions/2026-10-19-case-secrets-broker.md (symlink-safe config writes)
            let target = url.resolvingSymlinksInPath()
            let existing = fm.fileExists(atPath: target.path)
            let mode = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue
            if existing {
                let backup = target.appendingPathExtension("bak")
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: target, to: backup)
            }
            try (data + Data("\n".utf8)).write(to: target, options: .atomic)
            if let mode {
                try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            }
        } catch let error as CaseClientConnectorError {
            throw error
        } catch {
            throw CaseClientConnectorError.writeFailed(relativePath)
        }
    }
}

// MARK: Claude Code

/// `claude mcp add -s user whytap -- <helper> mcp`, then removes our older
/// user-scope `case` entry. When Claude's sandbox is on, the broker socket is
/// added to `sandbox.network.allowUnixSockets`.
struct ClaudeCodeCaseConnector: CaseClientConnector {
    let displayName = "Claude Code"
    let home: URL
    let socketPath: String
    let runner: CaseCommandRunning
    let locate: () -> URL?

    init(home: URL, socketPath: String, runner: CaseCommandRunning = SystemCaseCommandRunner(),
         locate: @escaping () -> URL? = { ClaudeBinaryLocator().locate() }) {
        self.home = home
        self.socketPath = socketPath
        self.runner = runner
        self.locate = locate
    }

    private var settings: CaseJSONConfigFile { CaseJSONConfigFile(home: home, relativePath: ".claude/settings.json") }

    func isInstalled() -> Bool { locate() != nil }

    private var userFile: CaseJSONConfigFile { CaseJSONConfigFile(home: home, relativePath: ".claude.json") }

    /// The user-scope servers of `~/.claude.json`. A file that cannot be read
    /// or whose `mcpServers` is not an object throws: Connect must not guess
    /// that no `whytap` server exists there.
    private func userServers() throws -> [String: Any] {
        guard let root = try userFile.read(), let servers = root["mcpServers"] else { return [:] }
        guard let object = servers as? [String: Any] else { throw CaseClientConnectorError.unreadableConfig(".claude.json") }
        return object
    }

    private func userEntry(_ name: String) -> Any? { (try? userServers())?[name] }

    /// A user-scope `whytap` entry exists in `~/.claude.json` (read only).
    func isConfigured() -> Bool { userEntry(WhytapMCPEntry.name) != nil }

    func install(helperPath: String) throws {
        // Read both files first: a broken one stops before anything changes.
        let current = try settings.read()
        let entry = try userServers()[WhytapMCPEntry.name]
        if entry != nil, !CaseMCPEntryOwnership.isOurServer(entry) { throw CaseClientConnectorError.foreignEntry }
        let claude = try binary()
        if entry != nil {
            try check(run(claude, ["mcp", "remove", "-s", "user", WhytapMCPEntry.name]))
        }
        try check(run(claude, ["mcp", "add", "-s", "user", WhytapMCPEntry.name, "--", helperPath] + WhytapMCPEntry.arguments))
        if CaseMCPEntryOwnership.isOurs(userEntry(WhytapMCPEntry.legacyName)) {
            _ = try? run(claude, ["mcp", "remove", "-s", "user", WhytapMCPEntry.legacyName])
        }
        try updateSandbox(current, adding: true)
    }

    func uninstall() throws {
        if CaseMCPEntryOwnership.isOurs(userEntry(WhytapMCPEntry.legacyName)) {
            try check(run(try binary(), ["mcp", "remove", "-s", "user", WhytapMCPEntry.legacyName]))
        }
        try updateSandbox(try settings.read(), adding: false)
    }

    private func binary() throws -> URL {
        guard let url = locate() else { throw CaseClientConnectorError.clientNotFound }
        return url
    }

    private func run(_ binary: URL, _ arguments: [String]) throws -> CaseCommandResult {
        try runner.run(executable: binary, arguments: arguments,
                       environment: CaseClientEnvironment.make(home: home, executable: binary))
    }

    private func check(_ result: CaseCommandResult) throws {
        guard result.status == 0 else { throw CaseClientConnectorError.commandFailed(status: result.status) }
    }

    /// Only a sandbox that is explicitly enabled is touched.
    private func updateSandbox(_ current: [String: Any]?, adding: Bool) throws {
        guard var root = current,
              var sandbox = root["sandbox"] as? [String: Any],
              sandbox["enabled"] as? Bool == true
        else { return }
        var network = sandbox["network"] as? [String: Any] ?? [:]
        var sockets = network["allowUnixSockets"] as? [String] ?? []
        if adding {
            guard !sockets.contains(socketPath) else { return }
            sockets.append(socketPath)
        } else {
            guard sockets.contains(socketPath) else { return }
            sockets.removeAll { $0 == socketPath }
        }
        network["allowUnixSockets"] = sockets
        sandbox["network"] = network
        root["sandbox"] = sandbox
        try settings.write(root)
    }
}

// MARK: Codex

/// `codex mcp add whytap -- <helper> mcp`, then removes our older `case`
/// entry. Codex's sandbox settings are never changed; `config.toml` is
/// written only by codex itself.
struct CodexCaseConnector: CaseClientConnector {
    let displayName = "Codex"
    let home: URL
    let runner: CaseCommandRunning
    let locate: () -> URL?

    init(home: URL, runner: CaseCommandRunning = SystemCaseCommandRunner(),
         locate: @escaping () -> URL? = { CodexBinaryLocator().locate() }) {
        self.home = home
        self.runner = runner
        self.locate = locate
    }

    func isInstalled() -> Bool { locate() != nil }

    func isConfigured() -> Bool { ((try? entry(WhytapMCPEntry.name)) ?? .uncertain) != .absent }

    /// What `config.toml` says about one server name (see CodexMCPConfigScanner).
    /// A file that exists but cannot be read throws: no guessing.
    private func entry(_ name: String) throws -> CodexMCPEntry {
        let url = home.appendingPathComponent(".codex/config.toml")
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CaseClientConnectorError.unreadableConfig(".codex/config.toml")
        }
        return CodexMCPConfigScanner.entry(named: name, in: text)
    }

    func install(helperPath: String) throws {
        // `codex mcp add` replaces a server by name: anything but nothing or
        // our own plain entry is refused before the CLI runs.
        let current = try entry(WhytapMCPEntry.name)
        if current != .absent, !CaseMCPEntryOwnership.isOurServer(current) {
            throw CaseClientConnectorError.foreignEntry
        }
        guard let codex = locate() else { throw CaseClientConnectorError.clientNotFound }
        if current != .absent {
            try check(run(codex, ["mcp", "remove", WhytapMCPEntry.name]))
        }
        try check(run(codex, ["mcp", "add", WhytapMCPEntry.name, "--", helperPath] + WhytapMCPEntry.arguments))
        if hasOurLegacyEntry() {
            _ = try? run(codex, ["mcp", "remove", WhytapMCPEntry.legacyName])
        }
    }

    func uninstall() throws {
        guard hasOurLegacyEntry() else { return }
        guard let codex = locate() else { throw CaseClientConnectorError.clientNotFound }
        try check(run(codex, ["mcp", "remove", WhytapMCPEntry.legacyName]))
    }

    private func hasOurLegacyEntry() -> Bool {
        guard let legacy = try? entry(WhytapMCPEntry.legacyName) else { return false }
        return CaseMCPEntryOwnership.isOurs(legacy)
    }

    private func run(_ binary: URL, _ arguments: [String]) throws -> CaseCommandResult {
        try runner.run(executable: binary, arguments: arguments,
                       environment: CaseClientEnvironment.make(home: home, executable: binary))
    }

    private func check(_ result: CaseCommandResult) throws {
        guard result.status == 0 else { throw CaseClientConnectorError.commandFailed(status: result.status) }
    }
}

// MARK: Cursor

/// `~/.cursor/mcp.json` → `mcpServers.whytap = {command, args: ["mcp"]}`;
/// our older `mcpServers.case` entry is removed in the same write.
struct CursorCaseConnector: CaseClientConnector {
    static let appPath = "/Applications/Cursor.app"

    let displayName = "Cursor"
    let home: URL
    let appInstalled: () -> Bool

    init(home: URL, appInstalled: @escaping () -> Bool = {
        FileManager.default.fileExists(atPath: CursorCaseConnector.appPath)
    }) {
        self.home = home
        self.appInstalled = appInstalled
    }

    private var file: CaseJSONConfigFile { CaseJSONConfigFile(home: home, relativePath: ".cursor/mcp.json") }

    func isInstalled() -> Bool { appInstalled() }

    func isConfigured() -> Bool {
        ((try? file.read())??["mcpServers"] as? [String: Any])?[WhytapMCPEntry.name] != nil
    }

    func install(helperPath: String) throws {
        var root = try file.read() ?? [:]
        // A `mcpServers` that is not an object is never replaced wholesale.
        if root["mcpServers"] != nil, !(root["mcpServers"] is [String: Any]) {
            throw CaseClientConnectorError.unreadableConfig(file.relativePath)
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        if let existing = servers[WhytapMCPEntry.name], !CaseMCPEntryOwnership.isOurServer(existing) {
            throw CaseClientConnectorError.foreignEntry
        }
        servers[WhytapMCPEntry.name] = ["command": helperPath, "args": WhytapMCPEntry.arguments]
        if CaseMCPEntryOwnership.isOurs(servers[WhytapMCPEntry.legacyName]) {
            servers[WhytapMCPEntry.legacyName] = nil
        }
        root["mcpServers"] = servers
        try file.write(root)
    }

    func uninstall() throws {
        guard var root = try file.read(),
              var servers = root["mcpServers"] as? [String: Any],
              CaseMCPEntryOwnership.isOurs(servers[WhytapMCPEntry.legacyName])
        else { return }
        servers[WhytapMCPEntry.legacyName] = nil
        root["mcpServers"] = servers
        try file.write(root)
    }
}

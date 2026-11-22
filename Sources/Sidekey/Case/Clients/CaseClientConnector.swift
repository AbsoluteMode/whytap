import Foundation

/// Adds Whytap's one MCP server to an AI client's own settings when it is
/// connected in Case, and cleans up the older Case-only entry.
/// Only the helper path goes into a client config: never a value or token.
///
/// One rule for every client: Whytap changes an entry only when it is exactly
/// what Whytap itself writes now or wrote in an earlier version
/// (`CaseMCPEntryOwnership`). An earlier Whytap's `whytap` entry is replaced
/// by the current one and an earlier `case` entry is removed. Any other entry,
/// whatever it holds, is the person's own and stays as it is, with
/// "Configured manually — Whytap left it as is" shown.
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md,
// .project-docs/decisions/2026-11-22-connect-replaces-older-whytap-entries.md
protocol CaseClientConnector {
    var displayName: String { get }
    /// The client is present on this Mac (used to offer it for registration).
    func isInstalled() -> Bool
    /// No `whytap` entry: adds `whytap` -> `<helperPath> mcp`. The canonical
    /// entry: nothing to add. An entry an earlier Whytap wrote is replaced by
    /// the canonical one. Any other `whytap` entry, or one that cannot be read
    /// for certain, throws `.configuredManually` or `.unreadableConfig` before
    /// anything changes, and the `case` entry stays. With the canonical
    /// `whytap` in place, a `case` entry an earlier Whytap wrote is removed,
    /// best effort.
    func install(helperPath: String) throws
    /// Removes the `case` entry when it is exactly what an earlier Whytap
    /// wrote (`CaseMCPEntryOwnership.isEarlierWhytap`). The `whytap` entry stays: it is the
    /// general Whytap server (also added by the plugin and the README line),
    /// and without a registration the broker already refuses its Case tools.
    func uninstall(helperPath: String?) throws
}

/// The entry Connect writes, and the Case-only entry earlier builds wrote.
enum WhytapMCPEntry {
    static let name = "whytap"
    static let arguments = ["mcp"]
    static let legacyName = "case"
    static let legacyArguments = ["case", "mcp"]
    /// Subcommands earlier builds wrote: `app mcp` (the app-control server,
    /// plugin and README line) and `case mcp` (Case Connect), plus today's.
    static let earlierArguments: [[String]] = [["mcp"], ["app", "mcp"], ["case", "mcp"]]

    /// Where a released build of each flavor keeps its helper, with the paths
    /// the same flavor used before the Exodia -> Whytap rename (Sparkle
    /// updates in place, so an older bundle name can still hold a new build).
    /// Beta and prod are different apps (bundle, keychain, broker): one never
    /// adopts the other's entries. A dev or moved build owns only its own path.
    static let installedHelpers: [String: [String]] = [
        "/Applications/Whytap.app/Contents/Helpers/whytap":
            ["/Applications/Exodia.app/Contents/Helpers/whytap"],
        "/Applications/Whytap-Beta.app/Contents/Helpers/whytap":
            ["/Applications/Exodia-Beta.app/Contents/Helpers/whytap"],
    ]

    /// Helper paths whose entries the app running `helperPath` may replace.
    static func ownHelperPaths(for helperPath: String) -> Set<String> {
        Set([helperPath] + (installedHelpers[helperPath] ?? []))
    }
}

enum CaseClientConnectorError: Error, Equatable {
    case clientNotFound
    case commandFailed(status: Int32)
    case timedOut
    /// Path relative to HOME; the file is left as it was.
    case unreadableConfig(String)
    case writeFailed(String)
    /// A `whytap` entry that is not exactly what Whytap writes: left as it is.
    case configuredManually

    var userMessage: String {
        switch self {
        case .clientNotFound: return "app not found"
        case .commandFailed(let status): return "command failed (\(status))"
        case .timedOut: return "command timed out"
        case .unreadableConfig(let path): return "couldn’t read ~/\(path)"
        case .writeFailed(let path): return "couldn’t write ~/\(path)"
        case .configuredManually: return "Configured manually — Whytap left it as is"
        }
    }
}

// MARK: Running client CLIs

struct CaseCommandResult: Equatable {
    let status: Int32
}

/// Seam for the client CLIs (`claude`, `codex`) that change their settings.
/// Output is discarded: it is never shown, stored or logged.
protocol CaseCommandRunning {
    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandResult
}

/// What a read-only client command printed. Used once to decide, in memory,
/// then dropped: never shown, stored or logged.
struct CaseCommandOutput: Equatable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    /// Either stream exceeded the read limit; the output is not trusted.
    var truncated = false
}

/// Seam for read-only client commands (`codex mcp get`), kept apart from
/// `CaseCommandRunning` so a refusal provably changes nothing.
protocol CaseCommandReading {
    func read(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandOutput
}

struct SystemCaseCommandRunner: CaseCommandRunning, CaseCommandReading {
    var timeout: TimeInterval = 30
    /// Per stream. A server entry is a few hundred bytes.
    var readLimit = 256 * 1024

    func run(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandResult {
        let process = makeProcess(executable, arguments, environment)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return CaseCommandResult(status: try wait(for: process))
    }

    func read(executable: URL, arguments: [String], environment: [String: String]) throws -> CaseCommandOutput {
        let process = makeProcess(executable, arguments, environment)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdout = BoundedSink(limit: readLimit), stderr = BoundedSink(limit: readLimit)
        let drained = DispatchGroup()
        for (pipe, sink) in [(out, stdout), (err, stderr)] {
            drained.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                sink.drain(pipe.fileHandleForReading)
                drained.leave()
            }
        }
        let status: Int32
        do {
            status = try wait(for: process)
        } catch {
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            throw error
        }
        // A child that left the pipes open (a grandchild) cannot hold us.
        guard drained.wait(timeout: .now() + 2) == .success else { throw CaseClientConnectorError.timedOut }
        return CaseCommandOutput(status: status, stdout: stdout.data, stderr: stderr.data,
                                 truncated: stdout.overflowed || stderr.overflowed)
    }

    private func makeProcess(_ executable: URL, _ arguments: [String], _ environment: [String: String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private func wait(for process: Process) throws -> Int32 {
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
        return process.terminationStatus
    }
}

/// Keeps at most `limit` bytes of a stream and drains the rest.
private final class BoundedSink: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()
    private var over = false
    init(limit: Int) { self.limit = limit }
    var data: Data { lock.withLock { bytes } }
    var overflowed: Bool { lock.withLock { over } }
    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            lock.withLock {
                let room = limit - bytes.count
                if chunk.count > room { over = true }
                if room > 0 { bytes.append(chunk.prefix(room)) }
            }
        }
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

/// The one test for touching an entry: it is exactly what Whytap writes now
/// or wrote before. JSON hosts: `{command: <helper>, args}` with nothing
/// else, apart from `type: "stdio"` and an empty `env`, which Claude Code adds
/// itself. Paths are compared as written (no symlink or spelling variants).
// WHY: .project-docs/decisions/2026-11-22-connect-replaces-older-whytap-entries.md
enum CaseMCPEntryOwnership {
    /// Plain `command` + `args`, or nil when the entry has anything else.
    static func plainCommand(_ entry: Any?) -> (command: String, args: [String])? {
        guard let entry = entry as? [String: Any],
              Set(entry.keys).isSubset(of: ["type", "command", "args", "env"]),
              let command = entry["command"] as? String,
              let args = entry["args"] as? [String] else { return nil }
        if let type = entry["type"], type as? String != "stdio" { return nil }
        if let env = entry["env"], (env as? [String: Any])?.isEmpty != true { return nil }
        return (command, args)
    }

    static func isCanonical(_ entry: Any?, helperPath: String, arguments: [String]) -> Bool {
        guard let plain = plainCommand(entry) else { return false }
        return plain.command == helperPath && plain.args == arguments
    }

    /// Any plain entry Whytap wrote: this app's helper, or the same flavor's
    /// helper at an earlier install path, running one of the MCP subcommands.
    static func isEarlierWhytap(command: String, args: [String], helperPath: String) -> Bool {
        WhytapMCPEntry.ownHelperPaths(for: helperPath).contains(command)
            && WhytapMCPEntry.earlierArguments.contains(args)
    }

    static func isEarlierWhytap(_ entry: Any?, helperPath: String) -> Bool {
        guard let plain = plainCommand(entry) else { return false }
        return isEarlierWhytap(command: plain.command, args: plain.args, helperPath: helperPath)
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

/// `claude mcp add -s user whytap -- <helper> mcp` when there is no `whytap`
/// entry. An earlier Whytap's `whytap` is removed and added again (the CLI
/// cannot replace a name); if the add fails, the earlier entry is put back,
/// which is exact because it was a plain command. Then our older user-scope
/// `case` entry is removed via `claude mcp remove`. When Claude's sandbox is on, the broker socket is
/// added to `sandbox.network.allowUnixSockets`. `~/.claude.json` is read with
/// the system JSON parser (escapes in keys included); it is written only by
/// `claude` itself.
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
    private var userFile: CaseJSONConfigFile { CaseJSONConfigFile(home: home, relativePath: ".claude.json") }

    func isInstalled() -> Bool { locate() != nil }

    /// The user-scope servers of `~/.claude.json`. A file that cannot be read
    /// or whose `mcpServers` is not an object throws: Connect never guesses
    /// that no `whytap` server exists there.
    private func userServers() throws -> [String: Any] {
        guard let root = try userFile.read(), let servers = root["mcpServers"] else { return [:] }
        guard let object = servers as? [String: Any] else { throw CaseClientConnectorError.unreadableConfig(".claude.json") }
        return object
    }

    /// A user-scope `whytap` entry exists in `~/.claude.json` (read only).
    func isConfigured() -> Bool { (try? userServers())?[WhytapMCPEntry.name] != nil }

    func install(helperPath: String) throws {
        // Read both files first: a broken one stops before anything changes.
        let current = try settings.read()
        let servers = try userServers()
        let entry = servers[WhytapMCPEntry.name]
        let canonical = CaseMCPEntryOwnership.isCanonical(entry, helperPath: helperPath,
                                                          arguments: WhytapMCPEntry.arguments)
        let earlier = canonical ? nil : CaseMCPEntryOwnership.plainCommand(entry).flatMap {
            CaseMCPEntryOwnership.isEarlierWhytap(command: $0.command, args: $0.args, helperPath: helperPath) ? $0 : nil
        }
        if entry != nil, !canonical, earlier == nil {
            throw CaseClientConnectorError.configuredManually
        }
        let claude = try binary()
        let add = ["mcp", "add", "-s", "user", WhytapMCPEntry.name, "--"]
        if let earlier {
            try check(run(claude, ["mcp", "remove", "-s", "user", WhytapMCPEntry.name]))
            let added = try? run(claude, add + [helperPath] + WhytapMCPEntry.arguments)
            if added?.status != 0 {
                _ = try? run(claude, add + [earlier.command] + earlier.args)
                throw CaseClientConnectorError.commandFailed(status: added?.status ?? -1)
            }
        } else if entry == nil {
            try check(run(claude, add + [helperPath] + WhytapMCPEntry.arguments))
        }
        if CaseMCPEntryOwnership.isEarlierWhytap(servers[WhytapMCPEntry.legacyName], helperPath: helperPath) {
            _ = try? run(claude, ["mcp", "remove", "-s", "user", WhytapMCPEntry.legacyName])
        }
        try updateSandbox(current, adding: true)
    }

    func uninstall(helperPath: String?) throws {
        if let helperPath, let servers = try? userServers(),
           CaseMCPEntryOwnership.isEarlierWhytap(servers[WhytapMCPEntry.legacyName], helperPath: helperPath) {
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

/// What Codex itself says about one server name. Read with `codex mcp get
/// <name> --json`, so Codex's own TOML parser decides (escapes, inline
/// tables, comments, profiles); Whytap never parses `config.toml`.
enum CodexMCPEntry: Equatable {
    case absent
    /// A stdio command with nothing else set.
    case stdio(command: String, args: [String])
    /// A stdio command with settings of its own (env, cwd, disabled, timeouts,
    /// tool lists or a field this parser does not know).
    case customized(command: String, args: [String])
    /// Present, but not a plain stdio command (a URL server, odd fields).
    case other
    /// The read failed or its answer could not be understood.
    case uncertain

    /// Codex's answer for a name that is not configured (codex-cli 0.170),
    /// as the last line of stderr (warnings may come before it). Any other
    /// failure, including a newer wording, reads as `.uncertain`.
    static func notFoundMessage(_ name: String) -> String { "Error: No MCP server named '\(name)' found." }

    static func parse(_ output: CaseCommandOutput, name: String) -> CodexMCPEntry {
        guard !output.truncated else { return .uncertain }
        guard output.status == 0 else {
            let lastLine = String(decoding: output.stderr, as: UTF8.self)
                .split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
            return lastLine == notFoundMessage(name) && output.stdout.isEmpty ? .absent : .uncertain
        }
        guard let object = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              object["name"] as? String == name,
              let transport = object["transport"] as? [String: Any] else { return .uncertain }
        guard transport["type"] as? String == "stdio", let command = transport["command"] as? String else { return .other }
        let args: [String]
        switch transport["args"] {
        case nil, is NSNull: args = []
        case let list as [String]: args = list
        default: return .other
        }
        let envVars = transport["env_vars"]
        let envVarsUnset = envVars == nil || envVars is NSNull || (envVars as? [Any])?.isEmpty == true
        let plain = isNeutral(object, except: ["name", "enabled", "transport"])
            && (object["enabled"] == nil || isTrue(object["enabled"]))
            && isNeutral(transport, except: ["type", "command", "args", "env_vars"])
            && envVarsUnset
        return plain ? .stdio(command: command, args: args) : .customized(command: command, args: args)
    }

    /// Every other field is unset: null or false. An empty list or table is a
    /// setting (`enabled_tools = []` allows no tool), except `env_vars`, which
    /// Codex reports as `[]` when absent and which passes no value when empty.
    private static func isNeutral(_ object: [String: Any], except: Set<String>) -> Bool {
        object.allSatisfy { key, value in
            if except.contains(key) || value is NSNull { return true }
            return isBoolean(value) && !isTrue(value)
        }
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let value = value as AnyObject? else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func isTrue(_ value: Any?) -> Bool { isBoolean(value) && (value as? Bool) == true }
}

/// `codex mcp add whytap -- <helper> mcp` when Codex has no `whytap` or has
/// one an earlier Whytap wrote (`codex mcp add` replaces it in one write),
/// then `codex mcp remove case` for our older entry. Each name is first read
/// with `codex mcp get --json` through `reader` (read-only); a changing
/// command runs only for an absent name or an entry Whytap wrote. Codex's sandbox settings are
/// never changed; `config.toml` is written only by codex.
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
struct CodexCaseConnector: CaseClientConnector {
    let displayName = "Codex"
    let home: URL
    let runner: CaseCommandRunning
    let reader: CaseCommandReading
    let locate: () -> URL?

    init(home: URL, runner: CaseCommandRunning = SystemCaseCommandRunner(),
         reader: CaseCommandReading = SystemCaseCommandRunner(),
         locate: @escaping () -> URL? = { CodexBinaryLocator().locate() }) {
        self.home = home
        self.runner = runner
        self.reader = reader
        self.locate = locate
    }

    func isInstalled() -> Bool { locate() != nil }

    func isConfigured() -> Bool {
        guard let codex = locate() else { return false }
        let current = entry(WhytapMCPEntry.name, codex: codex)
        return current != .absent && current != .uncertain
    }

    func entry(_ name: String, codex: URL) -> CodexMCPEntry {
        guard let output = try? reader.read(executable: codex, arguments: ["mcp", "get", name, "--json"],
                                            environment: CaseClientEnvironment.make(home: home, executable: codex))
        else { return .uncertain }
        return CodexMCPEntry.parse(output, name: name)
    }

    func install(helperPath: String) throws {
        guard let codex = locate() else { throw CaseClientConnectorError.clientNotFound }
        let add = ["mcp", "add", WhytapMCPEntry.name, "--", helperPath] + WhytapMCPEntry.arguments
        switch entry(WhytapMCPEntry.name, codex: codex) {
        case .absent:
            try check(run(codex, add))
        case .stdio(helperPath, WhytapMCPEntry.arguments):
            break
        case .stdio(let command, let args)
            where CaseMCPEntryOwnership.isEarlierWhytap(command: command, args: args, helperPath: helperPath):
            try check(run(codex, add))
        case .uncertain:
            throw CaseClientConnectorError.unreadableConfig(".codex/config.toml")
        case .stdio, .customized, .other:
            // Disabled, filtered, other settings, another path or subcommand:
            // the person's own, and it may not serve Case, so `case` stays too.
            throw CaseClientConnectorError.configuredManually
        }
        if hasOurLegacyEntry(codex: codex, helperPath: helperPath) {
            _ = try? run(codex, ["mcp", "remove", WhytapMCPEntry.legacyName])
        }
    }

    func uninstall(helperPath: String?) throws {
        guard let helperPath, let codex = locate(), hasOurLegacyEntry(codex: codex, helperPath: helperPath) else { return }
        try check(run(codex, ["mcp", "remove", WhytapMCPEntry.legacyName]))
    }

    /// Our older `case` entry exactly as an earlier Whytap wrote it.
    private func hasOurLegacyEntry(codex: URL, helperPath: String) -> Bool {
        guard case .stdio(let command, let args) = entry(WhytapMCPEntry.legacyName, codex: codex) else { return false }
        return CaseMCPEntryOwnership.isEarlierWhytap(command: command, args: args, helperPath: helperPath)
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

/// `~/.cursor/mcp.json` → `mcpServers.whytap = {command, args: ["mcp"]}`
/// when there is no `whytap` or an earlier Whytap wrote it; our older
/// `mcpServers.case` entry is removed in the same write when it is exactly
/// what an earlier Whytap wrote. Cursor has
/// no CLI for this, so its JSON file is written directly (other keys kept).
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
        let entry = servers[WhytapMCPEntry.name]
        let canonical = CaseMCPEntryOwnership.isCanonical(entry, helperPath: helperPath,
                                                          arguments: WhytapMCPEntry.arguments)
        if entry != nil, !canonical, !CaseMCPEntryOwnership.isEarlierWhytap(entry, helperPath: helperPath) {
            throw CaseClientConnectorError.configuredManually
        }
        var changed = false
        if !canonical {
            servers[WhytapMCPEntry.name] = ["command": helperPath, "args": WhytapMCPEntry.arguments]
            changed = true
        }
        if CaseMCPEntryOwnership.isEarlierWhytap(servers[WhytapMCPEntry.legacyName], helperPath: helperPath) {
            servers[WhytapMCPEntry.legacyName] = nil
            changed = true
        }
        guard changed else { return }
        root["mcpServers"] = servers
        try file.write(root)
    }

    func uninstall(helperPath: String?) throws {
        guard let helperPath,
              var root = try file.read(),
              var servers = root["mcpServers"] as? [String: Any],
              CaseMCPEntryOwnership.isEarlierWhytap(servers[WhytapMCPEntry.legacyName], helperPath: helperPath)
        else { return }
        servers[WhytapMCPEntry.legacyName] = nil
        root["mcpServers"] = servers
        try file.write(root)
    }
}

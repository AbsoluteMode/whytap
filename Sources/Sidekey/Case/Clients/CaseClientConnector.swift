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
    /// tools plus the names-only Case tools). An existing `whytap` entry is
    /// replaced only when it is provably ours (CaseMCPEntryOwnership); any
    /// other entry, or one that cannot be read for certain, throws
    /// `.foreignEntry` or `.unreadableConfig` before the client's CLI runs.
    /// Our older `case` entry is then removed, best effort: if it stays, it
    /// still works (`whytap case mcp` is kept) and only repeats the Case tools.
    func install(helperPath: String) throws
    /// Removes our older `case` entry when it provably points at `helperPath`.
    /// The `whytap` entry stays: it is the general Whytap server (also added
    /// by the plugin and the README line), and without a registration the
    /// broker already refuses its Case tools. Nothing to remove, an entry
    /// that is not provably ours, or no `helperPath` changes nothing.
    func uninstall(helperPath: String?) throws
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
    /// Replacing our `whytap` entry failed and the previous one could not be put back.
    case restoreFailed
    /// Our `whytap` entry carries its own settings (env and the like) that a
    /// replacement could not put back without passing them on a command line.
    case customizedEntry

    var userMessage: String {
        switch self {
        case .clientNotFound: return "app not found"
        case .commandFailed(let status): return "command failed (\(status))"
        case .timedOut: return "command timed out"
        case .unreadableConfig(let path): return "couldn’t read ~/\(path)"
        case .writeFailed(let path): return "couldn’t write ~/\(path)"
        case .foreignEntry:
            return "another MCP server named “whytap” already exists; rename or remove it, then connect again"
        case .restoreFailed:
            return "the new “whytap” entry was refused and the previous one couldn’t be put back; connect again"
        case .customizedEntry:
            return "the “whytap” entry has its own settings (such as env); remove it, then connect again"
        }
    }
}

// MARK: Running client CLIs
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

/// Whether an existing MCP entry is ours. Only one test counts: a stdio
/// entry whose command is an absolute path naming exactly this app's helper
/// (`helperPath`) once both are standardized and their symlinks resolved, with
/// arguments `mcp`, `app mcp` or `case mcp` (the legacy `case` entry: only
/// `case mcp`). No name or prefix matching: `/opt/bin/whytap-metrics`, a copy
/// of Whytap elsewhere or a bare `whytap` on PATH are someone else's.
// WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
enum CaseMCPEntryOwnership {
    static let serverArguments: [[String]] = [WhytapMCPEntry.arguments, ["app", "mcp"], ["case", "mcp"]]
    static let legacyArguments = ["case", "mcp"]

    static func isOurServer(command: String?, args: [String]?, helperPath: String) -> Bool {
        guard let args, serverArguments.contains(args) else { return false }
        return isOurHelper(command, helperPath: helperPath)
    }

    static func isOurs(command: String?, args: [String]?, helperPath: String) -> Bool {
        args == legacyArguments && isOurHelper(command, helperPath: helperPath)
    }

    /// A JSON entry (`~/.claude.json`, `~/.cursor/mcp.json`): an object with a
    /// string `command`, an array-of-strings `args`, no `url`, and `type`
    /// absent or `stdio`.
    static func isOurServer(_ entry: Any?, helperPath: String) -> Bool {
        guard let (command, args) = stdio(entry) else { return false }
        return isOurServer(command: command, args: args, helperPath: helperPath)
    }

    static func isOurs(_ entry: Any?, helperPath: String) -> Bool {
        guard let (command, args) = stdio(entry) else { return false }
        return isOurs(command: command, args: args, helperPath: helperPath)
    }

    private static func stdio(_ entry: Any?) -> (String, [String])? {
        guard let entry = entry as? [String: Any], entry["url"] == nil,
              entry["type"] == nil || entry["type"] as? String == "stdio",
              let command = entry["command"] as? String,
              let args = entry["args"] as? [String] else { return nil }
        return (command, args)
    }

    /// Already what Connect writes (`<helper> mcp`, exact path): left as it
    /// is, whatever else the person set on it.
    static func isCurrent(command: String?, args: [String]?, helperPath: String) -> Bool {
        command == helperPath && args == WhytapMCPEntry.arguments
    }

    static func isCurrent(_ entry: Any?, helperPath: String) -> Bool {
        guard let (command, args) = stdio(entry) else { return false }
        return isCurrent(command: command, args: args, helperPath: helperPath)
    }

    /// Command and arguments of a JSON entry that holds nothing else (stdio,
    /// empty or no env, no other field), or nil. Only such an entry may be
    /// replaced or removed by Connect: anything more is the person's own
    /// setting, which a rewrite would drop and a restore would have to pass on
    /// a command line where other processes can read it.
    static func plainServer(_ entry: Any?) -> (command: String, args: [String])? {
        guard let entry = entry as? [String: Any], let (command, args) = stdio(entry),
              Set(entry.keys).isSubset(of: ["type", "command", "args", "env"]) else { return nil }
        if let env = entry["env"], (env as? [String: Any])?.isEmpty != true { return nil }
        return (command, args)
    }

    static func isOurHelper(_ command: String?, helperPath: String) -> Bool {
        guard let command, command.hasPrefix("/"), helperPath.hasPrefix("/") else { return false }
        return canonical(command) == canonical(helperPath)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
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

/// `claude mcp add -s user whytap -- <helper> mcp` (our older `whytap` is
/// removed first and put back if the add is refused), then removes our older
/// user-scope `case` entry. When Claude's sandbox is on, the broker socket is
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
        if entry != nil, !CaseMCPEntryOwnership.isOurServer(entry, helperPath: helperPath) {
            throw CaseClientConnectorError.foreignEntry
        }
        let upToDate = entry != nil && CaseMCPEntryOwnership.isCurrent(entry, helperPath: helperPath)
        let previous = CaseMCPEntryOwnership.plainServer(entry)
        if entry != nil, !upToDate, previous == nil { throw CaseClientConnectorError.customizedEntry }
        let claude = try binary()
        if entry != nil {
            if !upToDate, let previous { try replace(previous, claude: claude, helperPath: helperPath) }
        } else {
            try check(run(claude, ["mcp", "add", "-s", "user", WhytapMCPEntry.name, "--", helperPath] + WhytapMCPEntry.arguments))
        }
        let legacy = servers[WhytapMCPEntry.legacyName]
        if CaseMCPEntryOwnership.isOurs(legacy, helperPath: helperPath), CaseMCPEntryOwnership.plainServer(legacy) != nil {
            _ = try? run(claude, ["mcp", "remove", "-s", "user", WhytapMCPEntry.legacyName])
        }
        try updateSandbox(current, adding: true)
    }

    /// `claude mcp add` refuses a name that exists, so our older entry is
    /// removed first. A refused add puts the previous command and arguments
    /// back with `claude mcp add` (plain entries only, see
    /// `CaseMCPEntryOwnership.plainServer`), so a
    /// failed Connect never leaves the person without the server that worked
    /// before and never puts configured values in a process's arguments.
    // WHY: .project-docs/decisions/2026-11-21-one-whytap-mcp-server.md
    private func replace(_ previous: (command: String, args: [String]), claude: URL, helperPath: String) throws {
        try check(run(claude, ["mcp", "remove", "-s", "user", WhytapMCPEntry.name]))
        do {
            try check(run(claude, ["mcp", "add", "-s", "user", WhytapMCPEntry.name, "--", helperPath] + WhytapMCPEntry.arguments))
        } catch {
            let restored = (try? run(claude, ["mcp", "add", "-s", "user", WhytapMCPEntry.name, "--", previous.command]
                                                  + previous.args))?.status == 0
            throw restored ? error : CaseClientConnectorError.restoreFailed
        }
    }

    func uninstall(helperPath: String?) throws {
        if let helperPath, let servers = try? userServers(),
           CaseMCPEntryOwnership.isOurs(servers[WhytapMCPEntry.legacyName], helperPath: helperPath),
           CaseMCPEntryOwnership.plainServer(servers[WhytapMCPEntry.legacyName]) != nil {
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
        let plain = isNeutral(object, except: ["name", "enabled", "transport"])
            && (object["enabled"] == nil || isTrue(object["enabled"]))
            && isNeutral(transport, except: ["type", "command", "args"])
        return plain ? .stdio(command: command, args: args) : .customized(command: command, args: args)
    }

    /// Every other field is unset: null, false, or an empty list or table.
    private static func isNeutral(_ object: [String: Any], except: Set<String>) -> Bool {
        object.allSatisfy { key, value in
            if except.contains(key) || value is NSNull { return true }
            if let list = value as? [Any] { return list.isEmpty }
            if let table = value as? [String: Any] { return table.isEmpty }
            return isBoolean(value) && !isTrue(value)
        }
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let value = value as AnyObject? else { return false }
        return CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func isTrue(_ value: Any?) -> Bool { isBoolean(value) && (value as? Bool) == true }
}

/// `codex mcp add whytap -- <helper> mcp`, then removes our older `case`
/// entry. `codex mcp add` replaces a server by name in one write (ours is
/// never removed first, so a refused add keeps it), so the existing entry is
/// first read with `codex mcp get --json` through `reader` (read-only); only
/// an absent name or our own entry lets a changing command run. Codex's
/// sandbox settings are never changed; `config.toml` is written only by codex.
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
        let current = entry(WhytapMCPEntry.name, codex: codex)
        switch current {
        // `codex mcp add` replaces an entry of that name in one write, so ours
        // is never removed first: a refused add leaves the working one as it was.
        case .absent:
            try add(codex, helperPath: helperPath)
        // A `where` binds only to the pattern before it, so each case has its own.
        case .stdio(let command, let args)
            where CaseMCPEntryOwnership.isCurrent(command: command, args: args, helperPath: helperPath):
            break
        case .customized(let command, let args)
            where CaseMCPEntryOwnership.isCurrent(command: command, args: args, helperPath: helperPath):
            break
        case .stdio(let command, let args)
            where CaseMCPEntryOwnership.isOurServer(command: command, args: args, helperPath: helperPath):
            try add(codex, helperPath: helperPath)
        case .customized(let command, let args)
            where CaseMCPEntryOwnership.isOurServer(command: command, args: args, helperPath: helperPath):
            // `add` would drop the person's settings (re-enable it, reset its timeouts).
            throw CaseClientConnectorError.customizedEntry
        case .stdio, .customized, .other, .uncertain:
            throw CaseClientConnectorError.foreignEntry
        }
        if hasOurLegacyEntry(codex: codex, helperPath: helperPath) {
            _ = try? run(codex, ["mcp", "remove", WhytapMCPEntry.legacyName])
        }
    }

    private func add(_ codex: URL, helperPath: String) throws {
        try check(run(codex, ["mcp", "add", WhytapMCPEntry.name, "--", helperPath] + WhytapMCPEntry.arguments))
    }

    func uninstall(helperPath: String?) throws {
        guard let helperPath, let codex = locate(), hasOurLegacyEntry(codex: codex, helperPath: helperPath) else { return }
        try check(run(codex, ["mcp", "remove", WhytapMCPEntry.legacyName]))
    }

    /// Our older `case` entry with nothing else set; one with settings of its
    /// own is left alone.
    private func hasOurLegacyEntry(codex: URL, helperPath: String) -> Bool {
        guard case .stdio(let command, let args) = entry(WhytapMCPEntry.legacyName, codex: codex) else { return false }
        return CaseMCPEntryOwnership.isOurs(command: command, args: args, helperPath: helperPath)
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
/// our older `mcpServers.case` entry is removed in the same write. An entry
/// already `<helper> mcp` is left as it is; ours with settings of its own is
/// refused, never rewritten.
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
        var changed = false
        if let existing = servers[WhytapMCPEntry.name] {
            if !CaseMCPEntryOwnership.isCurrent(existing, helperPath: helperPath) {
                guard CaseMCPEntryOwnership.isOurServer(existing, helperPath: helperPath) else {
                    throw CaseClientConnectorError.foreignEntry
                }
                // A rewrite would drop the person's own settings (env and the like).
                guard CaseMCPEntryOwnership.plainServer(existing) != nil else { throw CaseClientConnectorError.customizedEntry }
                servers[WhytapMCPEntry.name] = ["command": helperPath, "args": WhytapMCPEntry.arguments]
                changed = true
            }
        } else {
            servers[WhytapMCPEntry.name] = ["command": helperPath, "args": WhytapMCPEntry.arguments]
            changed = true
        }
        let legacy = servers[WhytapMCPEntry.legacyName]
        if CaseMCPEntryOwnership.isOurs(legacy, helperPath: helperPath), CaseMCPEntryOwnership.plainServer(legacy) != nil {
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
              CaseMCPEntryOwnership.isOurs(servers[WhytapMCPEntry.legacyName], helperPath: helperPath),
              CaseMCPEntryOwnership.plainServer(servers[WhytapMCPEntry.legacyName]) != nil
        else { return }
        servers[WhytapMCPEntry.legacyName] = nil
        root["mcpServers"] = servers
        try file.write(root)
    }
}

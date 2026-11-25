import Darwin
import Foundation
import Security

// A Whytap update replaces the bundled helper on disk, and the app trusts only
// a peer whose running code has that file's cdhash. A `whytap mcp` started
// before the update keeps the old image in memory, so every request it sends
// is denied as an untrusted helper until the harness reconnects. The helper
// therefore replaces itself, in place, with the new file: `execve` keeps its
// pid, its parent (the harness, whose access answer the app keys on) and its
// stdio, and the new image passes exactly the check a freshly started helper
// passes. The denied requests were never read by the app, so they are replayed.
// WHY: .project-docs/decisions/2026-11-25-helper-follows-new-build.md

/// What a helper hands to its new image: the MCP session's handshake state
/// and every request byte it has not answered yet, in arrival order.
public struct MCPResumeState: Codable, Equatable {
    /// Versioned: a helper file that does not contain this exact key cannot
    /// resume this envelope (a rollback to an older build).
    public static let environmentKey = "WHYTAP_MCP_RESUME_V1_FD"
    public static let currentVersion = 1
    /// One bound for the writer and the reader of the encoded envelope.
    public static let maxEncodedBytes = 16 * 1024 * 1024

    public var version: Int
    public var initialized: Bool
    /// The access probe completed with an answer from the app this image trusted.
    public var probed: Bool
    public var input: Data
    /// Earlier relaunches of this process (the loop budget survives exec).
    public var relaunches: [Date]
    /// cdhashes of the replacement the previous image verified; the new image
    /// resumes only if the code it runs is one of them.
    public var expectedCodeHashes: [Data]
    /// The installed helper this session belongs to; the new image runs from a
    /// private verified copy and still serves as that helper.
    public var helperPath: String?
    /// The private copy's folder, removed by the new image once it runs.
    public var stagingDirectory: String?

    public init(initialized: Bool, probed: Bool, input: Data, relaunches: [Date], expectedCodeHashes: [Data] = [],
                helperPath: String? = nil, stagingDirectory: String? = nil) {
        self.version = Self.currentVersion
        self.initialized = initialized; self.probed = probed
        self.input = input; self.relaunches = relaunches
        self.expectedCodeHashes = expectedCodeHashes
        self.helperPath = helperPath; self.stagingDirectory = stagingDirectory
    }

    /// nil when the envelope would exceed what a reader accepts.
    public func encoded() -> Data? {
        guard let data = try? JSONEncoder().encode(self), data.count <= Self.maxEncodedBytes else { return nil }
        return data
    }

    static func decode(_ data: Data) -> MCPResumeState? {
        guard data.count <= maxEncodedBytes,
              let state = try? JSONDecoder().decode(Self.self, from: data),
              state.version == currentVersion else { return nil }
        return state
    }

    /// Reads and removes the state an earlier image of this process left. Only
    /// an inherited regular file counts (never stdin or a pipe); anything
    /// unreadable starts a fresh session. Whoever can set the environment can
    /// also write to stdin, so the state grants nothing a client could not send.
    public static func takeFromEnvironment() -> MCPResumeState? {
        guard let raw = getenv(environmentKey) else { return nil }
        let text = String(cString: raw)
        unsetenv(environmentKey)
        guard let fd = Int32(text), fd > STDERR_FILENO else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maxEncodedBytes else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        _ = lseek(fd, 0, SEEK_SET)
        while data.count <= maxEncodedBytes {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 { data.append(contentsOf: chunk[0..<count]) }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
        return decode(data)
    }

    /// Binds the exec to the verified file: when this image is not the
    /// replacement the previous image checked (the file changed in between),
    /// every carried request gets an explicit error and nothing is replayed.
    public func admitted(runningHash: Data?, write: (String) -> Void) -> MCPResumeState {
        if let runningHash, expectedCodeHashes.contains(runningHash) { return self }
        let carried = MCPCarriedInput.split(input)
        MCPCarriedInput.refusals(for: carried.lines, message: MCPCarriedInput.retryMessage).forEach(write)
        return MCPResumeState(initialized: initialized, probed: false, input: carried.tail, relaunches: relaunches,
                              stagingDirectory: stagingDirectory)
    }
}

/// Request bytes carried across a handover.
enum MCPCarriedInput {
    static let retryMessage = "Whytap was updated while this request was waiting and the helper could not carry it over. Retry the request; read the current state before retrying a write."

    /// Complete lines and the unterminated tail.
    static func split(_ data: Data) -> (lines: [String], tail: Data) {
        var lines: [String] = []
        var rest = data
        while let line = FileDescriptorLineSource.splitLine(&rest, atEOF: false) { lines.append(line) }
        return (lines, rest)
    }

    static func join(_ lines: [String]) -> Data {
        var data = Data()
        for line in lines { data.append(Data((line + "\n").utf8)) }
        return data
    }

    private static func object(_ line: String) -> [String: AppControlValue]? {
        guard line.utf8.count <= AppControlMCPServer.maxLineBytes else { return nil }
        return (try? JSONDecoder().decode(AppControlValue.self, from: Data(line.utf8)))?.object
    }

    static func cancelledKey(_ line: String) -> String? {
        guard let request = object(line), request["jsonrpc"] == .string("2.0"),
              request["method"] == .string("notifications/cancelled"),
              let id = request["params"]?.object?["requestId"] else { return nil }
        return requestKey(id)
    }

    static func requestKey(_ id: AppControlValue) -> String? {
        switch id {
        case .string(let value): return "s:" + value
        case .int(let value): return "i:\(value)"
        case .null: return "null"
        default: return nil
        }
    }

    private static func requestID(_ line: String) -> AppControlValue? {
        guard let request = object(line), let id = request["id"], requestKey(id) != nil else { return nil }
        return id
    }

    /// Removes each request whose cancellation follows it in the carried
    /// bytes, and that cancellation, so the new image never dispatches it.
    static func droppingCancelled(_ lines: [String]) -> [String] {
        var drop = Set<Int>()
        for (index, line) in lines.enumerated() {
            guard let key = cancelledKey(line) else { continue }
            if let call = lines[..<index].indices.last(where: {
                !drop.contains($0) && requestID(lines[$0]).flatMap(requestKey) == key
            }) {
                drop.insert(call)
                drop.insert(index)
            }
        }
        return lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    /// One JSON-RPC error per request with an id; notifications get nothing.
    static func refusals(for lines: [String], message: String) -> [String] {
        lines.compactMap(requestID).compactMap { id in
            let reply: AppControlValue = .object(["jsonrpc": .string("2.0"), "id": id,
                                                  "error": .object(["code": .int(-32000), "message": .string(message)])])
            guard let data = try? JSONEncoder().encode(reply) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// A helper file verified as the replacement for the running build.
public struct HelperReplacement: Equatable {
    public let codeHashes: Set<Data>
    /// The file contains `MCPResumeState.environmentKey`: it resumes this envelope.
    public let resumesSession: Bool
    public init(codeHashes: Set<Data>, resumesSession: Bool) {
        self.codeHashes = codeHashes; self.resumesSession = resumesSession
    }
}

/// A private, verified copy of the replacement: the exact bytes that passed
/// validation are the bytes `execve` runs. It mirrors
/// `<App>.app/Contents/Helpers/whytap` with the app's `Info.plist`, so a build
/// that knows nothing of this (a rollback) still finds its app.
public struct StagedHelper: Equatable {
    public let executable: String
    public let directory: String
    public let replacement: HelperReplacement
    public init(executable: String, directory: String, replacement: HelperReplacement) {
        self.executable = executable; self.directory = directory; self.replacement = replacement
    }
}

public protocol HelperBuildIdentifying {
    /// The helper file now on disk, when it is a different build that passes
    /// whole-file code-signing validation against this helper's own designated
    /// requirement; nil otherwise (fail closed). Only decides whether to start.
    func verifiedReplacement() -> HelperReplacement?
    /// Copies the replacement into a private folder and verifies that copy the
    /// same way; nil when either step fails (the old image then stays).
    func stageReplacement() -> StagedHelper?
    /// Removes a staged copy that was not executed.
    func discard(_ staged: StagedHelper)
}

/// Verifies replacements of the helper at `executable` against the identity
/// this image was launched with. `captureBaseline()` reads the file's
/// designated requirement while the file is still the running code (the kernel
/// cdhash is among its validated cdhashes); without that baseline nothing is a
/// replacement. An ad-hoc helper's requirement is its own cdhash, so it never
/// accepts another build.
public final class SystemHelperBuildIdentity: HelperBuildIdentifying, @unchecked Sendable {
    public let executable: URL
    public let stagingRoot: URL
    private let lock = NSLock()
    private var requirement: SecRequirement?

    public init(executable: URL, stagingRoot: URL) { self.executable = executable; self.stagingRoot = stagingRoot }

    /// Off the handshake path: a host drops a server that answers late.
    public func captureBaselineInBackground() {
        DispatchQueue.global(qos: .utility).async { [self] in captureBaseline() }
    }

    @discardableResult
    public func captureBaseline() -> Bool {
        guard let running = Self.runningHash(),
              let code = Self.staticCode(executable),
              Self.validateWhole(code, requirement: nil),
              Self.hashes(of: code, url: executable, requirement: nil).contains(running) else { return false }
        var designated: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess, let designated else { return false }
        lock.withLock { requirement = designated }
        return true
    }

    public func verifiedReplacement() -> HelperReplacement? {
        verify(executable, contents: nil)
    }

    private func verify(_ url: URL, contents: Data?) -> HelperReplacement? {
        guard let requirement = lock.withLock({ requirement }),
              let running = Self.runningHash(),
              let code = Self.staticCode(url),
              Self.validateWhole(code, requirement: requirement) else { return nil }
        let hashes = Self.hashes(of: code, url: url, requirement: requirement)
        guard !hashes.isEmpty else { return nil }
        // The same build replaces this one only when this image lost its own
        // file: an update that swaps in byte-identical code unlinks the file
        // the process was started from, and the app's dynamic validity check
        // then denies it although the cdhash matches (seen 1760 -> 1761).
        // An intact image with the same cdhash is never re-executed (no loop).
        // WHY: .project-docs/decisions/2026-11-25-helper-follows-new-build.md
        if hashes.contains(running) && Self.runningCodeIntact() { return nil }
        guard let bytes = contents ?? (try? Data(contentsOf: url, options: .mappedIfSafe)) else { return nil }
        return HelperReplacement(codeHashes: hashes,
                                 resumesSession: bytes.range(of: Data(MCPResumeState.environmentKey.utf8)) != nil)
    }

    public func stageReplacement() -> StagedHelper? {
        let contents = executable.deletingLastPathComponent().deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard let bytes = try? Data(contentsOf: executable),
              let plist = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let directory = HelperStaging.makeDirectory(in: stagingRoot) else { return nil }
        let helpers = directory.appendingPathComponent(app.lastPathComponent)
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
        let copy = helpers.appendingPathComponent(executable.lastPathComponent)
        guard (try? FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])) != nil,
              HelperStaging.writeNew(plist, to: helpers.deletingLastPathComponent().appendingPathComponent("Info.plist"), mode: 0o400),
              HelperStaging.writeNew(bytes, to: copy, mode: 0o500),
              let replacement = verify(copy, contents: bytes) else {
            HelperStaging.remove(directory.path, root: stagingRoot)
            return nil
        }
        return StagedHelper(executable: copy.path, directory: directory.path, replacement: replacement)
    }

    public func discard(_ staged: StagedHelper) { HelperStaging.remove(staged.directory, root: stagingRoot) }

    /// The kernel's cdhash of the code this process runs. Security's signing
    /// information for `SecCodeCopySelf` is read from the file at the
    /// process's path, which after an update is already the new build (checked
    /// live on 2026-11-25), so it cannot tell the two apart.
    public static func runningHash() -> Data? {
        typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil } // RTLD_DEFAULT
        let csops = unsafeBitCast(symbol, to: CSOps.self)
        var hash = [UInt8](repeating: 0, count: 20) // CS_CDHASH_LEN
        let status = hash.withUnsafeMutableBytes { csops(getpid(), 5 /* CS_OPS_CDHASH */, $0.baseAddress, $0.count) }
        return status == 0 ? Data(hash) : nil
    }

    /// This process's executable path still resolves and its running code
    /// still validates against that file, as the app's broker requires.
    public static func runningCodeIntact() -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 else { return false }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// Every architecture, strict; a failure is final (no per-slice fallback).
    private static func validateWhole(_ code: SecStaticCode, requirement: SecRequirement?) -> Bool {
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// The whole file's cdhash and each slice's (a Rosetta process runs the
    /// x86_64 slice), only after the whole file validated.
    private static func hashes(of code: SecStaticCode, url: URL, requirement: SecRequirement?) -> Set<Data> {
        var hashes = Set<Data>()
        if let hash = hash(of: code) { hashes.insert(hash) }
        for architecture in ["arm64", "x86_64"] {
            let attributes = [kSecCodeAttributeArchitecture: architecture] as CFDictionary
            var slice: SecStaticCode?
            guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &slice) == errSecSuccess,
                  let slice, SecStaticCodeCheckValidity(slice, [], requirement) == errSecSuccess,
                  let hash = hash(of: slice) else { continue }
            hashes.insert(hash)
        }
        return hashes
    }

    private static func hash(of code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let hash = dict[kSecCodeInfoUnique as String] as? Data, !hash.isEmpty else { return nil }
        return hash
    }

}

/// Private copies of replacement helpers, one 0700 folder per handover under
/// a 0700 root this user owns, named `<pid>-…`. A process runs from its copy
/// for the rest of its life: the app identifies a helper through its
/// executable path (`proc_pidpath`), which fails once the file is gone. So a
/// copy is removed only after its process ended, or by the same process once
/// it runs from a newer copy. The root is in the app's Application Support
/// folder, which macOS does not clean like the temporary folder.
public enum HelperStaging {
    public static func root(bundleID: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("helper-handover", isDirectory: true)
    }

    static func makeDirectory(in root: URL) -> URL? {
        _ = mkdir(root.path, 0o700)
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return nil }
        var template = Array(root.appendingPathComponent("\(getpid())-XXXXXX").path.utf8CString)
        guard template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) != nil else { return nil }
        return URL(fileURLWithPath: String(cString: template), isDirectory: true)
    }

    /// O_EXCL | O_NOFOLLOW: a file only this call created.
    static func writeNew(_ data: Data, to url: URL, mode: mode_t) -> Bool {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var written = 0
        return data.withUnsafeBytes { raw -> Bool in
            while written < raw.count {
                let count = write(fd, raw.baseAddress! + written, raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }

    /// Removes a folder only when it is a direct child of `root`.
    public static func remove(_ path: String?, root: URL) {
        guard let path else { return }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.deletingLastPathComponent().path == root.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes the copies of ended processes and this process's older copies,
    /// keeping the one it runs from.
    public static func sweep(root: URL, keeping current: String?) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        var keep = Set([current].compactMap { $0.map { URL(fileURLWithPath: $0).standardizedFileURL.lastPathComponent } })
        // Never the folder this process's executable is in, whatever started it.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(getpid(), &path, UInt32(path.count)) > 0 {
            let components = URL(fileURLWithPath: String(cString: path)).standardizedFileURL.pathComponents
            let rootComponents = root.standardizedFileURL.pathComponents
            if components.count > rootComponents.count, Array(components.prefix(rootComponents.count)) == rootComponents {
                keep.insert(components[rootComponents.count])
            }
        }
        for name in names where !keep.contains(name) {
            guard let pid = name.split(separator: "-").first.flatMap({ pid_t($0) }), pid > 0 else { continue }
            let ended = kill(pid, 0) != 0 && errno == ESRCH
            if ended || pid == getpid() { remove(root.appendingPathComponent(name).path, root: root) }
        }
    }
}

/// Replaces the process image with `path` (a staged, verified copy). With a state, it travels through an
/// unlinked temporary file whose descriptor survives `execve`; the file is
/// unlinked before any request byte is written. Returns only when nothing was
/// executed, so the caller answers as before.
public enum HelperRelauncher {
    public static func exec(path: String, arguments: [String], state: MCPResumeState?) {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: MCPResumeState.environmentKey)
        var fd: Int32 = -1
        if let state {
            guard let payload = state.encoded() else { return }
            var template = Array((NSTemporaryDirectory() as NSString)
                .appendingPathComponent("whytap-mcp-resume.XXXXXX").utf8CString)
            fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
            guard fd >= 0 else { return }
            let unlinked = template.withUnsafeBufferPointer { unlink($0.baseAddress!) } == 0
            guard unlinked, write(all: payload, to: fd), lseek(fd, 0, SEEK_SET) == 0,
                  fcntl(fd, F_SETFD, 0) == 0 else {
                Darwin.close(fd); return
            }
            environment[MCPResumeState.environmentKey] = String(fd)
        }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(path, argv, envp)
        // Only reached when exec failed.
        argv.forEach { free($0) }; envp.forEach { free($0) }
        if fd >= 0 { Darwin.close(fd) }
    }

    private static func write(all data: Data, to fd: Int32) -> Bool {
        var written = 0
        return data.withUnsafeBytes { raw -> Bool in
            while written < raw.count {
                let count = Darwin.write(fd, raw.baseAddress! + written, raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
    }
}

/// Decides when a helper running an older build should hand over to the
/// helper file on disk, and keeps that from looping.
public final class MCPBuildHandover: @unchecked Sendable {
    public static let maxRelaunches = 3
    public static let relaunchWindow: TimeInterval = 120
    /// Lines that wait for a handover; beyond this it is abandoned.
    static let maxWaitingBytes = 8 * 1024 * 1024
    static let maxWaitingLines = 256

    public let resumed: MCPResumeState?
    private let identity: HelperBuildIdentifying
    /// Production: `HelperRelauncher.exec` of the staged copy, which returns
    /// only on failure. Tests return true to stand for an exec that replaced the image.
    private let relaunch: (StagedHelper, MCPResumeState?) -> Bool
    /// The installed helper path this session serves as.
    private let helperPath: String?
    private let now: () -> Date
    private let lock = NSLock()
    private var requested = false
    private var disabled = false
    private var staleOutsideCall = false
    private var relaunches: [Date]

    public init(identity: HelperBuildIdentifying, resumed: MCPResumeState?, helperPath: String? = nil,
                now: @escaping () -> Date = Date.init,
                relaunch: @escaping (StagedHelper, MCPResumeState?) -> Bool) {
        self.identity = identity; self.resumed = resumed; self.helperPath = helperPath
        self.now = now; self.relaunch = relaunch
        self.relaunches = resumed?.relaunches ?? []
    }

    /// True once a request found a newer valid build and no handover failed.
    public var isRequested: Bool { lock.withLock { requested && !disabled } }

    /// The access probe was denied as stale: the new image probes again.
    var probeWasStale: Bool { lock.withLock { staleOutsideCall } }

    // MARK: Calls

    final class CallMarks { var stale = false; var answered = false }
    private static let threadKey = "ai.whytap.mcp.handover.call"

    /// Runs one tool call and reports whether it may be replayed by the new
    /// image: it was denied as a stale helper and no broker request of it was
    /// answered otherwise (so the app applied nothing).
    func track<T>(_ body: () -> T) -> (T, replayable: Bool) {
        let marks = CallMarks()
        Thread.current.threadDictionary[Self.threadKey] = marks
        defer { Thread.current.threadDictionary.removeObject(forKey: Self.threadKey) }
        let value = body()
        return (value, marks.stale && !marks.answered && isRequested)
    }

    /// Called by `BuildFollowingBrokerClient` for every broker answer.
    func observe(_ response: CaseBrokerResponse) {
        let marks = Thread.current.threadDictionary[Self.threadKey] as? CallMarks
        guard case .denied(reason: .untrustedHelper) = response, shouldHandOver() else {
            marks?.answered = true
            return
        }
        lock.withLock {
            requested = true
            if let marks { marks.stale = true } else { staleOutsideCall = true }
        }
    }

    /// A request that may have reached the app (failed mid-exchange).
    func observeUncertain() {
        (Thread.current.threadDictionary[Self.threadKey] as? CallMarks)?.answered = true
    }

    private func budgetLeft() -> Bool {
        lock.withLock {
            guard !disabled else { return false }
            let since = now().addingTimeInterval(-Self.relaunchWindow)
            return relaunches.filter { $0 > since }.count < Self.maxRelaunches
        }
    }

    private func shouldHandOver() -> Bool {
        budgetLeft() && identity.verifiedReplacement() != nil
    }

    /// Stops following builds in this process; the caller answers everything.
    func abandon() { lock.withLock { disabled = true; requested = false } }

    enum Outcome: Equatable {
        /// A test relauncher stood in for exec: the server stops.
        case replaced
        /// Nothing was executed and nothing answered: the caller answers the
        /// held calls and restores the waiting bytes (handover now disabled).
        case answerHere
        /// Every carried complete request got an explicit answer; the caller
        /// restores these bytes (an unfinished frame). The handover stays
        /// requested when only that frame stopped the exec.
        case answered(restore: Data)
    }

    /// Stages and verifies a private copy right before exec, then replaces the
    /// process with exactly that copy. `held` are calls the app denied;
    /// `waiting` lines and `unread` bytes arrived after them. Runs with the
    /// server's gate held.
    func handOver(initialized: Bool, probed: Bool, held: [String], waiting: [String], unread: Data,
                  write: (String) -> Void) -> Outcome {
        guard isRequested, budgetLeft(), let staged = identity.stageReplacement() else {
            abandon(); return .answerHere
        }
        let split = MCPCarriedInput.split(unread)
        let lines = MCPCarriedInput.droppingCancelled(held + waiting + split.lines)
        let history: [Date] = lock.withLock {
            let since = now().addingTimeInterval(-Self.relaunchWindow)
            return relaunches.filter { $0 > since } + [now()]
        }
        if staged.replacement.resumesSession {
            let state = MCPResumeState(initialized: initialized, probed: probed && !probeWasStale,
                                       input: MCPCarriedInput.join(lines) + split.tail, relaunches: history,
                                       expectedCodeHashes: Array(staged.replacement.codeHashes),
                                       helperPath: helperPath, stagingDirectory: staged.directory)
            guard state.encoded() != nil else { identity.discard(staged); abandon(); return .answerHere }
            lock.withLock { relaunches = history }
            if relaunch(staged, state) { return .replaced }
            identity.discard(staged)
            abandon()
            return .answerHere
        }
        // A build without this protocol (a rollback) starts a fresh session on
        // the same stdio. Every complete request gets its answer now; the exec
        // waits until no half-written request would be cut in two.
        MCPCarriedInput.refusals(for: lines, message: MCPCarriedInput.retryMessage).forEach(write)
        guard split.tail.isEmpty else {
            identity.discard(staged)
            return .answered(restore: split.tail)
        }
        lock.withLock { relaunches = history }
        if relaunch(staged, nil) { return .replaced }
        identity.discard(staged)
        abandon()
        return .answered(restore: Data())
    }
}

/// Reports every broker answer to the handover. Wraps the MCP server's
/// clients only; one-shot commands start from the current file anyway.
public final class BuildFollowingBrokerClient: CancellableCaseBrokerCalling {
    private let inner: CaseBrokerCalling
    private let handover: MCPBuildHandover

    public init(inner: CaseBrokerCalling, handover: MCPBuildHandover) {
        self.inner = inner; self.handover = handover
    }

    public func send(_ request: CaseBrokerRequest) throws -> CaseBrokerResponse {
        try send(request, cancellation: nil)
    }

    public func send(_ request: CaseBrokerRequest, cancellation: AppControlCancellation?) throws -> CaseBrokerResponse {
        do {
            let response: CaseBrokerResponse
            if let inner = inner as? CancellableCaseBrokerCalling {
                response = try inner.send(request, cancellation: cancellation)
            } else { response = try inner.send(request) }
            handover.observe(response)
            return response
        } catch CaseBrokerClientError.unavailable {
            throw CaseBrokerClientError.unavailable // nothing was sent
        } catch {
            handover.observeUncertain()
            throw error
        }
    }
}

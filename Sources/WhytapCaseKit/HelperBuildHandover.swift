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
    public static let environmentKey = "WHYTAP_MCP_RESUME_FD"
    public static let currentVersion = 1
    static let maxBytes = 64 * 1024 * 1024

    public var version: Int
    public var initialized: Bool
    public var probed: Bool
    public var input: Data
    /// Earlier relaunches of this process (the loop budget survives exec).
    public var relaunches: [Date]

    public init(initialized: Bool, probed: Bool, input: Data, relaunches: [Date]) {
        self.version = Self.currentVersion
        self.initialized = initialized; self.probed = probed
        self.input = input; self.relaunches = relaunches
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
              info.st_size >= 0, info.st_size <= maxBytes else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        _ = lseek(fd, 0, SEEK_SET)
        while data.count <= maxBytes {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 { data.append(contentsOf: chunk[0..<count]) }
            else if count < 0 && errno == EINTR { continue }
            else { break }
        }
        guard let state = try? JSONDecoder().decode(Self.self, from: data),
              state.version == currentVersion else { return nil }
        return state
    }
}

/// Whether the helper file on disk is a different, valid build than the code
/// this process is running.
public protocol HelperBuildIdentifying {
    func newBuildAvailable() -> Bool
}

/// Compares this process's running cdhash with the cdhashes of the validly
/// signed helper at `executable`, the same comparison the app's broker makes
/// (`CaseSystemProcessInspector.isTrustedHelper`). An invalid, missing or
/// unsigned file is never "new": the helper then answers as before.
public struct SystemHelperBuildIdentity: HelperBuildIdentifying {
    public let executable: URL
    public init(executable: URL) { self.executable = executable }

    public func newBuildAvailable() -> Bool {
        guard let running = Self.runningHash(), !running.isEmpty else { return false }
        let onDisk = Self.validHashes(of: executable)
        return !onDisk.isEmpty && !onDisk.contains(running)
    }

    /// The kernel's cdhash of the code this process runs. Security's signing
    /// information for `SecCodeCopySelf` is read from the file at the
    /// process's path, which after an update is already the new build (checked
    /// live on 2026-11-25), so it cannot tell the two apart.
    static func runningHash() -> Data? {
        typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil } // RTLD_DEFAULT
        let csops = unsafeBitCast(symbol, to: CSOps.self)
        var hash = [UInt8](repeating: 0, count: 20) // CS_CDHASH_LEN
        let status = hash.withUnsafeMutableBytes { csops(getpid(), 5 /* CS_OPS_CDHASH */, $0.baseAddress, $0.count) }
        return status == 0 ? Data(hash) : nil
    }

    static func validHashes(of url: URL) -> Set<Data> {
        var hashes = Set<Data>()
        var whole: SecStaticCode?
        if SecStaticCodeCreateWithPath(url as CFURL, [], &whole) == errSecSuccess, let whole,
           SecStaticCodeCheckValidity(whole, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess,
           let hash = hash(of: whole), !hash.isEmpty {
            hashes.insert(hash)
        }
        for architecture in ["arm64", "x86_64"] {
            let attributes = [kSecCodeAttributeArchitecture: architecture] as CFDictionary
            var slice: SecStaticCode?
            guard SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attributes, &slice) == errSecSuccess,
                  let slice, SecStaticCodeCheckValidity(slice, [], nil) == errSecSuccess,
                  let hash = hash(of: slice), !hash.isEmpty else { continue }
            hashes.insert(hash)
        }
        return hashes
    }

    private static func hash(of code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }
}

/// Replaces the process image with `path`, passing `state` through an
/// unlinked temporary file whose descriptor survives `execve`. Returns only
/// when the exec failed; the caller then answers as before.
public enum HelperRelauncher {
    public static func exec(path: String, arguments: [String], state: MCPResumeState) {
        guard let payload = try? JSONEncoder().encode(state) else { return }
        var template = Array((NSTemporaryDirectory() as NSString)
            .appendingPathComponent("whytap-mcp-resume.XXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { return }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        var written = 0
        let complete = payload.withUnsafeBytes { raw -> Bool in
            while written < raw.count {
                let count = write(fd, raw.baseAddress! + written, raw.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                written += count
            }
            return true
        }
        guard complete, lseek(fd, 0, SEEK_SET) == 0, fcntl(fd, F_SETFD, 0) == 0 else {
            Darwin.close(fd); return
        }
        var environment = ProcessInfo.processInfo.environment
        environment[MCPResumeState.environmentKey] = String(fd)
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        execve(path, argv, envp)
        // Only reached when exec failed.
        argv.forEach { free($0) }; envp.forEach { free($0) }
        Darwin.close(fd)
    }
}

/// Decides when a helper running an older build should hand over to the
/// helper file on disk, and keeps that from looping.
public final class MCPBuildHandover: @unchecked Sendable {
    public static let maxRelaunches = 3
    public static let relaunchWindow: TimeInterval = 120

    public let resumed: MCPResumeState?
    private let identity: HelperBuildIdentifying
    /// Production: `HelperRelauncher.exec`, which returns only on failure.
    /// Tests return true to stand for an exec that replaced the image.
    private let relaunch: (MCPResumeState) -> Bool
    private let now: () -> Date
    private let lock = NSLock()
    private var requested = false
    private var disabled = false
    private var staleOutsideCall = false
    private var relaunches: [Date]

    public init(identity: HelperBuildIdentifying, resumed: MCPResumeState?,
                now: @escaping () -> Date = Date.init,
                relaunch: @escaping (MCPResumeState) -> Bool) {
        self.identity = identity; self.resumed = resumed
        self.now = now; self.relaunch = relaunch
        self.relaunches = resumed?.relaunches ?? []
    }

    /// True once a request found a newer valid build and no handover failed.
    public var isRequested: Bool { lock.withLock { requested && !disabled } }

    /// The access probe was denied as stale outside any call: the new image
    /// probes again instead of trusting the old image's flag.
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

    private func shouldHandOver() -> Bool {
        let recent = lock.withLock { () -> Int? in
            guard !disabled else { return nil }
            let since = now().addingTimeInterval(-Self.relaunchWindow)
            return relaunches.filter { $0 > since }.count
        }
        guard let recent, recent < Self.maxRelaunches else { return false }
        return identity.newBuildAvailable()
    }

    /// Replaces this process with the new build. Returns true only when a
    /// test relauncher stands in for a successful exec. On failure handover is
    /// disabled for this process and the caller answers as before.
    func handOver(initialized: Bool, probed: Bool, input: Data) -> Bool {
        let state: MCPResumeState? = lock.withLock {
            guard requested, !disabled else { return nil }
            let since = now().addingTimeInterval(-Self.relaunchWindow)
            relaunches = relaunches.filter { $0 > since } + [now()]
            return MCPResumeState(initialized: initialized, probed: probed && !staleOutsideCall,
                                  input: input, relaunches: relaunches)
        }
        guard let state else { return false }
        if relaunch(state) { return true }
        lock.withLock { disabled = true; requested = false }
        return false
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

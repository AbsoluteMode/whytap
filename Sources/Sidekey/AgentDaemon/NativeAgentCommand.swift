import Darwin
import Foundation

/// A separate process group bounds ordinary jobs. A detached child can leave
/// that group: never wait indefinitely for its inherited output descriptor.
final class NativeAgentCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let output = Pipe()
    private let gate = Pipe()
    private var pid: pid_t = 0
    private var data = Data()
    private var continuation: CheckedContinuation<String, Never>?
    private var finished = false
    private var interrupted = false
    private var truncated = false
    private var outputEnded = false
    private var exitSuffix: String?

    /// What a command sees. An app opened from Finder has no `LANG`, and
    /// without a UTF-8 locale `pbcopy`, `wc` and the like read text as
    /// MacRoman: a copied file arrived with every non-ASCII letter broken.
    /// The app's own locale is kept only when this Mac really has it as a
    /// UTF-8 locale; a name macOS does not know (`ja_JP.utf8`, a locale that
    /// is not installed) silently behaves as C, so it becomes en_US.UTF-8.
    // WHY: .project-docs/decisions/2026-11-20-agent-command-utf8-locale.md
    static func childEnvironment(
        from base: [String: String], helper: URL?,
        localeIsInstalled: (String) -> Bool = NativeAgentCommand.localeIsInstalled
    ) -> [String: String] {
        var environment = base.filter { ["HOME", "USER", "LOGNAME", "TMPDIR"].contains($0.key) }
        let inherited = base["LANG"] ?? ""
        environment["LANG"] = inherited.hasSuffix(".UTF-8") && localeIsInstalled(inherited) ? inherited : fallbackLocale
        environment["PATH"] = ([helper?.deletingLastPathComponent().path].compactMap { $0 }
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        return environment
    }

    static let fallbackLocale = "en_US.UTF-8"

    /// macOS resolves a locale name to this directory; a missing one is C.
    static func localeIsInstalled(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-@"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains), !name.hasPrefix(".") else { return false }
        return FileManager.default.fileExists(atPath: "/usr/share/locale/\(name)/LC_CTYPE")
    }

    func run(command: String, directory: URL, helper: URL?, timeout: Duration = .seconds(30),
             baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) async -> String {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                if Task.isCancelled { finish("Command cancelled."); return }
                let environment = Self.childEnvironment(from: baseEnvironment, helper: helper)
                let readFD = output.fileHandleForReading.fileDescriptor
                _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
                output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    guard let self else { return }
                    var ended = false
                    let suffix: String? = self.lock.withLock {
                        guard !self.finished else { return nil }
                        // FileHandle.read(upToCount:) can wait for a full chunk
                        // while a detached child holds the pipe open. One
                        // nonblocking read preserves bytes already available.
                        // The lock prevents a late read after finish closes FD.
                        var bytes = [UInt8](repeating: 0, count: 8192)
                        var count: Int
                        repeat { count = Darwin.read(readFD, &bytes, bytes.count) } while count < 0 && errno == EINTR
                        guard count >= 0 else { return nil }
                        if count == 0 {
                            self.outputEnded = true; ended = true
                            return self.exitSuffix
                        }
                        let room = max(0, 32_000 - self.data.count)
                        self.data.append(contentsOf: bytes.prefix(min(room, count)))
                        self.truncated = self.truncated || count > room
                        return nil
                    }
                    if ended { handle.readabilityHandler = nil }
                    if let suffix { self.finish(suffix) }
                }
                do {
                    let child = try spawn(command: command, directory: directory, environment: environment)
                    let mayStart = lock.withLock {
                        pid = child
                        if interrupted || finished { kill(-child, SIGKILL); return false }
                        return true
                    }
                    if mayStart { try? gate.fileHandleForWriting.write(contentsOf: Data("start\n".utf8)) }
                    try? gate.fileHandleForWriting.close()
                    try? gate.fileHandleForReading.close()
                    try? output.fileHandleForWriting.close()
                    DispatchQueue.global().async { [self] in
                        // Observe exit without reaping: retaining the leader PID
                        // prevents its group ID being reused before descendant cleanup.
                        var info = siginfo_t()
                        while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
                        let suffix = lock.withLock {
                            // Hold the lock across reap, so a stop callback
                            // cannot signal a newly reused process ID.
                            kill(-child, SIGKILL)
                            var status: Int32 = 0
                            var reaped: pid_t
                            repeat { reaped = waitpid(child, &status, 0) } while reaped == -1 && errno == EINTR
                            pid = 0
                            let signal = status & 0x7f
                            let text = interrupted ? "\n[Command stopped]"
                                : reaped == -1 ? "\n[Command exit status unavailable]"
                                : signal == 0 ? "\n[Exit \((status >> 8) & 0xff)]" : "\n[Terminated by signal \(signal)]"
                            exitSuffix = text
                            return outputEnded ? text : nil
                        }
                        if let suffix { finish(suffix) }
                        else {
                            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [weak self] in
                                guard let self else { return }
                                let cancelled = self.lock.withLock { self.interrupted }
                                self.finish(cancelled
                                    ? "\n[Command stopped waiting; output did not close. Detached child processes may still be running.]"
                                    : "\n[Command incomplete: output did not close after the shell exited. Stopped waiting; detached child processes may still be running.]")
                            }
                        }
                    }
                    Task { [weak self] in
                        try? await Task.sleep(for: timeout)
                        self?.stop()
                    }
                } catch { finish("Couldn’t start this command.") }
            }
        } onCancel: { self.stop() }
    }

    private func spawn(command: String, directory: URL, environment: [String: String]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, gate.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        guard posix_spawn_file_actions_addchdir_np(&actions, directory.path) == 0 else { throw CocoaError(.fileNoSuchFile) }
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        for handle in [gate.fileHandleForReading, gate.fileHandleForWriting, output.fileHandleForReading, output.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        _ = fcntl(gate.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let arguments = ["/bin/sh", "-c", "read -r _whytap_start || exit 125\n" + command].map { $0.withCString { strdup($0) } } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { arguments.forEach { free($0) }; variables.forEach { free($0) } }
        var child: pid_t = 0
        let result = arguments.withUnsafeBufferPointer { argv in
            variables.withUnsafeBufferPointer { envp in
                posix_spawn(&child, "/bin/sh", &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!), UnsafeMutablePointer(mutating: envp.baseAddress!))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        return child
    }

    private func stop() {
        let child: pid_t? = lock.withLock {
            guard !finished else { return nil }
            interrupted = true
            if pid > 0 { kill(-pid, SIGTERM); return pid }
            return nil
        }
        guard let child else {
            finish("\n[Command stopped waiting. Detached child processes may still be running.]")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // The wait handler owns reaping; do not signal after it has finished.
            self.lock.withLock { if self.pid == child { kill(-child, SIGKILL) } }
            self.finish("\n[Command stopped waiting; its process group was signalled. Detached child processes may still be running.]")
        }
    }

    private func finish(_ suffix: String) {
        let result: (CheckedContinuation<String, Never>, String)? = lock.withLock {
            guard !finished, let continuation else { return nil }
            finished = true; self.continuation = nil
            return (continuation, String(decoding: data, as: UTF8.self) + (truncated ? "\n[Output shortened]" : "") + suffix)
        }
        guard let result else { return }
        output.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        result.0.resume(returning: result.1)
    }
}

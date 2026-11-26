import Darwin
import Foundation

/// One local MCP server process (stdio transport).
///
/// Hosted the way `NotifyProcess` hosts notification scripts: an absolute
/// executable, its own process group led by a Perl parent-death guard, so the
/// whole group ends when Whytap quits, crashes or is killed. Differences: the
/// server's stdin is our request pipe (the guard's lifeline moves to fd 3),
/// and stderr is kept as a small in-memory tail for a readable exit reason.
/// No shell: argv is passed to exec as is. Secrets reach the server only in
/// `environment`. WHY: .project-docs/decisions/2026-11-26-agent-sources.md
final class MCPProcess: @unchecked Sendable {
    /// Parent-death guard (see `NotifyProcess.parentWatchGuardScript`), with
    /// the lifeline on fd 3 so stdin can carry JSON-RPC to the server.
    static let guardScript = """
        use POSIX ();
        my $pid;
        sub reap {
          return unless $pid && waitpid($pid, POSIX::WNOHANG()) == $pid;
          my $s = $?;
          POSIX::_exit(($s & 127) ? 128 + ($s & 127) : ($s >> 8));
        }
        $SIG{CHLD} = sub { reap() };
        open(my $life, '<&=', 3) or POSIX::_exit(125);
        $pid = fork();
        POSIX::_exit(126) unless defined $pid;
        if ($pid == 0) {
          $SIG{CHLD} = 'DEFAULT';
          close($life);
          POSIX::close(3);
          exec { $ARGV[0] } @ARGV or POSIX::_exit(127);
        }
        open(STDIN, '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        reap();
        my $buf;
        while (1) {
          my $n = sysread($life, $buf, 4096);
          last if defined $n && $n == 0;
          next if defined $n;
          last unless $!{EINTR};
        }
        $SIG{CHLD} = 'DEFAULT';
        $SIG{TERM} = 'IGNORE';
        my $group = getpgrp();
        kill('-TERM', $group);
        for (1 .. 20) {
          last if waitpid($pid, POSIX::WNOHANG()) != 0;
          select(undef, undef, undef, 0.05);
        }
        kill('-KILL', $group);
        POSIX::_exit(0);
        """

    /// One JSON-RPC message per line; a longer line ends the server.
    static let maxLineBytes = 16 * 1_048_576

    let pid: pid_t
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private let lifeline: Int32
    private let lock = NSLock()
    private var lifelineOpen = true
    private var stdinOpen = true
    private var exited = false
    private var stopping = false
    private var stderrTail = Data()
    private var overflowed = false
    private let writeQueue = DispatchQueue(label: "com.rootwise.sidekey.mcp.stdin")
    private let finished = DispatchGroup()

    /// - Parameters:
    ///   - onLine: each complete stdout line, in order, on a background queue.
    ///   - onExit: once, after stdout is drained: exit status and the last
    ///     stderr line (unmasked; the caller masks secrets), or `tooLarge`.
    init(executable: String, arguments: [String], environment: [String: String], directory: URL? = nil,
         onLine: @escaping @Sendable (Data) -> Void,
         onExit: @escaping @Sendable (Int32, String?, Bool) -> Void) throws {
        var info = stat()
        guard executable.hasPrefix("/"), stat(executable, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, access(executable, X_OK) == 0 else {
            throw MCPError.commandNotFound((executable as NSString).lastPathComponent)
        }
        func makePipe() throws -> [Int32] {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw MCPError.notConnected }
            return fds
        }
        let input = try makePipe(), output = try makePipe(), errors = try makePipe(), life = try makePipe()
        // Only this process may hold the write/read ends we keep.
        for fd in [input[1], output[0], errors[0], life[1]] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // A server that exits mid-write must not SIGPIPE the app.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        // Writes wait with a deadline (poll) instead of blocking.
        _ = fcntl(input[1], F_SETFL, fcntl(input[1], F_GETFL) | O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignalsBlocked = sigset_t()
        sigemptyset(&noSignalsBlocked)
        posix_spawnattr_setsigmask(&attributes, &noSignalsBlocked)
        posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        posix_spawn_file_actions_adddup2(&actions, life[0], 3)
        if let directory { posix_spawn_file_actions_addchdir_np(&actions, directory.path) }
        var argv = (["/usr/bin/perl", "-e", Self.guardScript, "--", executable] + arguments).map { strdup($0) } + [nil]
        var env = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; env.forEach { free($0) } }
        var child: pid_t = 0
        let result = posix_spawn(&child, "/usr/bin/perl", &actions, &attributes, &argv, &env)
        for fd in [input[0], output[1], errors[1], life[0]] { close(fd) }
        guard result == 0 else {
            for fd in [input[1], output[0], errors[0], life[1]] { close(fd) }
            throw MCPError.commandNotFound((executable as NSString).lastPathComponent)
        }
        pid = child
        stdinFD = input[1]; stdoutFD = output[0]; stderrFD = errors[0]; lifeline = life[1]

        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { readers.leave() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var line = Data()
            reading: while true {
                let count = Darwin.read(stdoutFD, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                var start = 0
                for index in 0..<count where buffer[index] == 10 {
                    // The limit holds for every complete line, before it is delivered.
                    guard line.count + (index - start) <= Self.maxLineBytes else {
                        lock.lock(); overflowed = true; lock.unlock(); stop(); break reading
                    }
                    line.append(contentsOf: buffer[start..<index])
                    if !line.isEmpty { onLine(line) }
                    line.removeAll(keepingCapacity: true)
                    start = index + 1
                }
                guard line.count + (count - start) <= Self.maxLineBytes else {
                    lock.lock(); overflowed = true; lock.unlock(); stop(); break
                }
                line.append(contentsOf: buffer[start..<count])
            }
            lock.lock(); let overflow = overflowed; lock.unlock()
            if !overflow, !line.isEmpty { onLine(line) }
            close(stdoutFD)
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { readers.leave() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(stderrFD, &buffer, buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                lock.lock()
                stderrTail.append(contentsOf: buffer[0..<count])
                if stderrTail.count > 4096 { stderrTail = stderrTail.suffix(4096) }
                lock.unlock()
            }
            close(stderrFD)
        }
        finished.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            // The group leader stays a zombie until helper cleanup completes,
            // so a delayed kill cannot hit a reused process group.
            var info = siginfo_t()
            while waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            kill(-child, SIGTERM)
            usleep(300_000)
            lock.lock()
            kill(-child, SIGKILL)
            var status: Int32 = 0
            while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            exited = true
            lock.unlock()
            closeLifeline()
            closeInput()
            _ = readers.wait(timeout: .now() + 2)
            let code: Int32 = (status & 0x7f) != 0 ? 128 + (status & 0x7f) : (status >> 8) & 0xff
            lock.lock(); let overflow = overflowed; lock.unlock()
            onExit(code, lastStderrLine(), overflow)
            finished.leave()
        }
    }

    /// Largest message Whytap sends to a server.
    static let maxWriteBytes = 1_048_576

    /// Writes one message and a newline within `timeout`: a server that stops
    /// reading its input is stopped instead of blocking the app.
    func write(_ data: Data, timeout: TimeInterval = 10) throws {
        guard data.count < Self.maxWriteBytes else { throw MCPError.tooLarge(limit: Self.maxWriteBytes) }
        var payload = data
        payload.append(10)
        let deadline = Date().addingTimeInterval(timeout)
        try writeQueue.sync {
            lock.lock()
            let open = stdinOpen
            lock.unlock()
            guard open else { throw MCPError.notConnected }
            try payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(stdinFD, raw.baseAddress! + offset, raw.count - offset)
                    if written >= 0 { offset += written; continue }
                    if errno == EINTR { continue }
                    guard errno == EAGAIN else { throw MCPError.notConnected }
                    let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
                    guard remaining > 0 else { stop(); throw MCPError.timedOut(seconds: Int(timeout.rounded())) }
                    var descriptor = pollfd(fd: stdinFD, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&descriptor, 1, min(remaining, 250))
                }
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        stopping = true
        let alive = !exited
        if alive { kill(-pid, SIGTERM) }
        lock.unlock()
        closeInput()
        if alive {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
                lock.lock()
                if !exited { kill(-pid, SIGKILL) }
                lock.unlock()
            }
        }
    }

    /// What the kernel does when the app dies; exposed for tests.
    func closeLifeline() {
        lock.lock(); defer { lock.unlock() }
        guard lifelineOpen else { return }
        lifelineOpen = false
        close(lifeline)
    }

    func waitUntilStopped(timeout: TimeInterval = 2) { _ = finished.wait(timeout: .now() + timeout) }

    private func closeInput() {
        writeQueue.async { [self] in
            lock.lock(); defer { lock.unlock() }
            guard stdinOpen else { return }
            stdinOpen = false
            close(stdinFD)
        }
    }

    private func lastStderrLine() -> String? {
        lock.lock(); let tail = stderrTail; lock.unlock()
        let lines = String(decoding: tail, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last.map { String($0.prefix(200)) }
    }
}

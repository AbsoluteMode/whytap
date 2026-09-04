import Foundation
import os.log

struct ProcessResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

protocol ClaudeStdinWriting: AnyObject {
    func writeLine(_ line: String)
    func closeStdin()
    /// SIGTERM the live child + close stdin. Wired to the AsyncStream's
    /// `onTermination` so cancelling the consumer (Esc / panel dismiss / new
    /// turn / app quit -> stop()) never orphans the CLI. Safe to call after the
    /// process already exited (guarded on `isRunning`) and safe to call twice.
    func terminate()
    /// PID of the live child, or nil for fakes / already-reaped. Read by the
    /// idle watchdog to snapshot TCC attribution on a soft-trigger.
    var processIdentifier: Int32? { get }
}

/// Serializes writes to the live process stdin (prompt + control_responses)
/// and owns SIGTERM for the spawned child.
///
/// Retaining the `Process` here (not just the stdin FileHandle) is what lets
/// `terminate()` actually stop the CLI: before this, NO code path ever
/// terminated a spawned `claude`, so a cancelled turn (Esc / dismiss / new
/// turn / quit) left it running headless — burning the user's subscription and,
/// under `--permission-mode acceptEdits`, still editing files with no UI.
final class StdinPipeWriter: ClaudeStdinWriting {
    private let handle: FileHandle
    /// The spawned child. Weak/strong does not matter for liveness (Process
    /// keeps itself alive while running); held strong so `terminate()` can
    /// signal it for the whole turn. Nil for fakes that have no real process.
    private let process: Process?
    private let queue = DispatchQueue(label: "com.sidekey.claudeprovider.stdin")
    private var closed = false
    init(_ handle: FileHandle, process: Process? = nil) {
        self.handle = handle
        self.process = process
    }
    func writeLine(_ line: String) {
        queue.async {
            guard !self.closed, let data = (line + "\n").data(using: .utf8) else { return }
            try? self.handle.write(contentsOf: data)
        }
    }
    func closeStdin() {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            try? self.handle.close()
        }
    }
    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }
    func terminate() {
        // Close stdin (async on the writer queue — the synchronous SIGTERM
        // below typically lands first; ordering is NOT guaranteed and does not
        // matter). The EOF is redundant insurance for a child blocked on a
        // stdin read (waiting for a control_response that will never come).
        closeStdin()
        // `isRunning` guards the already-exited case: Process.terminate()
        // raises if the receiver was never launched or already reaped. The
        // terminationHandler still fires on the natural-exit path, so pipe
        // teardown is not skipped by guarding here.
        // SIGTERM-only by design: claude exits promptly on it — no SIGKILL
        // escalation watchdog (fire-and-forget; the OS reaps on app exit).
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

final class ClaudeCodeProvider: CLIProvider {
    static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "agent.cli")

    let id: CLIProviderID = .claude
    let displayName = "Claude Code"
    let installURL = URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!

    private let locate: () -> URL?
    private let runOneShot: (_ binary: URL, _ args: [String]) -> ProcessResult?
    private let runStreaming: (
        _ binary: URL,
        _ args: [String],
        _ workingDir: URL?,
        _ onLine: @escaping (String) -> Void,
        _ onExit: @escaping (Int32) -> Void
    ) -> ClaudeStdinWriting
    private let idleSoftTimeout: TimeInterval
    private let idleHardTimeout: TimeInterval

    /// Serial queue that serializes all `lastSessionID` and `activeHandle`
    /// writes so they are safe even when the streaming callback fires off the
    /// main thread.
    private let sessionQueue = DispatchQueue(label: "com.sidekey.claudeprovider.session")

    /// The session_id from the last completed run(). The AgentController reads
    /// this after each turn and passes it as resumeSessionID for continuity.
    ///
    /// Both reads and writes go through `sessionQueue`. Finishing the
    /// AsyncStream does NOT synchronize with a write posted by
    /// `sessionQueue.async`, so an unsynchronized read could miss the id and
    /// silently drop `--resume` for the next turn.
    /// WHY: docs/decisions/2026-09-04-session-id-read-through-serial-queue.md
    var lastSessionID: String? {
        sessionQueue.sync { _lastSessionID }
    }

    /// Backing storage for `lastSessionID`. Touch only inside `sessionQueue`.
    private var _lastSessionID: String?

    /// The writable stdin handle for the currently-running process.
    /// Guarded by `sessionQueue`, like `lastSessionID`.
    private var activeHandle: ClaudeStdinWriting?

    init(
        locate: @escaping () -> URL? = { ClaudeBinaryLocator().locate() },
        runOneShot: @escaping (_ binary: URL, _ args: [String]) -> ProcessResult? = ClaudeCodeProvider.defaultRunOneShot,
        runStreaming: @escaping (
            _ binary: URL,
            _ args: [String],
            _ workingDir: URL?,
            _ onLine: @escaping (String) -> Void,
            _ onExit: @escaping (Int32) -> Void
        ) -> ClaudeStdinWriting = ClaudeCodeProvider.defaultRunStreaming,
        idleSoftTimeout: TimeInterval = 45,
        idleHardTimeout: TimeInterval = 120
    ) {
        self.locate = locate
        self.runOneShot = runOneShot
        self.runStreaming = runStreaming
        self.idleSoftTimeout = idleSoftTimeout
        self.idleHardTimeout = idleHardTimeout
    }

    func discoverBinary() -> URL? { locate() }

    func probe() async -> ConnectOutcome {
        guard let binary = locate() else {
            os_log("claude probe: binary not found", log: Self.log, type: .error)
            return .notInstalled
        }
        // Lightweight handshake: read the stored auth status. Unlike `claude -p`,
        // this makes NO model call -> it never bills tokens, returns in ~3s, and
        // is immune to ambient ANTHROPIC_* credentials. (Verified: `auth status`
        // reports the real claude.ai login even with a bogus ANTHROPIC_AUTH_TOKEN
        // in the environment. A `-p` round-trip, by contrast, authenticates with
        // that env token and fails when it is a stale/inherited one.) `--json` is
        // the default but we pass it explicitly to pin the output contract.
        let args = ["auth", "status", "--json"]
        os_log("claude probe: spawning %{public}@ auth status", log: Self.log, type: .default, binary.path)
        guard let result = runOneShot(binary, args) else {
            os_log("claude probe: runOneShot returned nil", log: Self.log, type: .error)
            return .notInstalled
        }
        os_log("claude probe: exit=%{public}d stdout_chars=%{public}d stderr_chars=%{public}d",
               log: Self.log, type: .default, result.exitCode, result.stdout.count, result.stderr.count)

        if let outcome = Self.parseAuthStatus(result.stdout) {
            return outcome
        }
        // Output wasn't the expected JSON -> fall back to the exit code.
        if result.exitCode == 0 { return .connected(sessionID: nil) }
        return .failed(
            code: "exit_\(result.exitCode)",
            message: result.stderr.isEmpty ? "Probe failed" : result.stderr
        )
    }

    /// Parse `claude auth status --json`:
    /// `{ "loggedIn": Bool, "authMethod": String, "subscriptionType": String, ... }`.
    /// Returns nil when the output isn't the expected object, so the caller can
    /// fall back to the process exit code.
    static func parseAuthStatus(_ stdout: String) -> ConnectOutcome? {
        guard let data = stdout.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let loggedIn = obj["loggedIn"] as? Bool else { return nil }
        return loggedIn ? .connected(sessionID: nil) : .notLoggedIn
    }

    /// The environment handed to every spawned `claude` (probe and run alike).
    /// Strips two families:
    /// - Claude Code process markers (CLAUDECODE / CLAUDE_CODE_* / CLAUDE_AGENT_*)
    ///   so claude never thinks it is nested inside another session and aborts;
    /// - ambient Anthropic credentials (ANTHROPIC_API_KEY / _AUTH_TOKEN /
    ///   _BASE_URL / _CUSTOM_HEADERS) so claude authenticates with the user's own
    ///   subscription login (keychain OAuth), never a stray key or proxy URL from
    ///   the launching environment.
    /// In production these are all absent; this matters when the app is launched
    /// from a developer's Claude Code session, and is correct hardening regardless.
    static func childEnvironment(
        from parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        scrubbingAnthropicAndClaudeVars(from: parent)
    }

    /// Drops the Claude Code nesting markers + ambient Anthropic credentials
    /// from `parent`. Factored out of `childEnvironment` so `CodexProvider`
    /// can reuse the exact same Anthropic/Claude carve-out (a dev session
    /// launched from Claude Code must not leak these into codex either).
    static func scrubbingAnthropicAndClaudeVars(
        from parent: [String: String]
    ) -> [String: String] {
        var env = parent
        let exactDrops = [
            "CLAUDECODE",
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "ANTHROPIC_BASE_URL",
            "ANTHROPIC_CUSTOM_HEADERS",
        ]
        for key in exactDrops { env.removeValue(forKey: key) }
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    func run(prompt: String, resumeSessionID: String?, options: AgentRunOptions) -> AsyncStream<AgentSSEEvent> {
        AsyncStream { continuation in
            guard let binary = locate() else {
                continuation.yield(.error(
                    code: "not_installed",
                    message: "Claude Code is not installed",
                    retryable: false
                ))
                continuation.yield(.done(sources: []))
                continuation.finish()
                return
            }

            var args: [String] = [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                // Skip-permission mode (testing phase): bypass every permission
                // check so the agent auto-runs all actions without prompting.
                // The stdio permission-prompt protocol is intentionally NOT
                // registered — there is no UI to answer it yet (the in-island
                // approval bar is a deferred follow-up). The parser +
                // respondToPermission machinery stays for that future bar.
                // Users are told about this at connect time (AgentModeView).
                "--permission-mode", "bypassPermissions",
            ]
            if let sid = resumeSessionID {
                args += ["--resume", sid]
            }
            if let model = options.model { args += ["--model", model] }
            if let effort = options.effort { args += ["--effort", effort] }

            continuation.yield(.started(
                turnId: UUID().uuidString,
                requestId: "",
                sessionId: resumeSessionID ?? ""
            ))

            let workingDir = try? AgentDaemonWorkingDirectory.ensure()
            var resultSeen = false
            let registry = ClaudeTaskRegistry()

            // Best-effort kick reference: assigned once after runStreaming returns,
            // but read via watchdog?.kick() on bufferQueue. A sub-µs window exists
            // where a very early first stdout line reads nil and drops one kick —
            // harmless (worst case the watchdog fires slightly early). Constructing
            // it before runStreaming would just trade this for a handle-capture
            // race, so leave the order as-is.
            var watchdog: ProcessIdleWatchdog?

            let handle = runStreaming(binary, args, workingDir, { [weak self] line in
                watchdog?.kick()   // any stdout = alive
                for event in StreamJSONParser.parse(line: line) {
                    if case .initSession(let sid) = event {
                        self?.sessionQueue.async { self?._lastSessionID = sid }
                    }
                    if case .result(let sid?, _, _, _) = event {
                        self?.sessionQueue.async { self?._lastSessionID = sid }
                    }
                    if case .result = event {
                        resultSeen = true
                        self?.sessionQueue.async { self?.activeHandle?.closeStdin() }
                    }
                    registry.observe(event)
                    for mapped in ClaudeEventMapper.map(event, registry: registry) {
                        continuation.yield(mapped)
                    }
                }
            }, { [weak self] exitCode in
                watchdog?.cancel()
                self?.sessionQueue.async { self?.activeHandle = nil }
                if exitCode != 0 && !resultSeen {
                    continuation.yield(.error(
                        code: "process_exit_\(exitCode)",
                        message: "Claude process exited unexpectedly (code \(exitCode))",
                        retryable: false
                    ))
                }
                continuation.finish()
            })

            let wd = ProcessIdleWatchdog(
                softTimeout: idleSoftTimeout,
                hardTimeout: idleHardTimeout,
                onSoft: {
                    if let pid = handle.processIdentifier {
                        os_log("agent watchdog soft %{public}@",
                               log: Self.log, type: .default,
                               AgentProcessDiagnostics.snapshot(pid: pid))
                    }
                },
                onHard: {
                    // Finish BEFORE terminate: the SIGTERM makes onExit fire with
                    // a nonzero code, but its process_exit yield lands post-finish
                    // and is a no-op — so no duplicate error, and we never touch
                    // resultSeen from this (watchdog) queue.
                    continuation.yield(.error(
                        code: "agent_timeout",
                        message: "Агент завис и был остановлен — нет ответа. Повторить?",
                        retryable: true))
                    continuation.finish()
                    handle.terminate()
                })
            watchdog = wd
            wd.start()

            sessionQueue.async { self.activeHandle = handle }

            // Terminate the child whenever the consumer goes away — cancelled
            // (Esc / panel dismiss / new turn / app quit -> AgentController.stop()
            // -> consumeTask.cancel()) OR finished. Without this the live CLI
            // was orphaned on cancel: it kept running headless on the user's
            // subscription and, under --permission-mode acceptEdits, kept
            // editing files with no UI attached. terminate() is idempotent and
            // guards `isRunning`, so the natural-exit (.finished) case — where
            // the process already reaped itself — is a safe no-op.
            continuation.onTermination = { [weak self] _ in
                wd.cancel()
                handle.terminate()
                self?.sessionQueue.async { self?.activeHandle = nil }
            }

            handle.writeLine(ControlProtocol.userMessage(prompt))
        }
    }

    /// Writes the user's permission decision to the live process stdin.
    /// Safe to call after exit (no-op once the handle is cleared).
    func respondToPermission(requestId: String, decision: PermissionDecision) {
        sessionQueue.async {
            self.activeHandle?.writeLine(
                ControlProtocol.controlResponse(requestId: requestId, decision: decision))
        }
    }

    static func defaultRunOneShot(binary: URL, args: [String]) -> ProcessResult? {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.environment = Self.childEnvironment()
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        return ProcessResult(
            stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    static func defaultRunStreaming(
        binary: URL,
        args: [String],
        workingDir: URL?,
        onLine: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) -> ClaudeStdinWriting {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        if let workingDir {
            process.currentDirectoryURL = workingDir
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Launch claude as a fresh top-level session on the user's own
        // subscription. See `childEnvironment` for exactly what is stripped and
        // why (Claude Code nesting markers + ambient Anthropic credentials).
        process.environment = Self.childEnvironment()

        // Single serial queue — ALL buffer mutations happen here.
        // Both readabilityHandler and terminationHandler funnel through
        // bufferQueue so `buffer`/`stderrTail` are never touched from two queues.
        let bufferQueue = DispatchQueue(
            label: "com.sidekey.claudeprovider.buffer",
            qos: .userInitiated
        )
        var buffer = Data()

        // Continuously drain stderr so its pipe buffer can never fill and wedge
        // claude mid-turn. (Same hazard CodexProvider guards against: a chatty
        // child fills the ~64KB pipe buffer, blocks on its next stderr write,
        // and the turn hangs forever on the "Thinking" spinner.) Chunks are
        // accumulated in a bounded buffer (last 16 KB) and logged on nonzero
        // exit for diagnostics; funnelled through bufferQueue to avoid
        // cross-queue mutation of stderrTail.
        var stderrTail = BoundedStderrBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferQueue.async { stderrTail.append(chunk) }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // Serialise: both readabilityHandler and terminationHandler funnel
            // through bufferQueue so `buffer` is never touched from two queues.
            bufferQueue.async {
                buffer.append(chunk)
                // Split on newlines, emit complete lines.
                while let newlineRange = buffer.range(of: Data("\n".utf8)) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
                    let line = String(decoding: lineData, as: UTF8.self)
                    onLine(line)
                }
            }
        }

        process.terminationHandler = { proc in
            // All teardown also goes through bufferQueue so it serialises after
            // any in-flight readabilityHandler blocks.
            bufferQueue.async {
                // Nil the handlers first (on the serial queue) so no new chunks
                // arrive after we call readDataToEndOfFile.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remaining.isEmpty {
                    buffer.append(remaining)
                }
                if !buffer.isEmpty {
                    onLine(String(decoding: buffer, as: UTF8.self))
                    buffer = Data()
                }
                // Drain any final stderr bytes so the captured tail is complete
                // (the readabilityHandler was niled above, so nothing else appends).
                let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingErr.isEmpty { stderrTail.append(remainingErr) }
                if proc.terminationStatus != 0 {
                    let tail = stderrTail.tail
                    if !tail.isEmpty {
                        os_log("agent claude stderr (exit=%{public}d): %{public}@",
                               log: ClaudeCodeProvider.log, type: .error,
                               proc.terminationStatus, String(tail.suffix(2000)))
                    }
                }
                onExit(proc.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            onExit(-1)
            return StdinPipeWriter(stdinPipe.fileHandleForWriting)
        }

        // Hand the live process to the writer so `terminate()` can SIGTERM it
        // when the stream's onTermination fires (cancel / dismiss / new turn /
        // quit).
        return StdinPipeWriter(stdinPipe.fileHandleForWriting, process: process)
    }
}

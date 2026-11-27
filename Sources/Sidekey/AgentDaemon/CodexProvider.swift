import Foundation
import os.log

/// SIGTERM handle for a spawned codex child. Codex runs one-shot: it reads the
/// prompt from stdin, which is closed at once, so termination is just a
/// guarded `Process.terminate()`. Returned by `runStreaming` and held by `run`
/// so the stream's `onTermination` can stop the CLI on cancel / dismiss / new
/// turn / quit — before this, codex had NO way to be stopped at all and a
/// cancelled turn orphaned the live CLI, burning the user's ChatGPT subscription.
protocol CodexProcessTerminating: AnyObject {
    func terminate()
    /// PID of the live child, or nil for fakes / already-reaped. Read by the
    /// idle watchdog to snapshot TCC attribution on a soft-trigger.
    var processIdentifier: Int32? { get }
}

/// Concrete handle wrapping the live `Process`. `noop` covers fakes/tests and
/// the spawn-failure path where there is nothing to terminate.
final class CodexProcessHandle: CodexProcessTerminating {
    /// Shared no-op instance for tests and the launch-failed path.
    static let noop = CodexProcessHandle(process: nil)
    private let process: Process?
    init(process: Process?) { self.process = process }
    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }
    func terminate() {
        // `isRunning` guards the already-exited case: Process.terminate()
        // raises if the receiver was never launched or already reaped. The
        // terminationHandler still fires on natural exit, so pipe teardown is
        // not skipped by guarding here.
        // SIGTERM-only by design: codex exits promptly on it — no SIGKILL
        // escalation watchdog (fire-and-forget; the OS reaps on app exit).
        if let process, process.isRunning {
            process.terminate()
        }
    }
}

/// Connects the user's locally-installed OpenAI Codex CLI.
///
/// Drives `codex exec --json` (one-shot JSONL stream) per turn, parses events
/// with `CodexStreamJSONParser` + `CodexEventMapper`, and streams the resulting
/// `AgentSSEEvent`s. The prompt goes through stdin, never argv, and the
/// permission flags come from the user's Agent settings (`AgentHarnessFlags`).
final class CodexProvider: CLIProvider {
    let id: CLIProviderID = .codex
    let displayName = "Codex"
    let installURL = URL(string: "https://developers.openai.com/codex/cli/")!
    static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "agent.cli")

    private let locate: () -> URL?
    private let runOneShot: (_ binary: URL, _ args: [String]) -> ProcessResult?
    private let runStreaming: (
        _ binary: URL,
        _ args: [String],
        _ workingDir: URL?,
        _ stdin: Data,
        _ onLine: @escaping (String) -> Void,
        _ onExit: @escaping (Int32) -> Void
    ) -> CodexProcessTerminating
    private let readConfig: () -> CodexConfigSnapshot
    private let idleSoftTimeout: TimeInterval
    private let idleHardTimeout: TimeInterval

    /// Serial queue that serialises all `lastSessionID` writes so they are
    /// safe even when the streaming callback fires off the main thread.
    private let sessionQueue = DispatchQueue(label: "com.sidekey.codexprovider.session")

    /// The thread_id from the last completed run(). AgentController reads this
    /// after each turn and passes it as resumeSessionID for continuity.
    ///
    /// Both reads and writes go through `sessionQueue`, for the same reason as
    /// `ClaudeCodeProvider.lastSessionID`: finishing the AsyncStream does not
    /// synchronize with a write posted by `sessionQueue.async`.
    /// WHY: docs/decisions/2026-09-04-session-id-read-through-serial-queue.md
    var lastSessionID: String? {
        sessionQueue.sync { _lastSessionID }
    }

    /// Backing storage for `lastSessionID`. Touch only inside `sessionQueue`.
    private var _lastSessionID: String?

    init(
        locate: @escaping () -> URL? = { CodexBinaryLocator().locate() },
        runOneShot: @escaping (_ binary: URL, _ args: [String]) -> ProcessResult? = CodexProvider.defaultRunOneShot,
        runStreaming: @escaping (
            _ binary: URL,
            _ args: [String],
            _ workingDir: URL?,
            _ stdin: Data,
            _ onLine: @escaping (String) -> Void,
            _ onExit: @escaping (Int32) -> Void
        ) -> CodexProcessTerminating = CodexProvider.defaultRunStreaming,
        readConfig: @escaping () -> CodexConfigSnapshot = { CodexConfigReader().read() },
        idleSoftTimeout: TimeInterval = 45,
        idleHardTimeout: TimeInterval = 120
    ) {
        self.locate = locate
        self.runOneShot = runOneShot
        self.runStreaming = runStreaming
        self.readConfig = readConfig
        self.idleSoftTimeout = idleSoftTimeout
        self.idleHardTimeout = idleHardTimeout
    }

    func discoverBinary() -> URL? { locate() }

    /// Codex v1 runs commands inside its own sandbox; there are no
    /// approval prompts, so permission decisions are no-ops here.
    func respondToPermission(requestId: String, decision: PermissionDecision) {}

    /// `codex login status` prints "Logged in using ChatGPT" / "Logged in using
    /// API key" and exits 0 when authenticated. Anything else means the binary
    /// is present but the user still needs `codex login`.
    func probe() async -> ConnectOutcome {
        guard let binary = locate() else { return .notInstalled }
        guard let result = runOneShot(binary, ["login", "status"]) else { return .notInstalled }
        let combined = (result.stdout + " " + result.stderr).lowercased()
        if result.exitCode == 0 && combined.contains("logged in") {
            return .connected(sessionID: nil)
        }
        return .notLoggedIn
    }

    func run(prompt: String, resumeSessionID: String?, options: AgentRunOptions) -> AsyncStream<AgentSSEEvent> {
        AsyncStream { continuation in
            guard let binary = locate() else {
                continuation.yield(.error(
                    code: "not_installed",
                    message: "Codex is not installed",
                    retryable: false
                ))
                continuation.yield(.done(sources: []))
                continuation.finish()
                return
            }

            // Fail closed: without the Agent's own folder the CLI would run
            // (and, with actions on, write) in whatever folder Whytap has.
            guard let workingDir = options.workingDirectory ?? (try? AgentDaemonWorkingDirectory.ensure()) else {
                continuation.yield(.error(code: "workspace_unavailable",
                                          message: AgentHarnessMessages.workspaceUnavailable,
                                          retryable: true))
                continuation.yield(.done(sources: []))
                continuation.finish()
                return
            }

            // Arg order: exec [resume] --json --skip-git-repo-check <flags>
            //     [<thread_id>] -
            // `codex exec resume` takes no -s/--sandbox, -C/--cd or
            // --approve-for-me (they make a follow-up exit 2), so the policy
            // goes through `-c` overrides valid on both, and the working dir
            // through the process cwd (set in defaultRunStreaming).
            // The prompt is `-`: read from stdin, so selected text and the
            // request never appear in argv, where any local process can read
            // them. WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
            var args = ["exec"]
            if resumeSessionID != nil { args.append("resume") }
            args += ["--json", "--skip-git-repo-check"]
            args += AgentHarnessFlags.codex(allowActions: options.allowActions)
            if let command = options.whytapMCPCommand {
                args += AgentHarnessFlags.codexMCPConfig(command: command)
            }
            if let model = options.model { args += ["-m", model] }
            if let effort = options.effort { args += ["-c", "model_reasoning_effort=\(effort)"] }
            if let tier = options.serviceTier {
                if let cliTier = Self.cliServiceTier(tier) {
                    args += ["-c", "service_tier=\(cliTier)"]
                }
            }
            if let tid = resumeSessionID { args.append(tid) }
            args.append("-")

            continuation.yield(.started(
                turnId: UUID().uuidString,
                requestId: "",
                sessionId: resumeSessionID ?? ""
            ))

            var turnCompleted = false
            var surfacedError = false
            // Best-effort kick reference: assigned once after runStreaming returns,
            // but read via watchdog?.kick() on bufferQueue. A sub-µs window exists
            // where a very early first stdout line reads nil and drops one kick —
            // harmless (worst case the watchdog fires slightly early). Constructing
            // it before runStreaming would just trade this for a handle-capture
            // race, so leave the order as-is.
            var watchdog: ProcessIdleWatchdog?

            let handle = runStreaming(binary, args, workingDir, Data(prompt.utf8), { [weak self] line in
                watchdog?.kick()   // any stdout = alive
                guard let event = CodexStreamJSONParser.parse(line: line) else { return }
                if case .threadStarted(let tid) = event {
                    self?.sessionQueue.async { self?._lastSessionID = tid }
                }
                if case .turnCompleted = event { turnCompleted = true }
                if case .streamError = event { surfacedError = true }
                for mapped in CodexEventMapper.map(event) {
                    continuation.yield(mapped)
                }
            }, { exitCode in
                watchdog?.cancel()
                // Skip the generic "exited unexpectedly" when codex already
                // surfaced the real error (e.g. model-not-supported) on the
                // stdout JSON stream — otherwise the pill shows a useless code.
                if exitCode != 0 && !turnCompleted && !surfacedError {
                    continuation.yield(.error(
                        code: "process_exit_\(exitCode)",
                        message: "Codex exited unexpectedly (code \(exitCode))",
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
                               log: CodexProvider.log, type: .default,
                               AgentProcessDiagnostics.snapshot(pid: pid))
                    }
                },
                onHard: {
                    // Finish BEFORE terminate: the SIGTERM makes onExit fire with a
                    // nonzero code, but its process_exit yield lands post-finish and
                    // is a no-op — so there's no duplicate error and no need to write
                    // surfacedError from this (watchdog) queue. surfacedError stays
                    // bufferQueue-only.
                    continuation.yield(.error(
                        code: "agent_timeout",
                        message: AgentHarnessMessages.stalled,
                        retryable: true))
                    continuation.finish()
                    handle.terminate()
                })
            watchdog = wd
            wd.start()

            // Terminate the child whenever the consumer goes away — cancelled
            // (Esc / panel dismiss / new turn / app quit -> AgentController.stop()
            // -> consumeTask.cancel()) OR finished. Codex runs one-shot, so a
            // cancelled turn used to orphan the live CLI with no stop path at
            // all. terminate() is guarded on `isRunning`, so the natural-exit
            // (.finished) case is a safe no-op.
            continuation.onTermination = { _ in
                wd.cancel()
                handle.terminate()
            }
        }
    }

    static func defaultRunOneShot(binary: URL, args: [String]) -> ProcessResult? {
        ProcessOneShot.run(binary: binary, args: args, environment: childEnvironment())
    }

    /// Capabilities are validated by AgentSettingsStore. Preserve registry IDs;
    /// Normal explicitly overrides a fast tier in the user's CLI config.
    static func cliServiceTier(_ uiTier: String) -> String? {
        let value = uiTier.lowercased()
        switch value {
        case "priority", "fast": return "fast"
        case "normal", "standard", "default": return "default"
        default:
            guard !value.isEmpty, value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else { return nil }
            return value
        }
    }

    /// The environment handed to every spawned `codex`. Mirrors
    /// `ClaudeCodeProvider.childEnvironment`'s hardening, but the credential
    /// families that matter for codex are different:
    /// - `OPENAI_*` (codex's own API key + base URL) — an inherited
    ///   `OPENAI_API_KEY` silently switches codex billing from the user's
    ///   ChatGPT subscription onto an API key, which the user did not consent
    ///   to and pays for separately;
    /// - `DOPPLER_*` — the documented dev launcher is `doppler run`, which
    ///   injects the app's secrets into the environment; codex must never see
    ///   them;
    /// - the Anthropic/Claude markers (shared with Claude's scrub) — a dev
    ///   session launched from Claude Code must not leak them sideways.
    /// In production all of these are absent; the scrub is correct hardening
    /// regardless and load-bearing under `doppler run`.
    static func childEnvironment(
        from parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // Start from Claude's shared Anthropic/Claude carve-out, then drop the
        // codex-specific billing families.
        var env = ClaudeCodeProvider.scrubbingAnthropicAndClaudeVars(from: parent)
        for key in env.keys where key.hasPrefix("OPENAI_") || key.hasPrefix("DOPPLER_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    /// Spawns the codex process and streams its stdout line-by-line.
    ///
    /// Mirrors `ClaudeCodeProvider.defaultRunStreaming`'s single serial
    /// `bufferQueue` pattern (the data-race fix), with these differences:
    /// - the prompt (`stdin`) is written to the child's stdin, which is then
    ///   closed: codex reads it to EOF and would hang on an open pipe.
    /// - Returns a `CodexProcessHandle` (not a stdin writer) so the stream can
    ///   SIGTERM the child on cancel; codex is one-shot, so there is no stdin
    ///   protocol to keep open.
    /// - `childEnvironment` scrub targets OPENAI_*/DOPPLER_* (billing) plus the
    ///   shared Anthropic/Claude markers, not just CLAUDECODE.
    static func defaultRunStreaming(
        binary: URL,
        args: [String],
        workingDir: URL?,
        stdin: Data,
        onLine: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) -> CodexProcessTerminating {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        if let workingDir {
            process.currentDirectoryURL = workingDir
        }

        // Scrub inherited credentials so codex always bills the user's ChatGPT
        // subscription, never an inherited OPENAI_API_KEY (critical under the
        // documented `doppler run` dev launcher). See `childEnvironment`.
        process.environment = Self.childEnvironment()

        // The prompt, then EOF: codex reads stdin to the end.
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Single serial queue — ALL buffer mutations happen here.
        // Both readabilityHandler and terminationHandler funnel through
        // bufferQueue so `buffer`/`stderrTail` are never touched from two queues.
        let bufferQueue = DispatchQueue(
            label: "com.sidekey.codexprovider.buffer",
            qos: .userInitiated
        )
        var lines = ProcessLineBuffer()

        // Continuously drain stderr so its pipe buffer can never fill and wedge
        // codex mid-turn. Only its size is logged: it can carry paths, prompts
        // or MCP server output.
        var stderrTail = BoundedStderrBuffer()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferQueue.async { stderrTail.append(chunk) }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            bufferQueue.async {
                for line in lines.append(chunk) { onLine(line) }
            }
        }

        process.terminationHandler = { proc in
            // All teardown also goes through bufferQueue so it serialises after
            // any in-flight readabilityHandler blocks.
            bufferQueue.async {
                // Nil the handler first (on the serial queue) so no new chunks
                // arrive after we call readDataToEndOfFile.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                for line in lines.finish(with: remaining) { onLine(line) }
                // Drain any final stderr bytes so the captured tail is complete
                // (the readabilityHandler was niled above, so nothing else appends).
                let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingErr.isEmpty { stderrTail.append(remainingErr) }
                if proc.terminationStatus != 0 {
                    os_log("agent codex exit=%{public}d stderr_bytes=%{public}d",
                           log: CodexProvider.log, type: .error,
                           proc.terminationStatus, stderrTail.byteCount)
                }
                onExit(proc.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            onExit(-1)
            return CodexProcessHandle.noop
        }
        // Write off the caller's thread: a prompt larger than the pipe buffer
        // blocks until codex reads it. A child that already exited raises
        // EPIPE here; the exit path reports the turn.
        let writer = stdinPipe.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: stdin)
            try? writer.close()
        }

        // Hand the live process to the handle so the stream's onTermination can
        // SIGTERM it on cancel / dismiss / new turn / quit.
        return CodexProcessHandle(process: process)
    }
}

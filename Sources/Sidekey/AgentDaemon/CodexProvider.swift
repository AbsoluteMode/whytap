import Foundation
import os.log

/// SIGTERM handle for a spawned codex child. Codex runs one-shot with
/// stdin=nullDevice (no stdin protocol to close), so termination is just a
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
/// `AgentSSEEvent`s. During the testing phase it runs with
/// `--dangerously-bypass-approvals-and-sandbox`: every action runs with NO
/// approval prompt and NO sandbox (full machine access). See `run(...)`.
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
        runOneShot: @escaping (_ binary: URL, _ args: [String]) -> ProcessResult? = ClaudeCodeProvider.defaultRunOneShot,
        runStreaming: @escaping (
            _ binary: URL,
            _ args: [String],
            _ workingDir: URL?,
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

            let workingDir = try? AgentDaemonWorkingDirectory.ensure()

            // Arg order: exec [resume] --json --skip-git-repo-check
            //     -c sandbox_mode=workspace-write [<thread_id>] <prompt>
            // CRITICAL: `codex exec resume` does NOT accept -s/--sandbox or
            // -C/--cd (those are exec-only) — passing them makes every
            // follow-up turn exit 2. So the sandbox goes through
            // `-c sandbox_mode=workspace-write` (valid on both exec and resume,
            // verified to actually block out-of-workspace writes) and the
            // working dir through the process cwd (set in defaultRunStreaming).
            // "resume" is a subcommand right after "exec"; thread_id + prompt
            // are trailing positionals.
            _ = workingDir  // used below for the process cwd, not as a -C flag
            var args = ["exec"]
            if resumeSessionID != nil { args.append("resume") }
            args += ["--json", "--skip-git-repo-check"]
            // Skip-permission mode (testing phase): run every action with NO
            // approval prompt AND NO sandbox. `codex exec` does not expose
            // `-a/--ask-for-approval` and does not honour `-c
            // approval_policy=never`, so an MCP tool ask — e.g. creating a
            // Linear issue — kept getting auto-cancelled ("user cancelled MCP
            // tool call"). `--dangerously-bypass-approvals-and-sandbox` is the
            // one switch that skips ALL confirmations, and it is accepted on
            // BOTH `exec` and `exec resume`. It also drops the workspace-write
            // sandbox — Codex gets full machine access. Disclosed to the user
            // at connect (AgentModeView). The deferred in-island approval bar
            // is where we will re-introduce a sandbox + per-call approval.
            args += ["--dangerously-bypass-approvals-and-sandbox"]
            if let model = options.model { args += ["-m", model] }
            if let effort = options.effort { args += ["-c", "model_reasoning_effort=\(effort)"] }
            if let tier = options.serviceTier {
                let selectedModel = options.model ?? readConfig().model
                if Self.supportsServiceTier(model: selectedModel),
                   let cliTier = Self.cliServiceTier(tier) {
                    args += ["-c", "service_tier=\(cliTier)"]
                }
            }
            if let tid = resumeSessionID { args.append(tid) }
            args.append(prompt)

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

            let handle = runStreaming(binary, args, workingDir, { [weak self] line in
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
                        message: "Агент завис и был остановлен — нет ответа. Повторить?",
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

    static func supportsServiceTier(model: String?) -> Bool {
        guard let model else { return true }
        return model.lowercased() != "gpt-5.3-codex-spark"
    }

    /// UI tier -> CLI config value. The old npm CLI (0.125) only accepts
    /// fast/flex and fatals on anything else at config-load; the Codex.app
    /// binary (0.140+) also accepts "priority"/"default". "fast" means the
    /// same lane as "priority", so map down to the value every CLI accepts;
    /// "default" means "no override" — send no flag at all.
    static func cliServiceTier(_ uiTier: String) -> String? {
        switch uiTier.lowercased() {
        case "priority", "fast": return "fast"
        case "flex": return "flex"
        default: return nil
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
    /// - `process.standardInput = FileHandle.nullDevice` — codex reads stdin
    ///   to append to the prompt and hangs if stdin stays open; nullDevice
    ///   gives immediate EOF.
    /// - Returns a `CodexProcessHandle` (not a stdin writer) so the stream can
    ///   SIGTERM the child on cancel; codex is one-shot, the prompt is a CLI
    ///   arg, so there is no stdin protocol to close.
    /// - `childEnvironment` scrub targets OPENAI_*/DOPPLER_* (billing) plus the
    ///   shared Anthropic/Claude markers, not just CLAUDECODE.
    static func defaultRunStreaming(
        binary: URL,
        args: [String],
        workingDir: URL?,
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

        // codex must see stdin EOF immediately or it hangs reading additional input.
        process.standardInput = FileHandle.nullDevice

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
        var buffer = Data()

        // Continuously drain stderr so its pipe buffer can never fill and wedge
        // codex mid-turn. Chunks are accumulated in a bounded buffer (last 16 KB)
        // and logged on nonzero exit for diagnostics; funnelled through bufferQueue
        // to avoid cross-queue mutation of stderrTail.
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
                // Nil the handler first (on the serial queue) so no new chunks
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
                        os_log("agent codex stderr (exit=%{public}d): %{public}@",
                               log: CodexProvider.log, type: .error,
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
            return CodexProcessHandle.noop
        }

        // Hand the live process to the handle so the stream's onTermination can
        // SIGTERM it on cancel / dismiss / new turn / quit.
        return CodexProcessHandle(process: process)
    }
}

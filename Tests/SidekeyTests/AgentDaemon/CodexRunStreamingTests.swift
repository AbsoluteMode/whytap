import XCTest
@testable import Sidekey

// MARK: - CodexRunStreamingTests
//
// Guards the real codex exec --json driving in CodexProvider.run().
// Strategy: inject a fake `runStreaming` closure that drives onLine/onExit
// directly — no process spawn, fast and hermetic.

final class CodexRunStreamingTests: XCTestCase {

    // MARK: - Test 1: happy path — codex events mapped, thread_id captured

    func testRunMapsCodexEventsAndCapturesThreadID() async {
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, args, _, onLine, onExit in
                XCTAssertTrue(args.contains("exec"))
                XCTAssertTrue(args.contains("--json"))
                XCTAssertTrue(args.contains("--dangerously-bypass-approvals-and-sandbox"),
                              "skip-permission mode: no approvals + no sandbox, accepted on exec AND resume; got: \(args)")
                XCTAssertFalse(args.contains("sandbox_mode=workspace-write"),
                               "sandbox is dropped in skip-permission mode; got: \(args)")
                XCTAssertFalse(args.contains("-s"),
                               "must NOT pass -s/--sandbox — `codex exec resume` rejects it (exit 2)")
                onLine(#"{"type":"thread.started","thread_id":"t-1"}"#)
                onLine(#"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"done"}}"#)
                onLine(#"{"type":"turn.completed","usage":{}}"#)
                onExit(0)
                return CodexProcessHandle.noop
            })

        var events: [AgentSSEEvent] = []
        for await e in provider.run(prompt: "hi", resumeSessionID: nil) { events.append(e) }

        XCTAssertTrue(events.contains(.finalAnswer(text: "done")),
                      "Expected .finalAnswer(text: done), got: \(events)")
        XCTAssertTrue(events.contains(.done(sources: [])),
                      "Expected .done(sources: []), got: \(events)")
        XCTAssertEqual(provider.lastSessionID, "t-1")
    }

    func testRunExtractsLegacyUsefulLinksFromCodexAgentMessageAsActions() async {
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, _, _, onLine, onExit in
                onLine(#"{"type":"thread.started","thread_id":"t-1"}"#)
                onLine(#"{"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"Open this.\n\n```json\n{\"kind\":\"useful.links\",\"schemaVersion\":1,\"links\":[{\"url\":\"https://linear.app/example/issue/EX-209\",\"description\":\"Security audit\",\"provider\":\"linear\"}]}\n```"}}"#)
                onLine(#"{"type":"turn.completed","usage":{}}"#)
                onExit(0)
                return CodexProcessHandle.noop
            })

        var events: [AgentSSEEvent] = []
        for await e in provider.run(prompt: "hi", resumeSessionID: nil) { events.append(e) }

        XCTAssertTrue(events.contains(.finalAnswer(text: "Open this.")), "events: \(events)")
        // Legacy useful.links input now folds into a useful.actions block with
        // an all-link item list (backward compatibility).
        let actions = events.compactMap { event -> UsefulActionsBlock? in
            if case .blockComplete(.usefulActions(let block)) = event { return block }
            return nil
        }
        XCTAssertEqual(
            actions.first?.items.first,
            .link(
                url: URL(string: "https://linear.app/example/issue/EX-209")!,
                description: "Security audit",
                provider: "linear"
            )
        )
        XCTAssertTrue(events.contains(.done(sources: [])), "events: \(events)")
    }

    // MARK: - Test 2: resume — thread_id + prompt are trailing positionals

    func testResumeForwardsThreadID() async {
        var captured: [String] = []
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/x/codex") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, args, _, _, onExit in captured = args; onExit(0); return CodexProcessHandle.noop })

        var it = provider.run(prompt: "follow", resumeSessionID: "t-9").makeAsyncIterator()
        while await it.next() != nil {}

        XCTAssertEqual(captured.first, "exec",
                       "First arg must be 'exec', got: \(captured)")
        XCTAssertTrue(captured.contains("resume"),
                      "'resume' subcommand missing from args: \(captured)")
        // SESSION_ID then PROMPT are the trailing positionals.
        XCTAssertEqual(captured.suffix(2).first, "t-9",
                       "Penultimate arg must be thread_id 't-9', got: \(captured)")
        XCTAssertEqual(captured.last, "follow",
                       "Last arg must be the prompt, got: \(captured)")
    }

    // MARK: - Test 3: non-zero exit without turn.completed -> synthetic error

    func testDirtyExitWithoutTurnCompletedEmitsSyntheticError() async {
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/x/codex") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, _, _, _, onExit in
                // No lines at all — process just dies with code 1.
                onExit(1)
                return CodexProcessHandle.noop
            })

        var events: [AgentSSEEvent] = []
        for await e in provider.run(prompt: "crash", resumeSessionID: nil) { events.append(e) }

        let errorEvent = events.first {
            if case .error = $0 { return true }
            return false
        }
        guard case .error(let code, _, _) = errorEvent else {
            return XCTFail("Expected a .error event, got: \(events)")
        }
        XCTAssertTrue(code.contains("process_exit"),
                      "code was '\(code)', expected it to contain 'process_exit'")
    }

    // MARK: - Test 4: turn.completed present + non-zero exit -> no synthetic error

    func testTurnCompletedSuppressesSyntheticErrorOnNonZeroExit() async {
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/x/codex") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, _, _, onLine, onExit in
                onLine(#"{"type":"turn.completed","usage":{}}"#)
                onExit(1)  // non-zero, but turn.completed already seen
                return CodexProcessHandle.noop
            })

        var events: [AgentSSEEvent] = []
        for await e in provider.run(prompt: "q", resumeSessionID: nil) { events.append(e) }

        let hasError = events.contains {
            if case .error = $0 { return true }
            return false
        }
        XCTAssertFalse(hasError,
                       "Should not emit synthetic error when turn.completed was seen; got: \(events)")
        XCTAssertTrue(events.contains(.done(sources: [])),
                      "Expected .done(sources: []), got: \(events)")
    }

    // MARK: - Test 5: cancelling the consumer terminates the codex child
    //
    // Codex runs one-shot with stdin=nullDevice and (before the fix) had NO
    // way to be stopped — cancelling Esc/dismiss/new-turn orphaned the live
    // CLI, burning the user's ChatGPT subscription. The stream's onTermination
    // must terminate the retained process.

    func testCancellingConsumerTerminatesChild() async {
        final class FakeCodexHandle: CodexProcessTerminating {
            var terminateCount = 0
            func terminate() { terminateCount += 1 }
            var processIdentifier: Int32? { nil }
        }
        let fake = FakeCodexHandle()
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/x/codex") },
            runOneShot: { _, _ in nil },
            // Never call onExit -> stream stays open until the consumer cancels.
            runStreaming: { _, _, _, _, _ in fake })

        let stream = provider.run(prompt: "long", resumeSessionID: nil)
        let started = expectation(description: "consumer began iterating")
        let consumer = Task {
            var first = true
            for await _ in stream {
                if first { first = false; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(fake.terminateCount, 0)

        consumer.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(fake.terminateCount, 1,
            "cancelling the consumer must terminate the live codex child")
    }

    // MARK: - Test 6: silent child triggers watchdog terminate + agent_timeout error

    func testSilentChildTriggersWatchdogTerminateAndError() async {
        final class FakeCodexHandle: CodexProcessTerminating {
            var terminateCount = 0
            func terminate() { terminateCount += 1 }
            var processIdentifier: Int32? { nil }   // nil → diagnostics no-op, fine
        }
        let fake = FakeCodexHandle()
        // Spawned, but never emits a line and never exits — pure silence.
        let provider = CodexProvider(
            locate: { URL(fileURLWithPath: "/x/codex") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, _, _, _, _ in fake },
            idleSoftTimeout: 0.05,
            idleHardTimeout: 0.1)

        var sawTimeoutError = false
        for await event in provider.run(prompt: "hang", resumeSessionID: nil) {
            if case .error(let code, _, let retryable) = event, code == "agent_timeout" {
                sawTimeoutError = true
                XCTAssertTrue(retryable)
            }
        }
        XCTAssertTrue(sawTimeoutError, "silent child must yield agent_timeout .error")
        XCTAssertGreaterThanOrEqual(fake.terminateCount, 1, "watchdog must terminate the stuck child")
    }

    // MARK: - Test 7: real-Process termination via tail -f /dev/null
    //
    // Codex's defaultRunStreaming uses stdin=nullDevice, so `cat` would EOF and
    // exit immediately. Use `tail -f /dev/null` instead — a cheap, always-present
    // blocker that never exits on its own. terminate() (SIGTERM) must kill it and
    // the terminationHandler must fire onExit (pipe teardown).

    func testRealBlockingProcessIsTerminatedAndFiresExit() async throws {
        let tail = ["/usr/bin/tail", "/bin/tail"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path = tail else { throw XCTSkip("no tail binary") }

        let exited = XCTestExpectation(description: "terminationHandler fired onExit")
        let handle = CodexProvider.defaultRunStreaming(
            binary: URL(fileURLWithPath: path),
            args: ["-f", "/dev/null"],
            workingDir: nil,
            onLine: { _ in },
            onExit: { _ in exited.fulfill() }
        )
        handle.terminate()
        await fulfillment(of: [exited], timeout: 5)
    }
}

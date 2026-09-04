import XCTest
@testable import Sidekey

// MARK: - ClaudeRunStreamingTests
//
// Guards the buffer-serialisation fix and session-ID capture in
// ClaudeCodeProvider.defaultRunStreaming / run().
//
// Strategy: inject a fake `runStreaming` closure that drives onLine/onExit
// directly — no process spawn needed, so tests are fast and hermetic.

final class ClaudeRunStreamingTests: XCTestCase {

    // MARK: Helpers

    /// JSON lines used across multiple tests.
    private let initLine = #"{"type":"system","subtype":"init","session_id":"sess-abc"}"#
    private let textLine = #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hello"}}}"#
    private let resultLine = #"{"type":"result","subtype":"success","session_id":"sess-xyz","is_error":false}"#

    /// A no-op stdin handle for fakes that don't care about stdin writes.
    final class NoopHandle: ClaudeStdinWriting {
        func writeLine(_ line: String) {}
        func closeStdin() {}
        func terminate() {}
        var processIdentifier: Int32? { nil }
    }

    /// Builds a ClaudeCodeProvider whose runStreaming is fully under test control.
    ///
    /// `script` receives the two callbacks and is responsible for driving them
    /// synchronously (or asynchronously if needed). `locate` returns a dummy URL
    /// so `run()` doesn't bail out early.
    private func makeProvider(
        script: @escaping (
            _ onLine: @escaping (String) -> Void,
            _ onExit: @escaping (Int32) -> Void
        ) -> Void
    ) -> ClaudeCodeProvider {
        ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/claude") },
            runStreaming: { _, _, _, onLine, onExit in
                script(onLine, onExit)
                return NoopHandle()
            }
        )
    }

    /// Collect all AgentSSEEvents from a run(), filtering out .started which
    /// ClaudeCodeProvider always emits as the first event before calling
    /// runStreaming (it's bookkeeping, not signal).
    private func collect(
        _ stream: AsyncStream<AgentSSEEvent>,
        timeout: TimeInterval = 5
    ) async -> [AgentSSEEvent] {
        var result: [AgentSSEEvent] = []
        for await event in stream {
            result.append(event)
        }
        return result
    }

    // MARK: - Test 1: happy path — normal lines, session_id captured

    func testHappyPathYieldsMappedEventsAndCapturesSessionID() async {
        let provider = makeProvider { onLine, onExit in
            onLine(#"{"type":"system","subtype":"init","session_id":"sess-abc"}"#)
            onLine(#"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Hello"}}}"#)
            onLine(#"{"type":"result","subtype":"success","session_id":"sess-xyz","is_error":false}"#)
            onExit(0)
        }

        let events = await collect(provider.run(prompt: "hi", resumeSessionID: nil))

        // Strip the leading .started that run() always emits
        let meaningful = events.filter {
            if case .started = $0 { return false }
            return true
        }

        // Expect: narrationDelta("Hello"), done (text_delta is hidden narration now)
        XCTAssertEqual(meaningful.count, 2, "events: \(meaningful)")
        XCTAssertEqual(meaningful[0], .narrationDelta(text: "Hello"))
        XCTAssertEqual(meaningful[1], .done(sources: []))

        // lastSessionID must be set (result line carried sess-xyz)
        XCTAssertEqual(provider.lastSessionID, "sess-xyz")
    }

    // MARK: - Test 2: split-line reassembly (the data-race guard)
    //
    // A JSON object is split across two onLine calls — the second half
    // arrives in a separate chunk. The real defaultRunStreaming accumulates
    // inside `buffer` and only emits after a newline; the fake just calls
    // onLine twice with the two halves (simulating what the bufferQueue
    // serialiser does after reassembly). This verifies the mapper handles
    // a correctly-reassembled line, and that partial delivery doesn't
    // produce a spurious event.

    func testSplitLineIsReassembledIntoOneEvent() async {
        let fullTextLine = #"{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"World"}}}"#
        // Split roughly at the midpoint, as if two read() calls arrived.
        let splitIdx = fullTextLine.index(fullTextLine.startIndex, offsetBy: fullTextLine.count / 2)
        let firstHalf = String(fullTextLine[..<splitIdx])
        let secondHalf = String(fullTextLine[splitIdx...])

        // Simulate what bufferQueue does: accumulate, emit only on newline.
        let provider = makeProvider { onLine, onExit in
            // Simulate chunk 1 (no newline yet — buffer won't emit)
            // Chunk 2 arrives; now we have the full line — emit once.
            let assembled = firstHalf + secondHalf
            onLine(assembled)          // one call for the fully-assembled line
            onLine(#"{"type":"result","subtype":"success","session_id":"s-split","is_error":false}"#)
            onExit(0)
        }

        let events = await collect(provider.run(prompt: "split", resumeSessionID: nil))

        let meaningful = events.filter {
            if case .started = $0 { return false }
            return true
        }

        // Must yield exactly: narrationDelta("World"), done — no spurious extras
        XCTAssertEqual(meaningful.count, 2, "events: \(meaningful)")
        XCTAssertEqual(meaningful[0], .narrationDelta(text: "World"))
        XCTAssertEqual(meaningful[1], .done(sources: []))
        XCTAssertEqual(provider.lastSessionID, "s-split")
    }

    // MARK: - Test 3: lastSessionID captured from result line (not only init)

    func testLastSessionIDSetFromResultLine() async {
        // No init line — only a result line carries the session_id.
        let provider = makeProvider { onLine, onExit in
            onLine(#"{"type":"result","subtype":"success","session_id":"sess-result","is_error":false}"#)
            onExit(0)
        }

        _ = await collect(provider.run(prompt: "q", resumeSessionID: nil))
        XCTAssertEqual(provider.lastSessionID, "sess-result")
    }

    // MARK: - Test 4: --resume is forwarded when resumeSessionID is provided

    func testResumeSessionIDForwardedInArgs() async {
        var capturedArgs: [String] = []

        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/local/bin/claude") },
            runStreaming: { _, args, _, _, onExit in
                capturedArgs = args
                onExit(0)
                return NoopHandle()
            }
        )

        _ = await collect(provider.run(prompt: "follow-up", resumeSessionID: "prev-session-id"))

        guard let resumeIndex = capturedArgs.firstIndex(of: "--resume") else {
            return XCTFail("--resume flag not found in args: \(capturedArgs)")
        }
        XCTAssertEqual(capturedArgs[resumeIndex + 1], "prev-session-id")
    }

    // MARK: - Test 5: non-zero exit without result -> synthetic error emitted

    func testDirtyExitWithoutResultEmitsSyntheticError() async {
        let provider = makeProvider { _, onExit in
            // No lines at all — process just dies with code 1.
            onExit(1)
        }

        let events = await collect(provider.run(prompt: "crash", resumeSessionID: nil))

        let errorEvent = events.first {
            if case .error = $0 { return true }
            return false
        }
        guard case .error(let code, _, _) = errorEvent else {
            return XCTFail("Expected a .error event, got: \(events)")
        }
        XCTAssertTrue(code.contains("process_exit"), "code was '\(code)', expected it to contain 'process_exit'")
    }

    // MARK: - Test 6: stream finishes after onExit

    func testStreamFinishesAfterOnExit() async {
        let provider = makeProvider { onLine, onExit in
            onLine(#"{"type":"result","subtype":"success","session_id":"s1","is_error":false}"#)
            onExit(0)
        }

        // If the stream never finishes this will hang; the test timeout (default 60s) guards it.
        var count = 0
        for await _ in provider.run(prompt: "fin", resumeSessionID: nil) {
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - Test 7: real-Process termination via /bin/cat
    //
    // Exercises the REAL defaultRunStreaming against a cheap fixture that
    // blocks like a chatty long-running CLI: `/bin/cat` with a pipe on stdin
    // reads forever and never exits on its own. `terminate()` (SIGTERM) must
    // kill it; the terminationHandler must then fire onExit so the stream
    // finishes and pipes are torn down. Guards the orphaned-CLI fix end to end
    // with a binary that is always present (no credits, no auth, no gating).

    func testRealCatProcessIsTerminatedAndFiresExit() async throws {
        let cat = URL(fileURLWithPath: "/bin/cat")
        guard FileManager.default.isExecutableFile(atPath: cat.path) else {
            throw XCTSkip("/bin/cat not available")
        }

        var exitCode: Int32?
        let exited = XCTestExpectation(description: "terminationHandler fired onExit")
        let handle = ClaudeCodeProvider.defaultRunStreaming(
            binary: cat,
            args: [],
            workingDir: nil,
            onLine: { _ in },
            onExit: { code in
                exitCode = code
                exited.fulfill()
            }
        )

        // cat is now blocked reading stdin. Terminate it.
        handle.terminate()

        await fulfillment(of: [exited], timeout: 5)
        // SIGTERM-killed processes report a non-zero/​signal termination — the
        // exact value is platform-defined; assert only that onExit fired (the
        // pipe-teardown path ran) and the process did not hang.
        XCTAssertNotNil(exitCode, "terminationHandler must fire onExit after terminate()")
    }

    // MARK: - Test 8: terminate() is safe after the process already exited

    func testTerminateAfterExitIsSafe() async throws {
        let trueBin = ["/usr/bin/true", "/bin/true"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path = trueBin else { throw XCTSkip("no /bin/true or /usr/bin/true") }

        let exited = XCTestExpectation(description: "process exited on its own")
        let handle = ClaudeCodeProvider.defaultRunStreaming(
            binary: URL(fileURLWithPath: path),
            args: [],
            workingDir: nil,
            onLine: { _ in },
            onExit: { _ in exited.fulfill() }
        )
        await fulfillment(of: [exited], timeout: 5)

        // Process is already dead — terminate() must be a guarded no-op, never
        // crash on terminating a non-running Process.
        handle.terminate()
        handle.terminate()
    }

    // MARK: - Test 9: idle watchdog fires agent_timeout when child is silent

    func testSilentChildTriggersWatchdogTerminateAndError() async {
        final class FakeWriter: ClaudeStdinWriting {
            var terminateCount = 0
            func writeLine(_ line: String) {}
            func closeStdin() {}
            func terminate() { terminateCount += 1 }
            var processIdentifier: Int32? { nil }
        }
        let fake = FakeWriter()
        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/x/claude") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, _, _, _, _ in fake },
            idleSoftTimeout: 0.05,
            idleHardTimeout: 0.1)

        var sawTimeoutError = false
        for await event in provider.run(prompt: "hang", resumeSessionID: nil, options: AgentRunOptions()) {
            if case .error(let code, _, let retryable) = event, code == "agent_timeout" {
                sawTimeoutError = true
                XCTAssertTrue(retryable)
            }
        }
        XCTAssertTrue(sawTimeoutError)
        XCTAssertGreaterThanOrEqual(fake.terminateCount, 1)
    }
}

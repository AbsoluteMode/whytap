import XCTest
@testable import Sidekey

final class ClaudePermissionStreamingTests: XCTestCase {

    final class FakeHandle: ClaudeStdinWriting {
        var lines: [String] = []
        var terminateCount = 0
        func writeLine(_ line: String) { lines.append(line) }
        func closeStdin() {}
        func terminate() { terminateCount += 1 }
        var processIdentifier: Int32? { nil }
    }

    /// Cancelling the AsyncStream consumer (Esc / panel dismiss / new turn /
    /// app quit -> stop() -> consumeTask.cancel()) must terminate the live CLI.
    /// Before the fix the stream had no `onTermination`, so the child kept
    /// running headless, burning the user's subscription and (with
    /// --permission-mode acceptEdits) editing files with no UI attached.
    func testCancellingConsumerTerminatesChild() async {
        let fake = FakeHandle()
        // Never call onExit -> the stream stays open until the consumer
        // cancels, exactly like a long-running turn the user aborts.
        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/bin/true") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, _, _, _, _ in fake })

        let stream = provider.run(prompt: "do it", resumeSessionID: nil)
        let started = expectation(description: "consumer began iterating")
        let consumer = Task {
            var first = true
            for await _ in stream {
                if first { first = false; started.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(fake.terminateCount, 0)

        // Cancel the consuming Task — this is what AgentController.stop() /
        // handleCancel() do via consumeTask?.cancel(). AsyncStream fires
        // onTermination(.cancelled), which must terminate the child.
        consumer.cancel()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThanOrEqual(fake.terminateCount, 1,
            "cancelling the consumer must terminate the live child")
    }

    func testWritesPromptThenRespondsToPermission() async {
        let fake = FakeHandle()
        var captured: ((String) -> Void)?
        let provider = ClaudeCodeProvider(
            locate: { URL(fileURLWithPath: "/usr/bin/true") },
            runOneShot: { _, _ in nil },
            runStreaming: { _, args, _, onLine, _ in
                // Skip-permission mode: bypass every check, and do NOT register
                // the stdio prompt tool (there is no UI to answer it yet).
                XCTAssertTrue(args.contains("--permission-mode"))
                XCTAssertTrue(args.contains("bypassPermissions"))
                XCTAssertFalse(args.contains("--permission-prompt-tool"),
                               "skip-permission mode must not register the stdio prompt tool")
                XCTAssertFalse(args.contains("acceptEdits"))
                XCTAssertTrue(args.contains("--input-format"))
                captured = onLine
                return fake
            })

        let stream = provider.run(prompt: "do it", resumeSessionID: nil)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next() // .started

        // The first stdin line is the user message.
        XCTAssertTrue(fake.lines.first?.contains("\"do it\"") ?? false)

        // Feed a can_use_tool line; expect a .permissionRequest event out.
        captured?(#"{"type":"control_request","request_id":"r9","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"},"description":"List"}}"#)
        let ev = await iterator.next()
        guard case .permissionRequest(let id, _, _, _)? = ev else { return XCTFail("expected permissionRequest, got \(String(describing: ev))") }
        XCTAssertEqual(id, "r9")

        // Responding writes a control_response with the matching id.
        provider.respondToPermission(requestId: "r9", decision: .deny(message: "no"))
        // Small yield to let the sessionQueue dispatch run.
        try? await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertTrue(fake.lines.contains { $0.contains("control_response") && $0.contains("r9") })
    }
}

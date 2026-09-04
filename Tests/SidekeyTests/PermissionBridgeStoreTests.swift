import XCTest
@testable import Sidekey

@MainActor
final class PermissionBridgeStoreTests: XCTestCase {
    func testConsumeSurfacesPendingPermissionAndDecisionRoundTrips() async {
        let store = AskResponseStore()
        var decided: (String, PermissionDecision)?
        store.onPermissionDecision = { decided = ($0, $1) }

        let stream = AsyncStream<AgentSSEEvent> { c in
            c.yield(.started(turnId: "t", requestId: "", sessionId: ""))
            c.yield(.permissionRequest(id: "r1", toolName: "Bash", summary: "run ls", inputJSON: "{\"command\":\"ls\"}"))
            c.finish()
        }
        await store.consume(stream)

        XCTAssertEqual(store.pendingPermission?.id, "r1")
        store.decide(.allow(inputJSON: store.pendingPermission!.inputJSON))
        XCTAssertNil(store.pendingPermission)
        XCTAssertEqual(decided?.0, "r1")
        XCTAssertEqual(decided?.1, .allow(inputJSON: "{\"command\":\"ls\"}"))
    }

    func testDecideWithNoPendingPermissionIsNoop() {
        let store = AskResponseStore()
        var called = false
        store.onPermissionDecision = { _, _ in called = true }
        store.decide(.deny(message: "no pending"))
        XCTAssertFalse(called)
    }

    func testDenyDecisionClearsPendingAndCallsCallback() async {
        let store = AskResponseStore()
        var decided: (String, PermissionDecision)?
        store.onPermissionDecision = { decided = ($0, $1) }

        let stream = AsyncStream<AgentSSEEvent> { c in
            c.yield(.permissionRequest(id: "r2", toolName: "Bash", summary: "rm -rf", inputJSON: "{}"))
            c.finish()
        }
        await store.consume(stream)

        XCTAssertEqual(store.pendingPermission?.id, "r2")
        store.decide(.deny(message: "User declined in Whytap"))
        XCTAssertNil(store.pendingPermission)
        XCTAssertEqual(decided?.0, "r2")
        XCTAssertEqual(decided?.1, .deny(message: "User declined in Whytap"))
    }

    // MARK: - FIFO queue (parallel can_use_tool batch)

    /// Claude batches parallel `can_use_tool` control_requests in one turn.
    /// The store must surface them one at a time (head only) and answer each
    /// in FIFO order — the single-slot design dropped every request but the
    /// last, leaving the CLI blocked on stdin for the un-answered ids.
    func testParallelPermissionsAreQueuedAndAnsweredFIFO() async {
        let store = AskResponseStore()
        var decisions: [(String, PermissionDecision)] = []
        store.onPermissionDecision = { decisions.append(($0, $1)) }

        let stream = AsyncStream<AgentSSEEvent> { c in
            c.yield(.permissionRequest(id: "r1", toolName: "Bash", summary: "ls", inputJSON: "{\"a\":1}"))
            c.yield(.permissionRequest(id: "r2", toolName: "Bash", summary: "pwd", inputJSON: "{\"b\":2}"))
            c.yield(.permissionRequest(id: "r3", toolName: "Bash", summary: "id", inputJSON: "{\"c\":3}"))
            c.finish()
        }
        await store.consume(stream)

        // Only the head is visible; the other two stay queued.
        XCTAssertEqual(store.pendingPermission?.id, "r1")

        // Answer the head -> next surfaces, in arrival order.
        store.decide(.allow(inputJSON: "{\"a\":1}"))
        XCTAssertEqual(store.pendingPermission?.id, "r2")
        store.decide(.deny(message: "no"))
        XCTAssertEqual(store.pendingPermission?.id, "r3")
        store.decide(.allow(inputJSON: "{\"c\":3}"))
        XCTAssertNil(store.pendingPermission)

        // Every request was answered exactly once, in FIFO order.
        XCTAssertEqual(decisions.map(\.0), ["r1", "r2", "r3"])
        XCTAssertEqual(decisions.map(\.1), [
            .allow(inputJSON: "{\"a\":1}"),
            .deny(message: "no"),
            .allow(inputJSON: "{\"c\":3}"),
        ])
    }

    /// `reset()` must DENY every queued request (head + backlog) so the CLI is
    /// never left blocked on stdin waiting for a control_response that the
    /// teardown silently dropped.
    func testResetDeniesAllQueuedPermissions() async {
        let store = AskResponseStore()
        var decisions: [(String, PermissionDecision)] = []
        store.onPermissionDecision = { decisions.append(($0, $1)) }

        let stream = AsyncStream<AgentSSEEvent> { c in
            c.yield(.permissionRequest(id: "r1", toolName: "Bash", summary: "ls", inputJSON: "{}"))
            c.yield(.permissionRequest(id: "r2", toolName: "Bash", summary: "pwd", inputJSON: "{}"))
            c.finish()
        }
        await store.consume(stream)
        XCTAssertEqual(store.pendingPermission?.id, "r1")

        store.reset()

        // Both ids denied; nothing left pending.
        XCTAssertNil(store.pendingPermission)
        XCTAssertEqual(decisions.map(\.0).sorted(), ["r1", "r2"])
        for (_, decision) in decisions {
            guard case .deny = decision else {
                return XCTFail("reset must deny, got \(decision)")
            }
        }
    }

    /// Same FIFO deny contract for the explicit dismiss/cancel path, exposed as
    /// `denyAllPending()` so the controller's dismiss/cancel handlers can clear
    /// the queue without driving a full reset.
    func testDenyAllPendingDeniesEveryQueuedRequest() async {
        let store = AskResponseStore()
        var decisions: [(String, PermissionDecision)] = []
        store.onPermissionDecision = { decisions.append(($0, $1)) }

        let stream = AsyncStream<AgentSSEEvent> { c in
            c.yield(.permissionRequest(id: "r1", toolName: "Bash", summary: "ls", inputJSON: "{}"))
            c.yield(.permissionRequest(id: "r2", toolName: "Bash", summary: "pwd", inputJSON: "{}"))
            c.yield(.permissionRequest(id: "r3", toolName: "Bash", summary: "id", inputJSON: "{}"))
            c.finish()
        }
        await store.consume(stream)

        store.denyAllPending()

        XCTAssertNil(store.pendingPermission)
        XCTAssertEqual(decisions.map(\.0).sorted(), ["r1", "r2", "r3"])
        for (_, decision) in decisions {
            guard case .deny = decision else {
                return XCTFail("denyAllPending must deny, got \(decision)")
            }
        }
        // Idempotent: a second call after the queue is empty does nothing.
        store.denyAllPending()
        XCTAssertEqual(decisions.count, 3)
    }
}

import XCTest
@testable import Sidekey

/// The MCP client against a real child process speaking stdio JSON-RPC.
final class MCPClientStdioTests: XCTestCase {
    private func client(mode: String = "normal", extra: [String: String] = [:]) throws -> (MCPClient, URL) {
        let fake = try FakeMCPServer.install()
        addTeardownBlock { try? FileManager.default.removeItem(at: fake.directory) }
        let client = MCPClient(transport: MCPStdioTransport(launch: FakeMCPServer.launch(fake.script, mode: mode, log: fake.log, extra: extra)))
        addTeardownBlock { await client.close() }
        return (client, fake.log)
    }

    func testConnectListsAllPagesAndCallsToolWithEnvironmentSecret() async throws {
        let (client, log) = try client(extra: ["SECRET_TOKEN": "tok-123456"])
        try await client.connect(timeout: 10)
        let tools = try await client.listTools(timeout: 5)
        XCTAssertEqual(tools.map(\.name), ["search_issues", "get_me", "create_issue", "delete_repository"])
        XCTAssertEqual(tools[0].readOnlyHint, true)
        XCTAssertEqual(tools[3].destructiveHint, true)
        XCTAssertEqual(tools[0].signature, "search_issues(query*: string)")
        let result = try await client.callTool("search_issues", arguments: .object(["query": .string("retry")]),
                                               timeout: 5, maxCharacters: 1000)
        XCTAssertEqual(result.text, "Found: #42 retry backoff for retry; token=tok-123456",
                       "The secret reaches the server only through its environment")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(FakeMCPServer.calls(log), [#"search_issues {"query":"retry"}"#])
    }

    func testNonJSONStdoutLinesAreSkipped() async throws {
        let (client, _) = try client(mode: "noisy")
        try await client.connect(timeout: 10)
        let tools = try await client.listTools(timeout: 5)
        XCTAssertEqual(tools.count, 4)
    }

    func testHugeResultIsClippedBeforeAnyModelSeesIt() async throws {
        let (client, _) = try client(mode: "huge")
        try await client.connect(timeout: 10)
        let result = try await client.callTool("get_me", arguments: .object([:]), timeout: 5, maxCharacters: 24_000)
        XCTAssertEqual(result.text.count, 24_000)
        XCTAssertTrue(result.shortened)
    }

    func testSlowCallTimesOutAndClientStaysUsable() async throws {
        let (client, _) = try client(mode: "slow")
        try await client.connect(timeout: 10)
        let started = Date()
        do {
            _ = try await client.callTool("get_me", arguments: .object([:]), timeout: 0.5, maxCharacters: 100)
            XCTFail("Expected a timeout")
        } catch let error as MCPError {
            XCTAssertEqual(error, .timedOut(seconds: 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCancellingTheCallingTaskEndsTheWait() async throws {
        let (client, _) = try client(mode: "slow")
        try await client.connect(timeout: 10)
        let task = Task { try await client.callTool("get_me", arguments: .object([:]), timeout: 30, maxCharacters: 100) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch let error as MCPError { XCTAssertEqual(error, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testServerCrashFailsThePendingCallWithAReadableReasonAndMasksSecrets() async throws {
        let (client, log) = try client(mode: "crash_on_call", extra: ["SECRET_TOKEN": "tok-secret-9"])
        try await client.connect(timeout: 10)
        do {
            _ = try await client.callTool("get_me", arguments: .object([:]), timeout: 10, maxCharacters: 100)
            XCTFail("Expected the crash to surface")
        } catch let error as MCPError {
            guard case .exited(let status, let detail) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 3)
            XCTAssertEqual(detail, "fake server starting with token ••••")
            XCTAssertFalse(error.message.contains("tok-secret-9"))
        }
        XCTAssertEqual(FakeMCPServer.calls(log).count, 1)
        let open = await client.isOpen
        XCTAssertFalse(open)
    }

    func testServerThatExitsAtStartIsReported() async throws {
        let (client, _) = try client(mode: "exit_at_start")
        do { try await client.connect(timeout: 10); XCTFail("Expected failure") }
        catch let error as MCPError {
            guard case .exited(let status, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 2)
        }
    }

    func testUnsupportedProtocolIsRefused() async throws {
        let (client, _) = try client(mode: "old_protocol")
        do { try await client.connect(timeout: 10); XCTFail("Expected failure") }
        catch let error as MCPError { XCTAssertEqual(error, .unsupportedProtocol("2023-01-01")) }
    }

    func testMissingExecutableIsNamed() async throws {
        let client = MCPClient(transport: MCPStdioTransport(launch: .init(executable: "/nonexistent/mcp-server", arguments: [], environment: [:])))
        do { try await client.connect(timeout: 5); XCTFail("Expected failure") }
        catch let error as MCPError {
            XCTAssertEqual(error, .commandNotFound("mcp-server"))
            XCTAssertTrue(error.message.contains("mcp-server was not found"))
        }
    }

    func testClosingTheLifelineEndsTheServerGroup() throws {
        let fake = try FakeMCPServer.install()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let exited = expectation(description: "exit")
        let process = try MCPProcess(executable: fake.script.path, arguments: [], environment: ["PATH": "/usr/bin:/bin"],
                                     onLine: { _ in }, onExit: { _, _, _ in exited.fulfill() })
        process.closeLifeline()
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(kill(process.pid, 0), -1, "The group leader is gone")
    }
}

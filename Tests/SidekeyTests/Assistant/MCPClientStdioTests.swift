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
        let tools = try await client.listTools(timeout: 5).tools
        XCTAssertEqual(tools.map(\.name), ["search_issues", "get_me", "create_issue", "delete_repository"])
        XCTAssertEqual(tools[0].readOnlyHint, true)
        XCTAssertEqual(tools[3].destructiveHint, true)
        XCTAssertEqual(tools[0].signature, "search_issues(query*: string)")
        let result = try await client.callListed("search_issues", arguments: .object(["query": .string("retry")]),
                                               timeout: 5, maxCharacters: 1000)
        XCTAssertEqual(result.text, "Found: #42 retry backoff for retry; token=tok-123456",
                       "The secret reaches the server only through its environment")
        XCTAssertFalse(result.isError)
        XCTAssertEqual(FakeMCPServer.calls(log), [#"search_issues {"query":"retry"}"#])
    }

    func testNonJSONStdoutLinesAreSkipped() async throws {
        let (client, _) = try client(mode: "noisy")
        try await client.connect(timeout: 10)
        let tools = try await client.listTools(timeout: 5).tools
        XCTAssertEqual(tools.count, 4)
    }

    func testHugeResultIsClippedBeforeAnyModelSeesIt() async throws {
        let (client, _) = try client(mode: "huge")
        try await client.connect(timeout: 10)
        let result = try await client.callListed("get_me", arguments: .object([:]), timeout: 5, maxCharacters: 24_000)
        XCTAssertEqual(result.text.count, 24_000)
        XCTAssertTrue(result.shortened)
    }

    func testSlowCallTimesOutAndClientStaysUsable() async throws {
        let (client, _) = try client(mode: "slow")
        try await client.connect(timeout: 10)
        let started = Date()
        do {
            _ = try await client.callListed("get_me", arguments: .object([:]), timeout: 0.5, maxCharacters: 100)
            XCTFail("Expected a timeout")
        } catch let error as MCPError {
            XCTAssertEqual(error, .timedOut(seconds: 1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testCancellingTheCallingTaskEndsTheWait() async throws {
        let (client, _) = try client(mode: "slow")
        try await client.connect(timeout: 10)
        let task = Task { try await client.callListed("get_me", arguments: .object([:]), timeout: 30, maxCharacters: 100) }
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
            _ = try await client.callListed("get_me", arguments: .object([:]), timeout: 10, maxCharacters: 100)
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

    // MARK: - Builder review regressions (point 6)

    func testAbsurdNumbersNeverTrap() throws {
        XCTAssertNil(MCPValue.number(1e300).int)
        XCTAssertNil(MCPValue.number(-1e300).int)
        XCTAssertNil(MCPValue.number(.nan).int)
        XCTAssertNil(MCPValue.number(.infinity).int)
        XCTAssertNil(MCPValue.number(1.5).int)
        XCTAssertEqual(MCPValue.number(42).int, 42)
        XCTAssertNoThrow(try MCPValue.number(1e300).encoded())
        let decoded = try MCPValue.decode(Data(#"{"id":1e300}"#.utf8))
        XCTAssertNil(decoded["id"]?.int)
    }

    func testAServerAnsweringWithAbsurdIDsDoesNotCrashTheClient() async throws {
        let (client, _) = try client(mode: "bad_id")
        try await client.connect(timeout: 10)
        let result = try await client.callListed("get_me", arguments: .object([:]), timeout: 5, maxCharacters: 1000)
        XCTAssertTrue(result.text.contains("octo"), "Lines with ids like 1e300 are ignored; the real answer still arrives")
    }

    func testOneHugeLineIsRefusedAsTooLarge() async throws {
        let (client, _) = try client(mode: "huge_line")
        try await client.connect(timeout: 10)
        do {
            _ = try await client.callListed("get_me", arguments: .object([:]), timeout: 20, maxCharacters: 1000)
            XCTFail("Expected tooLarge")
        } catch let error as MCPError {
            guard case .tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testAServerThatStopsReadingItsInputCannotBlockAWrite() async throws {
        let process = try MCPProcess(executable: "/bin/sleep", arguments: ["30"], environment: [:],
                                     onLine: { _ in }, onExit: { _, _, _ in })
        defer { process.stop() }
        let started = Date()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 900_000)
        do { try await process.write(chunk, deadline: Date().addingTimeInterval(0.5)); XCTFail("Expected a timeout") }
        catch let error as MCPError { XCTAssertEqual(error, .timedOut(seconds: 1)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        do { try await process.write(Data(repeating: 1, count: MCPProcess.maxWriteBytes), deadline: .distantFuture); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .tooLarge(limit: MCPProcess.maxWriteBytes)) }
    }

    // MARK: - Second review (ticket 629), point 6: cancellation stops the actual I/O

    /// A write blocked on a server that stops reading ends when its task is
    /// cancelled, well before its deadline, and the half-written server is stopped.
    func testCancellingABlockedWriteStopsTheWriteItself() async throws {
        let launch = MCPStdioLaunch(executable: "/bin/sleep", arguments: ["30"], environment: [:])
        let transport = MCPStdioTransport(launch: launch)
        try await transport.start { _ in }
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 900_000)
        let started = Date()
        let send = Task { try await transport.send(chunk, responseID: nil, deadline: Date().addingTimeInterval(20)) }
        try await Task.sleep(nanoseconds: 300_000_000)
        send.cancel()
        do { try await send.value; XCTFail() } catch let error as MCPError { XCTAssertEqual(error, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The write itself stopped, not just the wait")
        await transport.close()
    }

    /// One deadline covers initialize and the initialized notice: a server
    /// that never reads its input cannot hold connect past it.
    func testConnectHasOneDeadlineForTheWholeHandshake() async throws {
        let client = MCPClient(transport: MCPStdioTransport(launch: MCPStdioLaunch(executable: "/bin/sleep", arguments: ["30"], environment: [:])))
        let started = Date()
        do { try await client.connect(timeout: 1); XCTFail() } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        await client.close()
    }

    /// The pages of one list share one deadline.
    func testAListHasOneDeadlineAcrossPages() async throws {
        let (client, _) = try client(mode: "normal")
        try await client.connect(timeout: 10)
        let (tools, _) = try await client.listTools(timeout: 5)
        XCTAssertEqual(tools.count, 4, "Both pages under one deadline")
    }

    func testTheDeadlineHelperReturnsWithoutWaitingForTheOperation() async throws {
        let started = Date()
        do {
            _ = try await MCPDeadline.run(until: Date().addingTimeInterval(0.3), timeout: .timedOut(seconds: 1)) { () -> Int in
                // Ignores cancellation for a while, as a blocking read would.
                Thread.sleep(forTimeInterval: 2)
                return 1
            }
            XCTFail()
        } catch let error as MCPError { XCTAssertEqual(error, .timedOut(seconds: 1)) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    // MARK: - Point 2: approval is bound to the exact list at dispatch

    func testACallIsSentOnlyUnderTheListEpochLeaseAndPinItWasApprovedWith() async throws {
        let (client, log) = try client()
        try await client.connect(timeout: 10)
        let (tools, epoch) = try await client.listTools(timeout: 5)
        let pin = try XCTUnwrap(tools.first { $0.name == "get_me" }?.pinHash)
        let lease = SourceLease()
        func call(lease: SourceLease = lease, epoch: Int = epoch, pin: String = pin) async -> MCPError? {
            do { _ = try await client.callTool("get_me", arguments: .object([:]), timeout: 5, maxCharacters: 100,
                                               lease: lease, epoch: epoch, expectedPin: pin); return nil }
            catch { return error as? MCPError }
        }
        let wrongPin = await call(pin: "other")
        XCTAssertEqual(wrongPin, .notAllowed)
        let wrongEpoch = await call(epoch: epoch + 1)
        XCTAssertEqual(wrongEpoch, .notAllowed)
        let revoked = SourceLease(); revoked.revoke()
        let revokedCall = await call(lease: revoked)
        XCTAssertEqual(revokedCall, .notAllowed)
        XCTAssertEqual(FakeMCPServer.calls(log), [], "Nothing was sent")
        let allowed = await call()
        XCTAssertNil(allowed)
        XCTAssertEqual(FakeMCPServer.calls(log), ["get_me {}"])
    }
}

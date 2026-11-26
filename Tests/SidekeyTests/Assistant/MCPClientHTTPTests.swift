import XCTest
@testable import Sidekey

/// Streamable HTTP against a stubbed server: JSON and SSE replies, session
/// header, auth failures, size limit and the HTTPS rule.
final class MCPClientHTTPTests: XCTestCase {
    private func session() -> URLSession {
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel(); StubURLProtocol.reset() }
        return session
    }

    private static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    /// A server that answers initialize with JSON and everything else with SSE.
    private func serve(sse: Bool = true, callText: String = "ok", status: Int = 200) {
        StubURLProtocol.handler = { request in
            let body = StubURLProtocol.capturedBodies.last ?? Data()
            let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let method = message["method"] as? String ?? ""
            let id = message["id"] ?? 0
            if status != 200 { return (status, [:], Data()) }
            if message["id"] == nil { return (202, [:], Data()) }
            let result: [String: Any]
            switch method {
            case "initialize": result = ["protocolVersion": "2025-06-18", "capabilities": [:], "serverInfo": ["name": "stub"]]
            case "tools/list": result = ["tools": [["name": "search", "description": "Search", "inputSchema": ["type": "object"],
                                                    "annotations": ["readOnlyHint": true]]]]
            default: result = ["content": [["type": "text", "text": callText]]]
            }
            let reply = Self.json(["jsonrpc": "2.0", "id": id, "result": result])
            if sse && method != "initialize" {
                var stream = Data(": keep-alive\n\nevent: message\n".utf8)
                stream.append(Data("data: ".utf8)); stream.append(Self.json(["jsonrpc": "2.0", "method": "notifications/progress", "params": [:]])); stream.append(Data("\n\n".utf8))
                stream.append(Data("data: ".utf8)); stream.append(reply); stream.append(Data("\n\n".utf8))
                return (200, ["Content-Type": "text/event-stream"], stream)
            }
            return (200, ["Content-Type": "application/json", "Mcp-Session-Id": "session-1"], reply)
        }
    }

    func testJSONAndSSERepliesSessionHeaderAndToken() async throws {
        let session = session()
        serve()
        let client = MCPClient(transport: MCPHTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!,
                                                           headers: ["Authorization": "Bearer tok"], session: session))
        try await client.connect(timeout: 5)
        let tools = try await client.listTools(timeout: 5)
        XCTAssertEqual(tools.map(\.name), ["search"])
        let result = try await client.callTool("search", arguments: .object(["query": .string("retry")]), timeout: 5, maxCharacters: 100)
        XCTAssertEqual(result.text, "ok")
        let requests = StubURLProtocol.capturedRequests
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer tok" })
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Mcp-Session-Id"))
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Mcp-Session-Id"), "session-1")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-06-18")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Accept"), "application/json, text/event-stream")
        await client.close()
    }

    func testRejectedTokenIsAReadableUnauthorizedError() async throws {
        let session = session()
        serve(status: 401)
        let client = MCPClient(transport: MCPHTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!, headers: [:], session: session))
        do { try await client.connect(timeout: 5); XCTFail() }
        catch let error as MCPError {
            XCTAssertEqual(error, .unauthorized(status: 401))
            XCTAssertTrue(error.message.contains("Check or replace the token"))
        }
    }

    func testHugeResultIsClipped() async throws {
        let session = session()
        serve(sse: false, callText: String(repeating: "y", count: 60_000))
        let client = MCPClient(transport: MCPHTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!, headers: [:], session: session))
        try await client.connect(timeout: 5)
        let result = try await client.callTool("search", arguments: .object([:]), timeout: 5, maxCharacters: 24_000)
        XCTAssertEqual(result.text.count, 24_000)
        XCTAssertTrue(result.shortened)
    }

    func testOversizedResponseIsRefused() async throws {
        let session = session()
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "application/json"], Data(count: MCPHTTPTransport.maxResponseBytes + 10)) }
        let transport = MCPHTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!, headers: [:], session: session)
        try await transport.start { _ in }
        do { try await transport.send(Data("{}".utf8), responseID: 1); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .tooLarge(limit: MCPHTTPTransport.maxResponseBytes)) }
    }

    func testPlainHTTPOnlyForThisMac() async throws {
        XCTAssertTrue(MCPHTTPTransport.isAllowed(URL(string: "http://127.0.0.1:3000/mcp")!))
        XCTAssertTrue(MCPHTTPTransport.isAllowed(URL(string: "http://localhost/mcp")!))
        XCTAssertFalse(MCPHTTPTransport.isAllowed(URL(string: "http://example.com/mcp")!))
        XCTAssertFalse(MCPHTTPTransport.isAllowed(URL(string: "https://user:pass@example.com/mcp")!))
        let client = MCPClient(transport: MCPHTTPTransport(url: URL(string: "http://example.com/mcp")!, headers: [:]))
        do { try await client.connect(timeout: 1); XCTFail() }
        catch let error as MCPError { XCTAssertEqual(error, .insecureURL) }
    }
}

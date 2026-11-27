import XCTest
@testable import Sidekey

/// Fourth review of PR #491 (ticket 685), as classes: every rendering of a
/// known value × every clip offset; every protocol control token as a mask ×
/// the whole client flow; every way a connect fails × a slow transport close.
final class SourceRedactionProtocolClassTests: XCTestCase {
    static let numeric = "873416925701293"
    static let text = #"tok"en/with\slash_9f8e7d6c"#
    static let values = [numeric, text, "synthetic_value_for_secret_redaction_check"]

    static func leaks(_ output: String, _ value: String) -> Bool {
        let characters = Array(value)
        let width = min(8, characters.count)
        return (0...(characters.count - width)).contains { output.contains(String(characters[$0..<$0 + width])) }
    }

    /// Every place a value can sit in a tool result, as a function of the padding before it.
    static func placements(_ value: String) -> [(String, (String) -> MCPValue)] {
        var list: [(String, (String) -> MCPValue)] = [
            ("text", { .object(["content": .array([.object(["type": .string("text"), "text": .string($0 + value)])])]) }),
            ("structured string", { .object(["structuredContent": .object(["a": .string($0), "b": .string(value)])]) }),
            ("structured key", { .object(["structuredContent": .object(["a": .string($0), value: .bool(true)])]) }),
            ("resource text", { .object(["content": .array([.object(["type": .string("resource"),
                                                                    "resource": .object(["text": .string($0 + value)])])])]) }),
            ("resource link", { .object(["content": .array([.object(["type": .string("resource_link"), "name": .string($0),
                                                                    "uri": .string("https://x.example/" + value)])])]) }),
        ]
        if let number = Double(value) {
            list.append(("structured number", { .object(["structuredContent": .object(["a": .string($0), "n": .number(number)])]) }))
            list.append(("nested number", { .object(["structuredContent": .object(["a": .string($0),
                                                                                   "z": .array([.object(["n": .number(number)])])])]) }))
        }
        return list
    }

    func testEveryRenderingOfAKnownValueIsRedactedBeforeEveryClipOffset() {
        let limit = 300
        for value in Self.values {
            let mask = SourceSecretMask([value])
            for (label, make) in Self.placements(value) {
                // Find where the value starts in the full rendering, then move it across the limit.
                let unclipped = MCPClient.toolResult(make(""), maxCharacters: 1_000_000).text
                let escaped = String(MCPValue.string(value).canonicalJSON.dropFirst().dropLast())
                let found = unclipped.range(of: value) ?? unclipped.range(of: escaped)
                let start = found.map { unclipped.distance(from: unclipped.startIndex, to: $0.lowerBound) }
                guard let start else { XCTFail("\(label): value not rendered"); continue }
                for inside in 1..<value.count {
                    let padding = String(repeating: "x", count: max(0, limit - start - inside))
                    let result = MCPClient.toolResult(make(padding), maxCharacters: limit, mask: mask)
                    XCTAssertFalse(Self.leaks(result.text, value), "\(label), \(inside) characters inside the limit: …\(result.text.suffix(40))")
                }
            }
        }
    }

    func testToolMetadataAndErrorsRedactEveryRenderingBeforeTheirClips() async throws {
        for value in Self.values {
            let mask = SourceSecretMask([value])
            let number = Double(value)
            let entry = MCPValue.object([
                "name": .string("search"),
                "description": .string(String(repeating: "d", count: 1995) + value),
                "inputSchema": .object(["type": .string("object"), "properties": .object([
                    "q": .object(["type": .string("string"), "default": number.map(MCPValue.number) ?? .string(value)])])]),
            ])
            let tool = try XCTUnwrap(MCPToolInfo(entry, mask: mask))
            for surface in [tool.description, tool.inputSchema.canonicalJSON, tool.signature] {
                XCTAssertFalse(Self.leaks(surface, value), surface.suffix(60).description)
            }
            // Through the client: a JSON-RPC error with the value in its message and (numeric) code.
            let transport = ProtocolTransport()
            transport.errorOnCall = (code: number.map { Int($0) } ?? -32000, message: String(repeating: "m", count: 190) + value)
            let client = MCPClient(transport: transport, mask: mask)
            try await client.connect(timeout: 2)
            let (tools, epoch) = try await client.listTools(timeout: 2)
            do {
                _ = try await client.callTool("find_first", arguments: .object([:]), timeout: 2, maxCharacters: 100,
                                              lease: SourceLease(), epoch: epoch, expectedPin: tools[0].pinHash)
                XCTFail()
            } catch let error as MCPError {
                for surface in [error.message, error.agentMessage, "\(error)"] {
                    XCTAssertFalse(Self.leaks(surface, value), surface)
                }
            }
            await client.close()
        }
    }

    // MARK: - Control data is never rewritten

    static let controlTokens = ["2025-06-18", "protocolVersion", "result", "jsonrpc", "initialize", "notifications/initialized",
                                "tools/list", "tools/call", "nextCursor", "fixture_cursor", "cursor",
                                "notifications/tools/list_changed", "list_changed", "content", "isError", "capabilities",
                                "method", "params", "serverInfo", "structuredContent", "description", "inputSchema",
                                "resource_link", "annotations", "readOnlyHint"]

    func testAMaskMatchingAnyProtocolTokenLeavesTheWholeFlowIntact() async throws {
        for token in Self.controlTokens {
            let transport = ProtocolTransport()
            let client = MCPClient(transport: transport, mask: SourceSecretMask([token]))
            do { try await client.connect(timeout: 2) } catch { XCTFail("\(token): connect \(error)"); continue }
            let (tools, epoch) = try await client.listTools(timeout: 2)
            XCTAssertEqual(tools.map(\.name), ["find_first", "find_second"], "\(token): pagination")
            let answer = try await client.callTool("find_first", arguments: .object([:]), timeout: 2, maxCharacters: 100,
                                                   lease: SourceLease(), epoch: epoch, expectedPin: tools[0].pinHash)
            XCTAssertEqual(answer.text, "answer", token)
            let (fresh, current) = try await client.listTools(timeout: 2)
            transport.noticeBeforeAnswer = true
            do {
                _ = try await client.callTool("find_first", arguments: .object([:]), timeout: 2, maxCharacters: 100,
                                              lease: SourceLease(), epoch: current, expectedPin: fresh[0].pinHash)
                XCTFail("\(token): a list-change notice must still revoke")
            } catch let error as MCPError { XCTAssertEqual(error, .notAllowed, token) }
            let retired = await client.currentEpoch
            XCTAssertNil(retired, token)
            await client.close()
        }
    }

    // MARK: - A failed connect never waits for the transport to close

    enum Failure: CaseIterable { case noAnswer, startThrows, invalidResponse, unsupportedProtocol, cancelled }

    func testEveryFailedConnectReturnsAtOnceAndStillClosesTheTransport() async throws {
        for failure in Failure.allCases {
            let transport = ProtocolTransport()
            transport.closeDelay = 0.35
            switch failure {
            case .noAnswer: transport.silent = true
            case .startThrows: transport.startError = .commandNotFound("srv")
            case .invalidResponse: transport.initializeResult = .object([:])
            case .unsupportedProtocol: transport.initializeResult = .object(["protocolVersion": .string("1999-01-01")])
            case .cancelled: transport.silent = true
            }
            let client = MCPClient(transport: transport)
            let started = Date()
            let connecting = Task { try await client.connect(timeout: failure == .cancelled ? 5 : 0.035) }
            if failure == .cancelled { try await Task.sleep(nanoseconds: 50_000_000); connecting.cancel() }
            do { try await connecting.value; XCTFail("\(failure)") } catch {}
            let waited = Date().timeIntervalSince(started) - (failure == .cancelled ? 0.05 : 0)
            XCTAssertLessThan(waited, 0.2, "\(failure): the caller waited for closing")
            try await Task.sleep(nanoseconds: 600_000_000)
            XCTAssertTrue(transport.closed, "\(failure): the transport was still closed")
        }
    }
}

/// A scripted MCP server: initialize, a two-page list with an opaque cursor,
/// calls that answer, fail or are preceded by a change notice, and a slow close.
final class ProtocolTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var onEvent: (@Sendable (MCPTransportEvent) -> Void)?
    var initializeResult: MCPValue = .object(["protocolVersion": .string("2025-06-18"), "capabilities": .object([:]),
                                              "serverInfo": .object(["name": .string("scripted")])])
    var errorOnCall: (code: Int, message: String)?
    var noticeBeforeAnswer = false
    var silent = false
    var startError: MCPError?
    var closeDelay: TimeInterval = 0
    private var isClosed = false
    var closed: Bool { lock.withLock { isClosed } }

    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws {
        if let startError { throw startError }
        lock.withLock { self.onEvent = onEvent }
    }

    func send(_ message: Data, responseID: Int?, deadline: Date, authorize: @escaping @Sendable () -> Bool) async throws {
        guard !silent, authorize() else { return }
        let value = try MCPValue.decode(message)
        guard let method = value["method"]?.string, let id = value["id"] else { return }
        let deliver = lock.withLock { onEvent }
        func tool(_ name: String) -> MCPValue {
            .object(["name": .string(name), "description": .string(name), "inputSchema": .object(["type": .string("object")])])
        }
        var reply: [String: MCPValue] = ["jsonrpc": .string("2.0"), "id": id]
        switch method {
        case "initialize": reply["result"] = initializeResult
        case "tools/list":
            if value["params"]?["cursor"]?.string == "fixture_cursor" {
                reply["result"] = .object(["tools": .array([tool("find_second")])])
            } else {
                reply["result"] = .object(["tools": .array([tool("find_first")]), "nextCursor": .string("fixture_cursor")])
            }
        default:
            if noticeBeforeAnswer {
                deliver?(.message(try MCPValue.object(["jsonrpc": .string("2.0"),
                                                       "method": .string("notifications/tools/list_changed")]).encoded()))
            }
            if let errorOnCall {
                reply["error"] = .object(["code": .number(Double(errorOnCall.code)), "message": .string(errorOnCall.message)])
            } else {
                reply["result"] = .object(["content": .array([.object(["type": .string("text"), "text": .string("answer")])])])
            }
        }
        deliver?(.message(try MCPValue.object(reply).encoded()))
    }

    func setProtocolVersion(_ version: String) {}

    func close() async {
        if closeDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(closeDelay * 1_000_000_000)) }
        lock.withLock { isClosed = true; onEvent = nil }
    }
}

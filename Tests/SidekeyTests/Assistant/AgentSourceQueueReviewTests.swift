import Foundation
import XCTest
@testable import Sidekey

@MainActor
final class AgentSourceQueueReviewTests: XCTestCase {
    func testMaskLeavesNegotiationAndTheResponseEnvelopeIntact() async throws {
        for (label, fixtureValue) in [("protocol version", "2025-06-18"), ("response field", "result")] {
            let client = MCPClient(transport: ScriptedTransport(), mask: SourceSecretMask([fixtureValue]))
            do {
                try await client.connect(timeout: 1)
            } catch {
                XCTFail("A mask matching a standard \(label) changed protocol processing")
            }
            await client.close()
        }
    }

    func testListChangeStillRevokesApprovalWhenMaskMatchesAMethodComponent() async throws {
        for mask in [SourceSecretMask([]), SourceSecretMask(["list_changed"])] {
            let transport = ScriptedTransport()
            let client = MCPClient(transport: transport, mask: mask)
            try await client.connect(timeout: 1)
            let (tools, epoch) = try await client.listTools(timeout: 1)
            let tool = try XCTUnwrap(tools.first)
            transport.noticeBeforeAnswer = true
            do {
                _ = try await client.callTool(tool.name, arguments: .object([:]), timeout: 1, maxCharacters: 100,
                                              lease: SourceLease(), epoch: epoch, expectedPin: tool.pinHash)
                XCTFail("A normal list-change notification preceding the answer must invalidate its approval")
            } catch let error as MCPError {
                XCTAssertEqual(error, .notAllowed)
            }
            let current = await client.currentEpoch
            XCTAssertNil(current, "The previous list must be retired")
            await client.close()
        }
    }

    func testPaddingAndTruncationDoNotRetainNumericFixtureText() throws {
        let fixture = "873416925701293"
        let fixtureNumber = try XCTUnwrap(Double(fixture))
        let mask = SourceSecretMask([fixture])
        let limit = 24_000
        func structured(_ padding: String) -> MCPValue {
            .object(["a": .string(padding), "n": .number(fixtureNumber)])
        }
        let baseline = structured("").canonicalJSON
        let range = try XCTUnwrap(baseline.range(of: fixture))
        let offset = baseline.distance(from: baseline.startIndex, to: range.lowerBound)
        let padding = String(repeating: "x", count: limit - offset - 8)
        let result = MCPValue.object(["structuredContent": structured(padding)])
        let clipped = MCPClient.toolResult(mask.value(result), maxCharacters: limit)
        XCTAssertTrue(clipped.shortened)
        XCTAssertFalse(mask.result(clipped).text.contains(String(fixture.prefix(8))),
                       "A numeric fixture represented in JSON must be masked before clipping")
    }

    func testConnectDeadlineDoesNotWaitForClosingTheTransport() async throws {
        let transport = CloseDelayTransport()
        let client = MCPClient(transport: transport)
        let start = ContinuousClock.now
        do {
            try await client.connect(timeout: 0.035)
            XCTFail("Initialize has no response")
        } catch let error as MCPError {
            guard case .timedOut = error else { return XCTFail("Expected a timeout") }
        }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(200),
                          "Connect must return at its deadline even if making the transport close takes longer")
    }

    func testMaskDoesNotChangeOpaquePaginationCursor() async throws {
        let transport = PagedTransport()
        let client = MCPClient(transport: transport, mask: SourceSecretMask(["fixture_cursor"]))
        try await client.connect(timeout: 1)
        let (tools, _) = try await client.listTools(timeout: 1)
        XCTAssertEqual(tools.map(\.name), ["find_first", "find_second"])
        await client.close()
    }
}

private final class CloseDelayTransport: MCPTransport, @unchecked Sendable {
    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws {}
    func send(_ message: Data, responseID: Int?, deadline: Date, authorize: @escaping @Sendable () -> Bool) async throws {}
    func setProtocolVersion(_ version: String) {}
    func close() async { try? await Task.sleep(for: .milliseconds(350)) }
}

private final class PagedTransport: MCPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (MCPTransportEvent) -> Void)?

    func start(onEvent: @escaping @Sendable (MCPTransportEvent) -> Void) async throws {
        lock.withLock { callback = onEvent }
    }

    func send(_ message: Data, responseID: Int?, deadline: Date, authorize: @escaping @Sendable () -> Bool) async throws {
        let value = try MCPValue.decode(message)
        guard let method = value["method"]?.string, let id = value["id"] else { return }
        let result: MCPValue
        if method == "initialize" {
            result = .object(["protocolVersion": .string("2025-06-18")])
        } else if let cursor = value["params"]?["cursor"]?.string {
            result = .object(["tools": .array(cursor == "fixture_cursor" ? [tool("find_second")] : [])])
        } else {
            result = .object(["tools": .array([tool("find_first")]), "nextCursor": .string("fixture_cursor")])
        }
        let data = try MCPValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).encoded()
        lock.withLock { callback }?(.message(data))
    }

    private func tool(_ name: String) -> MCPValue { .object(["name": .string(name)]) }
    func setProtocolVersion(_ version: String) {}
    func close() async { lock.withLock { callback = nil } }
}

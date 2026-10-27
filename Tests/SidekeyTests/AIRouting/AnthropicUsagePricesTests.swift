import XCTest
@testable import Sidekey

final class AnthropicUsagePricesTests: XCTestCase {
    private func cost(_ model: String, _ usage: [String: Any]) -> Double? {
        AnthropicUsagePrices.cost(model: model, usage: usage)
    }

    func testOpusAgentTurnPricesEveryTokenCategory() throws {
        // 1,000 input × $4 + 2,000 5m writes × $5 + 1,000 1h writes × $8
        // + 10,000 cache reads × $0.20 + 500 output × $20, per million tokens.
        let usage: [String: Any] = [
            "input_tokens": 1000, "output_tokens": 500, "cache_read_input_tokens": 10_000,
            "cache_creation_input_tokens": 3000,
            "cache_creation": ["ephemeral_5m_input_tokens": 2000, "ephemeral_1h_input_tokens": 1000],
        ]
        XCTAssertEqual(try XCTUnwrap(cost("claude-opus-5-5", usage)), 0.034, accuracy: 1e-12)
    }

    func testCacheWritesWithoutBreakdownCountAsFiveMinuteWrites() throws {
        let usage: [String: Any] = ["input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 1_000_000]
        XCTAssertEqual(try XCTUnwrap(cost("claude-sonnet-5-5", usage)), 2.5, accuracy: 1e-12)
    }

    func testNewerFamilyIsNotPricedAsItsShorterPrefixAndSnapshotsResolve() {
        XCTAssertEqual(AnthropicUsagePrices.rates(model: "claude-opus-5-5", promptTokens: 0)?.input, 4)
        XCTAssertEqual(AnthropicUsagePrices.rates(model: "claude-opus-5", promptTokens: 0)?.input, 5)
        XCTAssertEqual(AnthropicUsagePrices.rates(model: "claude-sonnet-4-5-20250929", promptTokens: 0)?.input, 3)
        XCTAssertEqual(AnthropicUsagePrices.rates(model: "claude-opus-4-20250514", promptTokens: 0)?.input, 15)
        XCTAssertEqual(AnthropicUsagePrices.rates(model: "Claude-Haiku-4-5", promptTokens: 0)?.output, 5)
        XCTAssertNil(AnthropicUsagePrices.rates(model: "claude-opus-55", promptTokens: 0))
        XCTAssertNil(AnthropicUsagePrices.rates(model: "anthropic/claude-sonnet-5.5", promptTokens: 0),
                     "OpenRouter IDs report their own cost and must not be estimated here")
    }

    func testHaikuLongPromptTierStartsAboveOneHundredThousandPromptTokens() throws {
        let atLimit: [String: Any] = ["input_tokens": 40_000, "cache_read_input_tokens": 60_000, "output_tokens": 0]
        let over: [String: Any] = ["input_tokens": 40_001, "cache_read_input_tokens": 60_000, "output_tokens": 0]
        XCTAssertEqual(try XCTUnwrap(cost("claude-haiku-5-5", atLimit)), 0.0046, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(cost("claude-haiku-5-5", over)), 0.0230005, accuracy: 1e-12)
    }

    func testUSInferenceAddsTenPercent() throws {
        let usage: [String: Any] = ["input_tokens": 1_000_000, "output_tokens": 0, "inference_geo": "us"]
        XCTAssertEqual(try XCTUnwrap(cost("claude-sonnet-5-5", usage)), 2.2, accuracy: 1e-12)
    }

    func testUnknownOrIncompleteUsageStaysUnavailableNeverZero() {
        XCTAssertNil(AnthropicUsagePrices.cost(model: "claude-opus-5-5", usage: nil))
        XCTAssertNil(cost("claude-opus-5-5", ["input_tokens": 10]))
        XCTAssertNil(cost("claude-opus-5-5", ["input_tokens": 10, "output_tokens": true]))
        XCTAssertNil(cost("claude-opus-5-5", ["input_tokens": -1, "output_tokens": 1]))
        XCTAssertNil(cost("claude-next-model", ["input_tokens": 10, "output_tokens": 1]))
        XCTAssertNil(cost("claude-opus-5-5", ["input_tokens": 10, "output_tokens": 1, "speed": "fast"]))
        XCTAssertNotNil(cost("claude-opus-5-5", ["input_tokens": 10, "output_tokens": 1, "speed": "standard"]))
    }

    func testDirectAnthropicTextRequestRecordsEstimatedCost() async throws {
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        var replies = [
            #"{"content":[{"type":"text","text":"clean"}],"stop_reason":"end_turn","usage":{"input_tokens":1000,"output_tokens":100}}"#,
            #"{"content":[{"type":"text","text":"clean"}],"stop_reason":"end_turn"}"#,
        ]
        StubURLProtocol.handler = { _ in (200, [:], Data(replies.removeFirst().utf8)) }
        var recorded: [AIUsageEvent] = []
        let client = OpenRouterLLMClient(session: session, usageSink: { recorded.append($0) })
        let context = AIUsageContext(feature: .dropSmartCleanup, account: .anthropic, model: "claude-sonnet-5-5")
        for _ in 0..<2 {
            let text = try await AIUsageTaskScope.$context.withValue(context) {
                try await client.complete(endpoint: .anthropic(apiKey: "key"), model: "claude-sonnet-5-5",
                                          messages: [.init(role: "user", content: "text")])
            }
            XCTAssertEqual(text, "clean")
        }
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(try XCTUnwrap(recorded[0].amount), 0.003, accuracy: 1e-12)
        XCTAssertEqual(recorded[0].basis, .estimated)
        XCTAssertNil(recorded[1].amount, "A reply without usage is unpriced, not free")
        XCTAssertEqual(recorded[1].basis, .unavailable)
    }
}

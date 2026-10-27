import XCTest
@testable import Sidekey

final class SonioxUsagePricesTests: XCTestCase {
    private func event(_ reference: String = "take-a", model: String = "stt-rt-v5", job: Bool = false,
                       at date: Date = Date()) -> AIUsageEvent {
        .speech(.init(feature: .dropFast, account: .soniox, model: model), seconds: 60,
                id: (job ? "soniox-job:" : "soniox:") + reference, at: date)
    }
    private func row(_ id: String = "request-a", reference: String = "take-a", model: String = "stt-rt-v5",
                     amount: Any = "0.0012340000", scope: String = "api") -> [String: Any] {
        ["uuid": id, "client_reference_id": reference, "model": model, "cost_usd": amount, "request_scope": scope]
    }
    private func page(_ rows: [[String: Any]], cursor: String? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["usage_logs": rows, "next_page_cursor": cursor as Any? ?? NSNull()])
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let result = URLSession(configuration: config)
        addTeardownBlock { result.invalidateAndCancel(); StubURLProtocol.reset() }
        return result
    }

    func test_exact_reference_and_model_replace_estimate_without_importing_other_usage() throws {
        let original = event()
        let entries = try SonioxUsagePrices.parse(page([
            row(), row("unrelated", reference: "other-app", amount: "500"),
            row("other-model", model: "different", amount: "600"), row("playground", amount: "700", scope: "playground")
        ])).entries
        let priced = SonioxUsagePrices.match([original], entries: entries)
        XCTAssertEqual(priced.count, 1); XCTAssertEqual(priced[0].amount, 0.001234)
        XCTAssertEqual(priced[0].basis, .reported); XCTAssertEqual(priced[0].context, original.context)
        XCTAssertEqual(priced[0].createdAt, original.createdAt); XCTAssertEqual(priced[0].audioSeconds, 60)
        XCTAssertEqual(priced[0].id, original.id)
        XCTAssertTrue(SonioxUsagePrices.match([event("missing")], entries: entries).isEmpty)
        XCTAssertTrue(SonioxUsagePrices.match([event("request-a")], entries: entries).isEmpty,
                      "a client reference is never guessed from a provider request UUID")
        XCTAssertEqual(SonioxUsagePrices.match([event("request-a", job: true)], entries: entries).count, 1)
    }

    func test_ambiguous_and_invalid_prices_leave_estimates_while_reported_zero_is_valid() throws {
        for amount: Any in [true, -1, "NaN", "Infinity", "-0.01", NSNull()] {
            XCTAssertTrue(try SonioxUsagePrices.parse(page([row(amount: amount)])).entries.isEmpty)
        }
        let duplicate = try SonioxUsagePrices.parse(page([row(), row("second-request")])).entries
        XCTAssertTrue(SonioxUsagePrices.match([event()], entries: duplicate).isEmpty)
        let zero = try SonioxUsagePrices.parse(page([row(amount: "0.0000000000")])).entries
        XCTAssertEqual(SonioxUsagePrices.match([event()], entries: zero).first?.amount, 0)
        XCTAssertThrowsError(try SonioxUsagePrices.parse(Data("{}".utf8)))
    }

    func test_pagination_deduplicates_requests_and_uses_only_authorization_header() async throws {
        let first = try page([row()], cursor: "next"), second = try page([row(), row("request-b", reference: "take-b", amount: "0.002")])
        let start = Date(timeIntervalSince1970: 1_792_512_000), now = start.addingTimeInterval(3600)
        let urlSession = session()
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/usage-logs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-secret"))
            let params = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(params.first { $0.name == "sort" }?.value, "end_time_asc")
            let formatter = ISO8601DateFormatter()
            let end = formatter.date(from: params.first { $0.name == "end_time" }!.value!)!
            XCTAssertGreaterThan(end, start.addingTimeInterval(60), "request end-time window extends beyond the event start")
            return (200, [:], params.contains { $0.name == "cursor" } ? second : first)
        }
        let prices = try await SonioxUsagePrices(session: urlSession, readKey: { "fixture-secret" })
            .prices(for: [event(at: start), event("take-b", at: start)], now: now)
        XCTAssertEqual(calls, 2); XCTAssertEqual(prices.count, 2)
        XCTAssertEqual(prices.compactMap(\.amount).reduce(0, +), 0.003234, accuracy: 0.00000001)
    }

    func test_api_failure_and_untracked_history_keep_local_estimate() async throws {
        let urlSession = session()
        StubURLProtocol.handler = { _ in (403, [:], Data()) }
        let client = SonioxUsagePrices(session: urlSession, readKey: { "fixture" })
        do { _ = try await client.prices(for: [event()]); XCTFail("403 became a reported price") } catch {}
        let old = AIUsageEvent.speech(.init(feature: .dropFast, account: .soniox, model: "stt-rt-v5"), seconds: 3600)
        let prices = try await client.prices(for: [old])
        XCTAssertTrue(prices.isEmpty); XCTAssertEqual(old.amount, 0.12); XCTAssertEqual(old.basis, .estimated)
    }

    func test_long_period_uses_windows_no_longer_than_31_days_and_same_cursor_is_bounded() async throws {
        let urlSession = session(), now = Date(timeIntervalSince1970: 1_792_512_000)
        let empty = try page([]), looping = try page([], cursor: "repeat")
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let formatter = ISO8601DateFormatter()
            let a = formatter.date(from: query.first { $0.name == "start_time" }!.value!)!
            let b = formatter.date(from: query.first { $0.name == "end_time" }!.value!)!
            XCTAssertLessThanOrEqual(b.timeIntervalSince(a), 31 * 86400)
            return (200, [:], empty)
        }
        _ = try await SonioxUsagePrices(session: urlSession, readKey: { "fixture" })
            .prices(for: [event(at: now.addingTimeInterval(-40 * 86400)), event(at: now)], now: now)
        XCTAssertEqual(calls, 2)
        calls = 0
        StubURLProtocol.handler = { _ in calls += 1; return (200, [:], looping) }
        do {
            _ = try await SonioxUsagePrices(session: urlSession, readKey: { "fixture" }).prices(for: [event(at: now)], now: now)
            XCTFail("repeated cursor was not stopped")
        } catch SonioxUsagePriceError.invalidResponse {} catch { XCTFail("unexpected error") }
        XCTAssertEqual(calls, 2)
    }

    func test_expired_history_does_not_block_recent_prices_or_delayed_job_completion() async throws {
        let urlSession = session(), now = Date(timeIntervalSince1970: 1_792_512_000)
        let data = try page([row(reference: "recent"), row("delayed-job", reference: "queued", amount: "0.02")])
        StubURLProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let formatter = ISO8601DateFormatter()
            let start = formatter.date(from: query.first { $0.name == "start_time" }!.value!)!
            XCTAssertGreaterThan(start, now.addingTimeInterval(-91 * 86400))
            return (200, [:], data)
        }
        let prices = try await SonioxUsagePrices(session: urlSession, readKey: { "fixture" }).prices(for: [
            event("expired", at: now.addingTimeInterval(-100 * 86400)),
            event("queued", at: now.addingTimeInterval(-3 * 86400)),
            event("recent", at: now.addingTimeInterval(-86400))
        ], now: now)
        XCTAssertEqual(Set(prices.map(\.id)), Set(["soniox:queued", "soniox:recent"]))
    }

    func test_reported_price_persists_once_and_cannot_be_downgraded_or_reassigned() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AIUsageStore(url: dir.appendingPathComponent("usage.sqlite")), original = event(at: Date(timeIntervalSince1970: 1_792_512_000))
        try await store.insert(original)
        let exact = SonioxUsagePrices.match([original], entries: [SonioxUsagePrices.Entry(id: "request", reference: "take-a", model: "stt-rt-v5", amount: 0.001)])[0]
        try await store.insert(exact); try await store.insert(exact); try await store.insert(original)
        let reopened = AIUsageStore(url: dir.appendingPathComponent("usage.sqlite"))
        let saved = try await reopened.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(saved, [exact])
        let wrong = AIUsageEvent(id: original.id, createdAt: original.createdAt,
            context: .init(feature: .agentVoice, account: .soniox, model: original.context.model),
            currency: .usd, amount: 99, basis: .reported)
        try await reopened.insert(wrong)
        let after = try await reopened.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(after, [exact])
    }

    @MainActor func test_costs_keeps_estimate_on_api_failure_and_upgrades_on_later_refresh() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AIUsageStore(url: dir.appendingPathComponent("usage.sqlite")), original = event(at: Date(timeIntervalSince1970: 1_792_512_000))
        try await store.insert(original)
        var available = false
        let model = AIUsageCostsViewModel(store: store, loadPrices: { events in
            if !available { return .init(events: events, sonioxUnavailable: true) }
            return .init(events: SonioxUsagePrices.match(events, entries: [
                .init(id: "request", reference: "take-a", model: "stt-rt-v5", amount: 0.001)
            ]))
        })
        let interval = DateInterval(start: original.createdAt.addingTimeInterval(-1), duration: 86400)
        await model.load(interval)
        XCTAssertEqual(model.events, [original]); XCTAssertNotNil(model.pricingMessage)
        XCTAssertEqual(AIUsagePrice(events: model.events).lines.first?.detail, "Estimated")
        available = true
        await model.load(interval)
        XCTAssertEqual(model.events.first?.amount, 0.001); XCTAssertEqual(model.events.first?.basis, .reported)
        XCTAssertNil(model.pricingMessage)
        let reopened = AIUsageStore(url: dir.appendingPathComponent("usage.sqlite"))
        let saved = try await reopened.events(from: interval.start, to: interval.end)
        XCTAssertEqual(saved, model.events)
    }
}

import XCTest
@testable import Sidekey

final class ElevenLabsCreditUsageTests: XCTestCase {
    private func table(_ rows: [[Any]], creditUnit: String = "credits") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "columns": ["model", "product_type", "hashed_xi_api_key", "api_key_name", "timestamp", "total_usage", "total_minutes", "total_cost"],
            "column_units": [NSNull(), NSNull(), NSNull(), NSNull(), NSNull(), creditUnit, "min", "usd"],
            "rows": rows
        ])
    }
    private func row(_ credits: Any = 180, minutes: Any = 10, model: String = "scribe_v2_realtime", key: String = "fixture-key-id") -> [Any] {
        [model, "STT", key, "My key", "2026-10-20T00:00:00Z", credits, minutes, 0.065]
    }

    func test_live_usage_schema_sums_days_per_key_and_model_without_summing_usd() throws {
        let usage = try ElevenLabsCreditUsage.parse(table([
            row("180", minutes: "10"), row(36, minutes: 2),
            row(90, minutes: 5, key: "another-key"), row(15, minutes: 5, model: "different-model")
        ]))
        XCTAssertEqual(usage.rows.count, 3)
        XCTAssertEqual(usage.credits, 321)
        XCTAssertEqual(usage.rows.first { $0.id.hasPrefix("fixture-key-id|") && $0.model == "scribe_v2_realtime" }?.credits, 216)
    }

    func test_real_request_log_and_invalid_amounts_never_become_free_usage() throws {
        let requestLog = try JSONSerialization.data(withJSONObject: [
            "columns": ["event_id", "trace_id", "response_code"],
            "column_units": [NSNull(), NSNull(), NSNull()], "rows": [["event", "trace", 200]]
        ])
        XCTAssertThrowsError(try ElevenLabsCreditUsage.parse(requestLog))
        for value: Any in [true, -1, "NaN", "Infinity", NSNull()] {
            XCTAssertThrowsError(try ElevenLabsCreditUsage.parse(table([row(value)])))
        }
        XCTAssertThrowsError(try ElevenLabsCreditUsage.parse(table([row()], creditUnit: "usd")))
        XCTAssertThrowsError(try ElevenLabsCreditUsage.parse(table([["short"]])))
        XCTAssertEqual(try ElevenLabsCreditUsage.parse(table([])).credits, 0)
    }

    func test_features_use_their_own_recorded_duration_and_model_not_a_share_of_total() throws {
        let usage = try ElevenLabsCreditUsage.parse(table([
            row(180, minutes: 10), row(1800, minutes: 100, key: "other-app-key"),
            row(50, minutes: 10, model: "other-model")
        ]))
        let first = AIUsageEvent.speech(.init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"), seconds: 60)
        let second = AIUsageEvent.speech(.init(feature: .agentVoice, account: .elevenLabs, model: "scribe_v2_realtime"), seconds: 120)
        let otherModel = AIUsageEvent.speech(.init(feature: .dropSmart, account: .elevenLabs, model: "other-model"), seconds: 60)
        let a = usage.estimating(first), b = usage.estimating(second)
        XCTAssertEqual(a.amount, 18); XCTAssertEqual(b.amount, 36)
        XCTAssertEqual(usage.estimating(otherModel).amount, 5)
        XCTAssertEqual(a.basis, .estimated)
        XCTAssertEqual(a.id, first.id); XCTAssertEqual(a.context, first.context); XCTAssertEqual(a.createdAt, first.createdAt)
        XCTAssertNil(first.amount, "the durable journal is not rewritten as a reported debit")
        let unknown = AIUsageEvent.speech(.init(feature: .dropFast, account: .elevenLabs, model: "unknown"), seconds: 60)
        XCTAssertNil(usage.estimating(unknown).amount)
        var reported = first; reported = .init(id: first.id, createdAt: first.createdAt, context: first.context,
            currency: .elevenLabsCredits, amount: 7, basis: .reported, audioSeconds: 60)
        XCTAssertEqual(usage.estimating(reported).amount, 7)
    }

    func test_missing_or_zero_minutes_cannot_establish_a_rate() throws {
        for minutes: Any in [0, NSNull(), true, "-1", "NaN"] {
            let usage = try ElevenLabsCreditUsage.parse(table([row(180, minutes: minutes)]))
            let event = AIUsageEvent.speech(.init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"), seconds: 60)
            XCTAssertNil(usage.estimating(event).amount)
        }
    }

    func test_billing_read_uses_selected_dates_and_key_only_in_header() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        let data = try table([row()])
        let interval = DateInterval(start: Date(timeIntervalSince1970: 1_792_512_000), duration: 86400)
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/workspace/analytics/query/usage-by-product-over-time")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "fixture-secret")
            let body = try XCTUnwrap(StubURLProtocol.capturedBodies.last)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["start_time"] as? Double, interval.start.timeIntervalSince1970 * 1000)
            XCTAssertEqual(json["end_time"] as? Double, interval.end.timeIntervalSince1970 * 1000)
            XCTAssertEqual(Set(json["group_by"] as? [String] ?? []), Set(["hashed_xi_api_key", "model", "product_type"]))
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-secret"))
            return (200, [:], data)
        }
        let usage = try await ElevenLabsCreditUsage(session: session, readKey: { "fixture-secret" }).usage(in: interval)
        XCTAssertEqual(usage?.credits, 180)
    }

    func test_permission_failure_is_an_error_and_missing_key_does_not_request() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in (403, [:], Data()) }
        let interval = DateInterval(start: Date(), duration: 60)
        do {
            _ = try await ElevenLabsCreditUsage(session: session, readKey: { "fixture" }).usage(in: interval)
            XCTFail("permission failure became empty billing")
        } catch ElevenLabsBillingError.http(403) {} catch { XCTFail("unexpected error") }
        StubURLProtocol.reset()
        let absent = try await ElevenLabsCreditUsage(session: session, readKey: { nil }).usage(in: interval)
        XCTAssertNil(absent); XCTAssertTrue(StubURLProtocol.capturedBodies.isEmpty)
    }

    func test_missing_duration_does_not_request_a_rate_that_cannot_price_the_attempt() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = ElevenLabsCreditUsage(cacheURL: directory.appendingPathComponent("rates.json"),
                                          readKey: { XCTFail("no measured audio to price"); return nil })
        let attempt = AIUsageEvent(context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2"),
                                   currency: .elevenLabsCredits, amount: nil, basis: .unavailable)
        let result = await client.estimates(for: [attempt])
        XCTAssertEqual(result, [attempt])
        XCTAssertNil(result.first?.amount)
    }

    func test_cached_model_rate_survives_restart_and_api_outage_without_saving_workspace_usage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); StubURLProtocol.reset() }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let data = try table([row(180, minutes: 10)])
        StubURLProtocol.handler = { _ in (200, [:], data) }
        let url = directory.appendingPathComponent("rates.json")
        let event = AIUsageEvent.speech(.init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"), seconds: 120)
        let now = Date(timeIntervalSince1970: 1_792_512_000)
        let client = ElevenLabsCreditUsage(session: session, cacheURL: url, readKey: { "fixture-secret" })
        let first = await client.estimates(for: [event], now: now)
        XCTAssertEqual(first.first?.amount, 36); XCTAssertEqual(first.first?.basis, .estimated)
        let bytes = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(bytes.contains("fixture-secret")); XCTAssertFalse(bytes.contains("My key"))
        XCTAssertFalse(bytes.contains("fixture-key-id")); XCTAssertFalse(bytes.contains("credits"))
        StubURLProtocol.handler = { _ in (403, [:], Data()) }
        let reopened = ElevenLabsCreditUsage(session: session, cacheURL: url, readKey: { "fixture-secret" })
        let offline = await reopened.estimates(for: [event], now: now.addingTimeInterval(172800))
        XCTAssertEqual(offline.first?.amount, 36)
        let changed = try table([row(240, minutes: 10)])
        StubURLProtocol.handler = { _ in (200, [:], changed) }
        let historical = await reopened.estimates(for: first, now: now.addingTimeInterval(172800))
        XCTAssertEqual(historical.first?.amount, 36, "rate refresh does not reprice a saved estimate")
        let next = await reopened.estimates(for: [event], refresh: false)
        XCTAssertEqual(next.first?.amount, 48, "a new take uses the refreshed rate even if history was already priced")
        let noNetwork = ElevenLabsCreditUsage(session: session, cacheURL: url, readKey: { XCTFail("local recording read an API key"); return nil })
        let local = await noNetwork.estimates(for: [event], refresh: false)
        XCTAssertEqual(local.first?.amount, 48)
        let unknown = AIUsageEvent.speech(.init(feature: .agentVoice, account: .elevenLabs, model: "unpriced-model"), seconds: 60)
        let result = await noNetwork.estimates(for: [unknown], refresh: false)
        XCTAssertNil(result.first?.amount)
    }

    @MainActor func test_costs_saves_local_estimates_without_importing_workspace_total() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = AIUsageStore(url: dir.appendingPathComponent("usage.sqlite"))
        let event = AIUsageEvent.speech(.init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"), seconds: 60)
        try await store.insert(event)
        let billing = try ElevenLabsCreditUsage.parse(table([row(1800, minutes: 100)]))
        let model = AIUsageCostsViewModel(store: store, loadPrices: { events in
            AIUsageRecorder.Prices(events: events.map { billing.estimating($0) })
        })
        let interval = DateInterval(start: event.createdAt.addingTimeInterval(-1), duration: 86400)
        await model.load(interval)
        XCTAssertEqual(model.events.first?.amount, 18)
        XCTAssertEqual(model.pricedEvents.first?.amount, 18)
        XCTAssertEqual(AIUsagePrice(events: model.pricedEvents).lines.first?.detail, "Estimated")
        let saved = try await store.events(from: interval.start, to: interval.end)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, event.id)
        XCTAssertEqual(saved.first?.amount, 18)
        XCTAssertEqual(saved.first?.basis, .estimated)
        XCTAssertEqual(saved.first?.audioSeconds, 60)
        XCTAssertEqual(try XCTUnwrap(saved.first).createdAt.timeIntervalSince1970, event.createdAt.timeIntervalSince1970, accuracy: 0.00001)
    }
}

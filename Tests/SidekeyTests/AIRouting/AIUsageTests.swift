import XCTest
@testable import Sidekey

final class AIUsageTests: XCTestCase {
    private func storeURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("usage.sqlite")
    }
    private func event(_ amount: Double?, feature: AIFeature = .dropSmartCleanup,
                       account: ProviderAccount = .openRouter, model: String = "test/model", at date: Date = Date()) -> AIUsageEvent {
        AIUsageEvent(createdAt: date, context: .init(feature: feature, account: account, model: model),
                     currency: account == .elevenLabs ? .elevenLabsCredits : .usd,
                     amount: amount, basis: amount == nil ? .unavailable : .reported)
    }

    func test_persistence_deduplication_and_exclusive_end_boundary() async throws {
        let url = storeURL(), store = AIUsageStore(url: url)
        let start = Date(timeIntervalSince1970: 1_000), end = Date(timeIntervalSince1970: 2_000)
        let first = event(0.004, at: start)
        try await store.insert(first)
        try await store.insert(first)
        try await store.insert(event(0.1, at: end))
        let reopened = AIUsageStore(url: url)
        let rows = try await reopened.events(from: start, to: end)
        XCTAssertEqual(rows, [first])
    }

    @MainActor func test_models_and_features_come_from_history_and_group_paired_routes_once() {
        let rows = AIUsageCostRow.grouped([
            event(0.02, model: "old/model"), event(0.03, model: "new/model"),
            event(nil, feature: .dropSmart, account: .elevenLabs, model: "scribe_v2_realtime"),
            event(0.04, feature: .meetingNotes)
        ])
        XCTAssertEqual(rows.map(\.title), ["Drop Smart", "Meetings"])
        XCTAssertEqual(rows[0].models.count, 3)
        XCTAssertEqual(AIUsageTotal(events: rows[0].events, currency: .usd).text, "$0.05")
        XCTAssertEqual(AIUsageTotal(events: rows[0].events, currency: .elevenLabsCredits).text, "Unavailable")
        XCTAssertEqual(AIUsageTotal(events: rows[1].events, currency: .elevenLabsCredits).text, "—")
    }

    func test_partial_unknown_cost_and_small_nonzero_cost_are_not_free() {
        let events = [event(0.02), event(nil)]
        XCTAssertEqual(AIUsageTotal(events: events, currency: .usd).text, "$0.02")
        XCTAssertEqual(AIUsageTotal(events: events, currency: .usd).detail, "1 unpriced call")
        XCTAssertEqual(AIUsageTotal(events: [event(0.000001)], currency: .usd).text, "< $0.0001")
        XCTAssertEqual(AIUsageTotal(events: [event(0)], currency: .usd).text, "$0.00")
        XCTAssertEqual(AIUsageTotal(events: [event(0.01, account: .elevenLabs)], currency: .elevenLabsCredits).text, "< 0.1")
    }

    func test_one_price_preserves_mixed_units_and_unknown_portions() {
        let events = [event(0.02), event(1234, account: .elevenLabs)]
        XCTAssertEqual(AIUsagePrice(events: events).text, "$0.02\n\(1234.formatted()) credits")
        XCTAssertEqual(AIUsagePrice(events: [event(nil, account: .elevenLabs)]).text, "Credits unavailable. 1 unpriced call")
        XCTAssertEqual(AIUsagePrice(events: [event(0.02), event(nil)]).text, "$0.02. 1 unpriced call")
    }

    func test_each_currency_explains_its_own_estimates_and_excluded_calls() {
        let estimatedCredits = AIUsageEvent(context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"),
            currency: .elevenLabsCredits, amount: 1776.5, basis: .estimated)
        let price = AIUsagePrice(events: [event(6.22), event(nil), event(nil),
                                        estimatedCredits, event(nil, account: .elevenLabs)])
        XCTAssertEqual(price.lines.map(\.currency), [.usd, .elevenLabsCredits])
        XCTAssertEqual(price.lines.map(\.value), ["$6.22", 1776.5.formatted(.number.precision(.fractionLength(0...1))) + " credits"])
        XCTAssertEqual(price.lines.map(\.detail), ["2 unpriced calls", "Estimated · 1 unpriced call"])
        XCTAssertTrue(AIUsagePrice(events: []).lines.isEmpty)
        XCTAssertNil(AIUsagePrice(events: [event(0)]).lines.first?.detail)
    }

    func test_elevenlabs_model_details_explain_missing_duration_separately_from_missing_rate() {
        let missingDuration = event(nil, feature: .dropFast, account: .elevenLabs, model: "scribe_v2")
        let missingRate = AIUsageEvent.speech(.init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2"), seconds: 60)
        let unknown = AIUsageModelRow(id: "fixture", events: [missingDuration])
        XCTAssertEqual(unknown.total, "Credits unavailable. 1 unpriced call")
        XCTAssertTrue(unknown.pricingExplanation?.contains("durations were not recorded") == true)
        let unpriced = AIUsageModelRow(id: "fixture", events: [missingRate])
        XCTAssertEqual(unpriced.recordedMinutes, 1)
        XCTAssertEqual(unpriced.pricingExplanation, "Credit rate unavailable for this model.")

        let known = AIUsageEvent(context: missingRate.context, currency: .elevenLabsCredits,
                                amount: 18, basis: .estimated, audioSeconds: 60)
        let complete = AIUsageModelRow(id: "fixture", events: [known])
        XCTAssertNil(complete.pricingExplanation)
        let partial = AIUsageModelRow(id: "fixture", events: [missingDuration, known])
        XCTAssertEqual(partial.total, "18 credits. Estimated · 1 unpriced call")
        XCTAssertEqual(partial.recordedMinutes, 1)
        XCTAssertEqual(partial.pricingExplanation, unknown.pricingExplanation)
        XCTAssertNil(AIUsageModelRow(id: "usd", events: [event(nil)]).pricingExplanation)
    }

    @MainActor func test_each_costs_visit_defaults_to_this_month() {
        let model = AIUsageCostsViewModel(store: AIUsageStore(url: storeURL()))
        XCTAssertEqual(model.period, .month)
        model.period = .custom; model.beginVisit()
        XCTAssertEqual(model.period, .month)
    }

    func test_invalid_amounts_and_currency_are_rejected() async throws {
        let store = AIUsageStore(url: storeURL())
        for value in [-1.0, Double.nan, .infinity] {
            do { try await store.insert(event(value)); XCTFail("invalid amount accepted") } catch {}
        }
        let wrongCurrency = AIUsageEvent(context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe"),
                                        currency: .usd, amount: 1, basis: .reported)
        do { try await store.insert(wrongCurrency); XCTFail("currency silently converted") } catch {}
    }

    func test_local_calendar_period_includes_today_and_custom_end_day() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        let now = ISO8601DateFormatter().date(from: "2026-10-20T12:00:00Z")!
        let today = AIUsagePeriod.today.interval(now: now, start: now, end: now, calendar: calendar)!
        XCTAssertEqual(today.start, ISO8601DateFormatter().date(from: "2026-10-19T21:00:00Z"))
        XCTAssertEqual(today.duration, 86400)
        let custom = AIUsagePeriod.custom.interval(now: now, start: today.start.addingTimeInterval(-86400), end: now, calendar: calendar)!
        XCTAssertEqual(custom.duration, 2 * 86400)
        XCTAssertNil(AIUsagePeriod.custom.interval(now: now, start: now, end: today.start.addingTimeInterval(-86400), calendar: calendar))
    }

    func test_audio_estimates_use_actual_transmitted_model_and_never_guess_elevenlabs_credits() {
        let context = AIUsageContext(feature: .dropFast, account: .soniox, model: "stt-rt-v5")
        let estimate = AIUsageEvent.speech(context, seconds: 3600)
        XCTAssertEqual(estimate.amount, 0.12)
        XCTAssertEqual(estimate.basis, .estimated)
        let credits = AIUsageEvent.speech(.init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"), seconds: 60)
        XCTAssertNil(credits.amount)
        XCTAssertEqual(credits.currency, .elevenLabsCredits)
        XCTAssertEqual(credits.basis, .unavailable)
        XCTAssertNil(AIUsageEvent.speech(.init(feature: .dropFast, account: .soniox, model: "new-unpriced-model"), seconds: 60).amount)
    }

    func test_wav_duration_uses_audio_chunk_and_rejects_invalid_headers() {
        let wav = TurnAudioBuffer.wav(fromPCM16: Data(count: 32_000))
        XCTAssertEqual(AIUsageAudio.wavSeconds(wav), 1)
        XCTAssertNil(AIUsageAudio.wavSeconds(Data(count: 32_000)))
        XCTAssertNil(AIUsageAudio.wavSeconds(wav.prefix(44)))
    }

    func test_agent_deduplicates_step_parts_and_preserves_each_paid_step() {
        var recorded: [AIUsageEvent] = []
        let meter = AIUsageAgentMeter(account: .anthropic, model: "claude-test", record: { recorded.append($0) })
        let first = #"{"type":"step_finish","sessionID":"session-test","part":{"id":"a","cost":0.02}}"#
        meter.consume(first); meter.consume(first)
        meter.consume(#"{"type":"step_finish","sessionID":"session-test","part":{"id":"b","cost":0.03}}"#)
        meter.finish(); meter.finish()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.compactMap(\.amount).reduce(0, +), 0.05, accuracy: 0.000001)
        XCTAssertTrue(recorded.allSatisfy { $0.context.account == .anthropic })
        XCTAssertTrue(recorded.allSatisfy { $0.basis == .estimated })
    }

    func test_openai_agent_expenses_keep_the_direct_provider_identity() {
        var events: [AIUsageEvent] = []
        let meter = AIUsageAgentMeter(account: OpenCodeModelProvider.openAI.account, model: "selected-openai-model",
                                      record: { events.append($0) })
        meter.consume(#"{"type":"step_finish","sessionID":"fixture","part":{"id":"one","cost":0.01}}"#)
        meter.finish()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.context.account, .openAI)
        XCTAssertEqual(events.first?.context.model, "selected-openai-model")
    }

    func test_agent_interrupted_later_step_and_child_task_preserve_incomplete_total() {
        for tail in [#"{"type":"step_start"}"#, #"{"type":"tool_use","part":{"tool":"task"}}"#] {
            var events: [AIUsageEvent] = []
            let meter = AIUsageAgentMeter(account: .openRouter, model: "paid-model", record: { events.append($0) })
            meter.consume(#"{"type":"step_finish","part":{"id":"one","cost":0.02}}"#)
            meter.consume(tail); meter.finish(); meter.finish()
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(AIUsagePrice(events: events).text, "$0.02. Estimated · 1 unpriced call")
        }
    }

    func test_agent_cancel_during_child_work_without_tool_event_remains_incomplete() {
        var events: [AIUsageEvent] = []
        let meter = AIUsageAgentMeter(account: .openRouter, model: "paid-model", record: { events.append($0) })
        meter.consume(#"{"type":"step_finish","part":{"id":"parent","cost":0.02}}"#)
        meter.finish(interrupted: true); meter.finish(interrupted: true)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(AIUsagePrice(events: events).text, "$0.02. Estimated · 1 unpriced call")
    }

    func test_agent_missing_pricing_and_early_exit_remain_unknown() {
        var events: [AIUsageEvent] = []
        let meter = AIUsageAgentMeter(account: .openRouter, model: "not-free", record: { events.append($0) })
        meter.consume(#"{"type":"step_finish","part":{"id":"step","cost":0}}"#)
        meter.finish()
        XCTAssertEqual(events.count, 1); XCTAssertNil(events[0].amount)
        let second = AIUsageAgentMeter(account: .openRouter, model: "other", record: { events.append($0) })
        second.finish(); second.finish()
        XCTAssertEqual(events.count, 2); XCTAssertNil(events[1].amount)
    }

    func test_metered_audio_preserves_final_join_and_records_close_once() async {
        let upstream = Upstream()
        var events: [AIUsageEvent] = []
        let meter = AIUsageMeteredSession(upstream: upstream,
            context: .init(feature: .dropFast, account: .soniox, model: "stt-rt-v5"), record: { events.append($0) })
        XCTAssertEqual(meter.finalsJoin, .verbatim)
        await meter.sendAudio(Data(count: 32_000))
        await meter.endInput(); await meter.close(); await meter.close()
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].audioSeconds, 1)
        XCTAssertEqual(upstream.bytes, 32_000); XCTAssertEqual(upstream.ends, 1)
        var output: [BYOKStreamEvent] = []
        for await item in meter.events { output.append(item) }
        XCTAssertEqual(output, [.done("test")])
    }

    func test_meter_uses_accepted_audio_and_does_not_price_failed_session() async {
        for failed in [false, true] {
            let upstream = Upstream()
            upstream.snapshot = .init(acceptedAudioBytes: 16_000, failed: failed)
            var events: [AIUsageEvent] = []
            let meter = AIUsageMeteredSession(upstream: upstream,
                context: .init(feature: .dropFast, account: .soniox, model: "stt-rt-v5"), record: { events.append($0) })
            await meter.sendAudio(Data(count: 32_000)); await meter.close()
            XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].audioSeconds, 0.5)
            XCTAssertEqual(events[0].basis, failed ? .unavailable : .estimated)
            if failed { XCTAssertNil(events[0].amount) }
        }
    }

    func test_elevenlabs_meter_retains_exact_session_reference_for_credit_reconciliation() async {
        let upstream = Upstream()
        upstream.snapshot = .init(acceptedAudioBytes: nil, providerReference: "session-fixture")
        var events: [AIUsageEvent] = []
        let meter = AIUsageMeteredSession(upstream: upstream,
            context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"), record: { events.append($0) })
        await meter.sendAudio(Data(count: 32_000)); await meter.close()
        XCTAssertEqual(events.first?.id, "elevenlabs:session-fixture")
        XCTAssertNil(events.first?.amount)
    }

    private final class Upstream: BYOKUpstreamSession {
        let events = AsyncStream<BYOKStreamEvent> { c in c.yield(.done("test")); c.finish() }
        var finalsJoin: BYOKTranscriptJoin { .verbatim }
        var bytes = 0, ends = 0
        var snapshot: BYOKUsageSnapshot?
        func usageSnapshot() async -> BYOKUsageSnapshot? { snapshot }
        func sendAudio(_ pcm: Data) async { bytes += pcm.count }
        func endInput() async { ends += 1 }
        func close() async {}
    }
}

final class AIUsageLLMTests: XCTestCase {
    func test_openrouter_cost_and_resolved_model_recorded_without_prompt_or_reply() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in (200, [:], Data(#"{"model":"actual/model","usage":{"cost":0.0123},"choices":[{"message":{"content":"private-reply"}}]}"#.utf8)) }
        var events: [AIUsageEvent] = []
        let client = OpenRouterLLMClient(session: session, usageSink: { events.append($0) })
        let route = DirectLLMRoute(endpoint: .openRouter(apiKey: "fixture-key"), model: "requested/model",
            usageContext: .init(feature: .translation, account: .openRouter, model: "requested/model"))
        _ = try await client.complete(route: route, messages: [.init(role: "user", content: "private-prompt")])
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].amount, 0.0123)
        XCTAssertEqual(events[0].context.model, "actual/model"); XCTAssertEqual(events[0].context.feature, .translation)
        _ = try await client.complete(endpoint: route.endpoint, model: route.model, messages: [])
        XCTAssertEqual(events.count, 1, "synthetic checks have no feature context")
    }

    func test_billed_empty_content_still_recorded_and_custom_cost_not_assumed_usd() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        StubURLProtocol.handler = { _ in (200, [:], Data(#"{"usage":{"cost":0.01},"choices":[]}"#.utf8)) }
        var events: [AIUsageEvent] = []
        let client = OpenRouterLLMClient(session: session, usageSink: { events.append($0) })
        let context = AIUsageContext(feature: .meetingNotes, account: .openRouter, model: "test")
        do { _ = try await client.complete(route: .init(endpoint: .openRouter(apiKey: "fixture"), model: "test", usageContext: context), messages: []); XCTFail() } catch {}
        XCTAssertEqual(events[0].amount, 0.01)
        let custom = AIUsageContext(feature: .meetingNotes, account: .server(UUID()), model: "test")
        do { _ = try await client.complete(route: .init(endpoint: .custom(baseURL: URL(string: "https://fixture.invalid/v1")!, apiKey: nil), model: "test", usageContext: custom), messages: []); XCTFail() } catch {}
        XCTAssertEqual(events.count, 2); XCTAssertNil(events[1].amount)
    }
}

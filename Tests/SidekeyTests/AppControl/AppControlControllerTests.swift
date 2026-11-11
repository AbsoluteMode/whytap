import XCTest
import WhytapCaseKit
@testable import Sidekey

private actor ControlTestProbe: ModelProbing {
    var outcome: ProbeOutcome = .passed
    var pause = false
    var calls = 0
    private var pending: CheckedContinuation<ProbeOutcome, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func configure(outcome: ProbeOutcome = .passed, pause: Bool = false) { self.outcome = outcome; self.pause = pause }
    func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome {
        calls += 1
        started?.resume(); started = nil
        if pause { return await withCheckedContinuation { pending = $0 } }
        return outcome
    }
    func waitStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() { pending?.resume(returning: outcome); pending = nil }
}

private struct ControlTestCatalog: ModelCatalogFetching {
    func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
        throw CatalogFetchError.offline
    }
}

private struct ControlTestEndpoints: OpenRouterEndpointsFetching {
    func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] {
        [OpenRouterEndpoint(tag: "test/fast", providerName: "Test", quantization: nil,
                            latencyMs: nil, tokensPerSecond: nil, isUp: true)]
    }
}

@MainActor
final class AppControlControllerTests: XCTestCase {
    private struct Env {
        let routing: AIRoutingStore
        let preferences: UserPreferencesCache
        let probe: ControlTestProbe
        let controller: AppControlController
    }

    private func env(googleReview: @escaping () -> Bool = { false }) throws -> Env {
        let suite = "app-control-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        let snapshot = CatalogSnapshot(models: [CatalogModel(id: "candidate-text", uses: [.chat])], fetchedAt: Date(), lastRefreshFailed: false, limited: false)
        try JSONEncoder().encode(["openRouter": snapshot]).write(to: file)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        defaults.set("fake-secret-not-for-output", forKey: "private.otherSetting")
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let routing = AIRoutingStore(defaults: defaults)
        try keys.save("fake-provider-key-not-for-output", account: ProviderAccount.openRouter.keychainAccount(in: routing)!)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "old-text", provider: "old/pin"), for: .dropSmartCleanup)
        routing.setRoute(FeatureRoute(account: .elevenLabs, model: "scribe_v2_realtime"), for: .dropSmart)
        let probe = ControlTestProbe()
        let models = APIAndModelsViewModel(routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: file, fetcher: ControlTestCatalog()),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults),
            probe: probe, endpoints: ControlTestEndpoints(), inputLanguage: { nil })
        let preferences = UserPreferencesCache(defaults: defaults)
        let controller = AppControlController(routing: routing, models: models, preferences: preferences,
            languages: PrivacyPreferences(defaults: defaults), idle: IslandIdlePreferences(defaults: defaults),
            identity: AppBuildIdentity(info: ["CFBundleVersion": "test-42", "ExodiaSourceRevision": "fixture-sha"], bundleURL: URL(fileURLWithPath: "/tmp/Whytap.app")),
            activity: { .object(["drop": .string("idle")]) }, googleCalendarReview: googleReview)
        return Env(routing: routing, preferences: preferences, probe: probe, controller: controller)
    }

    private var expectedOld: AppControlValue {
        .object(["account": .string("openRouter"), "model": .string("old-text"), "provider": .string("old/pin")])
    }
    private func pick(expected: AppControlValue? = nil) -> AppControlRequest {
        AppControlRequest("set_model", arguments: ["feature": .string("dropSmartCleanup"), "account": .string("openRouter"),
                                                  "model": .string("candidate-text"), "expected": expected ?? expectedOld])
    }

    func test_live_state_uses_injected_build_and_omits_keys_raw_preferences_and_contents() async throws {
        let e = try env()
        let state = await e.controller.handle(AppControlRequest("get_state"))
        XCTAssertEqual(state.data.object?["build"], .string("test-42"))
        XCTAssertEqual(state.data.object?["sourceRevision"], .string("fixture-sha"))
        XCTAssertEqual(state.data.object?["googleCalendarReviewActive"], .bool(false))
        let settings = await e.controller.handle(AppControlRequest("get_settings"))
        let text = String(data: try JSONEncoder().encode([state, settings]), encoding: .utf8)!
        XCTAssertFalse(text.contains("fake-provider-key"))
        XCTAssertFalse(text.contains("private.otherSetting"))
        XCTAssertFalse(text.contains("fake-secret"))
        let calls = await e.probe.calls
        XCTAssertEqual(calls, 0)
    }

    func test_runtime_review_status_updates_without_exposing_the_session_configuration() async throws {
        var active = true
        let e = try env(googleReview: { active })
        let started = await e.controller.handle(AppControlRequest("get_state"))
        XCTAssertEqual(started.data.object?["googleCalendarReviewActive"], .bool(true))
        active = false
        let expired = await e.controller.handle(AppControlRequest("get_state"))
        XCTAssertEqual(expired.data.object?["googleCalendarReviewActive"], .bool(false))
        let encoded = String(data: try JSONEncoder().encode([started, expired]), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("WHYTAP_GOOGLE_CALENDAR_REVIEW"))
        XCTAssertFalse(encoded.contains("expiresAt"))
        let calls = await e.probe.calls
        XCTAssertEqual(calls, 0)
    }

    func test_retired_decision_feature_cannot_be_selected_or_listed() async throws {
        let e = try env()
        let response = await e.controller.handle(AppControlRequest("list_models", arguments: ["feature": .string("dropSmartDecision")]))
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.data.object?["code"], .string("invalid_arguments"))
        let attempted = await e.controller.handle(AppControlRequest("set_model", arguments: [
            "feature": .string("dropSmartDecision"), "account": .string("openRouter"),
            "model": .string("typesafe/jev-1.14"), "expected": .null
        ]))
        XCTAssertFalse(attempted.ok)
        XCTAssertEqual(attempted.data.object?["code"], .string("invalid_arguments"))
        let calls = await e.probe.calls
        XCTAssertEqual(calls, 0)
    }

    func test_model_change_resets_pin_preserves_speech_and_persists_in_app_store() async throws {
        let e = try env()
        let response = await e.controller.handle(pick())
        XCTAssertTrue(response.ok)
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup), FeatureRoute(account: .openRouter, model: "candidate-text"))
        XCTAssertEqual(e.routing.route(for: .dropSmart), FeatureRoute(account: .elevenLabs, model: "scribe_v2_realtime"))
        let calls = await e.probe.calls
        XCTAssertEqual(calls, 1)
    }

    func test_failed_probe_and_stale_expected_route_do_not_change_selection() async throws {
        let e = try env()
        await e.probe.configure(outcome: .failed(reason: "test refusal"))
        let refused = await e.controller.handle(pick())
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "old-text")
        let stale = await e.controller.handle(pick(expected: .null))
        XCTAssertEqual(stale.data.object?["code"], .string("conflict"))
        let calls = await e.probe.calls
        XCTAssertEqual(calls, 1)
    }

    func test_manual_route_change_during_probe_is_not_overwritten_and_plugin_writes_report_busy() async throws {
        let e = try env()
        await e.probe.configure(pause: true)
        let task = Task { await e.controller.handle(pick()) }
        await e.probe.waitStarted()
        let busy = await e.controller.handle(AppControlRequest("set_setting", arguments: ["key": .string("dropMode"), "value": .string("smart"), "expected": .string("fast")]))
        XCTAssertEqual(busy.data.object?["code"], .string("busy"))
        e.routing.setRoute(FeatureRoute(account: .openRouter, model: "manual-choice"), for: .dropSmartCleanup)
        await e.probe.finish()
        let response = await task.value
        XCTAssertEqual(response.data.object?["code"], .string("conflict"))
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "manual-choice")
    }

    func test_disconnected_cancelled_probe_never_assigns_model() async throws {
        let e = try env()
        await e.probe.configure(pause: true)
        let task = Task { await e.controller.handle(pick()) }
        await e.probe.waitStarted()
        task.cancel()
        await e.probe.finish()
        let result = await task.value
        XCTAssertFalse(result.ok)
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.model, "old-text")
    }

    func test_settings_validate_types_expected_values_and_notify_existing_mode_store() async throws {
        let e = try env()
        let changed = await e.controller.handle(AppControlRequest("set_setting", arguments: ["key": .string("dropMode"), "value": .string("smart"), "expected": .string("fast")]))
        XCTAssertTrue(changed.ok)
        XCTAssertEqual(e.preferences.currentMode, .smart)
        for args: [String: AppControlValue] in [
            ["key": .string("dropMode"), "value": .string("fast"), "expected": .string("fast")],
            ["key": .string("autoHideIsland"), "value": .int(0), "expected": .bool(true)],
            ["key": .string("inputLanguage"), "value": .string("invalid"), "expected": .null],
            ["key": .string("screenshotProtection"), "value": .bool(false), "expected": .bool(true)],
            ["key": .string("dropMode"), "value": .string("fast"), "expected": .string("smart"), "unexpected": .bool(true)]
        ] {
            let response = await e.controller.handle(AppControlRequest("set_setting", arguments: args))
            XCTAssertFalse(response.ok)
        }
        XCTAssertEqual(e.preferences.currentMode, .smart)
    }

    func test_provider_must_belong_to_current_model_and_auto_removes_pin() async throws {
        let e = try env()
        let wrong = await e.controller.handle(AppControlRequest("set_provider", arguments: ["feature": .string("dropSmartCleanup"), "provider": .string("foreign/pin"), "expected": expectedOld]))
        XCTAssertEqual(wrong.data.object?["code"], .string("unknown_provider"))
        XCTAssertEqual(e.routing.route(for: .dropSmartCleanup)?.provider, "old/pin")
        let auto = await e.controller.handle(AppControlRequest("set_provider", arguments: ["feature": .string("dropSmartCleanup"), "provider": .null, "expected": expectedOld]))
        XCTAssertTrue(auto.ok)
        XCTAssertNil(e.routing.route(for: .dropSmartCleanup)?.provider)
    }
}

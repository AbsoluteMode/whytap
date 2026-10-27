import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen pictures of API & Models for review, written only when
/// `EXODIA_APIMODELS_RENDER_DIR` is set. Every network path is a stub.
@MainActor
final class APIAndModelsRenderTests: XCTestCase {
    func test_render_cost_price_clarity() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_APIMODELS_RENDER_DIR"] else {
            throw XCTSkip("set EXODIA_APIMODELS_RENDER_DIR to write the pictures")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let usd = AIUsageContext(feature: .agent, account: .openRouter, model: "example/model")
        let credits = AIUsageContext(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime")
        let known = [AIUsageEvent(createdAt: now, context: usd, currency: .usd, amount: 6.22, basis: .estimated),
                     AIUsageEvent(createdAt: now, context: credits, currency: .elevenLabsCredits, amount: 1776.5, basis: .estimated)]
        let unknown = [AIUsageEvent(createdAt: now, context: usd, currency: .usd, amount: nil, basis: .unavailable),
                       AIUsageEvent(createdAt: now, context: credits, currency: .elevenLabsCredits, amount: nil, basis: .unavailable)]
        for (state, events) in [("partial", known + unknown), ("complete", known), ("unavailable", unknown)] {
            let store = AIUsageStore(url: directory.appendingPathComponent("clarity-\(state).sqlite"))
            for event in events { try await store.insert(event) }
            let model = AIUsageCostsViewModel(store: store, loadPrices: { .init(events: $0) })
            await model.load(AIUsagePeriod.month.interval(now: now, start: now, end: now)!)
            for dark in [false, true] {
                for width in [390.0, 600.0, 900.0] {
                    try await render(AIUsageCostsView(model: model, now: { now }),
                        size: NSSize(width: width, height: 520), dark: dark,
                        to: directory.appendingPathComponent("cost-clarity-\(state)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
                try await render(AIUsageModelsPopover(row: .init(title: "Drop Fast", events: events.filter { $0.currency == .elevenLabsCredits })),
                    size: NSSize(width: 422, height: 310), dark: dark,
                    to: directory.appendingPathComponent("cost-clarity-model-\(state)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func test_render_smart_editor_pass() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_APIMODELS_RENDER_DIR"] else {
            throw XCTSkip("set EXODIA_APIMODELS_RENDER_DIR to write the pictures")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = directory.appendingPathComponent("decision-catalog.json")
        try Data("{}".utf8).write(to: file)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        for account in [ProviderAccount.openRouter, .openAI, .soniox] {
            try keys.save("synthetic-key", account: XCTUnwrap(account.keychainAccount(in: routing)))
        }
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropSmart)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .dropSmartCleanup)
        routing.retireSmartDecisionIfNeeded()
        let stub = NoNetwork(list: [])
        let vm = APIAndModelsViewModel(routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: file, fetcher: stub), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults), keyChecker: stub, probe: stub, endpoints: stub)
        let sections = vm.sections(for: .dropSmartCleanup)
        XCTAssertFalse(sections.flatMap(\.options).contains { $0.model.hasPrefix("typesafe/jev-") })
        XCTAssertFalse(vm.rows.contains { $0.feature == .dropSmartDecision })
        for dark in [false, true] {
            for width in [600.0, 900.0] {
                try await render(APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil),
                    initiallyExpandedGroup: "Drop Smart"), size: NSSize(width: width, height: 850), dark: dark,
                    to: directory.appendingPathComponent("decision-smart-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
            try await render(ModelPicker(sections: sections, missingProviderHint: nil,
                onSelect: { _, _ in }, onRefresh: {}, onAddKey: {}, onClose: {}),
                size: NSSize(width: 440, height: 400), dark: dark,
                to: directory.appendingPathComponent("decision-picker-\(dark ? "dark" : "light").png"))
            try await render(VStack(spacing: 12) {
                ForEach(0..<5) { state in
                    MacPopupLabel(title: ["Normal", "Hover", "Pressed", "Focus", "Disabled"][state],
                                  minWidth: 300, maxWidth: 300)
                        .overlay(APIModelFeedbackOverlay(cornerRadius: MacPopupMetrics.radius,
                            hovered: state == 1 || state == 4, pressed: state == 2,
                            focused: state == 3 || state == 4, enabled: state != 4))
                        .disabled(state == 4)
                }
            }.padding(18), size: NSSize(width: 350, height: 240), dark: dark,
                to: directory.appendingPathComponent("decision-control-states-\(dark ? "dark" : "light").png"))
        }
    }

    private struct NoNetwork: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        let list: [OpenRouterEndpoint]
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            throw CatalogFetchError.offline
        }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { list }
    }

    func test_render_api_and_models() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_APIMODELS_RENDER_DIR"] else {
            throw XCTSkip("set EXODIA_APIMODELS_RENDER_DIR to write the pictures")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(root.appendingPathComponent("Resources/UsefulLinkIcons"))
        defer {
            ProviderBrandIconAsset.clearCacheForTesting()
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        }

        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        try Data("{}".utf8).write(to: file)
        let list = OpenRouterEndpointsClient.sorted([
            OpenRouterEndpoint(tag: "anthropic", providerName: "Anthropic", quantization: nil, latencyMs: 1_240, tokensPerSecond: 58, isUp: true),
            OpenRouterEndpoint(tag: "amazon-bedrock", providerName: "Amazon Bedrock", quantization: nil, latencyMs: 1_610, tokensPerSecond: 64, isUp: true),
            OpenRouterEndpoint(tag: "google-vertex/global", providerName: "Google", quantization: nil, latencyMs: 1_980, tokensPerSecond: 51, isUp: true),
        ])
        let stub = NoNetwork(list: list)
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        for account in [ProviderAccount.soniox, .deepgram, .elevenLabs, .openRouter] {
            try keys.save("key", account: XCTUnwrap(account.keychainAccount(in: routing)))
        }
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropFast)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .dropSmart)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-async-v5"), for: .meetings)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .dropSmartCleanup)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .meetingNotes)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5", provider: "anthropic"), for: .agent)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .subtitlesAudio)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "google/gemini-3.8-flash"), for: .subtitlesTranslation)
        routing.setRoute(FeatureRoute(account: .openRouter, model: "qwen/qwen3.8-27b"), for: .translation)
        routing.setRoute(FeatureRoute(account: .soniox, model: "stt-rt-v5"), for: .agentVoice)

        let vm = APIAndModelsViewModel(
            routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: file, fetcher: stub), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults), keyChecker: stub, probe: stub, endpoints: stub,
            inputLanguage: { "ru" }
        )
        for feature in [AIFeature.agent, .meetingNotes, .dropSmartCleanup, .translation, .subtitlesTranslation] { await vm.loadProviders(for: feature) }

        for dark in [false, true] {
            for width in [600.0, 900.0] {
                for target in [ProviderKeyTiles.Target.provider(.openAI), .provider(.openRouter), .provider(.openAICompatible)] {
                    let label: String
                    if case .provider(let kind) = target { label = kind.rawValue } else { label = "server" }
                    try await render(ProviderKeyTiles(viewModel: vm, initiallyExpanded: target)
                        .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(MacSettingsTheme.bgCard),
                        size: NSSize(width: width, height: 1100), dark: dark,
                        to: directory.appendingPathComponent("key-form-\(label)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
                for expanded in [nil, "Drop Smart", "Subtitles"] as [String?] {
                    let state = expanded == "Subtitles" ? "subtitles-expanded" : (expanded == nil ? "collapsed" : "expanded")
                    try await render(
                        APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil),
                                         initiallyExpandedGroup: expanded),
                        size: NSSize(width: width, height: 980), dark: dark,
                        to: directory.appendingPathComponent("models-\(state)-\(dark ? "dark" : "light")-\(Int(width)).png")
                    )
                }
            }
        }
        for dark in [false, true] {
            for accepted in [false, true] {
                try await render(APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil),
                    initialSection: .keys, initialKeyResult: accepted), size: NSSize(width: 600, height: 700), dark: dark,
                    to: directory.appendingPathComponent("key-notice-\(accepted ? "accepted" : "rejected")-\(dark ? "dark" : "light").png"))
            }
        }
        // Costs use a temporary journal and synthetic provider metadata only.
        let usageURL = directory.appendingPathComponent("fixture-usage.sqlite")
        try? FileManager.default.removeItem(at: usageURL)
        let usageStore = AIUsageStore(url: usageURL)
        let fixtureNow = Date()
        let billing = ElevenLabsBillingUsage(rows: [
            .init(id: "fixture", keyName: "Whytap key", model: "scribe_v2_realtime", product: "STT", credits: 180, minutes: 10)
        ])
        let usageModel = AIUsageCostsViewModel(store: usageStore, loadPrices: { events in
            AIUsageRecorder.Prices(events: events.map { billing.estimating($0) })
        })
        let usageEvents: [AIUsageEvent] = [
            .speech(.init(feature: .dropSmart, account: .soniox, model: "stt-rt-v5"), seconds: 300, at: fixtureNow),
            .init(createdAt: fixtureNow, context: .init(feature: .dropSmartCleanup, account: .openRouter, model: "google/gemini-3.8-flash"), currency: .usd, amount: 0.02, basis: .reported),
            .init(createdAt: fixtureNow, context: .init(feature: .dropSmart, account: .elevenLabs, model: "scribe_v2_realtime"), currency: .elevenLabsCredits, amount: 125, basis: .reported),
            .speech(.init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"), seconds: 300, at: fixtureNow),
            .init(createdAt: fixtureNow, context: .init(feature: .agent, account: .anthropic, model: "claude-opus-5-5"), currency: .usd, amount: 0.48, basis: .estimated),
            .init(createdAt: fixtureNow, context: .init(feature: .agent, account: .anthropic, model: "claude-sonnet-5-5"), currency: .usd, amount: nil, basis: .unavailable)
        ]
        for event in usageEvents { try await usageStore.insert(event) }
        let interval = AIUsagePeriod.month.interval(now: fixtureNow, start: fixtureNow, end: fixtureNow)!
        await usageModel.load(interval)
        let emptyModel = AIUsageCostsViewModel(store: AIUsageStore(url: directory.appendingPathComponent("empty-usage.sqlite")))
        await emptyModel.load(interval)
        let blockedFile = directory.appendingPathComponent("blocked-parent")
        try Data().write(to: blockedFile)
        let errorModel = AIUsageCostsViewModel(store: AIUsageStore(url: blockedFile.appendingPathComponent("usage.sqlite")))
        await errorModel.load(interval)
        let customModel = AIUsageCostsViewModel(store: usageStore)
        customModel.period = .custom
        customModel.start = fixtureNow.addingTimeInterval(-86400 * 5)
        customModel.end = fixtureNow
        await customModel.load(AIUsagePeriod.custom.interval(now: fixtureNow, start: customModel.start, end: customModel.end)!)
        let fallbackModel = AIUsageCostsViewModel(store: usageStore, loadPrices: { events in
            .init(events: events, sonioxUnavailable: true)
        })
        await fallbackModel.load(interval)
        let checkingModel = AIUsageCostsViewModel(store: usageStore, loadPrices: { events in
            try? await Task.sleep(for: .seconds(2))
            return .init(events: events)
        })
        for dark in [false, true] {
            for width in [600.0, 900.0] {
                for section in APIAndModelsSection.allCases {
                    try await render(APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil),
                        initialSection: section, usageModel: usageModel), size: NSSize(width: width, height: 700), dark: dark,
                        to: directory.appendingPathComponent("sections-\(section)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                }
            }
            for (name, stateModel) in [("empty", emptyModel), ("error", errorModel), ("custom", customModel),
                                       ("api-fallback", fallbackModel), ("checking-prices", checkingModel)] {
                try await render(APIAndModelsView(viewModel: vm, focusedFeature: .constant(nil),
                    initialSection: .costs, usageModel: stateModel), size: NSSize(width: 600, height: 700), dark: dark,
                    to: directory.appendingPathComponent("costs-\(name)-\(dark ? "dark" : "light").png"))
            }
            let manyModels = (0..<20).map { index in
                AIUsageEvent(createdAt: fixtureNow, context: .init(feature: .agent, account: .openRouter,
                    model: "provider/very-long-model-name-for-history-\(index)-with-an-extended-version-identifier"),
                    currency: .usd, amount: Double(index) / 100, basis: .reported)
            }
            try await render(AIUsageModelsPopover(row: .init(title: "Agent", events: manyModels)),
                size: NSSize(width: 390, height: 390), dark: dark,
                to: directory.appendingPathComponent("cost-models-many-\(dark ? "dark" : "light").png"))
            let creditDetails = [
                AIUsageEvent(context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2"),
                             currency: .elevenLabsCredits, amount: nil, basis: .unavailable),
                AIUsageEvent(context: .init(feature: .dropFast, account: .elevenLabs, model: "scribe_v2_realtime"),
                             currency: .elevenLabsCredits, amount: 360, basis: .estimated, audioSeconds: 1200)
            ]
            try await render(AIUsageModelsPopover(row: .init(title: "Drop Fast", events: creditDetails)),
                size: NSSize(width: 390, height: 300), dark: dark,
                to: directory.appendingPathComponent("cost-models-missing-duration-\(dark ? "dark" : "light").png"))
            try await render(AIUsageDateCalendar(title: "From", date: .constant(fixtureNow), latest: fixtureNow, close: {}),
                size: NSSize(width: 310, height: 318), dark: dark,
                to: directory.appendingPathComponent("cost-date-calendar-\(dark ? "dark" : "light").png"))
            try await render(HStack(spacing: 12) {
                Button("Normal") {}.buttonStyle(AIUsageControlStyle(hovered: false, focused: false, compactLabel: true))
                Button("Hover") {}.buttonStyle(AIUsageControlStyle(hovered: true, focused: false, compactLabel: true))
                Button("Focus") {}.buttonStyle(AIUsageControlStyle(hovered: false, focused: true, compactLabel: true))
                Button("Disabled") {}.buttonStyle(AIUsageControlStyle(hovered: true, focused: true, compactLabel: true)).disabled(true)
            }.padding(16), size: NSSize(width: 420, height: 80), dark: dark,
                to: directory.appendingPathComponent("cost-control-states-\(dark ? "dark" : "light").png"))
        }
        // What the Agent row's provider menu lists (a menu itself is not drawn offscreen).
        try await render(
            VStack(alignment: .leading, spacing: 6) {
                Text("   Auto")
                Divider()
                ForEach(list, id: \.tag) { endpoint in
                    Text("\(endpoint.tag == "anthropic" ? "✓ " : "   ")\(endpoint.title)   \(endpoint.speedText)")
                }
            }
            .font(.system(size: 13))
            .padding(12)
            .frame(width: 360, alignment: .leading),
            size: NSSize(width: 360, height: 150),
            to: directory.appendingPathComponent("provider-menu-items.png")
        )
    }

    func test_render_tavily_api_keys() async throws {
        guard let output = ProcessInfo.processInfo.environment["EXODIA_APIMODELS_RENDER_DIR"] else {
            throw XCTSkip("set EXODIA_APIMODELS_RENDER_DIR to write the pictures")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let catalog = directory.appendingPathComponent("tavily-catalog.json")
        try Data("{}".utf8).write(to: catalog)
        defer { try? FileManager.default.removeItem(at: catalog) }
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let offline = NoNetwork(list: [])
        let vm = APIAndModelsViewModel(routing: routing, keys: keys,
            catalogs: ModelCatalogStore(fileURL: catalog, fetcher: offline), checks: ModelCheckStore(defaults: defaults),
            keyStatuses: KeyStatusStore(defaults: defaults), keyChecker: offline, probe: offline, endpoints: offline)
        for connected in [false, true] {
            if connected { try keys.save("existing-fixture-key", account: TavilySearch.keychainAccount) }
            else { try keys.delete(account: TavilySearch.keychainAccount) }
            for dark in [false, true] {
                for width in [560.0, 760.0] {
                    let settings = vm.makeTavilySettings()
                    XCTAssertEqual(settings.configured, connected, "The moved form uses the same credential account")
                    if connected { settings.draftKey = "fixture-replacement" }
                    try await render(ProviderKeyTiles(viewModel: vm, initiallyExpanded: .tavily, tavily: settings)
                        .padding(18), size: NSSize(width: width, height: 850), dark: dark,
                        to: directory.appendingPathComponent("tavily-keys-\(connected ? "connected" : "new")-\(dark ? "dark" : "light")-\(Int(width)).png"),
                        inspect: { window in
                            settings.draftKey = "fixture-draft"
                            let unrelated = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
                            unrelated.isReleasedWhenClosed = false
                            unrelated.close()
                            XCTAssertFalse(settings.draftKey.isEmpty)
                            window.close()
                            XCTAssertTrue(settings.draftKey.isEmpty)
                            XCTAssertNil(settings.message)
                        })
                }
            }
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool = true, to url: URL,
                                 inspect: ((NSWindow) -> Void)? = nil) async throws {
        let host = NSHostingView(rootView: view.background(MacSettingsTheme.bgContent)
            .environment(\.colorScheme, dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)
        inspect?(window)
    }
}

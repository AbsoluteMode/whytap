import AppKit
import FluidAudio
import SwiftUI
import XCTest
@testable import Sidekey

/// Keys & models → API keys fits the Settings window without scrolling: the
/// owner had to scroll past huge square tiles to reach OpenRouter and the rest.
/// The pane sizes are the Settings window (1040×660 default, 960×560 minimum)
/// minus the 220pt sidebar, its 1pt separator and the 40pt title bar.
@MainActor
final class APIKeysFitTests: XCTestCase {
    static let defaultPane = NSSize(width: 1040 - 221, height: 660 - 40)
    static let minimumPane = NSSize(width: 960 - 221, height: 560 - 40)

    private actor FixedStore: OnDeviceSpeechModelManaging {
        let fixed: OnDeviceSpeechModelStatus
        init(_ status: OnDeviceSpeechModelStatus) { fixed = status }
        func status() -> OnDeviceSpeechModelStatus { fixed }
        func download(progress: (@Sendable (Double) -> Void)?) async throws {}
        func delete() async throws {}
        func acquire() async throws -> AsrManager { throw NoModel() }
        func release() {}
    }
    private struct NoModel: Error {}

    /// Answers every check with the status the scenario gave the account.
    private struct Stub: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        let statuses: [String: KeyStatus]
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] {
            throw CatalogFetchError.offline
        }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus {
            statuses[account.storageID] ?? .valid
        }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
    }

    /// The owner's screen: three speech keys in three states, OpenRouter set.
    static let ownerKeys: [(ProviderAccount, KeyStatus)] = [
        (.soniox, .valid), (.deepgram, .rejected(.invalidKey)), (.elevenLabs, .limited), (.openRouter, .valid),
    ]
    /// Every built-in key with the longest status texts.
    static let worstKeys: [(ProviderAccount, KeyStatus)] = [
        (.soniox, .rejected(.invalidKey)), (.deepgram, .rejected(.missingSpeechPermission)),
        (.elevenLabs, .rejected(.outOfCredit)), (.openRouter, .unreachable), (.openAI, .limited), (.anthropic, .valid),
    ]

    private func makeViewModel(_ keyed: [(ProviderAccount, KeyStatus)]) throws -> APIAndModelsViewModel {
        let suite = "APIKeysFit-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: catalogURL)
        }
        try Data("{}".utf8).write(to: catalogURL)
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let statuses = KeyStatusStore(defaults: defaults)
        for (account, status) in keyed {
            try keys.save("synthetic-key", account: XCTUnwrap(account.keychainAccount(in: routing)))
            statuses.set(status, for: account, at: Date())
        }
        let stub = Stub(statuses: Dictionary(uniqueKeysWithValues: keyed.map { ($0.0.storageID, $0.1) }))
        return APIAndModelsViewModel(
            routing: routing, keys: keys, catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: stub),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: statuses,
            keyChecker: stub, probe: stub, endpoints: stub, inputLanguage: { nil }, onDevice: .unavailable)
    }

    private func onDevice(_ status: OnDeviceSpeechModelStatus) async -> OnDeviceSpeechModelController {
        let controller = OnDeviceSpeechModelController(store: FixedStore(status))
        await controller.refresh()
        return controller
    }

    /// Hosts the whole Keys & models pane offscreen, lets SwiftUI lay it out,
    /// then hands the window to `inspect`.
    private func host(_ keyed: [(ProviderAccount, KeyStatus)], onDevice status: OnDeviceSpeechModelStatus,
                      size: NSSize, dark: Bool, inspect: (NSHostingView<AnyView>) throws -> Void) async throws {
        let viewModel = try makeViewModel(keyed)
        let controller = await onDevice(status)
        let view = APIAndModelsView(viewModel: viewModel, focusedFeature: .constant(nil),
                                    initialSection: .keys, onDeviceModel: controller)
            .background(MacSettingsTheme.bgContent)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: AnyView(view))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try inspect(host)
        XCTAssertFalse(window.isVisible)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    /// How far the API keys content overflows its scroll view; ≤ 0 = fits.
    private func overflow(_ host: NSView) throws -> CGFloat {
        let scroll = try XCTUnwrap(scrollViews(in: host).first, "the API keys tab scrolls in an NSScrollView")
        let document = try XCTUnwrap(scroll.documentView)
        return document.frame.height - scroll.contentView.bounds.height
    }

    // MARK: - Layout invariants

    func test_owner_keys_fit_the_default_window_without_scrolling() async throws {
        for status in [OnDeviceSpeechModelStatus.ready, .notDownloaded] {
            try await host(Self.ownerKeys, onDevice: status, size: Self.defaultPane, dark: true) { host in
                XCTAssertLessThanOrEqual(try overflow(host), 0.5, "\(status)")
            }
        }
    }

    func test_every_key_with_long_statuses_fits_the_default_window() async throws {
        try await host(Self.worstKeys, onDevice: .notDownloaded, size: Self.defaultPane, dark: false) { host in
            XCTAssertLessThanOrEqual(try overflow(host), 0.5)
        }
    }

    func test_owner_keys_fit_the_minimum_window() async throws {
        try await host(Self.ownerKeys, onDevice: .ready, size: Self.minimumPane, dark: true) { host in
            XCTAssertLessThanOrEqual(try overflow(host), 0.5)
        }
    }

    /// Only a key whose last check passed shows its status in green.
    func test_only_a_working_key_is_marked_as_working() throws {
        let viewModel = try makeViewModel(Self.ownerKeys + [(.openAI, .unreachable)])
        let working = Set(viewModel.chips.filter(\.keyWorks).map(\.account.storageID))
        XCTAssertEqual(working, [ProviderAccount.soniox.storageID, ProviderAccount.openRouter.storageID])
    }

    // MARK: - Review images

    func test_render_api_keys_tab() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_API_KEYS_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_API_KEYS_RENDER_DIR to save offscreen review images")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The real brand marks from the source Resources, as the app bundle has them.
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/UsefulLinkIcons")
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(resources)
        defer {
            ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
            ProviderBrandIconAsset.clearCacheForTesting()
        }
        for name in ["soniox", "deepgram", "elevenlabs", "openrouter"] {
            XCTAssertNotNil(ProviderBrandIconAsset.image(named: name), name)
        }
        let scenarios: [(String, [(ProviderAccount, KeyStatus)], OnDeviceSpeechModelStatus, NSSize)] = [
            ("1-owner-default-1040x660", Self.ownerKeys, .ready, Self.defaultPane),
            ("2-owner-minimum-960x560", Self.ownerKeys, .ready, Self.minimumPane),
            ("3-long-statuses-default", Self.worstKeys, .notDownloaded, Self.defaultPane),
            ("4-no-keys-default", [], .notDownloaded, Self.defaultPane),
        ]
        for dark in [false, true] {
            for (name, keyed, status, size) in scenarios {
                try await host(keyed, onDevice: status, size: size, dark: dark) { host in
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
            }
            // The key form opens under the row of the selected tile.
            let viewModel = try makeViewModel(Self.worstKeys)
            let tiles = ProviderKeyTiles(viewModel: viewModel, initiallyExpanded: .provider(.deepgram))
                .padding(18).frame(width: Self.defaultPane.width - 48, alignment: .topLeading)
                .background(MacSettingsTheme.bgCard)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: tiles)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: NSSize(width: Self.defaultPane.width - 48, height: host.fittingSize.height))
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: host.frame.width, height: host.frame.height),
                                  styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("5-form-open-\(dark ? "dark" : "light").png"))
            XCTAssertFalse(window.isVisible)
            window.contentView = nil
            window.close()
        }
    }
}

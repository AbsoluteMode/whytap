import AppKit
import FluidAudio
import SwiftUI
import XCTest
@testable import Sidekey

/// The On this Mac block of API keys: its own card above the key tiles, with
/// the one action in the card. No model is downloaded or loaded.
@MainActor
final class OnDeviceSpeechCardTests: XCTestCase {
    private struct NoModel: Error {}

    /// A store frozen in one status.
    private actor FixedStore: OnDeviceSpeechModelManaging {
        let fixed: OnDeviceSpeechModelStatus
        init(_ status: OnDeviceSpeechModelStatus) { fixed = status }
        func status() -> OnDeviceSpeechModelStatus { fixed }
        func download(progress: (@Sendable (Double) -> Void)?) async throws {}
        func delete() async throws {}
        func acquire() async throws -> AsrManager { throw NoModel() }
        func release() {}
    }

    private struct Offline: ModelCatalogFetching, ProviderKeyChecking, ModelProbing, OpenRouterEndpointsFetching {
        func fetch(account: ProviderAccount, apiKey: String?, server: ServerEndpoint?) async throws -> [CatalogModel] { [] }
        func check(_ account: ProviderAccount, apiKey: String?, server: ServerEndpoint?, allowPaidProbe: Bool) async -> KeyStatus { .valid }
        func probe(_ route: ResolvedRoute, use: ModelUse, catalog: CatalogModel?) async -> ProbeOutcome { .passed }
        func endpoints(model: String, apiKey: String) async throws -> [OpenRouterEndpoint] { [] }
    }

    private func makeViewModel() throws -> APIAndModelsViewModel {
        let suite = "OnDeviceCard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let catalogURL = FileManager.default.temporaryDirectory.appendingPathComponent(suite + ".json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: catalogURL)
        }
        try Data("{}".utf8).write(to: catalogURL)
        let offline = Offline()
        let box = InMemoryTokenStore.Box()
        return APIAndModelsViewModel(
            routing: AIRoutingStore(defaults: defaults),
            keys: ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) }),
            catalogs: ModelCatalogStore(fileURL: catalogURL, fetcher: offline),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults),
            keyChecker: offline, probe: offline, endpoints: offline, inputLanguage: { nil },
            onDevice: .unavailable
        )
    }

    // MARK: - Copy

    func test_each_state_says_what_it_is_and_offers_one_action() {
        typealias Presentation = OnDeviceSpeechCard.Presentation
        let fresh = Presentation(.notDownloaded)
        XCTAssertEqual(fresh.title, "Dictate without a key")
        XCTAssertEqual(fresh.action, "Download")
        XCTAssertTrue(fresh.detail.contains("audio never leaves it"))
        XCTAssertTrue(fresh.detail.contains("about 470 MB"), "the size is known before the click")

        let loading = Presentation(.downloading(0.427))
        XCTAssertEqual(loading.action, "Cancel")
        XCTAssertTrue(loading.detail.hasPrefix("42% of"))

        let ready = Presentation(.ready)
        XCTAssertEqual(ready.action, "Remove")
        XCTAssertTrue(ready.detail.contains("Works offline"))

        let failed = Presentation(.failed)
        XCTAssertEqual(failed.action, "Download", "a failed download is retried with the same button")

        XCTAssertEqual(Set([fresh, loading, ready, failed].map(\.symbol)).count, 4, "every state has its own symbol")
    }

    func test_percent_never_leaves_its_range_or_reads_100_before_the_end() {
        typealias Presentation = OnDeviceSpeechCard.Presentation
        XCTAssertEqual(Presentation.percent(-1), 0)
        XCTAssertEqual(Presentation.percent(0.999), 99)
        XCTAssertEqual(Presentation.percent(1), 100)
        XCTAssertEqual(Presentation.percent(7), 100)
    }

    // MARK: - Placement

    /// The tile looked like a key and its "Download model" line looked like a
    /// button that did nothing: the action was in a form below the row.
    func test_on_this_mac_is_a_card_above_the_tiles_not_a_key_tile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/Sidekey/Settings/APIAndModels")
        let tiles = try String(contentsOf: folder.appendingPathComponent("ProviderKeyTiles.swift"), encoding: .utf8)
        XCTAssertTrue(tiles.contains(".filter { $0 != .onDevice }"), "no On this Mac tile among the keys")
        XCTAssertFalse(tiles.contains("OnDeviceModelForm"))

        let view = try String(contentsOf: folder.appendingPathComponent("APIAndModelsView.swift"), encoding: .utf8)
        let card = try XCTUnwrap(view.range(of: "onDeviceBlock }"))
        let keys = try XCTUnwrap(view.range(of: "keysBlock\n"))
        XCTAssertLessThan(card.lowerBound, keys.lowerBound, "the card comes before the key tiles")
        XCTAssertTrue(view.contains("OnDeviceSpeechModelStore.isSupportedHost { onDeviceBlock }"), "Apple Silicon only")

        let source = try String(contentsOf: folder.appendingPathComponent("OnDeviceSpeechCard.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("MacButton(title: presentation.action"), "the action is a real button in the card")
        XCTAssertTrue(source.contains("accessibilityReduceMotion"), "motion is optional")
    }

    // MARK: - Review images

    func test_render_the_card_in_every_state() async throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_ON_DEVICE_CARD_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_ON_DEVICE_CARD_RENDER_DIR to save offscreen review images")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let viewModel = try makeViewModel()
        let states: [(String, OnDeviceSpeechModelStatus)] = [
            ("1-fresh", .notDownloaded), ("2-downloading", .downloading(0.42)), ("3-ready", .ready), ("4-failed", .failed),
        ]
        for dark in [false, true] {
            for (name, status) in states {
                let controller = OnDeviceSpeechModelController(store: FixedStore(status))
                await controller.refresh()
                let content = VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 0) {
                        MacGroupTitle(title: "On this Mac")
                        OnDeviceSpeechCard(viewModel: viewModel, model: controller)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        MacGroupTitle(title: "API keys")
                        ProviderKeyTiles(viewModel: viewModel)
                    }
                }
                .padding(18)
                .frame(width: 760, alignment: .topLeading)
                .background(MacSettingsTheme.bgCard)
                let host = NSHostingView(rootView: content)
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: NSSize(width: 760, height: min(size.height, 620)))
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 760, height: host.frame.height),
                                      styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(450))
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                XCTAssertFalse(window.isVisible)
                window.contentView = nil
                window.close()
            }
        }
    }
}

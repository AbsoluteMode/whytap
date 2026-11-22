import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// "Use your own server →" in the app opens the real server form: Settings
/// -> API & Models -> API keys, the Custom server tile as if clicked, with
/// the onboarding still open behind it.
@MainActor
final class OnboardingServerLinkTests: XCTestCase {
    func testSettingsSelectionAsksForTheServerFormOnAPIAndModels() {
        let selection = SettingsWindowSelection(selectedTab: .hotkeys)
        selection.requestNewServer()
        XCTAssertEqual(selection.selectedTab, .apiAndModels)
        XCTAssertTrue(selection.newServerRequested)
    }

    /// The tiles take the request (the same path as a click on Custom
    /// server) and clear it, so reopening Settings does not open it again.
    func testTheTilesTakeTheRequestOnce() async throws {
        let suite = "OnboardingServerLinkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        try Data("{}".utf8).write(to: file)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        let fake = OnboardingPreviewProviders()
        let viewModel = APIAndModelsViewModel(
            routing: AIRoutingStore(defaults: defaults), keys: keys,
            catalogs: ModelCatalogStore(fileURL: file, fetcher: fake),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults),
            keyChecker: fake, probe: fake, endpoints: fake, inputLanguage: { nil })
        let selection = SettingsWindowSelection(selectedTab: .apiAndModels)
        selection.requestNewServer()
        let view = APIAndModelsView(viewModel: viewModel, focusedFeature: .constant(nil),
                                    newServerRequested: Binding(get: { selection.newServerRequested },
                                                                set: { selection.newServerRequested = $0 }))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 900)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 720, height: 900),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for _ in 0..<50 where selection.newServerRequested {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(selection.newServerRequested, "API keys showed and the Custom server tile took the request")
        XCTAssertFalse(window.isVisible)
    }
}

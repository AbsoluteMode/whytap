import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Offscreen proof of the direct Anthropic/OpenAI picker rows priced from the
/// OpenRouter catalog. Reads a copy of a model catalog cache (public model
/// metadata only) named by WHYTAP_MODEL_METADATA_CATALOG and writes PNGs to
/// WHYTAP_MODEL_METADATA_RENDER_DIR; never touches the app's own stores.
@MainActor
final class DirectModelMetadataRenderTests: XCTestCase {
    func testDirectProviderSectionsRenderPricesAndReasoning() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["WHYTAP_MODEL_METADATA_RENDER_DIR"],
              let catalogPath = environment["WHYTAP_MODEL_METADATA_CATALOG"] else {
            throw XCTSkip("Set WHYTAP_MODEL_METADATA_RENDER_DIR and WHYTAP_MODEL_METADATA_CATALOG for offscreen proof")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-\(suite).json")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: catalogPath), to: file)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: file)
        }
        let routing = AIRoutingStore(defaults: defaults)
        let box = InMemoryTokenStore.Box()
        let keys = ProviderKeyStore(makeStore: { InMemoryTokenStore(account: $0, box: box) })
        for account in [ProviderAccount.anthropic, .openAI, .openRouter] {
            if let name = account.keychainAccount(in: routing) { try keys.save("key", account: name) }
        }
        let resolver = ModelStatusResolver(
            routing: routing, keys: keys, catalogs: ModelCatalogStore(fileURL: file),
            checks: ModelCheckStore(defaults: defaults), keyStatuses: KeyStatusStore(defaults: defaults))
        // The maintainer's own case: Drop Smart text on an OpenRouter model.
        routing.setRoute(FeatureRoute(account: .openRouter, model: "anthropic/claude-sonnet-5.5"), for: .dropSmartCleanup)
        let sections = resolver.sections(for: .dropSmartCleanup)
        XCTAssertEqual(sections.map(\.account), [.anthropic, .openAI, .openRouter])

        // The real picker: every section, the provider bar, optionally one provider chosen.
        let shots: [(name: String, provider: ProviderAccount?, query: String)] = [
            ("all-providers", nil, ""),
            ("all-search-sonnet", nil, "sonnet"),
            ("anthropic", .anthropic, ""),
            ("anthropic-claude-4", .anthropic, "claude 4"),
            ("openai-gpt-6", .openAI, "gpt-6"),
            ("openai-gpt-5", .openAI, "gpt-5."),
            ("openai-gpt-4", .openAI, "gpt-4"),
            ("openrouter-reference", .openRouter, "anthropic/claude"),
        ]
        var summary: [String] = []
        for section in sections {
            for option in section.options {
                summary.append([section.title, option.model, option.dateLabel ?? "-", option.priceLabel ?? "-",
                                option.hint ?? "-"].joined(separator: " | "))
            }
        }
        for shot in shots {
            for dark in [false, true] {
                let picker = ModelPicker(sections: sections, missingProviderHint: nil, initialQuery: shot.query,
                                         initialProvider: shot.provider,
                                         onSelect: { _, _ in }, onRefresh: {}, onAddKey: {}, onClose: {})
                let host = NSHostingView(rootView: picker.environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = NSSize(width: 440, height: 400)
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                      styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("\(shot.name)-\(dark ? "dark" : "light").png"))
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
                window.contentView = nil
                window.close()
            }
        }
        try (summary.joined(separator: "\n") + "\n")
            .write(to: directory.appendingPathComponent("rows.txt"), atomically: true, encoding: .utf8)
    }
}

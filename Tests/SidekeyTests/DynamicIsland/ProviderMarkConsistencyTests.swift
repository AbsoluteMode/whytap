import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// A route on Anthropic's own API shows the bundled Anthropic mark everywhere
/// (island ticker, API & Models), the same asset the Agent uses for Anthropic
/// models, never a generic SF Symbol.
@MainActor
final class ProviderMarkConsistencyTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(try projectRoot().appendingPathComponent("Resources/UsefulLinkIcons"))
    }

    override func tearDown() async throws {
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        try await super.tearDown()
    }

    private func routing() -> AIRoutingStore {
        let suite = "ProviderMarkConsistencyTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return AIRoutingStore(defaults: defaults)
    }

    func testAnthropicRoutesShowTheAgentsBundledMarkNotASystemSymbol() throws {
        let routing = routing()
        let route = FeatureRoute(account: .anthropic, model: "claude-sonnet-5-5")
        routing.setRoute(route, for: .agent)
        routing.setRoute(route, for: .dropSmartCleanup)

        // The Agent on an Anthropic route: the reference mark.
        let agent = TranscriptionProviderBrand.agent(.native, route: routing.route(for: .agent))
        XCTAssertEqual(agent.assetName, "model-anthropic")
        XCTAssertNil(agent.systemName)

        // Drop Smart cleanup ("thinking…" in the island) on the same account.
        let cleanup = try XCTUnwrap(TranscriptionProviderBrand.currentDropCleanup(routing: routing))
        XCTAssertEqual(cleanup.assetName, agent.assetName)
        XCTAssertNil(cleanup.systemName)
        XCTAssertEqual(cleanup.label, "Anthropic")

        // Any other surface that asks for the account's brand.
        let account = TranscriptionProviderBrand.brand(for: .anthropic, in: routing)
        XCTAssertEqual(account.assetName, agent.assetName)
        XCTAssertNil(account.systemName)

        // Settings → API & Models tiles, chips and model rows.
        XCTAssertEqual(ProviderKindIcon.assetName(for: .anthropic), agent.assetName)

        // An unset feature still shows nothing rather than a guessed mark.
        routing.setRoute(nil, for: .dropSmartCleanup)
        XCTAssertNil(TranscriptionProviderBrand.currentDropCleanup(routing: routing))
    }

    /// One provider, one mark: the Agent ticker, Drop, API & Models and the
    /// first-run key step all name the same bundled asset.
    func testOpenAIAndAnthropicShowOneMarkInEveryPlace() throws {
        let routing = routing()
        let cases: [(ProviderAccount, AIProviderKind, String)] = [
            (.openAI, .openAI, "model-openai"), (.anthropic, .anthropic, "model-anthropic"),
        ]
        for (account, kind, asset) in cases {
            let agent = TranscriptionProviderBrand.agent(.native, route: .init(account: account, model: "exact-user-model"))
            XCTAssertEqual(agent.assetName, asset)
            XCTAssertEqual(TranscriptionProviderBrand.brand(for: account, in: routing).assetName, asset)
            XCTAssertEqual(ProviderKindIcon.assetName(for: kind), asset)
            XCTAssertEqual(OnboardingKeyProvider.of(kind)?.assetName, asset)
            XCTAssertNotNil(ProviderBrandIconAsset.image(named: asset, pointSize: 16), "\(asset) is not bundled")
        }
        // Drop dictation on an OpenAI key and the plan hint use it too.
        XCTAssertEqual(TranscriptionProviderBrand.byok(.openAI).assetName, "model-openai")
        // An OpenRouter route to the same authors keeps the same marks.
        let routed = TranscriptionProviderBrand.agent(.native, route: .init(account: .openRouter, model: "openai/gpt-exact"))
        XCTAssertEqual(routed.assetName, "model-openai")
    }

    func testAnthropicMarkIsBundledAndReadsOnTheBlackIslandAtTickerSize() throws {
        let root = try projectRoot().appendingPathComponent("Resources/UsefulLinkIcons")
        let asset = try XCTUnwrap(TranscriptionProviderBrand.anthropic.assetName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(asset).pdf").path))
        XCTAssertNotNil(ProviderBrandIconAsset.image(named: asset, pointSize: 16), "Settings would fall back to a symbol")

        let image = try XCTUnwrap(ProviderBreathingMarkView.markImageForTesting(brand: .anthropic))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let rep = NSBitmapImageRep(cgImage: cg)
        var opaque = 0, dark = 0, clear = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent < 0.05 { clear += 1 }
                guard color.alphaComponent > 0.95 else { continue }
                opaque += 1
                if min(color.redComponent, color.greenComponent, color.blueComponent) < 0.6 { dark += 1 }
            }
        }
        XCTAssertGreaterThan(opaque, 0, "the mark is empty")
        XCTAssertEqual(dark, 0, "dark pixels vanish on the black island")
        XCTAssertGreaterThan(clear, 0, "the mark is a monogram, not a filled tile")

        // The same pixels as the Agent's Anthropic mark before its artwork refresh.
        let agent = TranscriptionProviderBrand(assetName: AgentModelBrand.anthropic.assetName, label: "Anthropic")
        XCTAssertEqual(image.tiffRepresentation, ProviderBreathingMarkView.markImageForTesting(brand: agent)?.tiffRepresentation)
    }

    /// Pictures of the island "thinking…" ticker and the Settings icon, written
    /// off screen without showing a window.
    func testRenderAnthropicMarkOffscreen() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_ANTHROPIC_MARK_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_ANTHROPIC_MARK_RENDER_DIR for the Anthropic mark pictures")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let ticker = HStack(spacing: 12) {
            ForEach(["Anthropic", "OpenAI", "OpenRouter"], id: \.self) { name in
                let brand: TranscriptionProviderBrand = name == "Anthropic" ? .anthropic
                    : name == "OpenAI" ? .openAI : .openRouter
                IslandAgentWingView(wing: .acting, faceWidth: 110, activityLabel: "thinking…",
                                    recordingProviderBrand: brand, height: 28, onComposingFocusChange: { _ in })
                    .frame(width: 110, height: 28)
                    .background(Color.black, in: Capsule())
            }
        }
        .padding(12)
        try render(ticker, size: NSSize(width: 390, height: 52), dark: true, scale: 4,
                   to: directory.appendingPathComponent("island-thinking.png"))

        for dark in [false, true] {
            let settings = HStack(spacing: 18) {
                ForEach([AIProviderKind.anthropic, .openAI, .openRouter, .elevenLabs], id: \.self) { kind in
                    VStack(spacing: 8) {
                        ProviderKindIcon(kind: kind, size: 28)
                        ProviderKindIcon(kind: kind, size: 16)
                    }
                }
            }
            .padding(16)
            .background(MacSettingsTheme.bgContent)
            .environment(\.colorScheme, dark ? .dark : .light)
            try render(settings, size: NSSize(width: 220, height: 92), dark: dark, scale: 4,
                       to: directory.appendingPathComponent("settings-icons-\(dark ? "dark" : "light").png"))
        }
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool, scale: CGFloat, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.backgroundColor = dark ? .black : .white
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        XCTAssertFalse(window.isVisible)
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "ProviderMarkConsistencyTests", code: 1)
    }
}

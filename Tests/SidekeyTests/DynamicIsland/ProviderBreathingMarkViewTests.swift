import AppKit
import XCTest
@testable import Sidekey

/// Contract for the drop-recording provider mark: the breathing pulse must be
/// a Core Animation (render-server) animation, NOT a SwiftUI `.animation` —
/// SwiftUI animations advance on the main thread, which is busy with session
/// setup (AX capture, Keychain JWT, WS handshake, audio-engine spin-up)
/// exactly when this mark appears, so the SwiftUI version visibly stuttered
/// on every first drop and intermittently afterwards.
@MainActor
final class ProviderBreathingMarkViewTests: XCTestCase {
    private var iconDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        iconDir = try projectRoot().appendingPathComponent("Resources/UsefulLinkIcons")
        ProviderBrandIconAsset.setResourceDirectoryForTesting(iconDir)
        ProviderBrandIconAsset.clearCacheForTesting()
    }

    override func tearDown() async throws {
        ProviderBrandIconAsset.clearCacheForTesting()
        ProviderBrandIconAsset.setResourceDirectoryForTesting(nil)
        try await super.tearDown()
    }

    private func makeView(
        brand: TranscriptionProviderBrand = .init(assetName: "soniox", label: "Soniox"),
        reduceMotion: Bool = false
    ) -> ProviderBreathingMarkView {
        ProviderBreathingMarkView(brand: brand, reduceMotion: reduceMotion)
    }

    // MARK: - Render-server animation contract

    func testBreathingPulseIsInfiniteRenderServerAnimation() {
        let view = makeView()

        let animation = view.markLayerForTesting.animation(
            forKey: ProviderBreathingMarkView.breathingAnimationKey
        )
        let group = try? XCTUnwrap(animation as? CAAnimationGroup)
        guard let group else { return }

        XCTAssertEqual(group.duration, ProviderBreathingMarkView.pulseDuration)
        XCTAssertTrue(group.autoreverses)
        XCTAssertEqual(group.repeatCount, .greatestFiniteMagnitude)

        let keyPaths = Set(
            (group.animations ?? []).compactMap { ($0 as? CABasicAnimation)?.keyPath }
        )
        XCTAssertEqual(keyPaths, ["transform.scale", "opacity"])
    }

    func testBreathingPulseMatchesPriorSwiftUIRange() throws {
        let view = makeView()

        let group = try XCTUnwrap(
            view.markLayerForTesting.animation(
                forKey: ProviderBreathingMarkView.breathingAnimationKey
            ) as? CAAnimationGroup
        )
        let basics = (group.animations ?? []).compactMap { $0 as? CABasicAnimation }
        let scale = try XCTUnwrap(basics.first { $0.keyPath == "transform.scale" })
        let opacity = try XCTUnwrap(basics.first { $0.keyPath == "opacity" })

        XCTAssertEqual(scale.fromValue as? CGFloat, 0.94)
        XCTAssertEqual(scale.toValue as? CGFloat, 1.08)
        XCTAssertEqual(opacity.fromValue as? Float, 0.58)
        XCTAssertEqual(opacity.toValue as? Float, 0.96)
    }

    // MARK: - Reduce Motion

    func testReduceMotionShowsStaticMarkWithoutAnimation() {
        let view = makeView(reduceMotion: true)

        XCTAssertNil(
            view.markLayerForTesting.animation(
                forKey: ProviderBreathingMarkView.breathingAnimationKey
            )
        )
        XCTAssertEqual(
            view.markLayerForTesting.opacity,
            ProviderBreathingMarkView.reducedMotionOpacity
        )
    }

    func testApplyTogglesReduceMotionWithoutRecreatingView() {
        let view = makeView(reduceMotion: false)
        let key = ProviderBreathingMarkView.breathingAnimationKey

        view.apply(
            brand: .init(assetName: "soniox", label: "Soniox"),
            reduceMotion: true
        )
        XCTAssertNil(view.markLayerForTesting.animation(forKey: key))

        view.apply(
            brand: .init(assetName: "soniox", label: "Soniox"),
            reduceMotion: false
        )
        XCTAssertNotNil(view.markLayerForTesting.animation(forKey: key))
    }

    // MARK: - Re-attach: CA drops animations when a layer leaves the render tree

    func testMovingToWindowReattachesAnimation() {
        let view = makeView()
        let key = ProviderBreathingMarkView.breathingAnimationKey
        view.markLayerForTesting.removeAllAnimations()
        XCTAssertNil(view.markLayerForTesting.animation(forKey: key))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(view)

        XCTAssertNotNil(view.markLayerForTesting.animation(forKey: key))
    }

    // MARK: - Contents

    func testAssetBrandRendersLayerContents() {
        let view = makeView(brand: .init(assetName: "deepgram", label: "Deepgram"))
        XCTAssertNotNil(view.markLayerForTesting.contents)
    }

    func testSystemSymbolBrandRendersLayerContents() {
        let view = makeView(brand: .init(systemName: "server.rack", label: "Self-hosted"))
        XCTAssertNotNil(view.markLayerForTesting.contents)
    }

    func testBrandSwapUpdatesLayerContents() throws {
        let view = makeView(brand: .init(assetName: "soniox", label: "Soniox"))
        let before = try XCTUnwrap(view.markLayerForTesting.contents as AnyObject?)

        view.apply(
            brand: .init(assetName: "deepgram", label: "Deepgram"),
            reduceMotion: false
        )
        let after = try XCTUnwrap(view.markLayerForTesting.contents as AnyObject?)

        XCTAssertFalse(before === after)
    }

    // MARK: - White tint

    /// Every brand the island ticker can show is flattened to the white tint,
    /// whatever colors its asset or symbol has: a skipped `.sourceAtop` wash
    /// leaves the dark source glyph, which vanishes on the black island. The
    /// legacy wash preserves its existing slight color; model-author marks use
    /// neutral 72% white through source alpha, including colorful remote artwork.
    func testEveryIslandBrandRendersWhiteTintedMark() throws {
        let brands: [TranscriptionProviderBrand] =
            BYOKProvider.allCases.map(TranscriptionProviderBrand.byok)
            + CLIProviderID.allCases.map(TranscriptionProviderBrand.agent)
            + [.google, .openRouter, .customLLM]
            + AgentModelBrand.allCases.map { TranscriptionProviderBrand(assetName: $0.assetName, label: $0.rawValue) }

        for brand in brands {
            let image = try XCTUnwrap(
                ProviderBreathingMarkView.markImageForTesting(brand: brand),
                "\(brand.label) has no mark"
            )
            let rep = try XCTUnwrap(bitmap(from: image))

            var opaque = 0
            var untinted = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let raw = rep.colorAt(x: x, y: y),
                          let color = raw.usingColorSpace(.deviceRGB),
                          color.alphaComponent > 0.95 else { continue }
                    opaque += 1
                    let maxC = max(color.redComponent, color.greenComponent, color.blueComponent)
                    let minC = min(color.redComponent, color.greenComponent, color.blueComponent)
                    if minC < 0.6 || maxC - minC > 0.3 { untinted += 1 }
                }
            }
            XCTAssertGreaterThan(opaque, 0, "\(brand.label) mark is empty")
            XCTAssertEqual(untinted, 0, "\(brand.label) mark has dark or colored pixels instead of the white tint")
        }
    }

    private func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: cg)
    }

    func testGoogleVoiceSearchRetainsItsExistingColorWash() throws {
        let image = try XCTUnwrap(ProviderBreathingMarkView.markImageForTesting(brand: .google))
        let rep = try XCTUnwrap(bitmap(from: image))
        var coloredPixels = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.95 else { continue }
                if max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent) > 0.08 {
                    coloredPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(coloredPixels, 0, "The model-only mask must not repaint the existing Google search mark")
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "ProviderBreathingMarkViewTests", code: 1)
    }
}

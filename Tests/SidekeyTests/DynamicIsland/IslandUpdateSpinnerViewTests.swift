import AppKit
import XCTest
@testable import Sidekey

/// Contract for the download spinner shown in the Dynamic Island update pill's
/// `.downloading` stage. The spin must be a Core Animation (render-server)
/// rotation, NOT a SwiftUI `.animation(.repeatForever)`: SwiftUI animations
/// advance on the main thread, which is busy exactly while Sparkle is fetching
/// + extracting the update (per-chunk progress emits mutate `@Published` state
/// and re-render the island). A render-server rotation keeps spinning through
/// those stalls — mirrors `ProviderBreathingMarkView`.
@MainActor
final class IslandUpdateSpinnerViewTests: XCTestCase {

    private func makeView(reduceMotion: Bool = false) -> UpdateSpinnerMarkView {
        UpdateSpinnerMarkView(reduceMotion: reduceMotion)
    }

    // MARK: - Render-server animation contract

    func testSpinIsInfiniteRenderServerRotation() throws {
        let view = makeView()

        let animation = view.spinnerLayerForTesting.animation(
            forKey: UpdateSpinnerMarkView.spinAnimationKey
        )
        let spin = try XCTUnwrap(animation as? CABasicAnimation)

        XCTAssertEqual(spin.keyPath, "transform.rotation.z")
        XCTAssertEqual(spin.repeatCount, .greatestFiniteMagnitude)
        XCTAssertEqual(spin.duration, UpdateSpinnerMarkView.spinDuration)
        XCTAssertFalse(spin.autoreverses, "a spinner turns one direction, never reverses")
    }

    func testSpinSweepsAFullTurn() throws {
        let view = makeView()

        let spin = try XCTUnwrap(
            view.spinnerLayerForTesting.animation(
                forKey: UpdateSpinnerMarkView.spinAnimationKey
            ) as? CABasicAnimation
        )
        XCTAssertEqual(spin.fromValue as? CGFloat, 0)
        XCTAssertEqual(spin.toValue as? CGFloat, CGFloat.pi * 2)
    }

    // MARK: - Reduce Motion

    func testReduceMotionShowsStaticGlyphWithoutAnimation() {
        let view = makeView(reduceMotion: true)

        XCTAssertNil(
            view.spinnerLayerForTesting.animation(
                forKey: UpdateSpinnerMarkView.spinAnimationKey
            ),
            "Reduce Motion must not attach the infinite rotation."
        )
    }

    func testApplyTogglesReduceMotionWithoutRecreatingView() {
        let view = makeView(reduceMotion: false)
        let key = UpdateSpinnerMarkView.spinAnimationKey

        view.apply(reduceMotion: true)
        XCTAssertNil(view.spinnerLayerForTesting.animation(forKey: key))

        view.apply(reduceMotion: false)
        XCTAssertNotNil(view.spinnerLayerForTesting.animation(forKey: key))
    }

    // MARK: - Re-attach: CA drops animations when a layer leaves the render tree

    func testMovingToWindowReattachesAnimation() {
        let view = makeView()
        let key = UpdateSpinnerMarkView.spinAnimationKey
        view.spinnerLayerForTesting.removeAllAnimations()
        XCTAssertNil(view.spinnerLayerForTesting.animation(forKey: key))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        defer { window.orderOut(nil) }
        window.contentView?.addSubview(view)

        XCTAssertNotNil(view.spinnerLayerForTesting.animation(forKey: key))
    }

    // MARK: - Contents

    func testRendersGlyphLayerContents() {
        let view = makeView()
        XCTAssertNotNil(
            view.spinnerLayerForTesting.contents,
            "The spinner must render its arrow glyph into the layer."
        )
    }
}

import AppKit
import XCTest
@testable import Sidekey

/// Unit tests for `BackgroundLuminanceObserver`: the pure math (sRGB
/// luminance + hysteresis) is verified in isolation, and the higher-level
/// `update(rgba:)` / `update(luminance:)` entry points are exercised via a
/// stub feeder so we never need real pixel capture output in CI.
@MainActor
final class BackgroundLuminanceObserverTests: XCTestCase {

    // MARK: - sRGB luminance math

    /// Pure white pixels must map to luminance 1.0 (Rec. 709 coefficients).
    func testLuminanceOfPureWhitePixelsIsOne() {
        let lum = BackgroundLuminanceObserver.luminance(
            ofRGBA: [255, 255, 255, 255]
        )
        XCTAssertEqual(lum, 1.0, accuracy: 0.001)
    }

    /// Pure black pixels must map to luminance 0.
    func testLuminanceOfPureBlackPixelsIsZero() {
        let lum = BackgroundLuminanceObserver.luminance(
            ofRGBA: [0, 0, 0, 255]
        )
        XCTAssertEqual(lum, 0.0, accuracy: 0.001)
    }

    /// Pure green carries the most luma weight (`0.7152`), so the
    /// resulting average must match that coefficient — not 0.5, not the
    /// average of the channels. Pinning the actual coefficient catches a
    /// future regression to the naive (R+G+B)/3 formula.
    func testLuminanceUsesRec709Coefficients() {
        let lum = BackgroundLuminanceObserver.luminance(
            ofRGBA: [0, 255, 0, 255]
        )
        XCTAssertEqual(lum, 0.7152, accuracy: 0.001)
    }

    /// Multiple pixels averaging across the sample region.
    func testLuminanceAveragesMultiplePixels() {
        // Two pixels: one black (0), one white (1) -> average 0.5.
        let lum = BackgroundLuminanceObserver.luminance(
            ofRGBA: [0, 0, 0, 255, 255, 255, 255, 255]
        )
        XCTAssertEqual(lum, 0.5, accuracy: 0.001)
    }

    /// Empty input (zero pixels) yields 0 — a defensive fallback rather
    /// than NaN. This protects callers from crashing on the first sample
    /// before any pixels have been captured.
    func testLuminanceOfEmptyBufferIsZero() {
        let lum = BackgroundLuminanceObserver.luminance(ofRGBA: [])
        XCTAssertEqual(lum, 0.0, accuracy: 0.001)
    }

    /// Mismatched buffer length (not a multiple of 4) — must not crash
    /// and must ignore the partial trailing pixel. We compute over the
    /// complete pixels only.
    func testLuminanceIgnoresPartialTrailingPixel() {
        // 1 complete white pixel + 3 trailing bytes (incomplete).
        let lum = BackgroundLuminanceObserver.luminance(
            ofRGBA: [255, 255, 255, 255, 10, 10, 10]
        )
        XCTAssertEqual(lum, 1.0, accuracy: 0.001)
    }

    // MARK: - Display-local crop coordinates

    func testDisplayLocalSourceRectConvertsFromCocoaToDisplayLocalCoordinates() throws {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let sample = CGRect(x: 1200, y: 6, width: 100, height: 100)

        let source = BackgroundLuminanceObserver.displayLocalSourceRect(
            sampleScreenFrame: sample,
            displayFrame: display
        )
        let rect = try XCTUnwrap(source)

        XCTAssertEqual(rect.minX, 1200, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 794, accuracy: 0.001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.height, 100, accuracy: 0.001)
    }

    func testDisplayLocalSourceRectClipsToDisplayBounds() throws {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let sample = CGRect(x: 1390, y: 850, width: 100, height: 100)

        let source = BackgroundLuminanceObserver.displayLocalSourceRect(
            sampleScreenFrame: sample,
            displayFrame: display
        )
        let rect = try XCTUnwrap(source)

        XCTAssertEqual(rect.minX, 1390, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 50, accuracy: 0.001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.001)
    }

    // MARK: - Hysteresis (avoid flicker at the threshold)

    /// Defaults: dark when luminance < 0.4, light when luminance > 0.6.
    /// The mid-band [0.4, 0.6] preserves the previous state so the orb
    /// doesn't flip on tiny background fluctuations.
    func testDefaultsToLightWhenStarted() {
        let observer = BackgroundLuminanceObserver()
        XCTAssertFalse(
            observer.isDarkBackground,
            "Initial state should be light — the orb starts dark-on-white, the safer default for a fresh app over a Finder window."
        )
    }

    func testCrossesIntoDarkBelowLowerThreshold() {
        let observer = BackgroundLuminanceObserver()
        observer.update(luminance: 0.30)
        XCTAssertTrue(observer.isDarkBackground)
    }

    func testCrossesIntoLightAboveUpperThreshold() {
        let observer = BackgroundLuminanceObserver()
        observer.update(luminance: 0.30)
        XCTAssertTrue(observer.isDarkBackground)
        observer.update(luminance: 0.70)
        XCTAssertFalse(observer.isDarkBackground)
    }

    /// Mid-band must NOT flip state — this is the entire point of
    /// hysteresis. A reading of 0.50 right after we registered "dark"
    /// must stay dark (no flicker on the threshold).
    func testMidBandReadingPreservesPreviousState() {
        let observer = BackgroundLuminanceObserver()
        observer.update(luminance: 0.30)
        XCTAssertTrue(observer.isDarkBackground)

        // Wallpaper shifts into the mid-band — orb must not flip.
        observer.update(luminance: 0.50)
        XCTAssertTrue(observer.isDarkBackground)

        // Same logic from the light side.
        observer.update(luminance: 0.70)
        XCTAssertFalse(observer.isDarkBackground)
        observer.update(luminance: 0.50)
        XCTAssertFalse(observer.isDarkBackground)
    }

    /// Exact threshold values: lower bound (0.4) is "still dark", upper
    /// bound (0.6) is "still light" — the strict-inequality semantics
    /// avoid bouncing exactly at the boundary.
    func testExactLowerBoundIsExclusiveForLight() {
        let observer = BackgroundLuminanceObserver()
        observer.update(luminance: 0.30)
        XCTAssertTrue(observer.isDarkBackground)
        observer.update(luminance: 0.40)
        XCTAssertTrue(
            observer.isDarkBackground,
            "Exactly hitting the lower bound (0.40) should not yet trip back to light."
        )
    }

    func testExactUpperBoundIsExclusiveForDark() {
        let observer = BackgroundLuminanceObserver()
        observer.update(luminance: 0.70)
        XCTAssertFalse(observer.isDarkBackground)
        observer.update(luminance: 0.60)
        XCTAssertFalse(
            observer.isDarkBackground,
            "Exactly hitting the upper bound (0.60) should not yet trip back to dark."
        )
    }

    // MARK: - Graceful fallback

    /// The observer must expose a usable `isDarkBackground` derived from
    /// `NSApp.effectiveAppearance` (system dark / light mode) so the orb
    /// has a sane palette without screen observation.
    func testFallbackFollowsSystemDarkAppearance() {
        let observer = BackgroundLuminanceObserver()
        observer.applySystemAppearanceFallback(isSystemDark: true)
        XCTAssertTrue(observer.isDarkBackground)
    }

    func testFallbackFollowsSystemLightAppearance() {
        let observer = BackgroundLuminanceObserver()
        observer.applySystemAppearanceFallback(isSystemDark: true)
        XCTAssertTrue(observer.isDarkBackground)
        observer.applySystemAppearanceFallback(isSystemDark: false)
        XCTAssertFalse(observer.isDarkBackground)
    }

    /// `start()` is a compatibility no-op now: it applies the system
    /// fallback without creating a running capture session.
    func testStartDoesNotCreateCaptureSession() async throws {
        let observer = BackgroundLuminanceObserver()
        await observer.start()
        await observer.start()
        XCTAssertFalse(
            observer.isRunning,
            "start() must not mark a capture session running."
        )
        await observer.stop()
        XCTAssertFalse(observer.isRunning)
    }

    // MARK: - Screen change invalidation (Fix 3)

    /// Moving the floating panel to a different screen MUST invalidate
    /// the running capture pipeline. Otherwise the observer keeps
    /// sampling the previous display while the panel sits over a
    /// different wallpaper — the symptom Maxim reported as "colour
    /// doesn't change on multi-monitor swap".
    ///
    /// We test the pure invalidation logic: a `noteScreenChanged(...)`
    /// call must flip `needsCaptureRestart` to `true`, which is what
    /// `FloatingDotPanel` reads to decide whether to tear down + restart
    /// the capture source.
    func testScreenChangeInvalidatesRunningPipeline() {
        let observer = BackgroundLuminanceObserver()
        // Simulate a steady-state running pipeline on display "A".
        observer.markPipelineCaptured(onDisplayID: 1)
        XCTAssertFalse(
            observer.needsCaptureRestart,
            "Freshly captured pipeline on display 1 must not flag a restart."
        )

        // Move the panel onto a different display.
        observer.noteScreenChanged(toDisplayID: 2)

        XCTAssertTrue(
            observer.needsCaptureRestart,
            "Screen change to a new display must flag the running pipeline for restart."
        )
    }

    /// Re-noting the SAME screen must NOT flag a restart — that would
    /// thrash the pipeline on every NSWindow.didChangeScreenNotification
    /// fired without a real display change (some macOS builds emit
    /// spurious notifications during workspace transitions).
    func testReNotingSameScreenDoesNotInvalidate() {
        let observer = BackgroundLuminanceObserver()
        observer.markPipelineCaptured(onDisplayID: 7)
        observer.noteScreenChanged(toDisplayID: 7)
        XCTAssertFalse(
            observer.needsCaptureRestart,
            "Same-display screen-change notification must be a no-op so the pipeline doesn't thrash."
        )
    }

    /// After the panel publishes its new sample region (typically via
    /// `setSampleRegion(...)` from the screen-change handler), the
    /// observer must hold onto the latest region so the next capture
    /// covers the new wallpaper. Pinning this prevents a regression
    /// where the region update gets dropped on the floor while the
    /// pipeline is being torn down.
    func testSampleRegionUpdateIsRetainedAcrossInvalidation() {
        let observer = BackgroundLuminanceObserver()
        let regionA = CGRect(x: 0, y: 0, width: 100, height: 100)
        let regionB = CGRect(x: 2000, y: 500, width: 100, height: 100)

        observer.markPipelineCaptured(onDisplayID: 1)
        observer.setSampleRegion(screenFrame: regionA)
        observer.noteScreenChanged(toDisplayID: 2)
        observer.setSampleRegion(screenFrame: regionB)

        XCTAssertEqual(
            observer.currentSampleRegion,
            regionB,
            "The sample region published after a screen change must be the one used on restart."
        )
    }

    /// If a legacy client has already started a capture before
    /// `FloatingDotPanel` publishes its exact sample rect, the first real
    /// rect must invalidate the captured pipeline even when the display is
    /// the same. A stale source rect would require recapture if a future
    /// visual sampler exists.
    func testSampleRegionChangeInvalidatesCapturedPipeline() {
        let observer = BackgroundLuminanceObserver()
        let regionA = CGRect(x: 0, y: 0, width: 100, height: 100)
        let regionB = CGRect(x: 400, y: 200, width: 100, height: 100)

        observer.markPipelineCaptured(onDisplayID: 1)
        observer.setSampleRegion(screenFrame: regionA)

        XCTAssertTrue(
            observer.needsCaptureRestart,
            "Publishing the first exact sample rect after capture must force a stream restart."
        )

        observer.markPipelineCaptured(onDisplayID: 1)
        observer.setSampleRegion(screenFrame: regionA)
        XCTAssertFalse(
            observer.needsCaptureRestart,
            "Re-publishing the same sample rect should not thrash the capture pipeline."
        )

        observer.setSampleRegion(screenFrame: regionB)
        XCTAssertTrue(
            observer.needsCaptureRestart,
            "Moving the sample rect on the same display must flag restart for any active sampler."
        )
    }

    /// After a screen change + restart cycle, the observer must clear
    /// the `needsCaptureRestart` flag once the new pipeline is captured
    /// — otherwise the next benign notification (or even the same one
    /// re-fired) would trigger another tear-down loop.
    func testRestartFlagClearsAfterRecapture() {
        let observer = BackgroundLuminanceObserver()
        observer.markPipelineCaptured(onDisplayID: 1)
        observer.noteScreenChanged(toDisplayID: 2)
        XCTAssertTrue(observer.needsCaptureRestart)
        // FloatingDotPanel tears down then re-captures on the new display.
        observer.markPipelineCaptured(onDisplayID: 2)
        XCTAssertFalse(
            observer.needsCaptureRestart,
            "Once the pipeline is re-captured on the new display the restart flag must reset, otherwise spurious notifications cause a tear-down loop."
        )
    }

    // MARK: - Orb lifecycle diagnostics without capture

    /// `notePanelVisibilityChanged(isVisible:)` is the bridge from
    /// FloatingDotPanel into the observer. It records the panel's
    /// visibility for diagnostics only; the panel no longer starts screen
    /// observation for orb contrast.
    func testNotePanelVisibilityOnlyRecordsDiagnosticState() {
        let observer = BackgroundLuminanceObserver()

        observer.notePanelVisibilityChanged(isVisible: false)
        XCTAssertFalse(observer.lastReportedPanelVisible)

        observer.notePanelVisibilityChanged(isVisible: true)
        XCTAssertTrue(observer.lastReportedPanelVisible)
        XCTAssertFalse(observer.isRunning)
    }
}

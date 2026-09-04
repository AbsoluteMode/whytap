import XCTest
import SwiftUI
import AppKit
@testable import Sidekey

@MainActor
final class MacProgressBarTests: XCTestCase {
    // MARK: - Fill fraction clamp

    func testFillFractionClamped() {
        // Mid-range passes through unchanged.
        XCTAssertEqual(MacProgressBar.clampedFraction(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(MacProgressBar.clampedFraction(0.0), 0.0, accuracy: 0.0001)
        XCTAssertEqual(MacProgressBar.clampedFraction(1.0), 1.0, accuracy: 0.0001)

        // Over-limit clamps to 1.
        XCTAssertEqual(MacProgressBar.clampedFraction(1.5), 1.0, accuracy: 0.0001)
        XCTAssertEqual(MacProgressBar.clampedFraction(42.0), 1.0, accuracy: 0.0001)

        // Negative / NaN guard clamps to 0.
        XCTAssertEqual(MacProgressBar.clampedFraction(-0.3), 0.0, accuracy: 0.0001)
        XCTAssertEqual(MacProgressBar.clampedFraction(.nan), 0.0, accuracy: 0.0001)
    }

    // MARK: - Color thresholds

    func testColorByFraction() {
        XCTAssertEqual(MacProgressBar.tier(for: 0.0), .normal)
        XCTAssertEqual(MacProgressBar.tier(for: 0.5), .normal)
        XCTAssertEqual(MacProgressBar.tier(for: 0.79), .normal)

        // Warning threshold at 0.8.
        XCTAssertEqual(MacProgressBar.tier(for: 0.8), .warning)
        XCTAssertEqual(MacProgressBar.tier(for: 0.95), .warning)
        XCTAssertEqual(MacProgressBar.tier(for: 0.999), .warning)

        // At/over the limit goes red.
        XCTAssertEqual(MacProgressBar.tier(for: 1.0), .over)
        XCTAssertEqual(MacProgressBar.tier(for: 1.4), .over)

        // Color mapping: accent / orange / red.
        func srgb(_ c: Color) -> NSColor { NSColor(c).usingColorSpace(.sRGB)! }
        let accent = srgb(MacSettingsTheme.accent)
        let orange = srgb(MacSettingsTheme.orange)
        let red = srgb(MacSettingsTheme.red)

        XCTAssertEqual(Double(srgb(MacProgressBar.FillTier.normal.color).redComponent),
                       Double(accent.redComponent), accuracy: 0.01)
        XCTAssertEqual(Double(srgb(MacProgressBar.FillTier.warning.color).greenComponent),
                       Double(orange.greenComponent), accuracy: 0.01)
        XCTAssertEqual(Double(srgb(MacProgressBar.FillTier.over.color).redComponent),
                       Double(red.redComponent), accuracy: 0.01)
    }
}

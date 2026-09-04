import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class HistoryStripPanelTests: XCTestCase {
    /// ROO-208 iter 4: the strip now spans the full screen width minus
    /// `2 × sideMargin`. The previous orb-hover-frame avoidance was
    /// dropped because the strip and the orb no longer share a
    /// horizontal band visually — once the strip extends edge-to-edge
    /// the 5-up rubbery cards row can actually fan out as designed.
    func testFrameSpansFullScreenWidthMinusSideMargins() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = HistoryStripPanel.computeFrame(visibleFrame: visible)
        XCTAssertEqual(frame.origin.y, visible.minY + HistoryStripPanel.bottomMargin)
        XCTAssertEqual(frame.size.height, HistoryStripPanel.height)
        // Left edge sits at visible.minX + sideMargin.
        XCTAssertEqual(
            frame.origin.x,
            visible.minX + HistoryStripPanel.sideMargin,
            accuracy: 0.5
        )
        // Right edge sits at visible.maxX - sideMargin (full-width strip).
        XCTAssertEqual(
            frame.maxX,
            visible.maxX - HistoryStripPanel.sideMargin,
            accuracy: 0.5
        )
        // Width == visible.width - 2*sideMargin (matches the math above).
        XCTAssertEqual(
            frame.size.width,
            visible.size.width - 2 * HistoryStripPanel.sideMargin,
            accuracy: 0.5
        )
    }

    func testFrameOnMultiMonitorOffsetVisibleFrame() {
        // Negative-X visibleFrame (left external monitor) must still
        // produce a frame anchored to the SAME monitor — origin.x rides
        // along with visible.minX, width matches visible.width.
        let visible = NSRect(x: -1440, y: 200, width: 1440, height: 900)
        let frame = HistoryStripPanel.computeFrame(visibleFrame: visible)
        XCTAssertEqual(frame.origin.y, visible.minY + HistoryStripPanel.bottomMargin)
        XCTAssertEqual(
            frame.origin.x,
            visible.minX + HistoryStripPanel.sideMargin,
            accuracy: 0.5
        )
        XCTAssertEqual(
            frame.maxX,
            visible.maxX - HistoryStripPanel.sideMargin,
            accuracy: 0.5
        )
    }

    func testFrameClampsToMinimumWidth() {
        // Degenerate / corrupt visibleFrame edge case: if visible.width
        // is smaller than `minimumWidth + 2*sideMargin`, the strip still
        // renders at least `minimumWidth` wide so it remains usable.
        let narrowWidth = HistoryStripPanel.minimumWidth - 50
        let visible = NSRect(x: 0, y: 0, width: narrowWidth, height: 900)
        let frame = HistoryStripPanel.computeFrame(visibleFrame: visible)
        XCTAssertGreaterThanOrEqual(frame.size.width, HistoryStripPanel.minimumWidth)
    }

    func testFrameBottomClearsDockSafeMargin() {
        // Maxim spec (Dock fix): strip now sits ABOVE visibleFrame.minY by
        // the dock-safe buffer (40pt added to the strip's previous in-dock-zone
        // anchor of -24). This keeps the cards visible when the Dock is set
        // to a full-bar / magnified size that the OS does not always subtract
        // from `visibleFrame`. The helper chip got the same +40 lift so the
        // strip + chip still read as one visually-aligned cluster.
        let visible = NSRect(x: 40, y: 72, width: 1440, height: 900)
        let frame = HistoryStripPanel.computeFrame(visibleFrame: visible)
        XCTAssertEqual(frame.minY, visible.minY + HistoryStripPanel.bottomMargin)
        XCTAssertGreaterThan(
            HistoryStripPanel.bottomMargin,
            0,
            "After the +40 lift, bottomMargin should be positive (strip sits above visibleFrame.minY)."
        )
    }

    // MARK: - Window level above Dock

    /// The strip lives inside the Dock zone (bottomMargin = -24), so its
    /// NSWindow level MUST sit above the Dock — otherwise the Dock
    /// (especially when magnified) renders over the strip and hides the
    /// history cards. Dock window level is `kCGDockWindowLevelKey` ≈ 20;
    /// `.floating` (the old setting) is 3 → below Dock. `.statusBar` is
    /// 25 → above Dock and above all `.floating` siblings.
    func testStripPanelLevelIsAboveDock() {
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertGreaterThan(
            HistoryStripPanel.windowLevel.rawValue,
            dockLevel,
            "strip lives in dock zone; its level must beat the Dock so cards are visible"
        )
    }

    /// The expanded card panel must order above the strip while both are
    /// visible. AppKit's order-front ordering helps but the level value
    /// must also not be lower than the strip's — otherwise on screens
    /// where window-server tie-breaking re-evaluates levels, the
    /// expanded card slips behind.
    func testExpandedPanelLevelIsAtLeastStripLevel() {
        XCTAssertGreaterThanOrEqual(
            HistoryExpandedPanel.windowLevel.rawValue,
            HistoryStripPanel.windowLevel.rawValue,
            "expanded panel must not sit below the strip"
        )
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertGreaterThan(
            HistoryExpandedPanel.windowLevel.rawValue,
            dockLevel,
            "expanded panel can drift into dock zone too; must clear Dock"
        )
    }

    /// The "Copied" toast must always be visible — it overlays the
    /// strip and the expanded panel. Therefore its level must be at
    /// least the expanded panel's level (and above Dock).
    func testCopiedToastPanelLevelIsAboveExpandedAndDock() {
        XCTAssertGreaterThanOrEqual(
            CopiedToastPanel.windowLevel.rawValue,
            HistoryExpandedPanel.windowLevel.rawValue,
            "toast must order above (or equal to) the expanded panel"
        )
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertGreaterThan(
            CopiedToastPanel.windowLevel.rawValue,
            dockLevel,
            "toast must clear the Dock"
        )
    }

    // MARK: - 30% vertical shrink (Maxim: «правую рамку + карточки уменьшить»)

    /// The strip's outer frame shrinks by ≈30% so the bottom UI cluster
    /// reads as proportional to the slimmer right-side overlay panels.
    /// Pre-shrink height was 220pt; post-shrink target is 154pt.
    /// Tolerance is 2pt to permit rounding.
    func testStripHeightIsRoughly70PercentOfPreShrinkValue() {
        let preShrink: CGFloat = 220
        let target = preShrink * 0.7
        XCTAssertEqual(HistoryStripPanel.height, target, accuracy: 2.0)
    }

    /// History cards shrink alongside the strip frame so the strip's
    /// chrome around them stays constant. Pre-shrink card height was
    /// 180pt; post-shrink target is 126pt. Tolerance 2pt for rounding.
    func testCardHeightIsRoughly70PercentOfPreShrinkValue() {
        let preShrink: CGFloat = 180
        let target = preShrink * 0.7
        XCTAssertEqual(HistoryCardView.cardHeight, target, accuracy: 2.0)
    }

    /// Card width is NOT touched by the 30% vertical shrink — Maxim
    /// scoped this strictly to vertical. Pin the card width so a future
    /// "shrink some more" pass can't accidentally drag it along.
    func testCardWidthIsUnchangedByVerticalShrink() {
        XCTAssertEqual(HistoryCardView.cardWidth, 260)
    }

    /// The strip's outer height must remain greater than or equal to
    /// the card's height plus its vertical insets so the card never
    /// clips against the strip frame. After the shrink: 154pt strip ≥
    /// 126pt card + ≥ 12pt of chrome. Catches a regression where the
    /// strip is shrunk past the card it hosts.
    func testStripHeightFitsCardWithBreathingRoom() {
        let chromeBudget: CGFloat = 12  // approx top/bottom padding inside strip
        XCTAssertGreaterThanOrEqual(
            HistoryStripPanel.height,
            HistoryCardView.cardHeight + chromeBudget,
            "Strip must still contain the card with at least a small chrome budget."
        )
    }
}

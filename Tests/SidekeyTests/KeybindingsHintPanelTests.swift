import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class KeybindingsHintPanelTests: XCTestCase {
    /// The hint chip anchors to the orb's bottom edge — its Y position
    /// is `orb.minY - marginBelowOrb - panelHeight`. Once the orb's
    /// anchor takes the +40 dock-safe lift the hint must follow, so
    /// the chip's minY stays a constant offset below the orb but
    /// strictly above (or just at) `visibleFrame.minY`. Concretely:
    /// orb.minY = visible.minY + 51 (11 base + 40 dock-safe), hint
    /// height = `KeybindingsHintView.compactChipIntrinsicHeight`
    /// (`KeycapView.compactSize` + 2 × `HotkeyHintView.compactChipVerticalPadding`
    /// = 18pt), gap = 4 → hint.minY = visible.minY + 29. Clear of a
    /// Dock at 20pt or smaller and still flush with the orb so the
    /// visual stack reads as a unit.
    func testHintFrameSitsJustBelowOrb() {
        let visible = NSRect(x: 100, y: 50, width: 1440, height: 900)
        let hintFrame = KeybindingsHintPanel.frameBelowOrb(visibleFrame: visible)
        let orbFrame = FloatingDotPanel.bottomRightFrame(visibleFrame: visible, expanded: false)
        XCTAssertEqual(
            hintFrame.maxY,
            orbFrame.minY - 4,
            accuracy: 0.5,
            "Hint top edge must sit 4pt below orb bottom (no overlap, single visual stack)."
        )
        XCTAssertEqual(
            hintFrame.midX,
            orbFrame.midX,
            accuracy: 0.5,
            "Hint must center horizontally on the orb."
        )
    }

    /// Hint panel level must beat the Dock so a magnified Dock can't
    /// paint over it. The hint sits one tier BELOW the orb (Sidekey
    /// overlays order above the hint via AppKit window-server level
    /// ordering), so picking `.statusBar - 1` keeps the relative
    /// stacking while still clearing Dock (= 20).
    func testHintPanelLevelIsAboveDock() {
        let panel = KeybindingsHintPanel()
        defer { panel.close() }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertGreaterThan(
            panel.level.rawValue,
            dockLevel,
            "Hint panel must order above the Dock."
        )
    }

    /// Hint must remain BELOW the orb in z-order — Sidekey overlays
    /// (orb, agent panels, overlay) are at `.statusBar`; the hint sits
    /// just under so a fade transition between them stays visually
    /// stacked.
    func testHintPanelLevelIsBelowOrbAndOtherOverlays() {
        let hint = KeybindingsHintPanel()
        defer { hint.close() }
        let orb = FloatingDotPanel()
        defer { orb.close() }
        XCTAssertLessThan(
            hint.level.rawValue,
            orb.level.rawValue,
            "Hint must sit below the orb so Sidekey overlays always order above it."
        )
    }

    /// Hint must follow the user across Spaces and be eligible to
    /// appear on fullscreen apps, just like the orb. Without these
    /// flags the hint vanishes when the orb appears in a fullscreen
    /// browser / video player Space.
    func testHintPanelJoinsAllSpacesAndFullScreenAuxiliary() {
        let panel = KeybindingsHintPanel()
        defer { panel.close() }
        XCTAssertTrue(
            panel.collectionBehavior.contains(.canJoinAllSpaces),
            "Hint must follow the user into other Spaces, including fullscreen."
        )
        XCTAssertTrue(
            panel.collectionBehavior.contains(.fullScreenAuxiliary),
            "Hint must be eligible to appear on top of fullscreen apps."
        )
    }
}

import AppKit
import XCTest
@testable import Sidekey

/// Tests for the new round-3 overlay panel that owns the actions
/// cluster on hover. The panel is a separate `NSPanel` layered on top
/// of the orb + helper panels — neither of those resizes anymore, the
/// overlay simply orders itself in/out and renders the darkened
/// rounded-rect background + the 3-row cluster inside.
@MainActor
final class OrbActionsOverlayPanelTests: XCTestCase {
    // MARK: - Frame computation

    /// The overlay's frame is the union of the orb panel rect and the
    /// helper panel rect, expanded by the configured padding. Pure
    /// math — no panel instantiation needed.
    func testOverlayFrameIsUnionOfOrbAndHintWithPadding() {
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let hint = NSRect(x: 988, y: 66, width: 144, height: 30)

        let frame = OrbActionsOverlayPanel.overlayFrame(orb: orb, hint: hint)

        XCTAssertGreaterThanOrEqual(
            frame.width, max(orb.maxX, hint.maxX) - min(orb.minX, hint.minX),
            "Overlay must be at least as wide as the orb ∪ hint union."
        )
        XCTAssertGreaterThanOrEqual(
            frame.height, orb.maxY - hint.minY,
            "Overlay must be at least as tall as the orb ∪ hint union."
        )
        // The padding adds breathing room — at least 4pt per side, so
        // the frame is strictly larger than the raw union.
        let rawUnion = orb.union(hint)
        XCTAssertLessThanOrEqual(frame.minX, rawUnion.minX)
        XCTAssertGreaterThanOrEqual(frame.maxX, rawUnion.maxX)
        XCTAssertLessThanOrEqual(frame.minY, rawUnion.minY)
        XCTAssertGreaterThanOrEqual(frame.maxY, rawUnion.maxY)
    }

    func testOverlayFrameWithoutHintIsJustOrbPlusPadding() {
        // Helper hidden by user → only orb counts. Overlay still
        // expands the orb's bounds by the padding so the rounded-rect
        // background reads against the wallpaper.
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)

        let frame = OrbActionsOverlayPanel.overlayFrame(orb: orb, hint: nil)

        XCTAssertLessThan(frame.minX, orb.minX)
        XCTAssertGreaterThan(frame.maxX, orb.maxX)
        XCTAssertLessThan(frame.minY, orb.minY)
        XCTAssertGreaterThan(frame.maxY, orb.maxY)
    }

    // MARK: - Panel construction

    /// The overlay is a borderless, non-activating, floating panel
    /// — same NSPanel shape as the orb / hint panels so the level
    /// ordering and Space behaviour stay consistent. Click-through
    /// is OFF (the buttons need clicks) but it's a `.nonactivatingPanel`
    /// so clicking inside it never activates Sidekey (preserves the
    /// menu-bar-only activation policy).
    func testOverlayPanelIsBorderlessAndNonActivating() {
        let panel = OrbActionsOverlayPanel(orbFrame: { .zero }, hintFrame: { nil })
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.borderless))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.ignoresMouseEvents, "The overlay must accept clicks — the action buttons live inside it.")
        XCTAssertFalse(panel.canBecomeKey, "Overlay must never become key — Sidekey is menu-bar-only.")
    }

    /// Overlay must beat the Dock so a magnified Dock can't paint over
    /// the actions cluster — and must be visible on fullscreen Spaces
    /// because hover-actions can happen while the user is in a
    /// fullscreen browser / video player.
    func testOverlayPanelLevelIsAboveDock() {
        let panel = OrbActionsOverlayPanel(orbFrame: { .zero }, hintFrame: { nil })
        defer { panel.close() }
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        XCTAssertGreaterThan(
            panel.level.rawValue,
            dockLevel,
            "Overlay panel must order above the Dock."
        )
    }

    func testOverlayPanelJoinsAllSpacesAndFullScreenAuxiliary() {
        let panel = OrbActionsOverlayPanel(orbFrame: { .zero }, hintFrame: { nil })
        defer { panel.close() }
        XCTAssertTrue(
            panel.collectionBehavior.contains(.canJoinAllSpaces),
            "Overlay must follow the user into other Spaces, including fullscreen."
        )
        XCTAssertTrue(
            panel.collectionBehavior.contains(.fullScreenAuxiliary),
            "Overlay must be eligible to appear on top of fullscreen apps."
        )
    }
}

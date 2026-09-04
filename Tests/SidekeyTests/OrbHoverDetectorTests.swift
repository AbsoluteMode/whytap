import AppKit
import XCTest
@testable import Sidekey

/// Pure-logic tests for the cursor-in-rect math that powers the orb
/// hover swap. The detector compares a screen-space cursor location
/// against the union of the floating orb panel's frame and the
/// keybindings-hint panel's frame; entering that union flips `orbHovered`
/// to `true`, exiting flips it back. The math is split out so it can be
/// exercised without spinning up actual NSPanels or NSEvent monitors.
@MainActor
final class OrbHoverDetectorTests: XCTestCase {
    // MARK: - Union of orb + hint frames

    func testUnionCoversBothFrames() {
        // The orb is anchored bottom-right; the hint sits just below it.
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let hint = NSRect(x: 958, y: 66, width: 144, height: 30)

        let union = OrbHoverDetector.hoverRegion(orb: orb, hint: hint)

        XCTAssertTrue(
            union.contains(NSPoint(x: orb.midX, y: orb.midY)),
            "Union must cover the orb's centre."
        )
        XCTAssertTrue(
            union.contains(NSPoint(x: hint.midX, y: hint.midY)),
            "Union must cover the hint's centre."
        )
    }

    func testUnionWhenHintIsNilEqualsOrbFrame() {
        // When the hint is hidden by the user, only the orb counts.
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)

        let union = OrbHoverDetector.hoverRegion(orb: orb, hint: nil)

        XCTAssertEqual(union, orb)
    }

    // MARK: - Cursor-in-region

    func testCursorInsideOrbCentreIsHovering() {
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)

        XCTAssertTrue(
            OrbHoverDetector.isHovering(
                cursor: NSPoint(x: 1030, y: 130),
                orb: orb,
                hint: nil
            )
        )
    }

    func testCursorOutsideEverythingIsNotHovering() {
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)

        XCTAssertFalse(
            OrbHoverDetector.isHovering(
                cursor: NSPoint(x: 100, y: 700),
                orb: orb,
                hint: nil
            )
        )
    }

    func testCursorInsideHintAreaIsHovering() {
        // The hint sits below the orb; cursor over the hint must keep
        // the action-icon mode latched (both panels react together).
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let hint = NSRect(x: 958, y: 66, width: 144, height: 30)

        XCTAssertTrue(
            OrbHoverDetector.isHovering(
                cursor: NSPoint(x: hint.midX, y: hint.midY),
                orb: orb,
                hint: hint
            )
        )
    }

    func testCursorJustOutsideRegionIsNotHovering() {
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let hint = NSRect(x: 958, y: 66, width: 144, height: 30)

        // Point clearly above the union (well past orb.maxY).
        XCTAssertFalse(
            OrbHoverDetector.isHovering(
                cursor: NSPoint(x: orb.midX, y: orb.maxY + 50),
                orb: orb,
                hint: hint
            )
        )
    }

    // MARK: - Region expansion (forgiveness margin)

    func testHoverRegionExpandsByMargin() {
        // Without forgiveness, cursor flicker at the edge would yo-yo
        // between the orb mode and actions mode. A small expansion
        // (~4pt) keeps the actions latched while the cursor traverses
        // anti-aliased edges between orb and hint.
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let expanded = OrbHoverDetector.hoverRegion(
            orb: orb,
            hint: nil,
            forgiveness: 4
        )

        XCTAssertEqual(expanded.minX, orb.minX - 4, accuracy: 0.001)
        XCTAssertEqual(expanded.minY, orb.minY - 4, accuracy: 0.001)
        XCTAssertEqual(expanded.maxX, orb.maxX + 4, accuracy: 0.001)
        XCTAssertEqual(expanded.maxY, orb.maxY + 4, accuracy: 0.001)
    }

    // MARK: - Overlay envelope (round 3)

    /// The new overlay panel sits ON TOP of the orb + helper while
    /// hovered. Its frame is the union of the orb panel rect and the
    /// helper panel rect, expanded by an `overlayPadding` margin per
    /// side so the rounded-rect background has visible breathing room
    /// around the orb and the hint chip.
    func testOverlayEnvelopeIsOrbHintUnionPlusPadding() {
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let hint = NSRect(x: 988, y: 66, width: 144, height: 30)
        let padding: CGFloat = 8

        let envelope = OrbHoverDetector.overlayEnvelope(
            orb: orb,
            hint: hint,
            padding: padding
        )

        XCTAssertEqual(envelope.minX, hint.minX - padding, accuracy: 0.001)
        XCTAssertEqual(envelope.minY, hint.minY - padding, accuracy: 0.001)
        XCTAssertEqual(envelope.maxX, max(orb.maxX, hint.maxX) + padding, accuracy: 0.001)
        XCTAssertEqual(envelope.maxY, orb.maxY + padding, accuracy: 0.001)
    }

    /// Round 4 follow-up: the actions cluster (helper chip + icon
    /// rows + magnification headroom) can be wider than the raw
    /// orb+helper union. When that's the case, `overlayEnvelope` must
    /// expand to fit the cluster — otherwise the rounded-rect frame
    /// would clip the magnified row even though the panel envelope
    /// thinks everything is fine. The bottom-right anchor is
    /// preserved (the panel sits at the orb's bottom-right; only the
    /// left and top edges shift outward).
    func testOverlayEnvelopeExpandsToFitMinimumClusterSize() {
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let hint = NSRect(x: 988, y: 66, width: 144, height: 30)
        let rawUnion = orb.union(hint)

        let envelope = OrbHoverDetector.overlayEnvelope(
            orb: orb,
            hint: hint,
            padding: 8,
            minimumClusterWidth: 200,
            minimumClusterHeight: 110
        )

        XCTAssertGreaterThanOrEqual(envelope.width, 200)
        XCTAssertGreaterThanOrEqual(envelope.height, 110)
        XCTAssertEqual(
            envelope.maxX, rawUnion.maxX + 8, accuracy: 0.001,
            "Right edge stays anchored to orb+helper maxX + padding."
        )
        XCTAssertEqual(
            envelope.maxY, rawUnion.maxY + 8, accuracy: 0.001,
            "Top edge stays anchored to orb+helper maxY + padding (Cocoa coords)."
        )
    }

    /// When the raw union is already wider/taller than the minimum
    /// cluster, the helper must NOT inflate the envelope spuriously
    /// just because a minimum was provided.
    func testOverlayEnvelopeIgnoresMinimumWhenUnionAlreadyLarger() {
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let hint = NSRect(x: 800, y: 66, width: 260, height: 30)

        let withMin = OrbHoverDetector.overlayEnvelope(
            orb: orb,
            hint: hint,
            padding: 8,
            minimumClusterWidth: 50,
            minimumClusterHeight: 50
        )
        let withoutMin = OrbHoverDetector.overlayEnvelope(
            orb: orb,
            hint: hint,
            padding: 8
        )

        XCTAssertEqual(withMin, withoutMin)
    }

    func testOverlayEnvelopeWithoutHintIsJustOrbPlusPadding() {
        // Helper chip hidden by the user (`KeybindingsHintPreferences.isHidden`)
        // → only the orb counts. Envelope expands the orb's frame by
        // the padding on every side.
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let padding: CGFloat = 8

        let envelope = OrbHoverDetector.overlayEnvelope(
            orb: orb,
            hint: nil,
            padding: padding
        )

        XCTAssertEqual(envelope.minX, orb.minX - padding, accuracy: 0.001)
        XCTAssertEqual(envelope.minY, orb.minY - padding, accuracy: 0.001)
        XCTAssertEqual(envelope.maxX, orb.maxX + padding, accuracy: 0.001)
        XCTAssertEqual(envelope.maxY, orb.maxY + padding, accuracy: 0.001)
    }

    /// `OrbHoverController` must keep the cursor latched in actions mode
    /// while it travels over the overlay panel — otherwise moving from
    /// the orb area into the overlay (which extends past the original
    /// orb/hint footprint) would flip `orbHovered` back to false. The
    /// detector accepts an optional `overlay` rect that joins the union.
    func testHoveringIncludesOverlayRectWhenProvided() {
        // Cursor sits well past the orb's right edge but inside the
        // overlay's expanded frame.
        let orb = NSRect(x: 1000, y: 100, width: 60, height: 60)
        let hint = NSRect(x: 988, y: 66, width: 144, height: 30)
        let overlay = NSRect(x: 970, y: 58, width: 162, height: 110)

        let cursorOutsideOrbButInsideOverlay = NSPoint(x: 975, y: 130)

        XCTAssertFalse(
            OrbHoverDetector.isHovering(
                cursor: cursorOutsideOrbButInsideOverlay,
                orb: orb,
                hint: hint,
                overlay: nil
            ),
            "Cursor must NOT register as hovering when only orb+hint count and the cursor is outside both."
        )
        XCTAssertTrue(
            OrbHoverDetector.isHovering(
                cursor: cursorOutsideOrbButInsideOverlay,
                orb: orb,
                hint: hint,
                overlay: overlay
            ),
            "Once the overlay is on screen, its frame joins the hover union so the cursor stays latched while it travels over the actions cluster."
        )
    }

    // MARK: - Icon row geometry

    /// The action-icons row replaces the orb when hover triggers. The
    /// row is centred on the orb's vertical axis and uses a fixed
    /// inter-icon spacing so neighbour-magnification math is deterministic.
    func testIconRowHasThreeSlotsAtKnownSpacing() {
        let positions = OrbHoverDetector.iconRowPositions(
            centerX: 1030,
            centerY: 130,
            iconCount: 3,
            spacing: 30
        )

        XCTAssertEqual(positions.count, 3)
        // Spacing between consecutive icons matches the requested value.
        XCTAssertEqual(positions[1].x - positions[0].x, 30, accuracy: 0.001)
        XCTAssertEqual(positions[2].x - positions[1].x, 30, accuracy: 0.001)
        // Centre icon lands on the centre line.
        XCTAssertEqual(positions[1].x, 1030, accuracy: 0.001)
        // All icons share the same y.
        XCTAssertEqual(positions[0].y, 130, accuracy: 0.001)
        XCTAssertEqual(positions[2].y, 130, accuracy: 0.001)
    }

    // MARK: - Magnification math

    /// Dock-style magnification curve: at the hovered icon scale peaks,
    /// neighbours get a smaller bump, far icons stay at 1.0. The pure
    /// math is testable without rendering.
    func testMagnificationScaleHoveredIconReturnsPeak() {
        let scale = OrbHoverDetector.magnificationScale(
            iconIndex: 1,
            hoveredIndex: 1,
            peak: 1.3,
            neighborPeak: 1.1
        )
        XCTAssertEqual(scale, 1.3, accuracy: 0.001)
    }

    func testMagnificationScaleAdjacentIconReturnsNeighborBump() {
        let left = OrbHoverDetector.magnificationScale(
            iconIndex: 0,
            hoveredIndex: 1,
            peak: 1.3,
            neighborPeak: 1.1
        )
        let right = OrbHoverDetector.magnificationScale(
            iconIndex: 2,
            hoveredIndex: 1,
            peak: 1.3,
            neighborPeak: 1.1
        )

        XCTAssertEqual(left, 1.1, accuracy: 0.001)
        XCTAssertEqual(right, 1.1, accuracy: 0.001)
    }

    func testMagnificationScaleFarIconReturnsBaseline() {
        let scale = OrbHoverDetector.magnificationScale(
            iconIndex: 0,
            hoveredIndex: 2,
            peak: 1.3,
            neighborPeak: 1.1
        )
        // Distance 2 → no bump.
        XCTAssertEqual(scale, 1.0, accuracy: 0.001)
    }

    func testMagnificationScaleNilHoveredReturnsBaseline() {
        // Cursor outside the row → every icon at baseline.
        let scale = OrbHoverDetector.magnificationScale(
            iconIndex: 1,
            hoveredIndex: nil,
            peak: 1.3,
            neighborPeak: 1.1
        )
        XCTAssertEqual(scale, 1.0, accuracy: 0.001)
    }
}

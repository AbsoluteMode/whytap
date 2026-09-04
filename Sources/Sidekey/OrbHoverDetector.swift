import AppKit

/// Pure-logic helpers for the orb hover swap.
///
/// The floating orb panel is click-through (`ignoresMouseEvents = true`),
/// so SwiftUI's `.onHover` never fires inside it — the only way to know
/// the cursor is over the orb is to compare the cursor's screen-space
/// position against the panel frames. The math lives in this
/// stateless enum so it can be unit-tested without spinning up panels
/// or `NSEvent` monitors, and so the controller (which owns the actual
/// `NSEvent.addGlobalMonitorForEvents` lifecycle) is a thin wrapper.
///
/// The hovered region is the union of the orb panel's frame and (when
/// visible) the keybindings-hint panel's frame, optionally expanded
/// by a `forgiveness` margin so cursor flicker at the anti-aliased
/// edge doesn't yo-yo between the two modes.
enum OrbHoverDetector {
    /// Defaults pinned in one place so the controller and the
    /// magnification animation read from the same source of truth.
    enum Defaults {
        /// How many points to expand the hover region per side. ~4pt
        /// covers anti-aliased edges and the gap between the orb and
        /// the hint panel without making the cursor feel sticky.
        static let forgiveness: CGFloat = 4

        /// Padding around the orb+hint union when computing the
        /// overlay panel's frame (round 3). Adds breathing room so the
        /// rounded-rect background reads with visible negative space
        /// around the orb and the helper chip.
        static let overlayPadding: CGFloat = 8
    }

    // MARK: - Hover region

    /// Computes the screen-space rectangle the cursor must enter for
    /// the orb→actions swap to fire. When the hint panel is hidden
    /// (`KeybindingsHintPreferences.isHidden == true`) callers pass
    /// `nil` for `hint` so only the orb counts.
    ///
    /// `forgiveness` adds the same expansion to every side. The default
    /// matches the value the controller uses in production; tests can
    /// pass `0` to assert the raw union.
    static func hoverRegion(
        orb: NSRect,
        hint: NSRect?,
        forgiveness: CGFloat = 0
    ) -> NSRect {
        let union: NSRect
        if let hint = hint {
            union = orb.union(hint)
        } else {
            union = orb
        }
        guard forgiveness > 0 else { return union }
        return union.insetBy(dx: -forgiveness, dy: -forgiveness)
    }

    /// True when the cursor is inside the (forgiveness-expanded) hover
    /// region. Always uses the default forgiveness margin so the
    /// controller and tests agree without having to thread the value
    /// through every call site.
    ///
    /// `overlay` (round 3) optionally joins the union. The overlay
    /// panel — when present and on screen — extends past the orb +
    /// hint footprint so the cursor must stay latched while it travels
    /// over the actions cluster. Passing `nil` matches the pre-round-3
    /// behaviour (orb ∪ hint only).
    static func isHovering(
        cursor: NSPoint,
        orb: NSRect,
        hint: NSRect?,
        overlay: NSRect? = nil
    ) -> Bool {
        var region = hoverRegion(
            orb: orb,
            hint: hint,
            forgiveness: Defaults.forgiveness
        )
        if let overlay = overlay {
            region = region.union(overlay)
        }
        return region.contains(cursor)
    }

    // MARK: - Overlay envelope

    /// Computes the overlay panel's screen-space frame: the union of
    /// the orb panel rect and (when visible) the helper panel rect,
    /// expanded by `padding` on every side so the rounded-rect
    /// background has breathing room around its contents.
    ///
    /// Round 4: `minimumClusterWidth`/`minimumClusterHeight` let the
    /// caller demand a minimum envelope size — used by
    /// `OrbActionsOverlayPanel` to guarantee the magnified actions
    /// cluster fits inside the rounded rect even when the raw
    /// orb+helper union is narrower than the cluster's intrinsic
    /// width. The envelope grows LEFTWARD (preserving the right
    /// edge) and UPWARD (preserving the bottom edge in Cocoa coords)
    /// so the panel stays anchored to the orb's bottom-right corner
    /// — the user's visual focal point.
    ///
    /// Pure function so the overlay panel can be sized correctly
    /// without instantiating actual `NSPanel`s in tests.
    static func overlayEnvelope(
        orb: NSRect,
        hint: NSRect?,
        padding: CGFloat = Defaults.overlayPadding,
        minimumClusterWidth: CGFloat = 0,
        minimumClusterHeight: CGFloat = 0
    ) -> NSRect {
        let union: NSRect = hint.map { orb.union($0) } ?? orb
        let paddedUnion = union.insetBy(dx: -padding, dy: -padding)

        // Bottom-right anchor is `(paddedUnion.maxX, paddedUnion.maxY)`
        // in Cocoa coords (origin = bottom-left of screen). When the
        // cluster needs more space than the padded union provides,
        // grow leftward/upward by extending minX/minY outward — maxX
        // and maxY stay pinned so the panel doesn't drift away from
        // the orb's screen position.
        let neededWidth = max(paddedUnion.width, minimumClusterWidth)
        let neededHeight = max(paddedUnion.height, minimumClusterHeight)
        let originX = paddedUnion.maxX - neededWidth
        let originY = paddedUnion.maxY - neededHeight
        return NSRect(
            x: originX,
            y: originY,
            width: neededWidth,
            height: neededHeight
        )
    }

    // MARK: - Icon row geometry

    /// Evenly-spaced icon positions for the actions row. Used by the
    /// tests so the geometry stays stable when the row layout changes.
    /// SwiftUI's `HStack` does the real layout inside `OrbActionsView`;
    /// this helper exists so future Dock-classic neighbour math (which
    /// needs per-icon screen positions to drive the magnification curve)
    /// can reuse the same arithmetic.
    static func iconRowPositions(
        centerX: CGFloat,
        centerY: CGFloat,
        iconCount: Int,
        spacing: CGFloat
    ) -> [CGPoint] {
        guard iconCount > 0 else { return [] }
        let firstX = centerX - CGFloat(iconCount - 1) * spacing / 2
        return (0..<iconCount).map { index in
            CGPoint(
                x: firstX + CGFloat(index) * spacing,
                y: centerY
            )
        }
    }

    // MARK: - Magnification

    /// Dock-style magnification scale for a given icon. The hovered
    /// icon hits `peak`; its direct neighbours hit `neighborPeak`;
    /// any icon further than one slot away stays at `1.0` (baseline).
    /// `hoveredIndex == nil` means the cursor is outside the row — every
    /// icon returns to baseline.
    ///
    /// The curve is intentionally piecewise (peak / neighbor / baseline)
    /// rather than a continuous Gaussian — it's simpler, the visual read
    /// is the same at three-icon widths, and the math is trivially
    /// testable.
    static func magnificationScale(
        iconIndex: Int,
        hoveredIndex: Int?,
        peak: CGFloat,
        neighborPeak: CGFloat
    ) -> CGFloat {
        guard let hoveredIndex = hoveredIndex else { return 1.0 }
        let distance = abs(iconIndex - hoveredIndex)
        switch distance {
        case 0: return peak
        case 1: return neighborPeak
        default: return 1.0
        }
    }
}

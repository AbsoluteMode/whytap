import SwiftUI

/// Two-slot Raycast-style hint bar pinned to the BOTTOM of the history
/// strip (ROO-208 iter 22). Replaces the iter-15 single-pill capsule
/// that sat in the strip's top slack band.
///
/// Layout (when both slots active):
/// ```
///   Click to copy                          Paste to <App> ↵
///   └──────────────┘                       └─────────────┘
///   left slot                              right slot
/// ```
///
/// Visibility contract (parent-driven):
/// * `isAnyCardHovered == false` → bar collapsed entirely. With no
///   hover, both labels lose their semantic meaning (no card to copy /
///   paste).
/// * `isAnyCardHovered == true && pasteTargetAppName == nil` → only the
///   "Click to copy" left slot renders. Matches the Desktop / Finder
///   case where the captured target failed AX validation and pressing
///   Enter is a silent no-op (so we don't tease a paste affordance the
///   user can't act on).
/// * `isAnyCardHovered == true && pasteTargetAppName != nil` → both
///   slots render.
///
/// Visual decisions:
/// * No outer stroke / pill backdrop. No keycap envelope around the ↵
///   glyph either. Iter 22-23 routed the ↵ through `HotkeyHintView`
///   (the canonical keycap), but the rounded-rect keycap border still
///   read as a leftover frame inside the bar — Maxim flagged it
///   ("осталась рамка на enter"). Iter 24 swaps in a flat SF Symbol
///   (`return`), no enclosing shape. Symmetrical on the left slot: a
///   small `cursorarrow.click` symbol next to "Click to copy".
/// * "Click to copy" is HORIZONTALLY CENTERED in the bar, independent
///   of the right slot's width. Implemented via `ZStack` (center
///   alignment) with the right slot rendered through an `HStack +
///   Spacer` overlay — so a long "Paste to <LongAppName>" string can
///   grow without dragging the center label off-center.
/// * Same flat treatment on both slots: text + small SF Symbol icon,
///   no decorations.
/// * Fonts: 13pt medium on the label, 11pt medium on the SF Symbol so
///   the icon reads as a glyph rather than competing with the text.
struct HistoryStripPasteHint: View {
    /// Drives whether either slot renders. Sourced from
    /// `HistoryStripController.hoveredCard != nil`.
    let isAnyCardHovered: Bool

    /// Display name of the validated paste target, or `nil` when AX
    /// validation came back negative (or no app was captured). When
    /// `nil` the right slot collapses; the left "Click to copy" slot
    /// remains visible as long as a card is hovered.
    let pasteTargetAppName: String?

    /// Inner spacing between the icon glyph and the label text in each
    /// slot. 6pt reads as "icon + label" rather than two separate items.
    private static let iconToLabelSpacing: CGFloat = 6
    /// Horizontal padding of the bar's outermost layer. Matches the
    /// strip's own 12pt outer padding (see `HistoryStripView.body`)
    /// plus a small extra so the right slot doesn't crowd the strip
    /// edge.
    private static let horizontalPadding: CGFloat = 16
    /// Top/bottom padding around the labels. Kept at 6pt so the flat
    /// bar fills the strip's bottom slack band comfortably without
    /// crowding the cards above. Higher than iter 22-23's 1pt because
    /// there's no longer a tall keycap glyph forcing the height; the
    /// label drives layout now.
    private static let verticalPadding: CGFloat = 6

    var body: some View {
        ZStack {
            // CENTER slot — "Click to copy". Centered via ZStack's
            // default alignment, so the right slot's varying width
            // (long app names) never shifts it off-center.
            centerSlot
            // RIGHT slot — "Paste to <App> ↵". Right-aligned via an
            // HStack + Spacer overlay on top of the ZStack so it can
            // grow without pushing the centered label.
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                rightSlot
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .center)
        .allowsHitTesting(false)  // pure affordance, never blocks card hover
    }

    /// CENTER slot — "Click to copy" with a small `cursorarrow.click`
    /// SF Symbol. Flat: text + icon, no envelope. Visible whenever a
    /// card is hovered.
    @ViewBuilder
    private var centerSlot: some View {
        if isAnyCardHovered {
            HStack(spacing: Self.iconToLabelSpacing) {
                Image(systemName: "cursorarrow.click")
                    .font(.system(size: 11, weight: .medium))
                Text("Click to copy")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(.white.opacity(0.65))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Click any card to copy")
        }
    }

    /// RIGHT slot — "Paste to <App> ↵" with a flat `return` SF Symbol
    /// (no keycap envelope). Only visible when AX validation returned
    /// a real app name AND a card is hovered.
    @ViewBuilder
    private var rightSlot: some View {
        if isAnyCardHovered, let app = pasteTargetAppName {
            HStack(spacing: Self.iconToLabelSpacing) {
                Text("Paste to \(app)")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Flat ↵ glyph: SF Symbol `return`, no enclosing
                // rounded-rect / keycap. Iter 22-23 used
                // `HotkeyHintView` here which rendered a visible
                // keycap border; iter 24 drops it.
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.85))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Paste to \(app), return key")
        }
    }
}

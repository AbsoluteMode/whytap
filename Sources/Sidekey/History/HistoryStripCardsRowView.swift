import AppKit
import SwiftUI

/// Pure layout math for the 5-up rubbery horizontal row that replaced
/// the deck-with-peek carousel (ROO-208 iter 3).
///
/// Maxim's iter-3 directive: «делаем просто по низу 5 видимых из общих
/// 10 (с возможностью полистать влево-вправо) так, чтобы они доходили
/// до правого края панели». The row spans from the sidebar (with a
/// small gap) to the strip's right edge. Cards are sized so exactly 5
/// fit in the visible viewport; the remaining 5 (cap is 10 from iter 2)
/// are reachable by horizontal scroll.
///
/// All math lives here so tests can pin the behavior without rendering
/// SwiftUI views.
enum HistoryStripRowLayout {
    /// Visible card count target — Maxim's spec. 10 cards max (cap
    /// from iter 2), 5 visible at a time. Remaining 5 reached by
    /// scroll.
    static let visibleCardCount: Int = 5
    /// Spacing between cards. Kept at 12pt to match the original
    /// iter-1 band so the visual rhythm is unchanged.
    static let interCardSpacing: CGFloat = 12
    /// Floor on a single card's width — prevents the cards from
    /// collapsing into unreadable slivers on narrow strips. If the
    /// available width drops below `5 * minCardWidth + 4 * spacing`,
    /// the row simply overflows horizontally and the user scrolls
    /// laterally to see them all.
    static let minCardWidth: CGFloat = 180
    /// Cap on a single card's width — prevents cards from ballooning
    /// to absurd widths on 27"+ displays where the strip is very wide.
    /// Matches the legacy `HistoryCardView.cardWidth` so visual
    /// hierarchy with the expanded panel stays consistent.
    static let maxCardWidth: CGFloat = 260
    /// Inner horizontal padding inside the scroll view's content. Keeps
    /// the leading and trailing cards from kissing the strip's edges.
    static let contentHorizontalPadding: CGFloat = 12

    /// Compute the width a single card should take to fit exactly
    /// `visibleCount` cards (separated by `spacing`) inside
    /// `availableWidth`. The result is clamped into
    /// `[minCardWidth, maxCardWidth]`.
    ///
    /// - Parameter availableWidth: Width of the scroll-view's content
    ///   area (i.e. the strip's frame width minus sidebar, outer
    ///   padding, and the inner `contentHorizontalPadding` allowance).
    /// - Parameter visibleCount: How many cards should be visible at
    ///   once. Usually `visibleCardCount` (5).
    /// - Parameter spacing: Inter-card spacing.
    /// - Parameter minCardWidth: Minimum acceptable card width.
    /// - Parameter maxCardWidth: Maximum acceptable card width.
    static func cardWidth(
        availableWidth: CGFloat,
        visibleCount: Int,
        spacing: CGFloat,
        minCardWidth: CGFloat = minCardWidth,
        maxCardWidth: CGFloat = maxCardWidth
    ) -> CGFloat {
        guard visibleCount > 0 else { return minCardWidth }
        let totalSpacing = spacing * CGFloat(visibleCount - 1)
        let raw = (availableWidth - totalSpacing) / CGFloat(visibleCount)
        return min(max(raw, minCardWidth), maxCardWidth)
    }

    /// Chat-style visual reordering (ROO-208 iter 5). The feed yields
    /// cards newest-first (storage order = SQLite `ORDER BY created_at
    /// DESC`), but Maxim wants iMessage-style direction: oldest on the
    /// LEFT, newest on the RIGHT. The scroll view trailing-anchors on
    /// open so the newest 5 are immediately visible. Quote: «самая
    /// свежая запись должна быть справа и с левой стороны самая
    /// старая».
    ///
    /// Pure function — the feed itself stays newest-first (other
    /// consumers and tests depend on that contract); the reversal lives
    /// at the view boundary.
    static func visualOrder(_ cards: [HistoryStripCard]) -> [HistoryStripCard] {
        Array(cards.reversed())
    }
}

/// Horizontal scroll view rendering up to 10 cards in a single row.
/// Replaces the iter-2 deck-with-peek carousel — Maxim wanted a simple
/// 5-up row of cards spanning from the sidebar to the strip's right
/// edge.
///
/// Layout:
///  * Outer `GeometryReader` measures the available cards-area width.
///  * `HistoryStripRowLayout.cardWidth(...)` computes the per-card
///    width so exactly 5 cards fit (clamped to a min/max range).
///  * `HorizontalCardsScrollView` (NSViewRepresentable wrapping
///    `NSScrollView`) hosts an `HStack` of cards sized to that width.
///    Native trackpad / wheel / overlay-scroller drive horizontal
///    scrolling.
///  * Cards are stored newest-first (feed convention from
///    `HistoryStripFeed`) but rendered chat-style:
///    `HistoryStripRowLayout.visualOrder(...)` reverses to oldest-left /
///    newest-right. The wrapper manually scrolls to trailing on first
///    render and whenever the card count changes.
///
/// Iter 9: replaced the SwiftUI `ScrollView` entirely. Iters 5/7/8
/// attempted to clear the underlying `NSScrollView` backdrop via
/// `.scrollContentBackground(.hidden)` or runtime introspection
/// (`enclosingScrollView`) — all failed to remove the grey ribbon. By
/// owning the `NSScrollView` directly we set `drawsBackground = false`
/// + `backgroundColor = .clear` + `contentView.drawsBackground = false`
/// at construction time, no introspection, no lifecycle race.
@MainActor
struct HistoryStripCardsRowView: View {
    let cards: [HistoryStripCard]
    let assetsDirectory: URL
    let onCopy: (HistoryStripCard) -> Void
    let onExpand: (HistoryStripCard) -> Void
    /// ROO-208 iter 15: per-card hover transition (`hovered = true` on
    /// enter, `false` on exit). Forwarded to `HistoryStripController`
    /// by the strip view so the hint + Enter-paste flow know which
    /// card the cursor is on. Default no-op so test instantiations
    /// that don't care about hover stay one-line.
    var onHoverChange: (HistoryStripCard, Bool) -> Void = { _, _ in }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(
                0,
                proxy.size.width - 2 * HistoryStripRowLayout.contentHorizontalPadding
            )
            let computedCardWidth = HistoryStripRowLayout.cardWidth(
                availableWidth: availableWidth,
                visibleCount: HistoryStripRowLayout.visibleCardCount,
                spacing: HistoryStripRowLayout.interCardSpacing
            )
            // Chat-style ordering: storage is newest-first, visuals are
            // oldest-left / newest-right.
            let visual = HistoryStripRowLayout.visualOrder(cards)
            scrollView(visual: visual, computedCardWidth: computedCardWidth, proxy: proxy)
        }
        // Height pinned to the card height + small slop for vertical
        // padding above so the row sits flush with the strip's bottom
        // edge (parent applies `.padding(.bottom, 4)`).
        .frame(height: HistoryCardView.cardHeight + 8)
    }

    @ViewBuilder
    private func scrollView(
        visual: [HistoryStripCard],
        computedCardWidth: CGFloat,
        proxy: GeometryProxy
    ) -> some View {
        HorizontalCardsScrollView(
            cardCount: visual.count,
            availableWidth: proxy.size.width
        ) {
            HStack(spacing: HistoryStripRowLayout.interCardSpacing) {
                ForEach(visual) { card in
                    HistoryCardView(
                        card: card,
                        width: computedCardWidth,
                        assetsDirectory: assetsDirectory,
                        onCopy: { onCopy(card) },
                        onExpand: { onExpand(card) },
                        onHoverChange: { hovered in onHoverChange(card, hovered) }
                    )
                }
            }
            .padding(.horizontal, HistoryStripRowLayout.contentHorizontalPadding)
            .padding(.vertical, 4)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
    }
}

/// `NSViewRepresentable` wrapping `NSScrollView` so we can deterministically
/// suppress the grey `controlBackgroundColor` ribbon SwiftUI's
/// `ScrollView` would otherwise paint behind the cards.
///
/// Iter 9 nuclear option: iters 5/7/8 attempted to clear that backdrop
/// via SwiftUI modifiers (`.scrollContentBackground(.hidden)`) or
/// runtime introspection of the SwiftUI ScrollView's underlying
/// NSScrollView — all failed. Owning the NSScrollView ourselves lets us
/// flip `drawsBackground = false` + `backgroundColor = .clear` +
/// `contentView.drawsBackground = false` at `makeNSView` time, before
/// the first paint. No introspection, no lifecycle hops, no SwiftUI
/// modifier ordering races.
///
/// Trailing scroll anchor (replaces SwiftUI's gone
/// `.defaultScrollAnchor(.trailing)`) is implemented manually: when
/// `cardCount` changes (e.g. new clipboard event lands), we scroll the
/// clip view to its max X in `DispatchQueue.main.async` so layout
/// completes first.
///
/// The hosting view is wrapped in a min-width frame aligned trailing,
/// so when content is narrower than the viewport the cards hug the
/// right edge (matching iter-5/3 trailing alignment); when content is
/// wider, the user scrolls.
@MainActor
struct HorizontalCardsScrollView<Content: View>: NSViewRepresentable {
    let cardCount: Int
    let availableWidth: CGFloat
    @ViewBuilder let content: () -> Content

    final class Coordinator {
        var lastCardCount: Int = -1
        var hosting: NSHostingView<AnyView>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        // Critical: suppress the AppKit chrome that paints the grey
        // ribbon. `drawsBackground` toggles the NSScrollView itself;
        // `contentView.drawsBackground` toggles the inner NSClipView.
        // Both must be false for the underlying surface (the strip's
        // clear panel + desktop wallpaper) to show through.
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        scroll.contentView.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()

        let initialRoot = AnyView(
            content()
                .frame(minWidth: availableWidth, alignment: .trailing)
        )
        let hosting = NSHostingView(rootView: initialRoot)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = []
        // Iter 10: clear the NSHostingView's own backing layer.
        // NSHostingView is layer-backed by default, and the layer
        // inherits `controlBackgroundColor` (light grey) via the
        // appearance system. When the trailing-aligned HStack of cards
        // doesn't fill the entire hosting frame, that grey shows
        // through above/below/left of the cards — exactly the ribbon
        // iter 9 still leaked. Iter 9 cleared NSScrollView + NSClipView
        // but the documentView's own layer kept painting it.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.layerContentsRedrawPolicy = .never
        // Inherit the panel's clear appearance instead of the system
        // default (which paints controlBackgroundColor through the
        // layer-backed hosting).
        hosting.appearance = nil
        // Initial size; updateNSView will resize as content layout
        // settles and availableWidth changes.
        hosting.frame = NSRect(
            x: 0, y: 0,
            width: max(hosting.intrinsicContentSize.width, availableWidth),
            height: max(hosting.intrinsicContentSize.height, 1)
        )
        scroll.documentView = hosting
        context.coordinator.hosting = hosting
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hosting else { return }
        // Re-wrap content with the latest availableWidth so the HStack's
        // trailing alignment frame matches the new viewport.
        hosting.rootView = AnyView(
            content()
                .frame(minWidth: availableWidth, alignment: .trailing)
        )
        // Defensive: re-clear the backing layer in case AppKit recreated
        // it during a re-layout pass (rootView reassign can trigger that).
        if hosting.layer?.backgroundColor != NSColor.clear.cgColor {
            hosting.layer?.backgroundColor = NSColor.clear.cgColor
        }
        let intrinsic = hosting.intrinsicContentSize
        let clipHeight = scroll.contentView.bounds.height
        let height = max(intrinsic.height, clipHeight, 1)
        let width = max(intrinsic.width, availableWidth)
        if hosting.frame.size.width != width || hosting.frame.size.height != height {
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }

        // Trailing scroll anchor: only on initial render and when the
        // card count changes (e.g. new clipboard / drop / agent event
        // lands). After that the user owns scroll position.
        let coordinator = context.coordinator
        if coordinator.lastCardCount != cardCount {
            coordinator.lastCardCount = cardCount
            DispatchQueue.main.async { [weak scroll, weak hosting] in
                guard let scroll, let hosting else { return }
                let maxX = max(0, hosting.frame.width - scroll.contentView.bounds.width)
                scroll.contentView.scroll(to: NSPoint(x: maxX, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
}

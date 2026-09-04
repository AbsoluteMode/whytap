import AppKit
import SwiftUI

/// SwiftUI root inside `HistoryStripPanel`. Hosts:
///  * Horizontal `NSScrollView` of cards (one per history entry).
///  * Empty state placeholder when the feed has no entries for the mode.
///
/// Round 2 UX 6 + UX 7: the mode-name capsule and X close button were
/// removed. The strip closes via Esc / outside-click / re-click on the
/// orb-frame icon; the cards self-identify visually.
///
/// The strip fades in when `controller.openMode` becomes non-nil and
/// content cross-fades when the mode changes.
struct HistoryStripView: View {
    @ObservedObject var controller: HistoryStripController
    // Live hotkey config so the Drop empty-state hint follows the binding
    // (post-cutover: "Hold Space") instead of a hardcoded ⌥ /.
    @ObservedObject private var hotkeys: HotkeyPreferences = .shared
    let feed: HistoryStripFeed
    let assetsDirectory: URL
    /// Optional toast controller — when supplied, card-body clicks
    /// raise the "Copied" toast for ~1.5s. Nil in tests that don't
    /// care about the toast surface.
    var toast: CopiedToastController? = nil

    /// Reload trigger — bumped externally when the underlying store
    /// changes (e.g. clipboard watcher inserts a new row). The view
    /// recomputes `cards` whenever this changes.
    var reloadToken: Int = 0

    private var mode: HistoryStripMode? { controller.openMode }

    var body: some View {
        // ROO-208 iter 22: the strip is now laid out as a vertical
        // stack — cards row on top, hint bar pinned to the bottom. The
        // strip's outer height (154pt) is unchanged; the iter-15 top
        // slack band that hosted the "Paste to <App> ↵" pill is moved
        // to the bottom so Maxim's screenshot («подсказку перенести
        // ниже + увеличить») lands.
        //
        // The cards row stays bottom-aligned WITHIN its own slot so the
        // existing card-frame math (`HistoryCardView.cardHeight + 8`)
        // doesn't drift; we just give it less vertical space.
        ZStack(alignment: .bottom) {
            backdrop
            VStack(spacing: 0) {
                if let mode = mode {
                    // ROO-208: unified strip lays out as `[sidebar] [cards]`.
                    // Sidebar is the only filter surface (the three `⌥1/2/3`
                    // hotkeys were removed). Cards cross-fade via `.id(mode)`
                    // when the user picks a different filter.
                    HStack(alignment: .bottom, spacing: 10) {
                        HistoryStripSidebarView(
                            activeFilter: mode,
                            onSelect: { controller.setFilter($0) }
                        )
                        .padding(.vertical, 4)
                        content(for: mode)
                            .transition(.opacity)
                            .id(mode)
                    }
                    .padding(.horizontal, 12)
                }
                hintBarSlot
            }
        }
        .animation(.easeInOut(duration: 0.2), value: mode)
    }

    /// Bottom hint bar slot — fixed-height (`Self.hintBarHeight`) so
    /// the cards row's vertical budget is predictable regardless of
    /// hover state. The bar's inner two-slot HStack collapses when
    /// neither slot has content (no card hovered), but the slot itself
    /// reserves its space so cards don't visually jump up/down on
    /// hover (Maxim's "no layout reflow on hover" contract from
    /// iter 15 still applies).
    @ViewBuilder
    private var hintBarSlot: some View {
        HistoryStripPasteHint(
            isAnyCardHovered: controller.hoveredCard != nil,
            pasteTargetAppName: controller.targetAppName
        )
        .frame(height: Self.hintBarHeight)
        .opacity(controller.hoveredCard != nil ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: controller.hoveredCard?.id)
    }

    /// Height reserved for the bottom hint bar. Strip is 154pt;
    /// cards row is `HistoryCardView.cardHeight (126) + 8 = 134pt`;
    /// 154 - 134 = 20pt for the hint bar. That's snug but enough for
    /// a 13pt label + the iter-15 ↵ keycap (the `HotkeyHintView`
    /// compact variant is ~18pt tall — it visually overflows the
    /// 20pt slot by ~2pt at the edges, which is fine because the
    /// strip's bottom edge is at `bottomMargin = +16pt` above
    /// `visibleFrame.minY` and the panel content can extend up to
    /// the frame edge without clipping).
    private static let hintBarHeight: CGFloat = 20

    private var backdrop: some View {
        // ROO-208 iter 5: the strip's frame is fully transparent — only
        // the sidebar pill and the individual `DarkGlassCard` bodies
        // carry the visual weight. The previous `Color.black.opacity(0.001)`
        // was nominally transparent but surfaced on Retina + Liquid
        // Glass as a faint light-grey ribbon wrapping the whole strip.
        // Maxim's quote: «давай вот этот непонятный фон вокруг карточек
        // уберем».
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(for mode: HistoryStripMode) -> some View {
        let cards = feed.cards(for: mode)

        // Round 2 UX 6 + UX 7: the mode-name capsule ("Agent" / "Drop"
        // / "Clipboard") and the X close button were removed. Cards
        // carry their own type-distinguishing visuals; closing is
        // already covered by Esc / outside-click / re-click on the
        // orb-frame icon, so the dedicated X button was redundant.
        Group {
            if cards.isEmpty {
                emptyState(for: mode)
            } else {
                cardsScrollView(cards)
            }
        }
        // Cards row is bottom-aligned WITHIN its slot in the VStack.
        // ROO-208 iter 22: the iter-15 `.padding(.bottom, 4)` was removed
        // here — the bottom slack that used to sit between the cards
        // and the strip's bottom edge now belongs to the hint bar
        // (see `hintBarSlot`). Without this removal, cards (134pt) +
        // hint bar (24pt) + 4pt pad = 162pt would overflow the 154pt
        // strip frame and SwiftUI would clip the keycap. Parent HStack
        // in `body` still applies the 12pt horizontal pad.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func cardsScrollView(_ cards: [HistoryStripCard]) -> some View {
        // ROO-208 iter 3: simple rubbery 5-up horizontal row replaces
        // the iter-2 deck-with-peek carousel. Maxim rejected the
        // wheel/deck metaphor — «делаем просто по низу 5 видимых из
        // общих 10 (с возможностью полистать влево-вправо)». The row
        // spans from the sidebar (with a small gap) to the strip's
        // right edge; cards are sized so exactly 5 fit at a time and
        // the rest (cap is 10 from iter 2) are reached by horizontal
        // scroll. Storage order = display order: leftmost = newest.
        HistoryStripCardsRowView(
            cards: cards,
            assetsDirectory: assetsDirectory,
            onCopy: { card in copyCardToPasteboard(card) },
            // Round 2 UX 8: expand button is a per-card toggle —
            // clicking the same card's expand button while the
            // expanded view is showing closes it; clicking a
            // different card swaps.
            onExpand: { card in controller.toggleExpand(makeExpanded(card)) },
            // ROO-208 iter 15: per-card hover propagates to the
            // controller so the "Paste to <App> ↵" hint can appear
            // and the Enter-paste flow knows which card to write.
            onHoverChange: { card, hovered in
                controller.setHoveredCard(hovered ? card : nil, from: card)
            }
        )
    }

    private func emptyState(for mode: HistoryStripMode) -> some View {
        VStack(spacing: 6) {
            Image(systemName: emptyStateIcon(for: mode))
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.4))
            Text(emptyStateMessage(for: mode))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Helpers

    private func emptyStateMessage(for mode: HistoryStripMode) -> String {
        switch mode {
        case .agent: return "No agent turns yet. Tap Right ⌘ to start one."
        case .drop: return "No drop dictations yet. \(dropTriggerHint) to start one."
        case .clipboard: return "No clipboard history yet. Copy something to begin."
        }
    }

    /// Config-driven Drop trigger phrase for the empty state — e.g.
    /// "Hold Space" (post-cutover) or "Toggle ⌥ /" for a tap-combo binding.
    /// Sourced from `normalizedDropGesture` + `dropVoiceShortcut` so it never
    /// drifts from the live binding and applies the voiceTitle mapping (.tap →
    /// "Toggle" for voice rows).
    private var dropTriggerHint: String {
        let gesture = hotkeys.configuration.normalizedDropGesture.voiceTitle
        let keys = hotkeys.dropVoiceShortcut.shortcutChipTitles.joined(separator: " ")
        return "\(gesture) \(keys)"
    }

    private func emptyStateIcon(for mode: HistoryStripMode) -> String {
        switch mode {
        case .agent: return "sparkles"
        case .drop: return "mic"
        case .clipboard: return "doc.on.clipboard"
        }
    }

    private func makeExpanded(_ card: HistoryStripCard) -> HistoryStripExpandedEntry {
        switch card {
        case .agent(let c):
            return .agent(.full(title: c.title, response: c.responseMarkdown, links: c.links))
        case .drop(let c):
            return .drop(.full(raw: c.formattedText, formatted: c.formattedText, targetApp: c.targetApp))
        case .clipboard(let c):
            switch c.payload {
            case .text(let s):
                return .clipboard(.text(s))
            case .image(let img):
                return .clipboard(.image(img))
            case .fileURLs(let urls):
                return .clipboard(.fileURLs(urls))
            }
        }
    }

    private func copyCardToPasteboard(_ card: HistoryStripCard) {
        // Suspend the watcher for one polling-cycle so a user-initiated
        // copy through the strip does not bounce-record itself as a
        // brand-new clipboard entry. The suppression is cleared in a
        // background task so subsequent user copies are still tracked.
        ClipboardSuppression.shared.setSuppressed(true)
        defer {
            // Two poll intervals (~1s) is enough for the watcher to
            // skip the bounce. Stretched in a Task so we don't block
            // the click handler.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                ClipboardSuppression.shared.setSuppressed(false)
            }
        }

        controller.writeCardToPasteboard(card, assetsDirectory: assetsDirectory)

        // Surface "Copied" so the user gets confirmation that the
        // click actually wrote something to the system pasteboard.
        toast?.show()
    }
}

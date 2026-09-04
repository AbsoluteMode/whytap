import AppKit
import SwiftUI

enum HistoryHoverContent {
    static func displayText(for card: HistoryStripCard) -> String {
        switch card {
        case .agent(let c):
            return c.responseMarkdown
        case .drop(let c):
            return c.formattedText
        case .clipboard(let c):
            switch c.payload {
            case .text(let s):
                return s
            case .image:
                return "Image"
            case .fileURLs(let urls):
                guard let first = urls.first else { return "Files" }
                if urls.count == 1 {
                    return first.lastPathComponent
                }
                return "\(first.lastPathComponent) and \(urls.count - 1) more"
            }
        }
    }
}

enum HistoryHoverVisualStyle {
    // The History panel deliberately has no shared slab behind its rows. Keep
    // each row opaque enough that wallpaper text cannot show through it.
    static let rowIdleOpacity = 0.82
    static let rowHoverOpacity = 0.90
    static let hintOpacity = 0.82
}

/// Enter→paste for the hover History panel, mirroring the bottom strip's
/// proven path: a local NSEvent keyDown monitor (Return 36 / Numpad Enter
/// 76) that fires while a row is hovered and swallows the event so AppKit
/// does not beep. SwiftUI key-press handlers + programmatic focus never
/// received Return reliably on the non-activating island panel.
@MainActor
final class HistoryHoverKeyMonitor: ObservableObject {
    var hoveredCard: HistoryStripCard?
    var onPaste: (HistoryStripCard) -> Void = { _ in }
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 36 || event.keyCode == 76 {
                if let card = self.hoveredCard {
                    let paste = self.onPaste
                    DispatchQueue.main.async { paste(card) }
                    return nil
                }
                return event  // no hover → not our event
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hoveredCard = nil
    }
}

struct HistoryHoverView: View {
    static let visibleRowCount = 5
    static let modeOrder: [HistoryStripMode] = [.agent, .drop, .clipboard]
    static let rowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 6
    static let resultViewportHeight: CGFloat =
        rowHeight * CGFloat(visibleRowCount)
        + rowSpacing * CGFloat(visibleRowCount - 1)
    static let topPadding: CGFloat = 4
    static let hintHeight: CGFloat = 23

    /// Results viewport height for the rows the feed actually has (capped
    /// at `visibleRowCount`). A near-empty feed must not stretch to the
    /// full fixed window; zero cards keep one slot for the empty-state row.
    static func viewportHeight(forCardCount count: Int) -> CGFloat {
        let rows = max(1, min(count, visibleRowCount))
        return rowHeight * CGFloat(rows) + rowSpacing * CGFloat(rows - 1)
    }
    /// Fixed height of the full content stack (top padding + mode row +
    /// results viewport + hint row + the two inter-section gaps). The island
    /// hover band must be at least this tall while History is on screen.
    static let requiredContentHeight: CGFloat =
        topPadding + rowHeight + rowSpacing
        + resultViewportHeight + rowSpacing + hintHeight

    /// Name of the coordinate space the hovered row frames are reported
    /// in. Owned by `IslandView`'s hover zone, where the preview bubble
    /// overlay is anchored.
    static let hoverZoneSpaceName = "islandHoverZone"

    @Binding var mode: HistoryStripMode
    let cards: [HistoryStripCard]
    let targetAppName: String?
    let onSelectMode: (HistoryStripMode) -> Void
    let onCopy: (HistoryStripCard) -> Void
    /// Reports the hovered row (and its frame in the island hover-zone
    /// space) when that row's content deserves a preview bubble; reports a
    /// `nil` frame on hover exit so the owner can clear matching state.
    let onPreviewAnchorChange: (HistoryStripCard, CGRect?) -> Void
    let onPaste: (HistoryStripCard) -> Void

    @State private var hoveredCard: HistoryStripCard?
    @StateObject private var keyMonitor = HistoryHoverKeyMonitor()

    static func hintText(targetAppName: String?) -> String {
        guard let targetAppName, !targetAppName.isEmpty else {
            return "Click for copy"
        }
        return "Click for copy   Enter to paste to \(targetAppName)"
    }

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            modeRow
            if cards.isEmpty {
                emptyStateRow
            } else {
                results
                hintRow
            }
        }
        .animation(.easeOut(duration: 0.14), value: cards.count)
        .padding(.horizontal, 8)
        .padding(.top, Self.topPadding)
        .onAppear {
            keyMonitor.onPaste = onPaste
            keyMonitor.start()
        }
        .onDisappear { keyMonitor.stop() }
        .onChange(of: hoveredCard) { _, newValue in
            keyMonitor.hoveredCard = newValue
        }
    }

    private var modeRow: some View {
        HStack(spacing: 0) {
            ForEach(Self.modeOrder, id: \.self) { candidate in
                Button {
                    mode = candidate
                    hoveredCard = nil
                    onSelectMode(candidate)
                } label: {
                    Text(title(for: candidate))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(candidate == mode ? Color.white : .white.opacity(0.58))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(candidate == mode ? Color.white.opacity(0.18) : Color.clear)
                        )
                        // Whole tab tappable, not just the text glyphs. With
                        // .buttonStyle(.plain) the hit area is the label's
                        // content shape, which for a Text is the glyphs only —
                        // so clicks on the padded/background area missed and
                        // only the text switched tabs. Matches the sidebar's
                        // filterButton (HistoryStripSidebarView).
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(for: candidate))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: Self.rowHeight)
        .background(rowBackground(isHovered: false))
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // Deliberately NOT lazy: the feed is capped to a few dozen
                // rows, and an eager stack gives the scroll view its full
                // content size on the first layout pass — a lazy stack
                // mid-grow underestimates it and the offset drifts.
                VStack(spacing: Self.rowSpacing) {
                    ForEach(cards) { card in
                        HistoryHoverRow(
                            card: card,
                            isHovered: hoveredCard == card,
                            onCopy: { onCopy(card) },
                            onAnchorChange: { frame in
                                if let frame,
                                   HistoryHoverPreviewPolicy.needsPreview(
                                       for: card,
                                       availableTextWidth: frame.width - 24
                                   ) {
                                    onPreviewAnchorChange(card, frame)
                                } else {
                                    onPreviewAnchorChange(card, nil)
                                }
                            },
                            onHover: { hovering in
                                if hovering {
                                    hoveredCard = card
                                } else if hoveredCard == card {
                                    hoveredCard = nil
                                }
                            }
                        )
                        .id(card.id)
                    }
                }
            }
            .frame(height: Self.viewportHeight(forCardCount: cards.count))
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.top)
            // The drawer grows 137→275 with a spring while this view is
            // born inside it (plus a scale transition) — the scroll view
            // inherits a clamped offset from the transient smaller viewport
            // and the top (most relevant) row ends up clipped. Re-pin to
            // the top after the spring settles (response 0.24s).
            .onAppear {
                guard let firstID = cards.first?.id else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(firstID, anchor: .top)
                    }
                }
            }
        }
    }

    private var emptyStateRow: some View {
        Text(emptyStateText)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity)
            .frame(height: Self.rowHeight)
            .background(rowBackground(isHovered: false))
    }

    private var emptyStateText: String {
        switch mode {
        case .agent: return "No agent answers yet"
        case .drop: return "No drops yet"
        case .clipboard: return "Clipboard history is empty"
        }
    }

    private var hintRow: some View {
        Text(Self.hintText(targetAppName: targetAppName))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .frame(height: Self.hintHeight)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(HistoryHoverVisualStyle.hintOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    )
            )
    }

    private func title(for mode: HistoryStripMode) -> String {
        switch mode {
        case .agent: return "Agent"
        case .drop: return "Drop"
        case .clipboard: return "Clipboard"
        }
    }
}

private struct HistoryHoverRow: View {
    let card: HistoryStripCard
    let isHovered: Bool
    let onCopy: () -> Void
    /// Reports this row's frame (hover-zone space) on hover enter, `nil`
    /// on exit — drives the preview bubble anchored to the row.
    let onAnchorChange: (CGRect?) -> Void
    let onHover: (Bool) -> Void

    @State private var rowFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 8) {
            Text(HistoryHoverContent.displayText(for: card))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.84))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: HistoryHoverView.rowHeight)
        .background(rowBackground(isHovered: isHovered))
        .contentShape(Rectangle())
        .onTapGesture(perform: onCopy)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(HistoryHoverView.hoverZoneSpaceName))
        } action: { rowFrame = $0 }
        .onHover { hovering in
            onHover(hovering)
            onAnchorChange(hovering ? rowFrame : nil)
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private func rowBackground(isHovered: Bool) -> some View {
    // Dark standalone cards: the panel itself has no glass backdrop, so each
    // row carries its own dark surface — translucent white washes out over
    // light wallpapers.
    RoundedRectangle(cornerRadius: 11, style: .continuous)
        .fill(Color.black.opacity(
            isHovered
                ? HistoryHoverVisualStyle.rowHoverOpacity
                : HistoryHoverVisualStyle.rowIdleOpacity
        ))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.white.opacity(isHovered ? 0.22 : 0.12), lineWidth: 0.5)
        )
}

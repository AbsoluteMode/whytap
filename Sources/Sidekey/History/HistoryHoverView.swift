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

extension HistoryHoverContent {
    /// The one-line text a History row shows: lines trimmed, blank lines
    /// dropped, the rest joined by spaces. A copy that starts with a line
    /// break or indentation (common from web pages and code) used to leave
    /// the row blank or shifted. Copy and paste still use the full entry.
    // WHY: .project-docs/decisions/2026-11-21-history-backdrop-always.md
    static func rowText(for card: HistoryStripCard) -> String {
        displayText(for: card)
            .split(whereSeparator: \.isNewline)
            .map { line in
                let head = line.drop(while: \.isWhitespace)
                return String(head.reversed().drop(while: \.isWhitespace).reversed())
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

enum HistoryHoverVisualStyle {
    // Legacy rows have no shared optical backdrop. Preserve their readable
    // dark fill on older macOS; native panels use foreground lenses instead.
    static let rowIdleOpacity = 0.82
    static let rowHoverOpacity = 0.90
    static let hintOpacity = 0.82
    /// Marked rows use the island's switch blue.
    static let selectionColor = Color(red: 0.04, green: 0.52, blue: 1.0)
}

/// Enter→paste for the hover History panel, mirroring the bottom strip's
/// proven path: a local NSEvent keyDown monitor (Return 36 / Numpad Enter
/// 76) that fires while a row is hovered and swallows the event so AppKit
/// does not beep. SwiftUI key-press handlers + programmatic focus never
/// received Return reliably on the non-activating island panel.
/// Rows marked with ⌘-click win over the hovered row, and Escape clears
/// the marks (`HistoryKeyDecision`).
@MainActor
final class HistoryHoverKeyMonitor: ObservableObject {
    var hoveredCard: HistoryStripCard?
    var selectedCards: () -> [HistoryStripCard] = { [] }
    /// False without a paste target: Enter then never takes marked rows.
    var canPaste = true
    var onClearSelection: () -> Void = {}
    var onPaste: ([HistoryStripCard]) -> Void = { _ in }
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // A modal alert owns the keyboard: Return there must never paste
            // the row still under the pointer.
            guard NSApp.modalWindow == nil else { return event }
            switch HistoryKeyDecision.action(
                keyCode: event.keyCode,
                hovered: self.hoveredCard,
                selection: self.selectedCards(),
                canPaste: self.canPaste
            ) {
            case .paste(let cards):
                let paste = self.onPaste
                DispatchQueue.main.async { paste(cards) }
                return nil
            case .clearSelection:
                self.onClearSelection()
                return nil
            case .pass:
                return event
            }
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
    /// Copies the clicked row, or every ⌘-click-marked row in mark order.
    let onCopy: ([HistoryStripCard]) -> Void
    /// Reports the hovered row (and its frame in the island hover-zone
    /// space) when that row's content deserves a preview bubble; reports a
    /// `nil` frame on hover exit so the owner can clear matching state.
    let onPreviewAnchorChange: (HistoryStripCard, CGRect?) -> Void
    /// Pastes the hovered row, or every ⌘-click-marked row in mark order.
    let onPaste: ([HistoryStripCard]) -> Void
    var allowsKeyboardPaste = true
    /// Rows already marked when the panel appears (offscreen review renders).
    var initialSelection: [HistoryStripCard] = []
    /// Test seam: receives the panel's key monitor when the panel appears.
    var onKeyMonitorReady: ((HistoryHoverKeyMonitor) -> Void)? = nil

    @State private var hoveredCard: HistoryStripCard?
    @StateObject private var keyMonitor = HistoryHoverKeyMonitor()
    @StateObject private var selection = HistoryPasteSelection()

    /// Footer. Without marks it teaches the gestures; with marks it says what
    /// a click and Enter will do with them. `escapeClears` is false where no
    /// key monitor runs (Toolbox): there ⌘-click unmarks. Each hint is one
    /// plain-text block; the view separates them with hairlines.
    // WHY: .project-docs/decisions/2026-11-22-history-hint-keycaps.md
    static func hints(targetAppName: String?, selectedCount: Int = 0, escapeClears: Bool = true) -> [HistoryHint] {
        let target = (targetAppName?.isEmpty == false) ? targetAppName : nil
        guard selectedCount > 0 else {
            var hints = [HistoryHint(text: "Click to copy"), HistoryHint(text: "⌘-click for several")]
            if let target { hints.append(HistoryHint(text: "Enter to paste to", target: target)) }
            return hints
        }
        var hints = [HistoryHint(text: "Click to copy \(selectedCount)")]
        if let target {
            hints.append(HistoryHint(text: "Enter to paste \(selectedCount) to", target: target))
        }
        hints.append(HistoryHint(text: escapeClears ? "Esc to clear" : "⌘-click to unmark"))
        return hints
    }

    /// Enter pastes only where a target was captured; marks and copy work everywhere.
    static func canPaste(allowsKeyboardPaste: Bool, targetAppName: String?) -> Bool {
        allowsKeyboardPaste && !(targetAppName ?? "").isEmpty
    }

    /// What a plain click copies: every marked row in mark order when there
    /// are marks (the clicked row need not be one of them), else the row.
    // WHY: .project-docs/decisions/2026-11-22-history-multi-copy.md
    static func cardsToCopy(clicked: HistoryStripCard, marked: [HistoryStripCard]) -> [HistoryStripCard] {
        marked.isEmpty ? [clicked] : marked
    }

    var body: some View {
        VStack(spacing: Self.rowSpacing) {
            modeRow
            if cards.isEmpty && selection.isEmpty {
                emptyStateRow
            } else if cards.isEmpty {
                // Another tab may hold marked rows: keep Enter's promise visible.
                emptyStateRow
                hintRow
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
            keyMonitor.selectedCards = { [selection] in selection.cards }
            keyMonitor.onClearSelection = { [selection] in selection.clear() }
            initialSelection.forEach(selection.toggle)
            if allowsKeyboardPaste { keyMonitor.start() }
            onKeyMonitorReady?(keyMonitor)
        }
        .onDisappear {
            keyMonitor.stop()
            selection.clear()
        }
        .onChange(of: hoveredCard) { _, newValue in
            keyMonitor.hoveredCard = newValue
        }
        // The island captures the paste target in the same panelMode change
        // that shows this panel, so the name can arrive after onAppear. A
        // copy taken only at appear left Enter with marks passing the key on
        // (AppKit beeped) while the footer already offered the paste.
        // WHY: .project-docs/decisions/2026-11-22-history-multi-paste.md
        .onChange(of: targetAppName, initial: true) { _, name in
            keyMonitor.canPaste = Self.canPaste(allowsKeyboardPaste: allowsKeyboardPaste,
                                                targetAppName: name)
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
                        .foregroundStyle(candidate == mode ? IslandInk.color : IslandInk.color.opacity(0.58))
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(candidate == mode ? IslandInk.color.opacity(0.18) : Color.clear)
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
                            selectionPosition: selection.position(of: card),
                            onCopy: {
                                if NSEvent.modifierFlags.contains(.command) {
                                    selection.toggle(card)
                                } else {
                                    // A plain click with marks copies them all,
                                    // then the marks are done.
                                    onCopy(Self.cardsToCopy(clicked: card, marked: selection.cards))
                                    selection.clear()
                                }
                            },
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
            .foregroundStyle(IslandInk.color.opacity(0.45))
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
        HistoryHintBar(hints: Self.hints(
            targetAppName: targetAppName,
            selectedCount: selection.count,
            escapeClears: allowsKeyboardPaste
        ))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: Self.hintHeight)
            .background {
                if IslandHoverGlass.usesNativeLiquidGlass {
                    historyForegroundLens(cornerRadius: 10, isHovered: false)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(IslandInk.plate(HistoryHoverVisualStyle.hintOpacity))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(IslandInk.color.opacity(0.08), lineWidth: 0.5)
                        )
                }
            }
    }

    private func title(for mode: HistoryStripMode) -> String {
        switch mode {
        case .agent: return "Agent"
        case .drop: return "Drop"
        case .clipboard: return "Clipboard"
        }
    }
}

/// One footer hint in plain text.
struct HistoryHint: Equatable {
    /// The hint up to the app name ("Click to copy", "Enter to paste 3 to").
    let text: String
    /// App the paste goes to. Drawn after the text and the only part that
    /// shortens when the footer is narrow, so the hints stay whole.
    var target: String? = nil

    var fullText: String { [text, target].compactMap { $0 }.joined(separator: " ") }
}

/// The footer's hints as separate plain-text blocks with a hairline between
/// them. The whole row steps down from 9.5 pt to 8 pt (as the old one-line
/// footer scaled to fit); only when 8 pt is still too wide does the app
/// name, and nothing else, shorten.
private struct HistoryHintBar: View {
    let hints: [HistoryHint]

    static let fontSizes: [CGFloat] = [9.5, 9, 8.5, 8]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.fontSizes, id: \.self) { size in
                row(size: size, truncatesTarget: false)
            }
            row(size: Self.fontSizes.last ?? 8, truncatesTarget: true)
        }
    }

    private func row(size: CGFloat, truncatesTarget: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(hints.enumerated()), id: \.offset) { index, hint in
                if index > 0 {
                    Capsule()
                        .fill(IslandInk.color.opacity(0.22))
                        .frame(width: 1, height: 10)
                }
                block(hint, truncatesTarget: truncatesTarget)
            }
        }
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(IslandInk.color.opacity(0.55))
        .lineLimit(1)
    }

    @ViewBuilder
    private func block(_ hint: HistoryHint, truncatesTarget: Bool) -> some View {
        HStack(spacing: 3) {
            Text(hint.text)
                .fixedSize()
            if let target = hint.target {
                if truncatesTarget {
                    Text(target)
                        .truncationMode(.tail)
                        .layoutPriority(-1)
                } else {
                    Text(target).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hint.fullText)
    }
}

private struct HistoryHoverRow: View {
    let card: HistoryStripCard
    let isHovered: Bool
    /// 1-based paste order when the row is marked with ⌘-click.
    let selectionPosition: Int?
    let onCopy: () -> Void
    /// Reports this row's frame (hover-zone space) on hover enter, `nil`
    /// on exit — drives the preview bubble anchored to the row.
    let onAnchorChange: (CGRect?) -> Void
    let onHover: (Bool) -> Void

    @State private var rowFrame: CGRect = .zero

    var body: some View {
        HStack(spacing: 8) {
            Text(HistoryHoverContent.rowText(for: card))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(IslandInk.color.opacity(0.84))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let selectionPosition {
                HistorySelectionBadge(position: selectionPosition)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, selectionPosition == nil ? 12 : 8)
        .frame(height: HistoryHoverView.rowHeight)
        .background(rowBackground(isHovered: isHovered, isSelected: selectionPosition != nil))
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
        .animation(.easeOut(duration: 0.12), value: selectionPosition)
        .accessibilityAddTraits(selectionPosition == nil ? [] : .isSelected)
    }
}

/// Paste order of a marked row: a small blue disk with its number.
private struct HistorySelectionBadge: View {
    let position: Int

    var body: some View {
        Text("\(position)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            // The system's text colour on a selected (accent) fill.
            .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, position > 9 ? 3 : 0)
            .background(Capsule().fill(HistoryHoverVisualStyle.selectionColor))
            .accessibilityLabel("Paste \(position)")
    }
}

@ViewBuilder
private func rowBackground(isHovered: Bool, isSelected: Bool = false) -> some View {
    if isSelected {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        shape
            .fill(HistoryHoverVisualStyle.selectionColor.opacity(isHovered ? 0.34 : 0.26))
            .overlay(shape.strokeBorder(HistoryHoverVisualStyle.selectionColor.opacity(0.75), lineWidth: 1))
            .allowsHitTesting(false)
    } else if IslandHoverGlass.usesNativeLiquidGlass {
        historyForegroundLens(cornerRadius: 11, isHovered: isHovered)
    } else {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(IslandInk.plate(
                isHovered
                    ? HistoryHoverVisualStyle.rowHoverOpacity
                    : HistoryHoverVisualStyle.rowIdleOpacity
            ))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(IslandInk.color.opacity(isHovered ? 0.22 : 0.12), lineWidth: 0.5)
            )
    }
}

/// The drawer owns one native optical backdrop. Rows remain translucent
/// foreground lenses so they neither cover it nor stack another glass effect.
private func historyForegroundLens(cornerRadius: CGFloat, isHovered: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    return shape
        .fill(IslandInk.color.opacity(isHovered ? 0.16 : 0.06))
        .overlay {
            IslandHoverGlassRim(shape: shape, highlighted: isHovered)
        }
        .allowsHitTesting(false)
}

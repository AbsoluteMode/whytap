import SwiftUI

/// Renders a `UsefulLinksBlock` as a vertical stack of full-width
/// `UsefulLinkChipView`s. The block schema caps at three links, but the
/// decoder accepts a larger defensive cap; when more than three links
/// arrive, the chip column renders a three-row slice with a separate
/// "+N more" page-down chip below it.
///
/// When a `UsefulLinksSelectionState` is supplied (production wiring
/// from the response panel), the view also surfaces the rolling
/// selection-marker chip to the left of the currently selected row.
/// Without state (e.g. block-renderer registry calls that don't know
/// about selection) the view falls back to the legacy chip-only stack
/// — the keyboard hotkey controller stays inactive and the chip
/// vanishes.
struct UsefulLinksBlockView: View {
    let block: UsefulLinksBlock
    @ObservedObject var selectionState: UsefulLinksSelectionState

    /// Inter-column spacing between the selection chip and the link
    /// chips. 6pt matches `HotkeyHintView.elementSpacing` so a chip
    /// neighbouring its own caps reads with consistent visual rhythm.
    private static let selectionColumnSpacing: CGFloat = 6

    /// Default viewport: exactly three compact link rows plus the two
    /// inter-row spacings between them.
    private static let visibleRowCount = 3
    private static let rowSpacing: CGFloat = 8

    /// SwiftUI namespace for the matched-geometry chip move. Reused
    /// across all rows so SwiftUI sees the chip "transform" between
    /// row positions rather than insert/remove on every selection
    /// change.
    @Namespace private var chipNamespace

    /// Index of the first full link row in the rendered three-row slice.
    @State private var topIndex: Int = 0

    init(
        block: UsefulLinksBlock,
        selectionState: UsefulLinksSelectionState? = nil
    ) {
        self.block = block
        self._selectionState = ObservedObject(
            wrappedValue: selectionState ?? UsefulLinksSelectionState()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            rows
            if shouldShowMoreChip {
                moreRow
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: rowIDs) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                topIndex = 0
            }
        }
        .onChange(of: selectionState.currentIndex) { _, _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                keepSelectionVisible()
            }
        }
        // Wrap the full stack so matchedGeometryEffect sees row changes.
        .animation(.easeInOut(duration: 0.2), value: selectionState.currentIndex)
        .animation(.easeInOut(duration: 0.2), value: topIndex)
    }

    private var sourceLinks: [UsefulLink] {
        // Prefer the selectionState's link list when it agrees with the
        // block — that way the chip lines up with whatever is on screen.
        // Falls back to the block's own list if state is stale (e.g.
        // the block landed before the panel applied state).
        if selectionState.links.isEmpty {
            return block.links
        }
        return selectionState.links
    }

    private var linkRows: [LinkRow] {
        var occurrencesByFingerprint: [LinkRowFingerprint: Int] = [:]
        return sourceLinks.enumerated().map { index, link in
            let fingerprint = LinkRowFingerprint(link: link)
            let occurrence = occurrencesByFingerprint[fingerprint, default: 0]
            occurrencesByFingerprint[fingerprint] = occurrence + 1
            return LinkRow(
                id: LinkRowID(fingerprint: fingerprint, occurrence: occurrence),
                index: index,
                link: link
            )
        }
    }

    private var rowIDs: [LinkRow.ID] {
        linkRows.map(\.id)
    }

    private var shouldScrollRows: Bool {
        linkRows.count > Self.visibleRowCount
    }

    private var visibleRows: [LinkRow] {
        guard !linkRows.isEmpty else { return [] }
        let start = clampedTopIndex
        let end = min(start + Self.visibleRowCount, linkRows.count)
        return Array(linkRows[start..<end])
    }

    private var hiddenRemainderCount: Int {
        max(0, linkRows.count - clampedTopIndex - Self.visibleRowCount)
    }

    private var maxTopIndex: Int {
        max(0, linkRows.count - Self.visibleRowCount)
    }

    private var clampedTopIndex: Int {
        min(max(topIndex, 0), maxTopIndex)
    }

    private var shouldShowMoreChip: Bool {
        shouldScrollRows && clampedTopIndex < maxTopIndex
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(visibleRows) { row in
            linkRow(row)
                .transition(.opacity)
        }
    }

    private var moreRow: some View {
        UsefulLinksMoreChipView(hiddenCount: hiddenRemainderCount) {
            showNextPage()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row: the link chip sits flush against the leading edge; the
    /// rolling hint chip is inserted to the LEFT of the selected row only,
    /// pushing that one chip rightward — the "pressed in" cursor look. The
    /// hint chip itself is the cursor.
    @ViewBuilder
    private func linkRow(_ row: LinkRow) -> some View {
        HStack(alignment: .center, spacing: Self.selectionColumnSpacing) {
            if row.index == selectionState.currentIndex
                && selectionState.selectedLink != nil {
                UsefulLinksRollingHintView(itemCount: linkRows.count)
                    .matchedGeometryEffect(
                        id: "useful-links-selection-chip",
                        in: chipNamespace
                    )
            }
            UsefulLinkChipView(link: row.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func showNextPage() {
        withAnimation(.easeInOut(duration: 0.2)) {
            topIndex = min(clampedTopIndex + Self.visibleRowCount, maxTopIndex)
        }
    }

    private func keepSelectionVisible() {
        guard shouldScrollRows else {
            topIndex = 0
            return
        }
        let currentIndex = selectionState.currentIndex
        if currentIndex < clampedTopIndex {
            topIndex = currentIndex
        } else if currentIndex >= clampedTopIndex + Self.visibleRowCount {
            topIndex = min(
                currentIndex - Self.visibleRowCount + 1,
                maxTopIndex
            )
        }
    }

    private struct LinkRow: Identifiable, Equatable {
        let id: LinkRowID
        let index: Int
        let link: UsefulLink
    }

    private struct LinkRowID: Hashable {
        let fingerprint: LinkRowFingerprint
        let occurrence: Int
    }

    private struct LinkRowFingerprint: Hashable {
        let url: URL
        let description: String
        let provider: String?

        init(link: UsefulLink) {
            self.url = link.url
            self.description = link.description
            self.provider = link.provider
        }
    }
}

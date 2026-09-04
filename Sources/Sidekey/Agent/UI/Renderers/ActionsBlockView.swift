import AppKit
import SwiftUI

/// Renders a `UsefulActionsBlock` as a vertical stack of full-width
/// `ActionChipView`s — the generalisation of `UsefulLinksBlockView` from
/// link-only to typed link / path / copy items. Up to three rows render at
/// once; extra items collapse behind a "+N more" page-down chip.
///
/// When a `UsefulLinksSelectionState` is supplied (production wiring from the
/// response panel) the view surfaces the rolling selection-marker chip to the
/// left of the currently selected row, and the rolling hint drops "Open" for a
/// selected copy item (which is insert-only). Without state the view falls back
/// to a plain chip stack and the keyboard hotkey controller stays inactive.
struct ActionsBlockView: View {
    let block: UsefulActionsBlock
    @ObservedObject var selectionState: UsefulLinksSelectionState

    /// Inter-column spacing between the selection chip and the action chips.
    private static let selectionColumnSpacing: CGFloat = 6
    private static let visibleRowCount = 3
    private static let rowSpacing: CGFloat = 8

    @Namespace private var chipNamespace
    @State private var topIndex: Int = 0

    init(
        block: UsefulActionsBlock,
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
        .animation(.easeInOut(duration: 0.2), value: selectionState.currentIndex)
        .animation(.easeInOut(duration: 0.2), value: topIndex)
    }

    /// Prefer the selection state's item list when it is populated (so the chip
    /// lines up with what's on screen); fall back to the block's own list when
    /// state is stale (block landed before the panel applied state).
    private var sourceItems: [ActionItem] {
        if selectionState.items.isEmpty {
            return block.items
        }
        return selectionState.items
    }

    private var actionRows: [ActionRow] {
        var occurrences: [Int: Int] = [:]
        return sourceItems.enumerated().map { index, item in
            // Dedup identical items by a stable hash so SwiftUI keeps row
            // identity across re-renders. The index disambiguates duplicates.
            let fingerprint = item.fingerprint
            let occurrence = occurrences[fingerprint, default: 0]
            occurrences[fingerprint] = occurrence + 1
            return ActionRow(
                id: ActionRowID(fingerprint: fingerprint, occurrence: occurrence),
                index: index,
                item: item
            )
        }
    }

    private var rowIDs: [ActionRow.ID] {
        actionRows.map(\.id)
    }

    private var shouldScrollRows: Bool {
        actionRows.count > Self.visibleRowCount
    }

    private var visibleRows: [ActionRow] {
        guard !actionRows.isEmpty else { return [] }
        let start = clampedTopIndex
        let end = min(start + Self.visibleRowCount, actionRows.count)
        return Array(actionRows[start..<end])
    }

    private var hiddenRemainderCount: Int {
        max(0, actionRows.count - clampedTopIndex - Self.visibleRowCount)
    }

    private var maxTopIndex: Int {
        max(0, actionRows.count - Self.visibleRowCount)
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
            actionRow(row)
                .transition(.opacity)
        }
    }

    private var moreRow: some View {
        UsefulLinksMoreChipView(hiddenCount: hiddenRemainderCount) {
            showNextPage()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row: the action chip sits flush against the leading edge; the rolling
    /// hint chip is inserted to the LEFT of the selected row only — the
    /// "pressed in" cursor look. The hint drops "Open" when the selected item is
    /// insert-only (a copy item).
    @ViewBuilder
    private func actionRow(_ row: ActionRow) -> some View {
        HStack(alignment: .center, spacing: Self.selectionColumnSpacing) {
            if row.index == selectionState.currentIndex
                && selectionState.selectedItem != nil {
                UsefulLinksRollingHintView(
                    itemCount: actionRows.count,
                    openAvailable: selectionState.selectedItemSupportsOpen
                )
                .matchedGeometryEffect(
                    id: "useful-actions-selection-chip",
                    in: chipNamespace
                )
            }
            ActionChipView(
                item: row.item,
                onOpen: { item in
                    // Prefer the host hook (runs the controller's open path);
                    // fall back to a direct NSWorkspace open on the target.
                    if let hook = selectionState.onOpenItem {
                        hook(item)
                    } else if let target = item.openTarget {
                        NSWorkspace.shared.open(target)
                    }
                },
                onInsert: { item in
                    selectionState.onInsertItem?(item)
                }
            )
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

    private struct ActionRow: Identifiable, Equatable {
        let id: ActionRowID
        let index: Int
        let item: ActionItem
    }

    private struct ActionRowID: Hashable {
        let fingerprint: Int
        let occurrence: Int
    }
}

private extension ActionItem {
    /// Stable hash for SwiftUI row identity. Combines the type discriminator
    /// with the item's load-bearing fields so two distinct items don't collide.
    var fingerprint: Int {
        var hasher = Hasher()
        switch self {
        case .link(let url, let description, let provider):
            hasher.combine(0)
            hasher.combine(url)
            hasher.combine(description)
            hasher.combine(provider)
        case .path(let path, let description):
            hasher.combine(1)
            hasher.combine(path)
            hasher.combine(description)
        case .copy(let text, let description):
            hasher.combine(2)
            hasher.combine(text)
            hasher.combine(description)
        }
        return hasher.finalize()
    }
}

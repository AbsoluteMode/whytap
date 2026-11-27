import SwiftUI

/// The hover drawer's tool grid: fixed columns, fixed row height, cells in
/// reading order. A plain `Layout` instead of `LazyVGrid` in a `ScrollView`:
/// the lazy grid placed shifted cells at their new position at once while
/// only some tiles slid, so an add or remove jumped.
// WHY: .project-docs/decisions/2026-11-27-hover-drag-out-and-smooth-edits.md
struct IslandHoverTileGridLayout: Layout {
    var columns = HoverLayoutStore.columns
    var columnSpacing = IslandHoverControlsLayout.columnSpacing
    var rowSpacing = IslandHoverControlsLayout.rowSpacing
    var rowHeight = IslandHoverControlsLayout.rowHeight

    static func rows(count: Int, columns: Int) -> Int {
        count <= 0 ? 0 : (count - 1) / max(1, columns) + 1
    }

    /// The centre of cell `index` in a grid `width` wide, from its top-left.
    static func cellCenter(index: Int, width: CGFloat, columns: Int = HoverLayoutStore.columns,
                           columnSpacing: CGFloat = IslandHoverControlsLayout.columnSpacing,
                           rowSpacing: CGFloat = IslandHoverControlsLayout.rowSpacing,
                           rowHeight: CGFloat = IslandHoverControlsLayout.rowHeight) -> CGPoint {
        let cellWidth = (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        let column = index % columns, row = index / columns
        return CGPoint(x: CGFloat(column) * (cellWidth + columnSpacing) + cellWidth / 2,
                       y: CGFloat(row) * (rowHeight + rowSpacing) + rowHeight / 2)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.rows(count: subviews.count, columns: columns)
        let height = rows == 0 ? 0 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowSpacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cellWidth = (bounds.width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        for (index, subview) in subviews.enumerated() {
            let center = Self.cellCenter(index: index, width: bounds.width, columns: columns,
                                         columnSpacing: columnSpacing, rowSpacing: rowSpacing, rowHeight: rowHeight)
            subview.place(at: CGPoint(x: bounds.minX + center.x, y: bounds.minY + center.y), anchor: .center,
                          proposal: ProposedViewSize(width: cellWidth, height: rowHeight))
        }
    }
}

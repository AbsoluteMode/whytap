import SwiftUI

/// A bottom-anchored stack that shows only the newest rows that fit whole:
/// an old pair leaves at the top as one piece, never as a translation cut off
/// from its original. Rows that no longer fit are placed just above the
/// visible area, so a clipped container lets them slide out upward.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
struct NewestRowsLayout: Layout {
    var spacing: CGFloat
    var maxHeight: CGFloat

    private func heights(_ subviews: Subviews, width: CGFloat?) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
    }

    /// The first visible row: the newest always shows, older ones while they fit.
    private func firstVisible(_ heights: [CGFloat]) -> Int {
        var total: CGFloat = 0
        var first = heights.count
        for index in heights.indices.reversed() {
            let next = total + heights[index] + (first == heights.count ? 0 : spacing)
            if next > maxHeight, first < heights.count { break }
            total = next
            first = index
        }
        return first
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let heights = heights(subviews, width: width)
        let first = firstVisible(heights)
        guard first < heights.count else { return CGSize(width: width, height: 0) }
        let total = heights[first...].reduce(0, +) + spacing * CGFloat(heights.count - first - 1)
        return CGSize(width: width, height: min(total, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = heights(subviews, width: bounds.width)
        let first = firstVisible(heights)
        var y = bounds.maxY
        for index in subviews.indices.reversed() {
            y -= heights[index]
            subviews[index].place(at: CGPoint(x: bounds.minX, y: index >= first ? y : min(y, bounds.minY - heights[index] - spacing)),
                                  anchor: .topLeading,
                                  proposal: ProposedViewSize(width: bounds.width, height: heights[index]))
            y -= spacing
        }
    }
}

/// The overlay's pairs, laid out so text already on screen never moves
/// sideways or reflows: the column split is fixed (the original gets
/// `sourceFraction` of the width, the translation the rest), the size is the
/// box's fixed caption area, and the newest row sits at the bottom. Every row
/// is placed; the ones above the area are clipped by the caller, so an old
/// pair leaves at the top a line at a time as new lines push it up, like the
/// RealtimeTranslator caption. Every row is three subviews: its band, its
/// original, its translation.
// WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
struct SteadyPairsLayout: Layout {
    var rowSpacing: CGFloat
    var columnSpacing: CGFloat
    var sourceFraction: CGFloat
    var size: CGSize
    /// Padding inside a row's band.
    var inset = CGSize.zero

    struct Columns: Equatable { var source: CGFloat; var translation: CGFloat }

    /// Depends only on the width, never on the text.
    func columns(width: CGFloat) -> Columns {
        let inner = max(0, width - 2 * inset.width - columnSpacing)
        let source = (inner * sourceFraction).rounded(.down)
        return Columns(source: source, translation: inner - source)
    }

    private func groups(_ subviews: Subviews) -> [Range<Int>] {
        stride(from: 0, to: subviews.count - subviews.count % 3, by: 3).map { $0..<($0 + 3) }
    }

    private func measure(_ subviews: Subviews, _ group: Range<Int>, _ columns: Columns)
        -> (height: CGFloat, sourceY: CGFloat, translationY: CGFloat) {
        let a = subviews[group.lowerBound + 1].dimensions(in: ProposedViewSize(width: columns.source, height: nil))
        let b = subviews[group.lowerBound + 2].dimensions(in: ProposedViewSize(width: columns.translation, height: nil))
        let baseline = max(a[VerticalAlignment.firstTextBaseline], b[VerticalAlignment.firstTextBaseline])
        let sourceY = baseline - a[VerticalAlignment.firstTextBaseline]
        let translationY = baseline - b[VerticalAlignment.firstTextBaseline]
        return (max(sourceY + a.height, translationY + b.height) + 2 * inset.height, sourceY, translationY)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(width: bounds.width)
        var y = bounds.maxY
        for group in groups(subviews).reversed() {
            let row = measure(subviews, group, columns)
            y -= row.height
            subviews[group.lowerBound].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                             proposal: ProposedViewSize(width: bounds.width, height: row.height))
            subviews[group.lowerBound + 1].place(
                at: CGPoint(x: bounds.minX + inset.width, y: y + inset.height + row.sourceY), anchor: .topLeading,
                proposal: ProposedViewSize(width: columns.source, height: nil))
            subviews[group.lowerBound + 2].place(
                at: CGPoint(x: bounds.minX + inset.width + columns.source + columnSpacing,
                            y: y + inset.height + row.translationY), anchor: .topLeading,
                proposal: ProposedViewSize(width: columns.translation, height: nil))
            y -= rowSpacing
        }
    }
}

/// The overlay box's content column: as wide as its widest child needs (up
/// to `maxWidth`), every child then laid out at that width. Controls with a
/// spacer stretch to it; the box no longer spans the panel by default.
struct HuggingColumnLayout: Layout {
    var spacing: CGFloat
    var maxWidth: CGFloat

    private func width(_ subviews: Subviews, proposed: CGFloat?) -> CGFloat {
        let cap = min(proposed ?? maxWidth, maxWidth)
        return subviews.map { min(cap, $0.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width) }.max() ?? 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(subviews, proposed: proposal.width)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for subview in subviews {
            let proposal = ProposedViewSize(width: bounds.width, height: nil)
            let height = subview.sizeThatFits(proposal).height
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: proposal)
            y += height + spacing
        }
    }
}

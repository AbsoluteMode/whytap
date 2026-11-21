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

/// One pair: the original in the narrower left column, its translation on
/// the right, aligned on their first baselines.
struct PairColumnsLayout: Layout {
    var sourceFraction: CGFloat = 0.4
    var spacing: CGFloat

    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        guard subviews.count == 2 else { return subviews.map { _ in .zero } }
        let sourceWidth = ((width - spacing) * sourceFraction).rounded(.down)
        let widths = [sourceWidth, width - spacing - sourceWidth]
        let dimensions = zip(subviews, widths).map { $0.dimensions(in: ProposedViewSize(width: $1, height: nil)) }
        let baseline = dimensions.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
        return dimensions.indices.map { index in
            CGRect(x: index == 0 ? 0 : sourceWidth + spacing,
                   y: baseline - dimensions[index][VerticalAlignment.firstTextBaseline],
                   width: widths[index], height: dimensions[index].height)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: frames(subviews, width: width).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

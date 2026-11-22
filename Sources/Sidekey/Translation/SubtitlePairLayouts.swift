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
/// sideways or reflows: the column split is fixed for a given width (the
/// original gets `sourceFraction` of it, the translation the rest), the height
/// is the box's fixed caption area, and the newest row sits at the bottom.
/// Every row is placed; the ones above the area are clipped by the caller, so
/// an old pair leaves at the top a line at a time as new lines push it up,
/// like the RealtimeTranslator caption. Every row is three subviews: its
/// band, its original, its translation. Each column is at most `columnCap`
/// high (`NewestLinesColumn`), so the newest row always fits below the top
/// fade with both its original and its translation.
// WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
struct SteadyPairsLayout: Layout {
    var rowSpacing: CGFloat
    var columnSpacing: CGFloat
    var sourceFraction: CGFloat
    /// The widest the caption gets, and its height.
    var size: CGSize
    /// Padding inside a row's band.
    var inset = CGSize.zero

    /// The share of the caption's height that fades out at the top.
    static let topFade: CGFloat = 0.14

    struct Columns: Equatable { var source: CGFloat; var translation: CGFloat }
    struct Column: Equatable { var height: CGFloat; var firstBaseline: CGFloat }
    struct Row: Equatable { var height: CGFloat; var sourceY: CGFloat; var translationY: CGFloat }

    /// Depends only on the width, never on the text.
    func columns(width: CGFloat) -> Columns {
        let inner = max(0, width - 2 * inset.width - columnSpacing)
        let source = (inner * sourceFraction).rounded(.down)
        return Columns(source: source, translation: inner - source)
    }

    /// The panel can be resized narrower than the box's usual width: the
    /// caption takes the width it is given, up to `size.width`.
    func width(proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return size.width }
        return max(0, min(proposed, size.width))
    }

    /// The tallest a column gets: the newest row then fits whole below the fade.
    var columnCap: CGFloat { max(0, (size.height * (1 - Self.topFade)).rounded(.down) - 2 * inset.height) }

    /// A row's columns share their first baseline. A column at its cap shows
    /// only its newest lines, so its first baseline is cut off: then both
    /// columns start at the top of the row.
    static func row(source: Column, translation: Column, cap: CGFloat, inset: CGFloat) -> Row {
        let clipped = source.height >= cap - 0.5 || translation.height >= cap - 0.5
        let valid = source.firstBaseline > 0 && translation.firstBaseline > 0
        guard !clipped, valid else {
            return Row(height: max(source.height, translation.height) + 2 * inset, sourceY: 0, translationY: 0)
        }
        let baseline = max(source.firstBaseline, translation.firstBaseline)
        let sourceY = baseline - source.firstBaseline
        let translationY = baseline - translation.firstBaseline
        return Row(height: max(sourceY + source.height, translationY + translation.height) + 2 * inset,
                   sourceY: sourceY, translationY: translationY)
    }

    private func groups(_ subviews: Subviews) -> [Range<Int>] {
        stride(from: 0, to: subviews.count - subviews.count % 3, by: 3).map { $0..<($0 + 3) }
    }

    private func measure(_ subviews: Subviews, _ group: Range<Int>, _ columns: Columns) -> Row {
        let a = subviews[group.lowerBound + 1].dimensions(in: ProposedViewSize(width: columns.source, height: nil))
        let b = subviews[group.lowerBound + 2].dimensions(in: ProposedViewSize(width: columns.translation, height: nil))
        return Self.row(source: Column(height: a.height, firstBaseline: a[VerticalAlignment.firstTextBaseline]),
                        translation: Column(height: b.height, firstBaseline: b[VerticalAlignment.firstTextBaseline]),
                        cap: columnCap, inset: inset.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width(proposed: proposal.width), height: size.height)
    }

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

/// A column of one overlay row, at most `cap` high: when the text is taller,
/// its newest lines show at the bottom and the oldest are cut at the top, so
/// a long unfinished original never pushes its translation out of sight.
/// Lines move up only when a new one starts, as in RealtimeTranslator.
// WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
struct NewestLinesColumn: ViewModifier {
    var cap: CGFloat

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: cap, alignment: .bottomLeading)
            .clipped()
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

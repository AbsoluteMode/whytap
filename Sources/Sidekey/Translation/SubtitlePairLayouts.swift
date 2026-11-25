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
/// band, its original, its translation. Each column is at most
/// `columnCap(height:)` of the caption's actual height (`NewestLinesColumn`),
/// so the newest row always fits below the top fade with both its original
/// and its translation. A shorter panel gets a shorter caption.
// WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
struct SteadyPairsLayout: Layout {
    var rowSpacing: CGFloat
    var columnSpacing: CGFloat
    var sourceFraction: CGFloat
    /// The widest and tallest the caption gets.
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

    /// The caption fills the box the user sized (`SubtitleOverlayFrame`):
    /// it takes the width and height it is offered. Without `fills`, at most
    /// `size`. Unspecified, `size`.
    // WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
    var fills = false
    /// Scrolled back: the pair the caption keeps in place; nil follows the newest.
    var anchor: SubtitleCaptionScroll.Anchor?
    /// Receives where the rows were placed, for the next scroll.
    var geometry: SubtitleCaptionGeometry?

    func width(proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return size.width }
        return max(0, fills ? proposed : min(proposed, size.width))
    }

    /// The caption is as tall as it is offered (up to `size.height` unless it fills).
    func height(proposed: CGFloat?) -> CGFloat {
        guard let proposed, proposed.isFinite else { return size.height }
        return max(0, fills ? proposed : min(proposed, size.height))
    }

    /// The tallest a column gets in a caption this high: the newest row then
    /// fits whole below the fade.
    func columnCap(height: CGFloat) -> CGFloat {
        max(0, (height * (1 - Self.topFade)).rounded(.down) - 2 * inset.height)
    }

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

    private func measure(_ subviews: Subviews, _ group: Range<Int>, _ columns: Columns, cap: CGFloat) -> Row {
        let a = subviews[group.lowerBound + 1].dimensions(in: ProposedViewSize(width: columns.source, height: cap))
        let b = subviews[group.lowerBound + 2].dimensions(in: ProposedViewSize(width: columns.translation, height: cap))
        return Self.row(source: Column(height: a.height, firstBaseline: a[VerticalAlignment.firstTextBaseline]),
                        translation: Column(height: b.height, firstBaseline: b[VerticalAlignment.firstTextBaseline]),
                        cap: cap, inset: inset.height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: width(proposed: proposal.width), height: height(proposed: proposal.height))
    }

    /// Where the rows' content starts (its top, y down), given each row's
    /// top within the content, the content's height and the caption's
    /// bounds. Following: the newest row at the bottom. Anchored: the
    /// anchored row stays where it was, or the oldest row at the top when
    /// it is gone; never past the oldest row's top or the newest row's bottom.
    static func contentTop(rowTops: [(id: UUID?, top: CGFloat)], total: CGFloat, bounds: CGRect,
                           anchor: SubtitleCaptionScroll.Anchor?) -> CGFloat {
        let following = bounds.maxY - total
        guard let anchor, total > bounds.height else { return following }
        let top = rowTops.first { $0.id == anchor.id }.map { bounds.minY + anchor.top - $0.top } ?? bounds.minY
        return min(max(top, following), bounds.minY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columns(width: bounds.width)
        let cap = columnCap(height: bounds.height)
        let groups = groups(subviews)
        let rows = groups.map { measure(subviews, $0, columns, cap: cap) }
        var tops: [(id: UUID?, top: CGFloat)] = []
        var y: CGFloat = 0
        for (group, row) in zip(groups, rows) {
            tops.append((subviews[group.lowerBound][SubtitleRowID.self], y))
            y += row.height + rowSpacing
        }
        let total = max(0, y - rowSpacing)
        let contentTop = Self.contentTop(rowTops: tops, total: total, bounds: bounds, anchor: anchor)
        var placed: [SubtitleCaptionGeometry.Row] = []
        for ((group, row), entry) in zip(zip(groups, rows), tops) {
            let y = contentTop + entry.top
            subviews[group.lowerBound].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                                             proposal: ProposedViewSize(width: bounds.width, height: row.height))
            subviews[group.lowerBound + 1].place(
                at: CGPoint(x: bounds.minX + inset.width, y: y + inset.height + row.sourceY), anchor: .topLeading,
                proposal: ProposedViewSize(width: columns.source, height: cap))
            subviews[group.lowerBound + 2].place(
                at: CGPoint(x: bounds.minX + inset.width + columns.source + columnSpacing,
                            y: y + inset.height + row.translationY), anchor: .topLeading,
                proposal: ProposedViewSize(width: columns.translation, height: cap))
            if let id = entry.id {
                placed.append(.init(id: id, top: y - bounds.minY, bottom: y - bounds.minY + row.height))
            }
        }
        geometry?.record(.init(rows: placed, height: bounds.height, width: bounds.width))
    }
}

/// A column of one overlay row, at most as high as it is offered: when the
/// text is taller, its newest lines show at the bottom and the oldest are cut
/// at the top, so a long unfinished original never pushes its translation out
/// of sight. Lines move up only when a new one starts, as in RealtimeTranslator.
// WHY: .project-docs/decisions/2026-11-23-subtitle-steady-overlay.md
struct NewestLinesColumn: ViewModifier {
    func body(content: Content) -> some View {
        NewestLinesLayout { content }.clipped()
    }
}

/// `NewestLinesColumn`'s layout: the text at its full height, bottom-anchored
/// in a frame no taller than the offer.
struct NewestLinesLayout: Layout {
    static func height(text: CGFloat, offered: CGFloat?) -> CGFloat {
        guard let offered, offered.isFinite else { return text }
        return min(text, max(0, offered))
    }

    private func text(_ subviews: Subviews, width: CGFloat?) -> CGSize {
        subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)) ?? .zero
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let text = text(subviews, width: proposal.width)
        return CGSize(width: text.width, height: Self.height(text: text.height, offered: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let text = text(subviews, width: bounds.width)
        subview.place(at: CGPoint(x: bounds.minX, y: bounds.maxY - text.height), anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: nil))
    }

    /// Baselines of the text where it is placed: above the frame when cut.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard let subview = subviews.first, guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let dimensions = subview.dimensions(in: ProposedViewSize(width: bounds.width, height: nil))
        return bounds.height - dimensions.height + dimensions[guide]
    }
}

/// The overlay box's content column: as wide as its widest child needs (up
/// to `maxWidth`), every child then laid out at that width. Controls with a
/// spacer stretch to it; the box no longer spans the panel by default. A
/// child with a negative layout priority (the caption) gets the height the
/// others leave, up to what it wants, so a short or narrow panel shrinks the
/// caption instead of cutting the box.
struct HuggingColumnLayout: Layout {
    var spacing: CGFloat
    var maxWidth: CGFloat

    private func width(_ subviews: Subviews, proposed: CGFloat?) -> CGFloat {
        let cap = min(proposed ?? maxWidth, maxWidth)
        return subviews.map { min(cap, $0.sizeThatFits(ProposedViewSize(width: nil, height: nil)).width) }.max() ?? 0
    }

    private func heights(_ subviews: Subviews, width: CGFloat, height: CGFloat?) -> [CGFloat] {
        let fixed = subviews.map { $0.priority < 0 ? 0 : $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let flexible = subviews.filter { $0.priority < 0 }.count
        let spare = height.map { max(0, $0 - fixed.reduce(0, +) - spacing * CGFloat(max(0, subviews.count - 1))) }
        return subviews.indices.map { index in
            guard subviews[index].priority < 0 else { return fixed[index] }
            let offer = spare.map { $0 / CGFloat(flexible) }
            return subviews[index].sizeThatFits(ProposedViewSize(width: width, height: offer)).height
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(subviews, proposed: proposal.width)
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
        let heights = heights(subviews, width: width, height: height)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = heights(subviews, width: bounds.width, height: bounds.height)
        var y = bounds.minY
        for (subview, height) in zip(subviews, heights) {
            subview.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: subview.priority < 0 ? height : nil))
            y += height + spacing
        }
    }
}

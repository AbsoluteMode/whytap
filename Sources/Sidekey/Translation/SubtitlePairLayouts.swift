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

/// The overlay's pairs as one grid: every row is three subviews (its band,
/// its original, its translation). One column split serves all visible rows
/// so the columns line up, and it is chosen from the content: the original
/// takes what it needs up to 45 % and the translation gets the rest, which
/// keeps a translation from wrapping beside an empty strip. The grid reports
/// the width its rows use, so the box hugs the text; only the newest rows
/// that fit whole are shown, bottom-anchored.
// WHY: .project-docs/decisions/2026-11-21-subtitle-phrase-pairs.md
struct PairGridLayout: Layout {
    var rowSpacing: CGFloat
    var columnSpacing: CGFloat
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    /// Padding inside a row's band (zero when bands are off).
    var inset = CGSize.zero

    struct Plan {
        var sourceWidth: CGFloat = 0
        var translationWidth: CGFloat = 0
        var rows: [(height: CGFloat, sourceY: CGFloat, translationY: CGFloat)] = []
        var first = 0
        var size = CGSize.zero
    }

    private func groups(_ subviews: Subviews) -> [Range<Int>] {
        stride(from: 0, to: subviews.count - subviews.count % 3, by: 3).map { $0..<($0 + 3) }
    }

    private func measure(_ subviews: Subviews, _ group: Range<Int>, source: CGFloat, translation: CGFloat)
        -> (height: CGFloat, sourceY: CGFloat, translationY: CGFloat) {
        let a = subviews[group.lowerBound + 1].dimensions(in: ProposedViewSize(width: source, height: nil))
        let b = subviews[group.lowerBound + 2].dimensions(in: ProposedViewSize(width: translation, height: nil))
        let baseline = max(a[VerticalAlignment.firstTextBaseline], b[VerticalAlignment.firstTextBaseline])
        let sourceY = baseline - a[VerticalAlignment.firstTextBaseline]
        let translationY = baseline - b[VerticalAlignment.firstTextBaseline]
        return (max(sourceY + a.height, translationY + b.height) + 2 * inset.height, sourceY, translationY)
    }

    func plan(_ subviews: Subviews, width proposed: CGFloat?) -> Plan {
        let groups = groups(subviews)
        guard !groups.isEmpty else { return Plan() }
        let width = min(proposed ?? maxWidth, maxWidth)
        let inner = max(0, width - 2 * inset.width - columnSpacing)
        let sourceNatural = groups.map { subviews[$0.lowerBound + 1].sizeThatFits(.unspecified).width }.max() ?? 0
        let translationNatural = groups.map { subviews[$0.lowerBound + 2].sizeThatFits(.unspecified).width }.max() ?? 0
        var plan = Plan()
        if sourceNatural + translationNatural <= inner {
            plan.sourceWidth = sourceNatural
            plan.translationWidth = translationNatural
        } else {
            // Try splits from a quarter to 45 % of the width; keep the one
            // with the fewest total lines (lowest height), then the widest
            // translation. Only the newest rows matter: older ones leave.
            let recent = groups.suffix(SubtitleCaption.maxPairs)
            var best: (height: CGFloat, source: CGFloat)?
            for step in 0...8 {
                let source = min(sourceNatural, (inner * (0.25 + 0.025 * CGFloat(step))).rounded(.down))
                let translation = min(translationNatural, inner - source)
                let height = recent.reduce(0) { $0 + measure(subviews, $1, source: source, translation: translation).height }
                if best == nil || height < best!.height - 0.5 { best = (height, source) }
            }
            plan.sourceWidth = best?.source ?? (inner * 0.4).rounded(.down)
            plan.translationWidth = min(translationNatural, inner - plan.sourceWidth)
        }
        plan.rows = groups.map { measure(subviews, $0, source: plan.sourceWidth, translation: plan.translationWidth) }
        var total: CGFloat = 0
        plan.first = groups.count
        for index in plan.rows.indices.reversed() {
            let next = total + plan.rows[index].height + (plan.first == groups.count ? 0 : rowSpacing)
            if next > maxHeight, plan.first < groups.count { break }
            total = next
            plan.first = index
        }
        let used = plan.sourceWidth + columnSpacing + plan.translationWidth + 2 * inset.width
        plan.size = CGSize(width: min(width, used.rounded(.up)), height: min(total, maxHeight))
        return plan
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(subviews, width: bounds.width)
        var y = bounds.maxY
        for (index, group) in groups(subviews).enumerated().reversed() {
            let row = plan.rows[index]
            y -= row.height
            let top = index >= plan.first ? y : min(y, bounds.minY - row.height - rowSpacing)
            subviews[group.lowerBound].place(at: CGPoint(x: bounds.minX, y: top), anchor: .topLeading,
                                             proposal: ProposedViewSize(width: bounds.width, height: row.height))
            subviews[group.lowerBound + 1].place(
                at: CGPoint(x: bounds.minX + inset.width, y: top + inset.height + row.sourceY), anchor: .topLeading,
                proposal: ProposedViewSize(width: plan.sourceWidth, height: nil))
            subviews[group.lowerBound + 2].place(
                at: CGPoint(x: bounds.minX + inset.width + plan.sourceWidth + columnSpacing,
                            y: top + inset.height + row.translationY), anchor: .topLeading,
                proposal: ProposedViewSize(width: plan.translationWidth, height: nil))
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

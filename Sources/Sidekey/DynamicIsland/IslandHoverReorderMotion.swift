import SwiftUI

// Island tool reorder, how it moves: the lifted tile floats above the grid and
// follows the pointer frame by frame; its empty cell slides with the others;
// on release it lands in its cell, on cancel it flies back to where it was.
// WHY: .project-docs/decisions/2026-11-25-island-hover-reorder.md

/// The curves of the reorder. All are critically or nearly critically damped,
/// so nothing overshoots, wobbles or stops abruptly.
enum IslandHoverReorderMotionCurve {
    /// The tile rising under the finger.
    static let lift = Animation.spring(response: 0.24, dampingFraction: 0.82)
    /// The tile settling into its cell, or flying back on cancel.
    static let land = Animation.spring(response: 0.34, dampingFraction: 0.9)
    /// How much larger a lifted tile is drawn.
    static let liftedScale: CGFloat = 1.1
}

/// Every tile's frame in the grid's coordinate space, so the floating tile
/// starts exactly over its cell and lands exactly in its new one.
struct IslandHoverTileFramesKey: PreferenceKey {
    static let defaultValue: [HoverTool: CGRect] = [:]
    static func reduce(value: inout [HoverTool: CGRect], nextValue: () -> [HoverTool: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct IslandHoverTileFrameReporter: View {
    let tool: HoverTool
    let space: String

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: IslandHoverTileFramesKey.self,
                                   value: [tool: proxy.frame(in: .named(space))])
        }
    }
}

/// The lifted tile. Only this view observes the pointer's travel, so a drag
/// redraws one tile per frame instead of the whole island.
struct IslandHoverFloatingTile<Content: View>: View {
    @ObservedObject var motion: IslandHoverReorderMotion
    /// The tile's centre in its cell when it was lifted.
    let origin: CGPoint
    /// Where it lands, once let go; nil while it follows the pointer.
    let settle: CGPoint?
    let lifted: Bool
    @ViewBuilder let content: () -> Content

    static func position(origin: CGPoint, translation: CGSize, settle: CGPoint?) -> CGPoint {
        settle ?? CGPoint(x: origin.x + translation.width, y: origin.y + translation.height)
    }

    var body: some View {
        content()
            .scaleEffect(lifted ? IslandHoverReorderMotionCurve.liftedScale : 1)
            .shadow(color: .black.opacity(lifted ? 0.35 : 0), radius: lifted ? 10 : 0, y: lifted ? 5 : 0)
            .fixedSize()
            .position(Self.position(origin: origin, translation: motion.translation, settle: settle))
            // Following the pointer is immediate; only lift and landing animate.
            .animation(nil, value: motion.translation)
    }
}

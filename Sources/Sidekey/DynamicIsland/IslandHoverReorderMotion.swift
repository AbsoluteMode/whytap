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

/// What the floating layer draws: the lifted tile's picture (taken from the
/// drawer at the lift), where it started, and where it lands. The drawer
/// drives it; the layer that draws it sits above the drawer's clip, so on
/// the macOS 14/15 backdrop the tile stays visible outside the drawer.
@MainActor
final class IslandHoverReorderStage: ObservableObject {
    @Published private(set) var tool: HoverTool?
    @Published private(set) var content: AnyView?
    @Published private(set) var origin: CGPoint = .zero
    @Published var settle: CGPoint?
    @Published var lifted = false
    /// The lift this picture belongs to (`IslandHoverHitBridge.reorderGeneration`).
    private(set) var generation = 0

    func begin(_ tool: HoverTool, content: AnyView, origin: CGPoint, generation: Int) {
        self.tool = tool
        self.content = content
        self.origin = origin
        self.generation = generation
        settle = nil
        lifted = false
    }

    func clear(generation: Int) {
        guard generation == self.generation else { return }
        tool = nil
        content = nil
        settle = nil
        lifted = false
    }
}

/// Drawn over the whole island (outside the drawer's clip), in the same
/// coordinate space the tiles report their frames in.
struct IslandHoverFloatingLayer: View {
    @ObservedObject var stage: IslandHoverReorderStage
    let motion: IslandHoverReorderMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let content = stage.content {
                IslandHoverFloatingTile(motion: motion, origin: stage.origin,
                                        settle: stage.settle, lifted: stage.lifted) { content }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

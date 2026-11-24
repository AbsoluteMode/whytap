import AppKit
import SwiftUI

/// The row of drops right of the island: one glass capsule per step the
/// Agent made, with the changed part's mark and the app's own line.
/// A drop exists only while it is on screen. The shelved suggestion drops
/// kept all of theirs in the hierarchy and hid them with opacity, which
/// glass does not follow; here arriving and leaving are insertion and
/// removal, and macOS 26 glass morphs out of and back into its neighbour.
/// WHY: .project-docs/decisions/2026-11-24-agent-step-drops.md
struct AgentStepDropsView: View {
    @ObservedObject var model: AgentStepDropsModel

    enum Metrics {
        static let gap: CGFloat = 7
        /// The panel starts this far under the island's edge, so a drop
        /// arriving without glass comes out from under it.
        static let islandOverlap: CGFloat = 28
        /// Clear space between the island and the first drop at rest.
        static let islandGap: CGFloat = 6
        static let rowHeight: CGFloat = 28
        static let maxDropWidth: CGFloat = 340
        static var leading: CGFloat { islandOverlap + islandGap }
        /// Room for a full row of the widest drops.
        static var panelWidth: CGFloat {
            leading + CGFloat(AgentStepDropsModel.maxVisible) * (maxDropWidth + gap) + 12
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var glass

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Metrics.leading)
            container
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var usesNativeGlass: Bool {
        AgentStepGlass.kind(reduceTransparency: reduceTransparency) == .native
    }

    private var onlyFades: Bool { reduceMotion || model.isReducedMotion || model.fading }

    @ViewBuilder
    private var container: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), usesNativeGlass {
            GlassEffectContainer(spacing: Metrics.gap) { row }
        } else {
            row
        }
        #else
        row
        #endif
    }

    private var row: some View {
        HStack(spacing: Metrics.gap) {
            ForEach(model.visible) { drop in
                // A drop comes out from behind the one before it.
                arriving(AgentStepDrop(step: drop.step), id: drop.id)
                    .zIndex(-Double(drop.id))
            }
        }
        .frame(height: Metrics.rowHeight + 6)
        .animation(animation, value: model.visible.map(\.id))
    }

    private var animation: Animation {
        onlyFades ? .easeOut(duration: AgentStepDropsModel.Timing.fade)
            : .spring(response: 0.42, dampingFraction: 0.8)
    }

    /// How one drop comes and goes. Native glass: the system morphs the
    /// capsule out of the drop before it and back, the content fades.
    /// Otherwise the drop grows out of its leading side from where its
    /// parent is (the island for the first one).
    @ViewBuilder
    private func arriving(_ drop: AgentStepDrop, id: Int) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), usesNativeGlass {
            drop
                .glassEffectID(id, in: glass)
                .glassEffectTransition(.matchedGeometry)
                .transition(.opacity)
        } else {
            drop.transition(fallbackTransition)
        }
        #else
        drop.transition(fallbackTransition)
        #endif
    }

    private var fallbackTransition: AnyTransition {
        onlyFades ? .opacity
            : .modifier(active: AgentStepBud(progress: 0), identity: AgentStepBud(progress: 1))
    }
}

/// A drop on its way out of its parent: `progress` 0 is small, see-through
/// and still at the parent; 1 is in place.
struct AgentStepBud: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let shown = min(1, max(0, progress))
        content
            .scaleEffect(0.35 + 0.65 * progress, anchor: .leading)
            .offset(x: -(1 - progress) * (AgentStepDropsView.Metrics.islandGap + 20))
            .opacity(Double(min(1, shown * 1.6)))
    }
}

/// One step: the mark of what changed and the app's line, the saved value
/// in bold ("Vocab + **whytap**").
struct AgentStepDrop: View {
    let step: AgentAppStep

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: step.symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                .accessibilityHidden(true)
            line
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(.horizontal, 11)
        .frame(height: AgentStepDropsView.Metrics.rowHeight)
        .frame(maxWidth: AgentStepDropsView.Metrics.maxDropWidth)
        .fixedSize(horizontal: true, vertical: false)
        .agentStepGlass(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.line)
    }

    private var line: Text {
        let parts = step.parts
        let quiet = Color(nsColor: .secondaryLabelColor)
        return Text(parts.subject) + Text(parts.sign).foregroundColor(quiet)
            + Text(parts.value).fontWeight(.semibold)
    }
}

// MARK: - Glass

enum AgentStepGlass {
    enum Kind: Equatable { case native, material, opaque }

    static func kind(reduceTransparency: Bool) -> Kind {
        if reduceTransparency { return .opaque }
        return IslandHoverGlass.usesNativeLiquidGlass ? .native : .material
    }
}

private struct AgentStepGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch AgentStepGlass.kind(reduceTransparency: reduceTransparency) {
        case .opaque:
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
        case .material:
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        case .native:
            nativeGlass(content)
        }
    }

    @ViewBuilder
    private func nativeGlass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
        #else
        content.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

private extension View {
    func agentStepGlass<S: InsettableShape>(_ shape: S) -> some View {
        modifier(AgentStepGlassModifier(shape: shape))
    }
}

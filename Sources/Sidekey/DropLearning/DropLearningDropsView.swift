import AppKit
import SwiftUI

/// Four liquid-glass drops in one row in the menu bar right of the island:
/// list icon, action with +/− in a thin circle, Y, N. Y and N are plain
/// glass inside; colour is only a thin contour around the whole edge with a
/// soft glow (green Y, red N). Letters at rest, ✓/✕ under the pointer.
/// WHY: .project-docs/decisions/2026-11-22-drop-learning-drops.md
struct DropLearningDropsView: View {
    @ObservedObject var model: DropLearningDropsModel
    /// The row's frame in the view, for the panel's hit area.
    var onRowFrame: (CGRect) -> Void = { _ in }

    enum Metrics {
        static let gap: CGFloat = 7
        /// How far the first drop starts under the island's edge.
        static let islandOverlap: CGFloat = 16
        static let iconSize: CGFloat = 28
        static let buttonSize: CGFloat = 26
        static let rowHeight: CGFloat = 28
        static let maxActionWidth: CGFloat = 340
        /// Glass shapes closer than this blend: only a drop still leaving
        /// its parent touches it, which draws the bridge.
        static let blendSpacing: CGFloat = 5
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var actionWidth: CGFloat = 120

    var body: some View {
        GeometryReader { _ in
            HStack(spacing: 0) {
                Color.clear.frame(width: Metrics.islandOverlap)
                container
                    .onHover { model.setHovered($0) }
                    .background(GeometryReader { geometry in
                        let frame = geometry.frame(in: .named(Self.space))
                        Color.clear
                            .onAppear { onRowFrame(frame) }
                            .onChange(of: frame) { _, value in onRowFrame(value) }
                    })
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .coordinateSpace(name: Self.space)
        .accessibilityElement(children: .contain)
    }

    private static let space = "drop-learning-drops"

    @ViewBuilder
    private var container: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), DropLearningGlass.kind(reduceTransparency: false) == .native {
            GlassEffectContainer(spacing: Metrics.blendSpacing) { row }
        } else {
            row
        }
        #else
        row
        #endif
    }

    private var row: some View {
        HStack(spacing: Metrics.gap) {
            drop(0, width: Metrics.iconSize, travel: Metrics.islandOverlap + Metrics.iconSize / 2) { iconDrop }
            drop(1, width: actionWidth, travel: Metrics.iconSize / 2 + Metrics.gap + actionWidth / 2) { actionDrop }
            drop(2, width: Metrics.buttonSize, travel: actionWidth / 2 + Metrics.gap + Metrics.buttonSize / 2) {
                answerDrop(.yes)
            }
            drop(3, width: Metrics.buttonSize, travel: Metrics.buttonSize + Metrics.gap) { answerDrop(.no) }
        }
        .frame(height: Metrics.rowHeight + 4)
    }

    // MARK: - Chain

    /// A drop buds from its parent (the island, or the drop before it): it
    /// starts small at the parent's centre and springs to its place.
    private func drop<Content: View>(_ index: Int, width: CGFloat, travel: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        let out = index < model.dropsOut
        let moves = !reduceMotion && !model.isReducedMotion
        return content()
            .scaleEffect(out || !moves ? 1 : 0.3)
            .offset(x: out || !moves ? 0 : -travel)
            .opacity(out ? 1 : 0)
            .animation(animation(out: out, moves: moves), value: out)
    }

    private func animation(out: Bool, moves: Bool) -> Animation {
        guard moves else { return .easeOut(duration: DropLearningDropsModel.Timing.fade) }
        return out ? .spring(response: 0.36, dampingFraction: 0.64) : .spring(response: 0.3, dampingFraction: 0.8)
    }

    // MARK: - Drops

    private var iconDrop: some View {
        let symbol: String
        if model.confirmed {
            symbol = model.content?.yesOpens == true ? "arrow.up.right" : "checkmark"
        } else {
            symbol = model.content?.list.symbol ?? "book.closed"
        }
        let size = model.confirmed ? Metrics.iconSize + 4 : Metrics.iconSize
        return Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .dropGlass(Circle())
            .frame(width: Metrics.iconSize, height: Metrics.iconSize)
            .animation(.spring(response: 0.24, dampingFraction: 0.86), value: model.confirmed)
            .accessibilityHidden(true)
    }

    private var actionDrop: some View {
        HStack(spacing: 7) {
            Image(systemName: model.content?.adds == false ? "minus" : "plus")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 15)
                .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                .accessibilityHidden(true)
            actionText
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = model.content?.detail {
                Text(detail)
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Color(nsColor: .labelColor))
        .padding(.horizontal, 12)
        .frame(height: Metrics.rowHeight)
        .frame(maxWidth: Metrics.maxActionWidth)
        .fixedSize(horizontal: true, vertical: false)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { actionWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, value in actionWidth = value }
        })
        .dropGlass(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.content?.accessibilityLabel ?? "")
    }

    private var actionText: Text {
        (model.content?.runs ?? []).reduce(Text("")) { text, run in
            switch run {
            case .plain(let value): return text + Text(value)
            case .emphasis(let value): return text + Text(value).fontWeight(.semibold)
            case .arrow: return text + Text(" → ").foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
        }
    }

    private func answerDrop(_ button: DropLearningDropsModel.Button) -> some View {
        DropLearningAnswerDrop(
            button: button,
            yesOpens: model.content?.yesOpens == true,
            hovered: model.hoveredButton == button,
            controlHeld: model.controlHeld,
            action: { model.answer(button) },
            onHover: { model.setHoveredButton($0 ? button : (model.hoveredButton == button ? nil : model.hoveredButton)) }
        )
    }
}

/// Y or N: plain glass, a letter at rest and ✓/✕ under the pointer, both in
/// the text colour. The only colour is the contour and its glow.
private struct DropLearningAnswerDrop: View {
    let button: DropLearningDropsModel.Button
    let yesOpens: Bool
    let hovered: Bool
    let controlHeld: Bool
    let action: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(button == .yes ? "Y" : "N")
                    .font(.system(size: 12.5, weight: .semibold))
                    .opacity(hovered ? 0 : 1)
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .bold))
                    .opacity(hovered ? 1 : 0)
            }
            .foregroundStyle(Color(nsColor: .labelColor))
            .frame(width: DropLearningDropsView.Metrics.buttonSize, height: DropLearningDropsView.Metrics.buttonSize)
            .animation(.easeOut(duration: 0.12), value: hovered)
        }
        .buttonStyle(DropLearningAnswerStyle(
            tint: button == .yes ? Color(nsColor: .systemGreen) : Color(nsColor: .systemRed),
            lit: hovered || controlHeld,
            dark: colorScheme == .dark
        ))
        .onHover(perform: onHover)
        .accessibilityLabel(button == .yes ? (yesOpens ? "Open Vocab" : "Yes") : "No")
        .accessibilityHint(button == .yes ? "Control-Y" : "Control-N")
    }

    private var glyph: String {
        switch button {
        case .yes: return yesOpens ? "arrow.up.right" : "checkmark"
        case .no: return "xmark"
        }
    }
}

/// Glass, then a thin contour around the whole edge with a soft glow
/// outside it; hover or held ⌃ brighten it, a press brightens the glow.
private struct DropLearningAnswerStyle: ButtonStyle {
    let tint: Color
    let lit: Bool
    let dark: Bool

    func makeBody(configuration: Configuration) -> some View {
        let rim = lit ? 0.95 : (dark ? 0.75 : 0.70)
        let glow = configuration.isPressed ? 0.70 : (lit ? 0.55 : (dark ? 0.38 : 0.30))
        return configuration.label
            .dropGlass(Circle())
            .overlay(
                Circle()
                    .strokeBorder(tint.opacity(rim), lineWidth: 0.75)
                    .shadow(color: tint.opacity(glow), radius: 3)
            )
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.14), value: lit)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

// MARK: - Glass

enum DropLearningGlass {
    enum Kind: Equatable { case native, material, opaque }

    static func kind(reduceTransparency: Bool) -> Kind {
        if reduceTransparency { return .opaque }
        return IslandHoverGlass.usesNativeLiquidGlass ? .native : .material
    }
}

private struct DropGlassModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        switch DropLearningGlass.kind(reduceTransparency: reduceTransparency) {
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
    func dropGlass<S: InsettableShape>(_ shape: S) -> some View {
        modifier(DropGlassModifier(shape: shape))
    }
}

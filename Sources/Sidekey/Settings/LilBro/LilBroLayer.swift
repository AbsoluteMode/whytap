import SwiftUI

/// Lil Bro drawn over the whole Settings window: the outline of the block he
/// brought the person to, his ladder, himself and his balloon. Only he and
/// the balloon take clicks; everything else passes through to Settings.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
@MainActor
struct LilBroLayer: View {
    @ObservedObject var controller: LilBroController
    @ObservedObject var preferences: LilBroPreferences
    @Environment(\.colorScheme) private var colorScheme
    @State private var balloonSize = CGSize(width: LilBroBalloonView.width, height: 120)
    @State private var fieldSize = CGSize(width: LilBroReplyField.width, height: 28)

    init(controller: LilBroController) {
        self.controller = controller
        preferences = controller.preferences
    }

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .named(LilBroSpace.name))
            ZStack(alignment: .topLeading) {
                Color.clear.allowsHitTesting(false)
                if let target = controller.target {
                    RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
                        .fill(MacSettingsTheme.accent.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
                            .strokeBorder(MacSettingsTheme.accent, lineWidth: 2))
                        .frame(width: target.width, height: target.height)
                        .offset(x: target.minX - bounds.minX, y: target.minY - bounds.minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if let flash = controller.flash {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(MacSettingsTheme.accent.opacity(0.45), lineWidth: 3)
                        .frame(width: flash.width, height: flash.height)
                        .offset(x: flash.minX - bounds.minX, y: flash.minY - bounds.minY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if preferences.mascotVisible, controller.placed {
                    if let ladder = controller.ladder {
                        LilBroLadderView(height: ladder.bottom - ladder.top)
                            .offset(x: ladder.x - bounds.minX, y: ladder.top - bounds.minY)
                            .allowsHitTesting(false)
                    }
                    LilBroMascot(controller: controller, origin: bounds.origin, dark: colorScheme == .dark)
                }
                if controller.bubble == .full {
                    balloon(bounds: bounds)
                } else if !preferences.mascotVisible, controller.bubble == .thinking {
                    // No little guy to carry the dots: they sit on the entry.
                    if let entry = controller.map.home {
                        LilBroTag(text: nil)
                            .offset(x: entry.minX - bounds.minX + 12, y: entry.minY - bounds.minY - 34)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onAppear { controller.update(bounds: bounds) }
            .onChange(of: bounds) { _, new in controller.update(bounds: new) }
        }
    }

    @ViewBuilder
    private func balloon(bounds: CGRect) -> some View {
        let layout = layout(bounds: bounds)
        LilBroBalloonView(controller: controller, tail: layout.tail, tailOffset: layout.tailOffset,
                          maxHeight: LilBroBalloonLayout.maxHeight(feet: controller.feet, bounds: bounds,
                                                                    fieldHeight: fieldSize.height))
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { p in
                Color.clear.onAppear { balloonSize = p.size }.onChange(of: p.size) { _, s in balloonSize = s }
            })
            .offset(x: layout.balloon.minX - bounds.minX, y: layout.balloon.minY - bounds.minY)
        LilBroReplyField(controller: controller)
            .fixedSize()
            .background(GeometryReader { p in
                Color.clear.onAppear { fieldSize = p.size }.onChange(of: p.size) { _, s in fieldSize = s }
            })
            .offset(x: layout.field.minX - bounds.minX, y: layout.field.minY - bounds.minY)
    }

    private func layout(bounds: CGRect) -> LilBroBalloonLayout {
        if !preferences.mascotVisible || !controller.placed, let entry = controller.map.home {
            return .above(entry: entry, balloon: balloonSize, field: fieldSize, bounds: bounds)
        }
        return .around(feet: controller.feet, balloon: balloonSize, field: fieldSize,
                       bounds: bounds, target: controller.target)
    }
}

/// The little guy himself, sampled every frame from his current move.
@MainActor
struct LilBroMascot: View {
    @ObservedObject var controller: LilBroController
    let origin: CGPoint
    let dark: Bool

    var body: some View {
        // Smooth while he moves; at rest his frames change every ~80-500 ms.
        TimelineView(.animation(minimumInterval: controller.segment == nil ? 0.05 : 1.0 / 30)) { context in
            let feet = controller.position(at: context.date)
            let pose = controller.shownPose
            let elapsed = context.date.timeIntervalSince(controller.poseStart)
            ZStack(alignment: .bottom) {
                Button { controller.catchHim() } label: {
                    LilBroSprite(pose: pose, elapsed: elapsed, dark: dark, facingRight: controller.facingRight)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .onHover { controller.hovering = $0 }
                .help("Lil Bro")
                .accessibilityLabel("Lil Bro")
                .accessibilityHint("Opens a balloon to ask where something is in Settings")
            }
            .frame(width: 28, height: 32)
            .overlay(alignment: .top) { tag }
            .offset(x: feet.x - 14 - origin.x, y: feet.y - 31 - origin.y)
        }
    }

    @ViewBuilder private var tag: some View {
        switch controller.bubble {
        case .tag(let text):
            LilBroTag(text: text).fixedSize().offset(y: -30)
        case .thinking:
            LilBroTag(text: nil).fixedSize().offset(y: -30)
        case .closed where controller.hovering && !controller.isBusy:
            LilBroTag(text: LilBroCopy.catchMe).fixedSize().offset(y: -30)
        default:
            EmptyView()
        }
    }
}

/// One frame of the sheet at 2 points per pixel, crisp.
struct LilBroSprite: View {
    let pose: LilBroPose
    let elapsed: TimeInterval
    let dark: Bool
    let facingRight: Bool
    var atlas: LilBroAtlas? = .shared

    var body: some View {
        if let atlas, let image = atlas.image(atlas.frameName(for: pose, elapsed: elapsed), dark: dark) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: atlas.pointSize.width, height: atlas.pointSize.height)
                .scaleEffect(x: facingRight ? 1 : -1, y: 1)
                .contentShape(Rectangle())
        } else {
            Color.clear.frame(width: 28, height: 32)
        }
    }
}

/// His amber ladder, drawn in pixels like him.
struct LilBroLadderView: View {
    let height: CGFloat
    static let amber = Color(hexCSS: "#E8A33A")

    var body: some View {
        Canvas { context, size in
            let rail = Self.amber, rung = Self.amber.opacity(0.85)
            context.fill(Path(CGRect(x: 0, y: 0, width: 2, height: size.height)), with: .color(rail))
            context.fill(Path(CGRect(x: 10, y: 0, width: 2, height: size.height)), with: .color(rail))
            var y: CGFloat = 3
            while y < size.height - 1 {
                context.fill(Path(CGRect(x: 2, y: y, width: 8, height: 2)), with: .color(rung))
                y += 7
            }
        }
        .frame(width: 12, height: max(0, height))
        .accessibilityHidden(true)
    }
}

/// A small balloon over his head: a word ("On my way…", "Catch me") or
/// three dots while he thinks.
struct LilBroTag: View {
    let text: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let text {
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
            } else {
                TimelineView(.animation(minimumInterval: 0.2, paused: reduceMotion)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate * 3) % 3
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle().fill(MacSettingsTheme.text2)
                                .frame(width: 5, height: 5)
                                .opacity(reduceMotion || i == step ? 1 : 0.35)
                        }
                    }
                }
                .accessibilityLabel("Thinking")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(MacSettingsTheme.bgCard, in: Capsule())
        .overlay(Capsule().strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .allowsHitTesting(false)
    }
}

/// "Lil Bro · ask anything" at the bottom of the sidebar: his home, and the
/// way to ask when the little guy is hidden or out of sight.
@MainActor
struct LilBroSidebarEntry: View {
    @ObservedObject var controller: LilBroController
    @FocusState private var focused: Bool

    var body: some View {
        Button { controller.toggleFromSidebar() } label: {
            HStack(spacing: 6) {
                Text("Lil Bro")
                    .font(.system(size: SettingsSidebarStyle.labelFontSize, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                Text("ask anything")
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SettingsSidebarStyle.buttonHorizontalPadding)
            .frame(height: 34)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(controller.isOpen ? MacSettingsTheme.selection : MacSettingsTheme.controlBg.opacity(0.7)))
        }
        .buttonStyle(SettingsSidebarButtonStyle(focused: focused))
        .focused($focused)
        .lilBroSpot(.home)
        .accessibilityLabel("Lil Bro")
        .accessibilityHint("Ask where something is in Settings")
        .accessibilityAddTraits(controller.isOpen ? .isSelected : [])
    }
}

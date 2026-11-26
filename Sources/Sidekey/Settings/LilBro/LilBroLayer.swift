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

    init(controller: LilBroController) {
        self.controller = controller
        preferences = controller.preferences
    }

    #if DEBUG
    /// How many times the layer was evaluated; tests read it to prove typing
    /// redraws only the reply field.
    nonisolated(unsafe) static var evaluations = 0
    #endif

    var body: some View {
        #if DEBUG
        let _ = Self.evaluations += 1
        #endif
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

    #if DEBUG
    /// Every balloon place drawn, in order; tests read it to see jumps.
    nonisolated(unsafe) static var balloonPlaces: [CGRect] = []
    #endif

    /// The balloon, its tail and the reply field, measured and placed in one
    /// pass: never drawn first at an old size and then moved.
    // WHY: .project-docs/decisions/2026-11-24-lil-bro.md
    private func balloon(bounds: CGRect) -> some View {
        let anchor: LilBroBalloonStage.Anchor
        if !preferences.mascotVisible || !controller.placed, let entry = controller.map.home {
            anchor = .entry(entry)
        } else {
            anchor = .feet(controller.feet, target: controller.target)
        }
        let maxHeight = LilBroBalloonLayout.maxHeight(feet: controller.feet, bounds: bounds,
                                                      fieldHeight: LilBroReplyField.height)
        return LilBroBalloonStage(anchor: anchor, bounds: bounds) {
            VStack(alignment: .leading, spacing: 6) {
                // Before the first question: one line of greeting over the field.
                if !controller.showsBalloon { LilBroGreetingLine(text: controller.greeting) }
                LilBroReplyField(controller: controller)
            }
            // Before the first question only the greeting and the field show.
            if controller.showsBalloon {
                LilBroBalloonView(controller: controller, maxHeight: maxHeight)
                // Over the balloon, so its edge does not cross the tail.
                ForEach(LilBroBalloonLayout.Tail.allCases, id: \.self) { tail in
                    LilBroBalloonTail(tail: tail)
                }
            }
        }
    }
}

/// Places the balloon, its tail and the reply field from their real sizes in
/// the same layout pass that draws them.
struct LilBroBalloonStage: Layout {
    enum Anchor: Equatable {
        case feet(CGPoint, target: CGRect?)
        case entry(CGRect)
    }

    let anchor: Anchor
    /// The layer's frame in the window's coordinates.
    let bounds: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: bounds.size)
    }

    /// Subviews: the field, then the balloon and four tails (down, up, left,
    /// right) once there is a balloon.
    func placeSubviews(in rect: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let tails = LilBroBalloonLayout.Tail.allCases.count
        guard subviews.count == 1 || subviews.count == tails + 2 else { return }
        let fieldView = subviews[0]
        let balloonView = subviews.count > 1 ? subviews[1] : nil
        let size = balloonView?.sizeThatFits(ProposedViewSize(width: LilBroBalloonView.width, height: nil)) ?? .zero
        let fieldSize = fieldView.sizeThatFits(.unspecified)
        let layout: LilBroBalloonLayout
        switch anchor {
        case .feet(let feet, let target):
            layout = .around(feet: feet, balloon: size, field: fieldSize, bounds: bounds, target: target)
        case .entry(let entry):
            layout = .above(entry: entry, balloon: size, field: fieldSize, bounds: bounds)
        }
        func place(_ view: LayoutSubview, _ frame: CGRect) {
            view.place(at: CGPoint(x: rect.minX + frame.minX - bounds.minX, y: rect.minY + frame.minY - bounds.minY),
                       proposal: ProposedViewSize(frame.size))
        }
        place(fieldView, layout.field)
        guard let balloonView else { return }
        #if DEBUG
        LilBroLayer.balloonPlaces.append(layout.balloon)
        #endif
        place(balloonView, layout.balloon)
        for (index, tail) in LilBroBalloonLayout.Tail.allCases.enumerated() {
            place(subviews[2 + index], tail == layout.tail ? layout.tailFrame : .zero)
        }
    }
}

/// The little guy himself. While he moves, only his place is sampled, at
/// the display's own rate; the control, its focus and hover stay put, and
/// his frames change on their own slower clock.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
@MainActor
struct LilBroMascot: View {
    #if DEBUG
    /// Frames drawn while he moves; tests read it as his frame rate.
    nonisolated(unsafe) static var movingFrames = 0
    static func frameDrawn(moving: Bool) { if moving { movingFrames += 1 } }
    #endif

    @ObservedObject var controller: LilBroController
    let origin: CGPoint
    let dark: Bool

    var body: some View {
        let moving = controller.segment != nil
        // No minimum interval: every display refresh while he moves; none at rest.
        TimelineView(.animation(minimumInterval: nil, paused: !moving)) { context in
            let feet = moving ? controller.position(at: context.date) : controller.feet
            #if DEBUG
            let _ = LilBroMascot.frameDrawn(moving: moving)
            #endif
            LilBroFigure(controller: controller, dark: dark)
                .offset(x: feet.x - 14 - origin.x, y: feet.y - 31 - origin.y)
        }
    }
}

/// Him as a control: a click catches him while the balloon is closed.
@MainActor
struct LilBroFigure: View {
    @ObservedObject var controller: LilBroController
    let dark: Bool
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            // Hover and focus show wherever a click catches him.
            Ellipse()
                .fill(MacSettingsTheme.accent.opacity(0.22))
                .frame(width: 26, height: 6)
                .offset(y: 3)
                .opacity(controller.canCatch && controller.hovering ? 1 : 0)
            Button { controller.catchHim() } label: {
                LilBroAnimatedSprite(controller: controller, dark: dark)
            }
            .buttonStyle(LilBroPressStyle())
            // Only while a click catches him (the balloon is closed): with
            // it open he is not a control, so no press, focus or ring.
            .disabled(!controller.canCatch)
            // His own ring follows the sprite; the default one is square and offset.
            .focusEffectDisabled()
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MacSettingsTheme.accent, lineWidth: 2)
                .padding(-3).opacity(focused && controller.canCatch ? 1 : 0))
            .onHover { controller.hovering = $0 }
            .help("Lil Bro")
            .accessibilityLabel("Lil Bro")
            .accessibilityHint("Opens a balloon to ask where something is in Settings")
        }
        .frame(width: 28, height: 32)
        .overlay(alignment: .top) { tag }
    }

    @ViewBuilder private var tag: some View {
        switch controller.bubble {
        case .tag(let text):
            LilBroTag(text: text).fixedSize().offset(y: -30)
        case .thinking:
            LilBroTag(text: nil).fixedSize().offset(y: -30)
        case .closed where controller.hovering && controller.canCatch:
            LilBroTag(text: LilBroCopy.catchMe).fixedSize().offset(y: -30)
        default:
            EmptyView()
        }
    }
}

/// His frames: about every 80-500 ms by pose. With Reduce Motion he holds
/// each pose's first frame and no clock runs.
@MainActor
struct LilBroAnimatedSprite: View {
    @ObservedObject var controller: LilBroController
    let dark: Bool

    var body: some View {
        let still = controller.reducesMotion && controller.segment == nil
        TimelineView(.animation(minimumInterval: controller.segment == nil ? 0.05 : 1.0 / 30, paused: still)) { context in
            LilBroSprite(pose: controller.shownPose,
                         elapsed: still ? 0 : max(0, context.date.timeIntervalSince(controller.poseStart)),
                         dark: dark, facingRight: controller.facingRight)
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

/// His one-line greeting over the reply field when the balloon opens.
struct LilBroGreetingLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(MacSettingsTheme.text)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(MacSettingsTheme.bgCard))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .fixedSize()
            .accessibilityLabel("Lil Bro: \(text)")
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

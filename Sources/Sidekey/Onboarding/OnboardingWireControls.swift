import SwiftUI

// The controls and pieces the wire steps share (design pass screens 04 to
// 09): the dark capsule with its white disc, the quiet link under it, the
// serif title with its lede, strokes drawn on a figure, and the slow motion
// every figure has.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md

/// The capsule's colour: calm, listening, done or not yet.
enum OnboardingWireTone: Equatable {
    case rest, active, done, warn

    var border: Color {
        switch self {
        case .rest: return Color.white.opacity(0.10)
        case .active: return OnboardingWireframeInk.roseColor.opacity(0.32)
        case .done: return OnboardingWireframeInk.greenColor.opacity(0.55)
        case .warn: return OnboardingWireframeInk.amberColor.opacity(0.55)
        }
    }

    /// The light on a figure in this tone.
    var tint: OnboardingWireframeInk.RGB {
        switch self {
        case .rest, .active: return OnboardingWireframeInk.rose
        case .done: return OnboardingWireframeInk.green
        case .warn: return OnboardingWireframeInk.amber
        }
    }

    var lineColor: Color {
        switch self {
        case .rest, .active: return OnboardingTheme.muted
        case .done: return OnboardingWireframeInk.greenColor
        case .warn: return OnboardingWireframeInk.amberColor
        }
    }
}

/// The disc at the capsule's end.
enum OnboardingWireDisc: Equatable {
    case arrow, check, finish, none
}

/// The dark capsule of the wire steps: a label and a white disc (Allow →,
/// Continue →, Finish ✓), or a status with no disc. Never a spinner.
struct OnboardingWirePill<Label: View>: View {
    let tone: OnboardingWireTone
    let disc: OnboardingWireDisc
    var isDefault = false
    var interactive = true
    let action: () -> Void
    @ViewBuilder var label: Label
    @FocusState private var focused: Bool
    @State private var hovered = false

    private var lit: Bool { hovered && interactive }

    var body: some View {
        let content = HStack(spacing: 14) {
            label
                .font(OnboardingTheme.sans(14.5, weight: .semibold))
                .foregroundColor(OnboardingTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            discView
        }
        .padding(.leading, 22)
        .padding(.trailing, disc == .none ? 22 : 6)
        .frame(minWidth: 196)
        .frame(height: 46)
        .fixedSize()
        .background(Capsule(style: .continuous)
            .fill(Color(red: 0.106, green: 0.106, blue: 0.122).opacity(lit ? 0.75 : 1)))
        .background(Capsule(style: .continuous).fill(Color.white.opacity(lit ? 0.06 : 0)))
        .overlay(Capsule(style: .continuous).strokeBorder(tone.border, lineWidth: 1))
        .overlay(Capsule(style: .continuous).strokeBorder(focused ? OnboardingTheme.accent : .clear, lineWidth: 2))
        .contentShape(Capsule())
        if interactive {
            Button(action: action) { content }
                .buttonStyle(.plain)
                // A done capsule stays bright (a disabled button would dim it).
                .focusEffectDisabled()
                .focused($focused)
                .onHover { hovered = $0 }
                .keyboardShortcut(isDefault ? .defaultAction : nil)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var discView: some View {
        switch disc {
        case .none:
            EmptyView()
        case .check:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(OnboardingWireframeInk.greenColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(OnboardingWireframeInk.greenColor.opacity(0.16)))
        case .arrow, .finish:
            Image(systemName: disc == .finish ? "checkmark" : "arrow.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.black)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.white.opacity(lit ? 0.88 : 0.96)))
        }
    }
}

extension OnboardingWirePill where Label == Text {
    init(_ title: String, tone: OnboardingWireTone = .rest, disc: OnboardingWireDisc = .arrow, isDefault: Bool = false,
         interactive: Bool = true, action: @escaping () -> Void) {
        self.init(tone: tone, disc: disc, isDefault: isDefault, interactive: interactive, action: action) { Text(title) }
    }
}

/// A quiet link under a capsule: Open System Settings ↗, Skip for now →.
struct OnboardingWireLink: View {
    let title: String
    let arrow: String
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: arrow).font(.system(size: 10, weight: .semibold))
            }
            .font(OnboardingTheme.sans(13, weight: .medium))
            .foregroundColor(hovered || focused ? OnboardingTheme.ink2 : OnboardingTheme.muted)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .overlay(Capsule(style: .continuous).strokeBorder(focused ? OnboardingTheme.accent : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($focused)
        .onHover { hovered = $0 }
    }
}

/// The serif title of a wire step and its one-line lede.
struct OnboardingWireTitle: View {
    let title: String
    var lede: String?

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(OnboardingTheme.serifItalic(31))
                .foregroundColor(OnboardingTheme.ink)
                .accessibilityAddTraits(.isHeader)
            if let lede {
                Text(lede)
                    .font(OnboardingTheme.sans(13))
                    .foregroundColor(OnboardingTheme.muted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 6)
    }
}

/// Strokes drawn flat on a figure (a key's legend): projected like its wire
/// and stroked in one weight so they read at a small size.
enum OnboardingWireStrokes {
    typealias Vec3 = OnboardingWireSolid.Vec3

    static func draw(_ strokes: [[Vec3]], in context: inout GraphicsContext, center: CGPoint, radius: Double,
                     worldZ: Double, angles: (ax: Double, ay: Double, az: Double), lift: Double = 0,
                     fade: Double, tint: OnboardingWireframeInk.RGB, width: Double = 1.35) {
        let m = OnboardingWireSolid.matrix(angles)
        let camera = OnboardingWireSolid.cameraDistance
        func project(_ v: Vec3) -> CGPoint {
            let y = v.y + lift
            let x = m[0] * v.x + m[1] * y + m[2] * v.z
            let py = m[3] * v.x + m[4] * y + m[5] * v.z
            let z = m[6] * v.x + m[7] * y + m[8] * v.z
            let k = camera / max(1.2, camera - (worldZ + z * 0.55))
            return CGPoint(x: center.x + x * k * radius, y: center.y + py * k * radius)
        }
        var path = Path()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            path.move(to: project(first))
            for v in stroke.dropFirst() { path.addLine(to: project(v)) }
        }
        let base = OnboardingWireframeInk.wire, mix = 0.45
        let color = Color(red: base.0 + (tint.0 - base.0) * mix, green: base.1 + (tint.1 - base.1) * mix,
                          blue: base.2 + (tint.2 - base.2) * mix)
        context.stroke(path, with: .color(color.opacity(0.92 * fade)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    /// The wire style every figure of these steps uses: the light glints in
    /// the step's tone.
    static func style(fade: Double, tint: OnboardingWireframeInk.RGB, strength: Double, clock: Double,
                      waveY: Double? = nil) -> OnboardingWireStyle {
        let light = (x: 0.44 + sin(clock * 0.58) * 0.14, y: -0.52 + cos(clock * 0.46) * 0.12, z: 0.72)
        return OnboardingWireStyle(fade: fade, specular: .init(rgb: tint, strength: strength, light: light, dots: true,
                                                              waveY: waveY),
                                   keyStage: true)
    }
}

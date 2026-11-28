import SwiftUI

/// Tokens of the onboarding: the editorial dark look of the former paid
/// onboarding (2026-05 to 2026-08), kept dark in every appearance because the
/// island it introduces is always dark.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
enum OnboardingTheme {
    static let canvas = CGSize(width: 960, height: 600)
    static let leftPaneWidth: CGFloat = 380

    // Surfaces
    static let bg = Color(red: 0.047, green: 0.047, blue: 0.063)
    static let surface = Color(red: 0.082, green: 0.082, blue: 0.106)
    static let surface2 = Color(red: 0.110, green: 0.110, blue: 0.141)
    static let surface3 = Color(red: 0.145, green: 0.145, blue: 0.184)

    // Text
    static let ink = Color(red: 0.961, green: 0.957, blue: 0.973)
    static let ink2 = Color(red: 0.847, green: 0.839, blue: 0.875)
    static let muted = Color(red: 0.580, green: 0.569, blue: 0.620)
    static let faint = Color(red: 0.400, green: 0.392, blue: 0.447)

    // Lines
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.14)

    // Meaning
    static let accent = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let green = Color(red: 0.302, green: 0.808, blue: 0.459)
    static let orange = Color(red: 1.0, green: 0.690, blue: 0.290)

    // The traffic lights of the pictured windows.
    static let trafficRed = Color(red: 1.0, green: 0.376, blue: 0.345)
    static let trafficYellow = Color(red: 1.0, green: 0.741, blue: 0.180)
    static let trafficGreen = Color(red: 0.157, green: 0.788, blue: 0.247)

    // Instrument Serif is bundled under Contents/Resources/Fonts and
    // registered through ATSApplicationFontsPath.
    static func serif(_ size: CGFloat) -> Font { .custom("InstrumentSerif-Regular", size: size) }
    static func serifItalic(_ size: CGFloat) -> Font { .custom("InstrumentSerif-Italic", size: size) }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A page headline: plain words, then the words that carry the page in italic
/// ("Try" + "Drop.").
struct OnboardingHeadline: View {
    let plain: String
    let italic: String
    var size: CGFloat = 44
    /// Two lines, the italic words on the second. The serif's tall line box
    /// would leave a wide gap if the text wrapped by itself.
    var stacked = false

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: -size * 0.22) {
                    Text(plain).font(OnboardingTheme.serif(size))
                    Text(italic).font(OnboardingTheme.serifItalic(size))
                }
            } else {
                Text(plain.isEmpty ? "" : plain + " ").font(OnboardingTheme.serif(size))
                    + Text(italic).font(OnboardingTheme.serifItalic(size))
            }
        }
        .foregroundColor(OnboardingTheme.ink)
        .kerning(-0.6)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(plain.isEmpty ? italic : "\(plain) \(italic)")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The white capsule of the main action; dims while it cannot be used.
struct OnboardingPrimaryButton: View {
    let title: String
    var chevron = true
    var isEnabled = true
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if chevron {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .font(OnboardingTheme.sans(13, weight: .medium))
            .foregroundColor(isEnabled ? OnboardingTheme.bg : OnboardingTheme.muted)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .fixedSize(horizontal: true, vertical: false)
            .background(Capsule(style: .continuous)
                .fill(isEnabled ? OnboardingTheme.ink.opacity(hovered ? 0.88 : 1) : OnboardingTheme.surface2))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(focused ? OnboardingTheme.accent : .clear, lineWidth: 2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .focused($focused)
        .onHover { hovered = $0 }
    }
}

/// A quiet secondary path (Skip, Set up later, I have an API key).
struct OnboardingQuietButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title)
            }
            .font(OnboardingTheme.sans(13, weight: .medium))
            .foregroundColor(hovered || focused ? OnboardingTheme.ink : OnboardingTheme.muted)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .fixedSize(horizontal: true, vertical: false)
            .background(Capsule(style: .continuous).fill(hovered ? OnboardingTheme.surface2 : .clear))
            .overlay(Capsule(style: .continuous)
                .strokeBorder(focused ? OnboardingTheme.accent : .clear, lineWidth: 2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
    }
}

/// A small outlined capsule for an action inside a card (Add a model).
struct OnboardingOutlineButton: View {
    let title: String
    let action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(OnboardingTheme.sans(12, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .fixedSize()
                .background(Capsule(style: .continuous).fill(hovered ? OnboardingTheme.surface3 : OnboardingTheme.surface2))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(focused ? OnboardingTheme.accent : OnboardingTheme.borderStrong, lineWidth: focused ? 2 : 0.75))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
    }
}

/// One keycap of a shortcut in the onboarding's own look. `held` sinks it and
/// lights it in the accent colour, the way a held key feels.
struct OnboardingKeycaps: View {
    let contents: [KeycapContent]
    var held = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                Group {
                    switch content {
                    case .text(let value):
                        Text(value).font(.system(size: 12, weight: .semibold))
                    case .symbol(let name, _):
                        Image(systemName: name).font(.system(size: 10, weight: .semibold))
                    case .prefixedGlyph(let prefix, let glyph, _):
                        HStack(spacing: 3) {
                            Text(prefix).font(.system(size: 8, weight: .medium)).opacity(0.85)
                            Text(glyph).font(.system(size: 12, weight: .semibold))
                        }
                    }
                }
                .foregroundColor(OnboardingTheme.ink)
                .frame(minWidth: 22, minHeight: 22)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(held ? OnboardingTheme.accent.opacity(0.22) : OnboardingTheme.surface))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(held ? OnboardingTheme.accent.opacity(0.7) : OnboardingTheme.borderStrong,
                                  lineWidth: held ? 1 : 0.5))
                .offset(y: held ? 1.5 : 0)
                .shadow(color: held ? OnboardingTheme.accent.opacity(0.45) : .clear, radius: held ? 8 : 0)
            }
        }
        .animation(.easeOut(duration: 0.25), value: held)
        .accessibilityHidden(true)
    }
}

/// The right half of every page: a dark stage lit from one corner.
struct OnboardingStageBackdrop: View {
    var tint: Color = OnboardingTheme.accent
    var corner: UnitPoint = UnitPoint(x: 0.8, y: 0.12)

    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: tint.opacity(0.26), location: 0),
                            .init(color: .clear, location: 0.62)
                        ]),
                        center: corner, startRadius: 0, endRadius: 560)
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.03), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.15, y: 0.9), startRadius: 0, endRadius: 520)
                }
            )
    }
}

/// A pictured macOS window: traffic lights, a mono caption and a body.
struct OnboardingMockWindow<Accessory: View, Content: View>: View {
    let caption: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(OnboardingTheme.trafficRed).frame(width: 9, height: 9)
                Circle().fill(OnboardingTheme.trafficYellow).frame(width: 9, height: 9)
                Circle().fill(OnboardingTheme.trafficGreen).frame(width: 9, height: 9)
                Text(caption)
                    .font(OnboardingTheme.mono(10, weight: .medium))
                    .tracking(0.6)
                    .foregroundColor(OnboardingTheme.faint)
                    .padding(.leading, 8)
                Spacer(minLength: 0)
                accessory
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(OnboardingTheme.surface2)
            .overlay(Rectangle().fill(OnboardingTheme.border).frame(height: 0.5), alignment: .bottom)
            content
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(OnboardingTheme.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(OnboardingTheme.border, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.40), radius: 30, x: 0, y: 20)
        .shadow(color: .black.opacity(0.20), radius: 8, x: 0, y: 4)
    }
}

/// A short status under a stage: an icon in its colour and one sentence.
struct OnboardingStageStatus: View {
    enum Tone { case success, warning, neutral }
    let tone: Tone
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundColor(color).accessibilityHidden(true)
            Text(text)
                .font(OnboardingTheme.sans(12.5))
                .foregroundColor(tone == .neutral ? OnboardingTheme.muted : OnboardingTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tone {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .neutral: return "arrow.down.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .success: return OnboardingTheme.green
        case .warning: return OnboardingTheme.orange
        case .neutral: return OnboardingTheme.muted
        }
    }
}

/// A thin progress line for the model download. `indeterminate` (the
/// model's preparation, which has no progress signal) sweeps a highlight
/// along the track instead of a fill; with Reduce Motion it rests.
struct OnboardingProgressLine: View {
    let fraction: Double
    var indeterminate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                if indeterminate {
                    Capsule().fill(LinearGradient(
                        colors: [OnboardingTheme.accent.opacity(0), OnboardingTheme.accent, OnboardingTheme.accent.opacity(0)],
                        startPoint: .leading, endPoint: .trailing))
                        .frame(width: 70)
                        .offset(x: reduceMotion ? 0 : (sweep ? proxy.size.width : -70))
                } else {
                    Capsule().fill(LinearGradient(colors: [OnboardingTheme.accent, Color(red: 0.70, green: 0.60, blue: 1)],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 3)
        .animation(.easeOut(duration: 0.3), value: fraction)
        .onAppear {
            guard indeterminate, !reduceMotion else { return }
            withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

/// The onboarding's dark selection label with one down chevron (language).
struct OnboardingMenuLabel: View {
    let title: String
    var minWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(OnboardingTheme.sans(12.5, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(OnboardingTheme.muted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 11)
        .frame(minWidth: minWidth, minHeight: 28, maxHeight: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OnboardingTheme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(OnboardingTheme.borderStrong, lineWidth: 0.75))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize()
    }
}

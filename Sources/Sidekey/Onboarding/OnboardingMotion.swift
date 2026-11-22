import SwiftUI

// MARK: - Compact canvas and machined surfaces

extension OnboardingTheme {
    /// The compact single-pane onboarding window.
    static let compactCanvas = CGSize(width: 520, height: 440)
    static let compactHeaderHeight: CGFloat = 44
    static let compactFooterHeight: CGFloat = 42
    static let compactHorizontalInset: CGFloat = 28

    /// A 1 pt top-edge highlight that gives raised dark cards depth without glow.
    static let specularRim = Color.white.opacity(0.075)
    /// The deep recessed fill of key fields and the dictation well.
    static let recessed = Color(red: 0.035, green: 0.035, blue: 0.048)
}

// MARK: - Motion

/// Motion tokens of the onboarding. Springs are near-critically damped
/// (dampingFraction >= 0.80): mass and a precise stop, no wobble. Hover and
/// press never change geometry; nothing moves at rest; every spatial movement
/// collapses under Reduce Motion.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
enum OnboardingMotion {
    /// Surface response on pointer-down (80 ms).
    static let pressIn = Animation.timingCurve(0.2, 0.0, 0.0, 1.0, duration: 0.08)
    /// Release, or the pointer leaving the target (130 ms).
    static let pressRelease = Animation.timingCurve(0.2, 0.0, 0.0, 1.0, duration: 0.13)
    /// A keycap returning after release.
    static let keyReturn = Animation.spring(response: 0.18, dampingFraction: 0.80, blendDuration: 0)
    /// A chosen card, row or provider tab locking into place.
    static let detent = Animation.spring(response: 0.24, dampingFraction: 0.86, blendDuration: 0)
    /// A checkmark drawing itself.
    static let checkDraw = Animation.timingCurve(0.18, 0.90, 0.32, 1.0, duration: 0.19)
    /// Key slot idle → checking → accepted, permission Allow → Waiting → Granted.
    static let slotMorph = Animation.spring(response: 0.30, dampingFraction: 0.88, blendDuration: 0)
    /// The horizontal glide between steps.
    /// The page's dissolve while the key flies from step 1 to step 2; about
    /// as long as the key's own spring takes to settle.
    static let keyFlow = Animation.spring(response: 0.55, dampingFraction: 1.0)
    static let stepGlide = Animation.spring(response: 0.38, dampingFraction: 0.90, blendDuration: 0.06)
    /// Opacity alone, with the glide or under Reduce Motion.
    static let crossDissolve = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.16)
    /// Dictated words settling on the note.
    static let inkSettle = Animation.timingCurve(0.16, 1.0, 0.30, 1.0, duration: 0.22)
    /// The island wing widening while Drop listens.
    static let wingExpand = Animation.spring(response: 0.28, dampingFraction: 0.86, blendDuration: 0)
    /// The island docking to the card's top edge on the last step.
    static let notchDock = Animation.spring(response: 0.46, dampingFraction: 0.88, blendDuration: 0)

    /// `nil` (or a short fade when `allowFade`) under Reduce Motion.
    static func resolve(_ animation: Animation, reduceMotion: Bool, allowFade: Bool = false) -> Animation? {
        guard !reduceMotion else { return allowFade ? .linear(duration: 0.14) : nil }
        return animation
    }
}

extension AnyTransition {
    /// The next step enters from +22 pt (Back: -22 pt) while the old one leaves
    /// 16 pt the other way; opacity only under Reduce Motion.
    /// Steps 1 and 2 dissolve under the flying key: the old page leaves
    /// quickly, the new one settles in a beat later, so the two titles barely
    /// overlap.
    static func onboardingKeyFlow(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(OnboardingMotion.keyFlow.delay(0.10)),
            removal: .opacity.animation(.spring(response: 0.22, dampingFraction: 1.0)))
    }

    static func onboardingStep(direction: OnboardingNavDirection, reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        let enter = CGFloat(direction.rawValue) * 22
        let exit = CGFloat(direction.rawValue) * -16
        return .asymmetric(insertion: .offset(x: enter).combined(with: .opacity),
                           removal: .offset(x: exit).combined(with: .opacity))
    }
}

/// A damped horizontal impulse when a key is refused; none under Reduce
/// Motion, where the border, icon and text carry the meaning.
struct OnboardingShakeEffect: GeometryEffect {
    var trigger: CGFloat
    var reduceMotion: Bool

    var animatableData: CGFloat {
        get { trigger }
        set { trigger = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard !reduceMotion else { return ProjectionTransform(.identity) }
        let progress = trigger - floor(trigger)
        let displacement = sin(progress * .pi * 4) * 5.5 * (1 - progress)
        return ProjectionTransform(CGAffineTransform(translationX: displacement, y: 0))
    }
}

/// A raised card: fill by state, a 1 pt specular top edge and a state border.
struct OnboardingElevatedSurface: ViewModifier {
    var cornerRadius: CGFloat = 13
    var isSelected = false
    var isConfirmed = false
    var isHovered = false
    var isPressed = false

    private var fill: Color {
        if isPressed { return OnboardingTheme.surface3 }
        if isSelected { return OnboardingTheme.accent.opacity(0.10) }
        if isConfirmed { return OnboardingTheme.green.opacity(0.07) }
        if isHovered { return OnboardingTheme.surface2 }
        return OnboardingTheme.surface
    }

    private var border: Color {
        if isConfirmed { return OnboardingTheme.green.opacity(0.65) }
        if isSelected { return OnboardingTheme.accent.opacity(0.82) }
        if isHovered { return OnboardingTheme.borderStrong }
        return OnboardingTheme.border
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(LinearGradient(colors: [OnboardingTheme.specularRim, .clear],
                                                       startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .overlay(shape.strokeBorder(border, lineWidth: isSelected || isConfirmed ? 1.2 : 0.75))
    }
}

extension View {
    func onboardingElevatedCard(cornerRadius: CGFloat = 13, isSelected: Bool = false, isConfirmed: Bool = false,
                                isHovered: Bool = false, isPressed: Bool = false) -> some View {
        modifier(OnboardingElevatedSurface(cornerRadius: cornerRadius, isSelected: isSelected,
                                           isConfirmed: isConfirmed, isHovered: isHovered, isPressed: isPressed))
    }

    /// A recessed slot: the deep fill with a thin border.
    func onboardingRecessed(cornerRadius: CGFloat = 11, border: Color = OnboardingTheme.border,
                            lineWidth: CGFloat = 0.75) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(shape.fill(OnboardingTheme.recessed))
            .overlay(shape.strokeBorder(border, lineWidth: lineWidth))
    }
}

/// A press-aware plain style: hands the pressed state to its label.
struct OnboardingPressStyle<Label: View>: ButtonStyle {
    let label: (Bool) -> Label
    func makeBody(configuration: Configuration) -> some View { label(configuration.isPressed) }
}

/// A checkmark drawn by its stroke.
struct OnboardingCheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

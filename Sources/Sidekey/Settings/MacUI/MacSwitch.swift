import SwiftUI

/// Native adaptation of the supplied toggle-switch-glass reference.
// WHY: docs/DESIGN.md — Settings appearance and switches.
struct MacSwitch: View {
    enum Size {
        case regular, compact

        var track: CGSize { self == .regular ? CGSize(width: 60, height: 33) : CGSize(width: 30, height: 18) }
        var thumb: CGSize { self == .regular ? CGSize(width: 35, height: 28) : CGSize(width: 14, height: 14) }
        var inset: CGFloat { (track.height - thumb.height) / 2 }
        var travel: CGFloat { track.width - thumb.width - 2 * inset }
    }

    @Binding var isOn: Bool
    var isEnabled: Bool = true
    var size: Size = .regular
    var label: String = "Switch"

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(GlassSwitchStyle(size: size))
            .disabled(!isEnabled)
            .lilBroControl(label)
            .fixedSize()
    }
}

enum MacSwitchInteraction {
    static func destination(startOn: Bool, currentOn: Bool, translation: CGFloat, predictedTranslation: CGFloat, travel: CGFloat) -> Bool {
        // A live preference update wins over a gesture started on older state.
        guard currentOn == startOn else { return currentOn }
        let start = startOn ? travel : 0
        let projection = predictedTranslation - translation
        if abs(projection) > travel / 2 { return projection > 0 }
        return start + translation > travel / 2
    }
}

private struct GlassSwitchStyle: ToggleStyle {
    let size: MacSwitch.Size
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var translation: CGFloat? = nil
    @State private var startOn: Bool?
    @State private var cancelled = false
    @State private var hovered = false
    @FocusState private var focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        let dragging = translation != nil
        let position = min(size.travel, max(0, ((startOn ?? configuration.isOn) ? size.travel : 0) + (translation ?? 0)))
        Button {
            configuration.isOn.toggle()
        } label: {
            Color.clear.frame(width: size.track.width, height: size.track.height)
        }
        .buttonStyle(GlassSwitchButtonStyle(size: size, isOn: configuration.isOn, position: dragging && !cancelled ? position : nil,
                                          dragging: dragging && !cancelled, focused: focused))
        .overlay {
            Capsule().fill(MacSettingsTheme.text.opacity(isEnabled && hovered ? 0.10 : 0))
                .allowsHitTesting(false)
        }
        .onHover { hovered = $0 }
        .focused($focused)
        .highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .updating($translation) { value, state, _ in
                    guard isEnabled else { return }
                    state = value.translation.width
                }
                .onChanged { _ in
                    guard isEnabled else { return }
                    if startOn == nil {
                        startOn = configuration.isOn
                        cancelled = false
                        focused = true // Escape must reach a drag started with focus in another field.
                    }
                }
                .onEnded { value in
                    if isEnabled && !cancelled {
                        configuration.isOn = MacSwitchInteraction.destination(
                            startOn: startOn ?? configuration.isOn,
                            currentOn: configuration.isOn,
                            translation: value.translation.width,
                            predictedTranslation: value.predictedEndTranslation.width, travel: size.travel)
                    }
                    startOn = nil
                    cancelled = false
                }
        )
        .onChange(of: dragging) { _, active in
            if !active { startOn = nil }
        }
        .onChange(of: configuration.isOn) { _, value in
            if let startOn, dragging && value != startOn { cancelled = true }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { cancelled = true }
        }
        .onExitCommand { cancelled = true }
        .onMoveCommand { direction in
            guard isEnabled else { return }
            if direction == .left { configuration.isOn = false }
            if direction == .right { configuration.isOn = true }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.88), value: configuration.isOn)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .disabled(!isEnabled)
        }
    }
}

private struct GlassSwitchButtonStyle: ButtonStyle {
    let size: MacSwitch.Size
    let isOn: Bool
    let position: CGFloat?
    let dragging: Bool
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeBody(configuration: Configuration) -> some View {
        RoundedRectangle(cornerRadius: size.track.height / 2, style: .continuous)
            .fill(isOn ? (size == .compact ? MacSettingsTheme.accentFill : MacSettingsTheme.switchOn) : MacSettingsTheme.switchOff)
            .overlay {
                RoundedRectangle(cornerRadius: size.track.height / 2, style: .continuous)
                    .strokeBorder(MacSettingsTheme.switchBorder, lineWidth: 0.75)
            }
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                thumb
                    .frame(width: size.thumb.width, height: size.thumb.height)
                    .shadow(color: .black.opacity(dragging ? 0.24 : 0.16), radius: dragging ? 5 : 2, y: 2)
                    .scaleEffect(reduceMotion ? 1 : (dragging ? 1.1 : (configuration.isPressed ? 1.04 : 1)))
                    .offset(x: size.inset + (position ?? (isOn ? size.travel : 0)))
            }
            .frame(width: size.track.width, height: size.track.height)
            .contentShape(Capsule())
            .overlay {
                Capsule().strokeBorder(focused ? MacSettingsTheme.accent : .clear, lineWidth: 2)
                    .padding(-3)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: dragging)
    }

    @ViewBuilder private var thumb: some View {
        if reduceTransparency {
            Capsule().fill(.white)
        } else {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                Capsule().fill(.white.opacity(dragging ? 0.55 : 0.9))
                    .glassEffect(.regular, in: Capsule())
            } else {
                fallbackThumb
            }
            #else
            fallbackThumb
            #endif
        }
    }

    private var fallbackThumb: some View {
        Capsule()
            .fill(.white.opacity(dragging ? 0.8 : 1))
            .overlay {
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.8), .clear, .black.opacity(0.07)],
                                               startPoint: .top, endPoint: .bottom))
            }
            .overlay { Capsule().strokeBorder(.white.opacity(0.65), lineWidth: 0.5) }
    }
}

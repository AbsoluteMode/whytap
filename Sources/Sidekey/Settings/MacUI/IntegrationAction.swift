import SwiftUI

/// The full button rectangle responds to hover/press/focus; disabled stays inert.
struct IntegrationAction: View {
    let title: String
    var primary = false
    var enabled = true
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(title, action: action)
            .buttonStyle(IntegrationButtonStyle(primary: primary, focused: focused))
            .focused($focused)
            .disabled(!enabled)
            .lilBroControl(title)
    }
}

struct IntegrationButtonStyle: ButtonStyle {
    let primary: Bool
    let focused: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        IntegrationControlSurface(primary: primary, focused: focused, enabled: enabled,
            hovering: hovering, pressed: configuration.isPressed, reduceMotion: reduceMotion) { configuration.label }
            .onHover { hovering = enabled && $0 }
    }
}

/// Shared rendering for actual button/link states and offscreen visual fixtures.
struct IntegrationControlSurface<Label: View>: View {
    let primary: Bool
    let focused: Bool
    let enabled: Bool
    let hovering: Bool
    let pressed: Bool
    let reduceMotion: Bool
    @ViewBuilder let label: () -> Label

    var body: some View {
        let active = enabled && hovering
        let pressed = enabled && pressed
        label()
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Color.white : MacSettingsTheme.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(primary ? (pressed ? Color(hexCSS: "#004B9E") : active ? Color(hexCSS: "#0055B5") : MacSettingsTheme.accentFill)
                        : pressed ? MacSettingsTheme.accent.opacity(0.25) : active ? MacSettingsTheme.hover : MacSettingsTheme.controlBg,
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                pressed ? MacSettingsTheme.accent : active ? MacSettingsTheme.text2 : .clear, lineWidth: 0.75))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(focused && enabled ? MacSettingsTheme.accent : .clear, lineWidth: 2).padding(-3))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .opacity(enabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: active)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
    }
}

struct IntegrationLink: View {
    let title: String
    let destination: URL
    @FocusState private var focused: Bool

    var body: some View {
        Link(title, destination: destination)
            .buttonStyle(IntegrationButtonStyle(primary: false, focused: focused))
            .focused($focused)
    }
}

import SwiftUI

/// Local to Keys & models: feedback covers the full hit target, including plain
/// provider tiles and rows. Disabled controls never react to a retained hover.
struct APIModelFeedbackStyle: ButtonStyle {
    var cornerRadius: CGFloat = 6
    var focused = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                APIModelFeedbackOverlay(cornerRadius: cornerRadius, hovered: hovered,
                                        pressed: configuration.isPressed, focused: focused, enabled: enabled)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .opacity(enabled ? 1 : 0.42)
            .onHover { hovered = $0 }
    }
}

/// Keeps the existing action geometry and colors without changing shared
/// MacButton behavior in unrelated settings panels.
struct APIModelAction: View {
    let title: String
    var style: MacButton.Style = .default
    var isEnabled = true
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 13).padding(.vertical, 5)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
        }
        .lilBroControl(title)
        .buttonStyle(APIModelFeedbackStyle(focused: focused))
        .disabled(!isEnabled).focused($focused)
    }
    private var foreground: Color {
        switch style {
        case .primary: return .white
        case .danger: return MacSettingsTheme.red
        case .tinted, .ghost: return MacSettingsTheme.accent
        case .default: return MacSettingsTheme.text
        }
    }
    private var background: Color {
        switch style {
        case .primary: return MacSettingsTheme.accentFill
        case .tinted: return MacSettingsTheme.accent.opacity(0.06)
        case .danger, .ghost: return .clear
        case .default: return MacSettingsTheme.controlBg
        }
    }
}

/// Shared drawing for live control states and the offscreen state matrix.
struct APIModelFeedbackOverlay: View {
    var cornerRadius: CGFloat = 6
    let hovered: Bool
    let pressed: Bool
    let focused: Bool
    let enabled: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(MacSettingsTheme.text.opacity(enabled ? (pressed ? 0.08 : (hovered ? 0.04 : 0)) : 0))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(enabled && focused ? MacSettingsTheme.accent : .clear, lineWidth: 1.5)
            }
            .allowsHitTesting(false)
    }
}

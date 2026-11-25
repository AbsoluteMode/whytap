import SwiftUI

/// Button with the mockup's `.mac-btn` style variants.
struct MacButton: View {
    enum Style: Equatable {
        case primary
        case tinted
        case danger
        case ghost
        case `default`
    }

    let title: String
    var style: Style = .default
    var isEnabled: Bool = true
    let action: () -> Void
    @Environment(\.isEnabled) private var parentEnabled
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .foregroundStyle(fg)
        }
        .buttonStyle(MacButtonInteractionStyle(background: bg,
                                               highlight: style == .primary ? .black : MacSettingsTheme.text,
                                               outline: style == .ghost || style == .tinted || style == .danger ? fg : nil,
                                               focused: focused))
        .focused($focused)
        .disabled(!isEnabled)
        .opacity(isEnabled && parentEnabled ? 1 : 0.42)
    }

    private var fg: Color {
        switch style {
        case .primary: return .white
        case .danger: return MacSettingsTheme.red
        case .tinted, .ghost: return MacSettingsTheme.accent
        case .default: return MacSettingsTheme.text
        }
    }

    private var bg: Color {
        switch style {
        case .primary: return MacSettingsTheme.accentFill
        case .tinted: return MacSettingsTheme.accent.opacity(0.06)
        case .ghost, .danger: return .clear
        case .default: return MacSettingsTheme.controlBg
        }
    }
}

/// Keep the existing control geometry and colors while making every live
/// hit area respond to the pointer, press and keyboard focus.
// WHY: docs/DESIGN.md — Backup: automatic synchronization.
struct MacButtonInteractionStyle: ButtonStyle {
    var background: Color = .clear
    var highlight: Color = MacSettingsTheme.text
    var outline: Color? = nil
    var focused = false
    var cornerRadius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, background: background, highlight: highlight,
                outline: outline, focused: focused, cornerRadius: cornerRadius)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let background: Color
        let highlight: Color
        let outline: Color?
        let focused: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background {
                    MacButtonInteractionSurface(background: background, highlight: highlight,
                                                outline: outline,
                                                hovered: isHovered, pressed: configuration.isPressed,
                                                focused: focused, enabled: isEnabled, cornerRadius: cornerRadius)
                        .allowsHitTesting(false)
                }
                .onHover { isHovered = $0 }
        }
    }
}

struct MacButtonInteractionSurface: View {
    var background: Color
    var highlight: Color
    var outline: Color? = nil
    var hovered: Bool
    var pressed: Bool
    var focused: Bool
    var enabled: Bool
    var cornerRadius: CGFloat = 6

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(background)
            .overlay {
                shape.fill(highlight.opacity(!enabled || outline != nil ? 0 : pressed ? 0.18 : hovered ? 0.10 : 0))
            }
            .overlay {
                // Colored labels retain their existing contrast. Brightening
                // their dark background would make blue/red text harder to read.
                shape.stroke((outline ?? .clear).opacity(!enabled ? 0 : pressed ? 0.85 : hovered ? 0.5 : 0),
                             lineWidth: pressed ? 2 : 1)
            }
            .overlay {
                shape.stroke(enabled && focused ? MacSettingsTheme.accent : .clear, lineWidth: 2)
                    .padding(-3)
            }
    }
}

import SwiftUI

/// Button with the mockup's `.mac-btn` style variants.
struct MacButton: View {
    enum Style {
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

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 5)
                .foregroundStyle(fg)
                .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
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
        case .primary: return MacSettingsTheme.accent
        case .tinted: return MacSettingsTheme.accent.opacity(0.16)
        case .ghost: return .clear
        case .default, .danger: return MacSettingsTheme.controlBg
        }
    }
}

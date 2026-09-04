import SwiftUI

/// iOS-style toggle (38×22), accent fill when on. Mirrors the mockup's `.mac-switch`
/// and replaces the old textual ON/OFF switch.
struct MacSwitch: View {
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isOn ? MacSettingsTheme.accent : Color(hexCSS: "#787880").opacity(0.42))
                .frame(width: 38, height: 22)
                .overlay(
                    Circle()
                        .fill(.white)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
                        .padding(2)
                        .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

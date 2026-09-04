import SwiftUI

/// Text or secure field mirroring the mockup's `.mac-field input` (field-bg + focus ring).
struct MacField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var monospaced: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: monospaced ? 12 : 13, weight: .regular, design: monospaced ? .monospaced : .default))
        .foregroundStyle(MacSettingsTheme.text)
        .focused($focused)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    focused ? MacSettingsTheme.accent.opacity(0.6) : Color.white.opacity(0.12),
                    lineWidth: focused ? 2 : 0.5
                )
        )
    }
}

import SwiftUI

/// Small status pill, mirroring the mockup's `.mac-pill` tones.
struct MacPill: View {
    enum Tone { case neutral, green, red, orange, blue }

    let text: String
    var tone: Tone = .neutral
    var showsDot: Bool = false

    private var fg: Color {
        switch tone {
        case .neutral: return MacSettingsTheme.text2
        case .green: return MacSettingsTheme.green
        case .red: return MacSettingsTheme.red
        case .orange: return MacSettingsTheme.orange
        case .blue: return MacSettingsTheme.accent
        }
    }

    private var bg: Color {
        tone == .neutral ? Color(hexCSS: "#787880").opacity(0.16) : fg.opacity(0.16)
    }

    var body: some View {
        HStack(spacing: 5) {
            if showsDot {
                Circle().fill(fg).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 9)
        .padding(.vertical, 2.5)
        .background(bg, in: Capsule())
    }
}

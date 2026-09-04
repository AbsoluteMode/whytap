import SwiftUI

/// Informational banner with tone, mirroring the mockup's `.mac-banner` (info/warn/privacy).
struct MacBanner: View {
    enum Tone {
        case info
        case warn
        case privacy
    }

    var tone: Tone = .info
    let systemImage: String
    var title: String?
    let text: String

    private var accent: Color {
        switch tone {
        case .info: return MacSettingsTheme.accent
        case .warn: return MacSettingsTheme.orange
        case .privacy: return MacSettingsTheme.green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(accent)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                }
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MacSettingsTheme.bgCard)
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accent.opacity(0.10))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 0.5)
        )
    }
}

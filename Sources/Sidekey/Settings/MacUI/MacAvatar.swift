import SwiftUI
import AppKit

/// Round gradient avatar showing the user's initials, mirroring the mockup's `.acct-avatar`.
struct MacAvatar: View {
    let email: String?
    var size: CGFloat = 40

    /// Initials for the avatar: two letters from the email local part
    /// (split on `. - _ space`), or the first two characters, else "?".
    static func initials(from email: String?) -> String {
        guard let local = email?.split(separator: "@").first.map(String.init),
              !local.isEmpty else { return "?" }
        let parts = local.split(whereSeparator: { ".-_ ".contains($0) }).filter { !$0.isEmpty }
        if parts.count >= 2 {
            return (parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(local.prefix(2)).uppercased()
    }

    var body: some View {
        Text(Self.initials(from: email))
            .font(.system(size: size * 0.35, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [
                        MacSettingsTheme.accent,
                        MacSettingsTheme.accent.blended(with: Color(hexCSS: "#b06bff")),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.30), lineWidth: 0.5))
    }
}

extension Color {
    /// Midpoint sRGB blend of two colors. Used for gradient end-stops.
    func blended(with other: Color) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .clear
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .clear
        return Color(
            .sRGB,
            red: Double(a.redComponent + b.redComponent) / 2,
            green: Double(a.greenComponent + b.greenComponent) / 2,
            blue: Double(a.blueComponent + b.blueComponent) / 2,
            opacity: 1
        )
    }
}

import SwiftUI
import AppKit

extension Color {
    /// Parse a CSS hex string ("#rgb", "#rrggbb", with or without '#') into a Color.
    init(hexCSS raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = Double((v & 0xFF0000) >> 16) / 255.0
        let g = Double((v & 0x00FF00) >> 8) / 255.0
        let b = Double(v & 0x0000FF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

/// macOS System Settings dark-theme tokens, ported 1:1 from the mockup's `.win.dark`.
///
/// Alpha from the mockup's `rgba(...)` surfaces is applied at the call site via
/// `.opacity(...)` so the base hex stays readable here.
enum MacSettingsTheme {
    // accent
    static let accent = Color(hexCSS: "#007aff")
    static let accentPress = Color(hexCSS: "#0067d6")

    // radii
    static let radiusCard: CGFloat = 12
    static let radiusWin: CGFloat = 18

    // surfaces
    static let bgContent = Color(hexCSS: "#1c1c1f").opacity(0.74)
    static let bgCard = Color(hexCSS: "#404045").opacity(0.58)
    static let bgSidebar = Color(hexCSS: "#28282d").opacity(0.46)
    static let bgTitlebar = Color(hexCSS: "#303035").opacity(0.50)

    // text
    static let text = Color(hexCSS: "#f2f2f4")
    static let text2 = Color.white.opacity(0.58)
    static let text3 = Color.white.opacity(0.32)

    // separators / hover
    static let sep = Color.white.opacity(0.09)
    static let sepStrong = Color.white.opacity(0.13)
    static let hover = Color.white.opacity(0.07)
    /// Neutral grey fill for list-row selection (calm, not accent-blue).
    /// SwiftUI mirror of `MacSettingsTheme.NS.selection`.
    static let selection = Color.white.opacity(0.14)

    // controls
    static let segBg = Color(hexCSS: "#787880").opacity(0.28)
    static let segSel = Color(hexCSS: "#76767c").opacity(0.85)
    static let controlBg = Color(hexCSS: "#5e5e63").opacity(0.60)
    static let fieldBg = Color.black.opacity(0.26)

    // status pills
    static let green = Color(hexCSS: "#4cd964")
    static let red = Color(hexCSS: "#ff6961")
    static let orange = Color(hexCSS: "#ffb340")
}

extension MacSettingsTheme {
    /// AppKit (`NSColor`) mirrors of the tokens, for chrome that is not SwiftUI —
    /// the Meetings sidebar `NSTableView` and tab bar.
    enum NS {
        static let accent = NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1.0)    // #007aff
        /// Neutral grey fill for Notes list-row selection (calm, not accent-blue).
        static let selection = NSColor(white: 1.0, alpha: 0.14)
        static let text = NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1.0)  // #f2f2f4
        static let text2 = NSColor(white: 1.0, alpha: 0.58)
        static let sep = NSColor(white: 1.0, alpha: 0.09)
        static let hover = NSColor(white: 1.0, alpha: 0.07)
    }
}

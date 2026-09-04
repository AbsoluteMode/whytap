import SwiftUI

/// Design tokens for the native SwiftUI onboarding. Mirrors the
/// editorial dark palette from the JSX draft
/// (`Sidekey Onboarding source/styles.css`, `.style-dark`) so the
/// native flow stays visually 1:1 with the reference.
enum OnboardingTheme {
    // Window canvas — matches draft's 960x600 mock window
    static let canvasWidth: CGFloat = 960
    static let canvasHeight: CGFloat = 600
    static let leftPaneWidth: CGFloat = 380

    // Surfaces (dark only — Sidekey has no light theme)
    static let bg = Color(red: 0.047, green: 0.047, blue: 0.063)
    static let surface = Color(red: 0.082, green: 0.082, blue: 0.106)
    static let surface2 = Color(red: 0.110, green: 0.110, blue: 0.141)
    static let surface3 = Color(red: 0.145, green: 0.145, blue: 0.184)

    // Text
    static let ink = Color(red: 0.961, green: 0.957, blue: 0.973)
    static let ink2 = Color(red: 0.847, green: 0.839, blue: 0.875)
    static let muted = Color(red: 0.541, green: 0.529, blue: 0.580)
    static let faint = Color(red: 0.302, green: 0.294, blue: 0.345)

    // Borders
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.14)

    // Accent (purple)
    static let accent = Color(red: 0.545, green: 0.361, blue: 0.965)

    // Traffic-light reference colours (kept for fake windows in mocks)
    static let trafficRed = Color(red: 1.0, green: 0.376, blue: 0.345)
    static let trafficYellow = Color(red: 1.0, green: 0.741, blue: 0.180)
    static let trafficGreen = Color(red: 0.157, green: 0.788, blue: 0.247)

    // Fonts. Instrument Serif is bundled under Contents/Resources/Fonts/
    // and registered via Info.plist `ATSApplicationFontsPath = Fonts`.
    // The PostScript names below match the .ttf metadata; if either
    // family fails to register at launch SwiftUI falls back to the
    // system serif silently — visually close, never crashes.
    static func serif(_ size: CGFloat) -> Font {
        Font.custom("InstrumentSerif-Regular", size: size)
    }

    static func serifItalic(_ size: CGFloat) -> Font {
        Font.custom("InstrumentSerif-Italic", size: size)
    }

    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }
}

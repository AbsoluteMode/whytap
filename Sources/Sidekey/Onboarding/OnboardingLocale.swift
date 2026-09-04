import SwiftUI

/// The UI language of the onboarding flow (ROO-261). This is the
/// *interface* language of the walkthrough — distinct from the
/// transcription/agent language picked on `OnboardingLanguageScreen`
/// (`PrivacyPreferences.selectedLanguage`). The two are intentionally
/// decoupled: a user may run the tour in Russian yet dictate in English,
/// or vice-versa.
///
/// English is always the default. We do NOT auto-detect the system
/// locale — a deliberate product decision so the first-run experience is
/// predictable and the toggle is the only thing that changes language.
enum OnboardingUILanguage: String, CaseIterable, Hashable {
    case en
    case ru

    /// Label shown inside the EN/RU toggle. Each language names itself in
    /// its own script so the inactive segment is still recognisable.
    var toggleLabel: String {
        switch self {
        case .en: return "EN"
        case .ru: return "RU"
        }
    }
}

/// Observable holder for the onboarding UI language. Injected into the
/// flow via `.environmentObject(_:)` so every step reads the same
/// `@Published` value and re-renders the instant the toggle flips — no
/// app relaunch (runtime dictionary approach, not system `.lproj`).
///
/// The selection persists under a dedicated UserDefaults key so a
/// resumed onboarding (the flow supports resume) reopens in the same
/// language.
@MainActor
final class OnboardingLocale: ObservableObject {
    /// UserDefaults key. Namespaced under `sidekey.onboarding.*` to sit
    /// alongside the existing onboarding resume keys
    /// (`OnboardingResumeStore`), and kept separate from the
    /// transcription-language key (`sidekey.preferences.selectedLanguage`).
    static let defaultsKey = "sidekey.onboarding.uiLanguage"

    @Published var language: OnboardingUILanguage {
        didSet {
            guard oldValue != language else { return }
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default is ALWAYS English; an absent or unrecognised stored
        // value falls back to English rather than crashing or guessing.
        if let raw = defaults.string(forKey: Self.defaultsKey),
           let stored = OnboardingUILanguage(rawValue: raw) {
            self.language = stored
        } else {
            self.language = .en
        }
    }
}

extension OnboardingTheme {
    /// Upright serif headline font for the active onboarding UI language.
    /// English keeps Instrument Serif; Russian uses Playfair Display
    /// (Instrument Serif has zero Cyrillic glyphs). Both are bundled OFL
    /// statics registered the same way (Info.plist `ATSApplicationFontsPath`
    /// in the app, `CTFontManagerRegisterFontsForURL` in the preview).
    static func serif(_ size: CGFloat, language: OnboardingUILanguage) -> Font {
        switch language {
        case .en: return serif(size)
        case .ru: return Font.custom("PlayfairDisplay-Regular", size: size)
        }
    }

    /// Italic serif headline font for the active onboarding UI language.
    static func serifItalic(_ size: CGFloat, language: OnboardingUILanguage) -> Font {
        switch language {
        case .en: return serifItalic(size)
        case .ru: return Font.custom("PlayfairDisplay-Italic", size: size)
        }
    }
}

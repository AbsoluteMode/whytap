import SwiftUI

// MARK: - Copy provider (ROO-261)

/// Localized copy for the "Choose your language" transcription-language
/// picker screen. Only the screen's *chrome* is routed through this
/// provider — the language display names themselves come from
/// `AppLanguage` and stay in their own native script regardless of the
/// onboarding UI language (the user may run the tour in Russian yet pick
/// English transcription, or vice-versa). The search field's example
/// text already includes a native sample ("Русский") and the "+N"
/// overflow badge and country flags are not localized either.
///
/// The "Whytap" brand word stays English in both locales.
protocol OnboardingLanguageCopy {
    /// Headline split into an upright serif lead-in and an italic serif
    /// tail (e.g. "Choose your " + "language."). The view composes the
    /// two with the language-aware serif fonts.
    var headlineLead: String { get }
    var headlineTail: String { get }
    var subtitle: String { get }
    /// Inline red hint shown when the Pick card is engaged but no
    /// language was picked yet.
    var pickToContinue: String { get }
    var autoDetectTitle: String { get }
    var autoDetectDesc: String { get }
    var pickALanguage: String { get }
    var recommendedBadge: String { get }
    var pickAccuracyNote: String { get }
    var back: String { get }
    var ccontinue: String { get }
    /// Variant-popover header count line, e.g. "Spain · 3 languages".
    /// `country` is the localized country name and `count` the number of
    /// language variants under that flag; both interpolations are
    /// preserved and the word for "languages" uses the locale's natural
    /// plural form.
    func variantCountLine(country: String, count: Int) -> String
}

struct OnboardingLanguageCopyEN: OnboardingLanguageCopy {
    let headlineLead = "Choose your "
    let headlineTail = "language."
    let subtitle = "Whytap transcribes 99 languages. Pick yours — we route to the best model for it automatically."
    let pickToContinue = "Pick a language to continue."
    let autoDetectTitle = "Auto-detect"
    let autoDetectDesc = "Whytap picks the language per dictation."
    let pickALanguage = "Pick a language"
    let recommendedBadge = "RECOMMENDED"
    let pickAccuracyNote = "Pinning a language sharpens transcription accuracy."
    let back = "Back"
    let ccontinue = "Continue"
    func variantCountLine(country: String, count: Int) -> String {
        "\(country) · \(count) languages"
    }
}

struct OnboardingLanguageCopyRU: OnboardingLanguageCopy {
    let headlineLead = "Выберите "
    let headlineTail = "язык."
    let subtitle = "Whytap расшифровывает 99 языков. Выберите свой — мы автоматически подберём для него лучшую модель."
    let pickToContinue = "Выберите язык, чтобы продолжить."
    let autoDetectTitle = "Автоопределение"
    let autoDetectDesc = "Whytap выбирает язык для каждой диктовки."
    let pickALanguage = "Выберите язык"
    let recommendedBadge = "РЕКОМЕНДУЕМ"
    let pickAccuracyNote = "Фиксация языка повышает точность расшифровки."
    let back = "Назад"
    let ccontinue = "Продолжить"
    func variantCountLine(country: String, count: Int) -> String {
        "\(country) · \(count) \(Self.languagesPlural(count))"
    }

    /// Russian plural for "язык" (language): 1 язык, 2–4 языка,
    /// 5+ языков, with the 11–14 exception.
    private static func languagesPlural(_ count: Int) -> String {
        let mod100 = abs(count) % 100
        let mod10 = abs(count) % 10
        if mod100 >= 11 && mod100 <= 14 { return "языков" }
        switch mod10 {
        case 1: return "язык"
        case 2, 3, 4: return "языка"
        default: return "языков"
        }
    }
}

func onboardingLanguageCopy(for language: OnboardingUILanguage) -> OnboardingLanguageCopy {
    switch language {
    case .en: return OnboardingLanguageCopyEN()
    case .ru: return OnboardingLanguageCopyRU()
    }
}

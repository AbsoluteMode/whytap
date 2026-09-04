import SwiftUI

// MARK: - Copy provider (ROO-261)

/// Localized copy for the Try-Agent step. Brand and chrome words stay
/// English in both locales: the "Agent." word in the headline, the
/// "AGENT" window badge, and the "R⌘" keycap glyph are all product chrome
/// and are not routed through this provider. The headline's leading verb
/// ("Try ") and the prose strings below differ by UI language.
///
/// `connectToTry(provider:)` keeps the live provider name (Claude Code /
/// Codex — both brand words that never translate) interpolated into the
/// sentence.
protocol OnboardingAgentTryCopy {
    /// Leading, upright-serif part of the "Try Agent." headline. The
    /// trailing "Agent." stays English italic and is rendered by the view.
    var headlineLead: String { get }
    var subtitle: String { get }
    var back: String { get }
    var skip: String { get }
    var ccontinue: String { get }
    /// Placeholder shown in the answer card until an agent is connected.
    func connectToTry(provider: String) -> String
}

struct OnboardingAgentTryCopyEN: OnboardingAgentTryCopy {
    let headlineLead = "Try "
    let subtitle = "Whytap is a voice layer for the agents you already love — your own Claude Code or Codex. Connect one to try it, or skip and set it up later."
    let back = "Back"
    let skip = "Skip"
    let ccontinue = "Continue"
    func connectToTry(provider: String) -> String {
        "Connect \(provider) above to try it live."
    }
}

struct OnboardingAgentTryCopyRU: OnboardingAgentTryCopy {
    let headlineLead = "Попробуйте "
    let subtitle = "Whytap — это голосовой слой для агентов, которые вы уже любите: вашего Claude Code или Codex. Подключите один, чтобы попробовать, или пропустите и настройте позже."
    let back = "Назад"
    let skip = "Пропустить"
    let ccontinue = "Продолжить"
    func connectToTry(provider: String) -> String {
        "Подключите \(provider) выше, чтобы попробовать вживую."
    }
}

func onboardingAgentTryCopy(for language: OnboardingUILanguage) -> OnboardingAgentTryCopy {
    switch language {
    case .en: return OnboardingAgentTryCopyEN()
    case .ru: return OnboardingAgentTryCopyRU()
    }
}

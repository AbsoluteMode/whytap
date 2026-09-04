import SwiftUI

// MARK: - Copy provider (ROO-261)

/// Localized copy for the Agent intro screen. Brand and chrome words stay
/// English in both locales: the "Agent." headline, the "AGENT" window
/// badge, the "·" separator, the "A" avatar glyph, and the per-step
/// `"\(label)."` format are all product chrome and are not routed through
/// this provider. Only the prose strings below differ by UI language.
protocol OnboardingAgentCopy {
    var subtitle: String { get }
    /// Faux chat window placeholder shown before the agent starts acting.
    var demoPlaceholder: String { get }
    var step1Label: String { get }
    var step1Desc: String { get }
    var step2Label: String { get }
    var step2Desc: String { get }
    var step3Label: String { get }
    var step3Desc: String { get }
    /// Rolling hotkey hint labels under the agent response.
    var linkInsert: String { get }
    var linkOpen: String { get }
    var back: String { get }
    var next: String { get }
}

struct OnboardingAgentCopyEN: OnboardingAgentCopy {
    let subtitle = "Whytap’s agent doesn’t just write — it acts. Ask anything about your work and it reaches into your tools to answer."
    let demoPlaceholder = "Ask Whytap anything."
    let step1Label = "Hold"
    let step1Desc = "Hold Right ⌘ to ask Whytap anything."
    let step2Label = "Speak"
    let step2Desc = "Whytap transcribes as you talk."
    let step3Label = "Act"
    let step3Desc = "It reaches into your tools and brings you the answer."
    let linkInsert = "Insert"
    let linkOpen = "Open"
    let back = "Back"
    let next = "Next"
}

struct OnboardingAgentCopyRU: OnboardingAgentCopy {
    let subtitle = "Агент Whytap не просто пишет — он действует. Спросите что угодно о вашей работе, и он обратится к вашим инструментам, чтобы дать ответ."
    let demoPlaceholder = "Спросите Whytap о чём угодно."
    let step1Label = "Зажмите"
    let step1Desc = "Зажмите правый ⌘, чтобы спросить Whytap о чём угодно."
    let step2Label = "Говорите"
    let step2Desc = "Whytap расшифровывает по мере речи."
    let step3Label = "Действуйте"
    let step3Desc = "Он обращается к вашим инструментам и приносит ответ."
    let linkInsert = "Вставить"
    let linkOpen = "Открыть"
    let back = "Назад"
    let next = "Далее"
}

func onboardingAgentCopy(for language: OnboardingUILanguage) -> OnboardingAgentCopy {
    switch language {
    case .en: return OnboardingAgentCopyEN()
    case .ru: return OnboardingAgentCopyRU()
    }
}

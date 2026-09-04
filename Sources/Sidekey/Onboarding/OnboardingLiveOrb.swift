import SwiftUI

/// A filled, gently-breathing `VoiceOrbView` for the onboarding island
/// mockups. The production island uses the orb's `.idle` "silent ring"
/// when nothing is happening, but in the onboarding teaching surfaces we
/// want the orb to read as the rich, alive Whytap orb — so this feeds a
/// small synthetic level into an active mode via `TimelineView`.
struct OnboardingLiveOrb: View {
    var mode: VoiceOrbMode = .dropVoice

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let breath = (sin(t * 1.7) + 1) * 0.5
            let level = Float(0.30 + 0.18 * breath)
            VoiceOrbView(mode: mode, levels: [level], isDarkBackground: true)
        }
    }
}

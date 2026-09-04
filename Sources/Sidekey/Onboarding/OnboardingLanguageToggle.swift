import SwiftUI

/// Live EN/RU language toggle for the onboarding flow (ROO-261). Lives
/// as a single top-trailing overlay in the flow container, so it appears
/// on every step and flips the whole walkthrough's language instantly.
///
/// A very compact, self-sizing segmented control in the `MacSegmented`
/// visual style (same `MacSettingsTheme` colours) but deliberately thin
/// so it tucks into the top-right corner without crowding screen content
/// (badges, cards) on any step. ROO-261.
struct OnboardingLanguageToggle: View {
    @EnvironmentObject private var locale: OnboardingLocale

    private let segmentHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(OnboardingUILanguage.allCases, id: \.self) { lang in
                let isSel = locale.language == lang
                Button {
                    locale.language = lang
                } label: {
                    Text(lang.toggleLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSel ? Color.white : MacSettingsTheme.text)
                        .padding(.horizontal, 7)
                        .frame(height: segmentHeight)
                        .background(
                            isSel ? MacSettingsTheme.segSel : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 1.5)
        .background(MacSettingsTheme.segBg, in: RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        .fixedSize()
        .accessibilityLabel("Onboarding language")
    }
}

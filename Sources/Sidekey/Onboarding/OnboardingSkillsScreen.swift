import SwiftUI

// MARK: - Copy provider (ROO-261)

/// Localized copy for the Skills onboarding screen.
///
/// English retention: the capability *names* (Agent / Meetings / Google)
/// are product/brand nouns and stay English in both locales — they are the
/// same words the live app surfaces use. So do the brand words inside the
/// detail prose (Whytap, Claude Code, Codex, Google, Slack, Gmail, Notes,
/// Dynamic Island) and the keycaps (R⌘, R⌥). Everything that is *prose* —
/// blurbs, detail descriptions, how-it-works steps, the right-pane mock
/// captions, the "Take notes / Skip" Whytap nudge labels (Whytap's own
/// Dynamic Island UI, rendered in the app's language), the "Off" status
/// badge, "HOW IT WORKS", and the Connect / connected CTA wrappers — is
/// translated. The "quarterly report" sample is illustrative selected text
/// and is localized too.
protocol OnboardingSkillsCopy {
    /// Italic-serif "Skills" headline.
    var headline: String { get }
    var subtitle: String { get }

    /// Per-capability prose. Titles are passed through `capabilityTitle`
    /// (brand nouns — English in both locales).
    func capabilityTitle(_ cap: OnboardingSkillCapability) -> String
    func capabilityBlurb(_ cap: OnboardingSkillCapability) -> String
    func capabilityDetail(_ cap: OnboardingSkillCapability) -> String
    func capabilityHowItWorks(_ cap: OnboardingSkillCapability) -> [(icon: String, text: String)]

    /// Feature-card "off" status badge.
    var off: String { get }
    /// Connect CTA: `<title> connected` once a capability is enabled.
    func connectedLabel(title: String) -> String
    /// Connect CTA: `Connect <title>` while a capability is off.
    func connectLabel(title: String) -> String

    /// Meetings right-pane mock.
    var meetingsTakeNotes: String { get }
    var meetingsSkip: String { get }
    var meetingsCaption: String { get }

    /// Google right-pane mock.
    var googleSampleSelection: String { get }
    var googleCaption: String { get }

    /// Detail-panel "how it works" section heading.
    var howItWorksHeading: String { get }

    var back: String { get }
    var ccontinue: String { get }
}

struct OnboardingSkillsCopyEN: OnboardingSkillsCopy {
    let headline = "Skills"
    let subtitle = "Off by default — nothing runs in the background until you switch it on."

    func capabilityTitle(_ cap: OnboardingSkillCapability) -> String {
        switch cap {
        case .agent: return "Agent"
        case .meetings: return "Meetings"
        case .google: return "Google"
        }
    }

    func capabilityBlurb(_ cap: OnboardingSkillCapability) -> String {
        switch cap {
        case .agent: return "Your own Claude Code or Codex"
        case .meetings: return "Detect, record, summarize calls"
        case .google: return "Search your selection"
        }
    }

    func capabilityDetail(_ cap: OnboardingSkillCapability) -> String {
        switch cap {
        case .agent:
            return "Press R⌘ to ask your own local agent — Claude Code or Codex. Tap for text, hold for voice. Whytap is the voice layer; your agent does the thinking."
        case .meetings:
            return "Detect calls, record mic and system audio, and get a summary. Nothing is captured until you turn this on."
        case .google:
            return "Right Option searches your selection on Google — no copy-paste, no switching apps. Off until you enable it."
        }
    }

    func capabilityHowItWorks(_ cap: OnboardingSkillCapability) -> [(icon: String, text: String)] {
        switch cap {
        case .agent:
            return []
        case .meetings:
            return [
                ("mic.fill", "Detects a call from your mic and the system audio"),
                ("bell.badge", "Nudges you in the Dynamic Island — Take notes?"),
                ("waveform", "Records and transcribes both sides of the call"),
                ("doc.text", "Summarizes everything into notes you can open")
            ]
        case .google:
            return [
                ("text.cursor", "Select any text in any app"),
                ("option", "Press Right Option (R⌥)"),
                ("magnifyingglass", "Google opens with your selection")
            ]
        }
    }

    let off = "Off"
    func connectedLabel(title: String) -> String { "\(title) connected" }
    func connectLabel(title: String) -> String { "Connect \(title)" }

    let meetingsTakeNotes = "Take notes"
    let meetingsSkip = "Skip"
    let meetingsCaption = "Take notes / Skip drops in just under your Dynamic Island when a call starts."

    let googleSampleSelection = "quarterly report"
    let googleCaption = "Works in any app — no copy-paste, no switching windows."

    let howItWorksHeading = "HOW IT WORKS"

    let back = "Back"
    let ccontinue = "Continue"
}

struct OnboardingSkillsCopyRU: OnboardingSkillsCopy {
    let headline = "Навыки"
    let subtitle = "Всё выключено по умолчанию — ничего не работает в фоне, пока вы сами не включите."

    func capabilityTitle(_ cap: OnboardingSkillCapability) -> String {
        // Brand / product nouns — English in both locales.
        switch cap {
        case .agent: return "Agent"
        case .meetings: return "Meetings"
        case .google: return "Google"
        }
    }

    func capabilityBlurb(_ cap: OnboardingSkillCapability) -> String {
        switch cap {
        case .agent: return "Ваш собственный Claude Code или Codex"
        case .meetings: return "Распознаёт, записывает и подытоживает звонки"
        case .google: return "Поиск по выделенному тексту"
        }
    }

    func capabilityDetail(_ cap: OnboardingSkillCapability) -> String {
        switch cap {
        case .agent:
            return "Нажмите R⌘, чтобы обратиться к своему локальному агенту — Claude Code или Codex. Нажатие — для текста, удержание — для голоса. Whytap отвечает за голос, а думает ваш агент."
        case .meetings:
            return "Распознаёт звонки, записывает микрофон и системный звук и готовит итоги. Ничего не записывается, пока вы это не включите."
        case .google:
            return "Right Option ищет выделенный текст в Google — без копирования и переключения приложений. Выключено, пока вы не включите."
        }
    }

    func capabilityHowItWorks(_ cap: OnboardingSkillCapability) -> [(icon: String, text: String)] {
        switch cap {
        case .agent:
            return []
        case .meetings:
            return [
                ("mic.fill", "Распознаёт звонок по микрофону и системному звуку"),
                ("bell.badge", "Подсказывает в Dynamic Island — записать заметки?"),
                ("waveform", "Записывает и расшифровывает обе стороны разговора"),
                ("doc.text", "Сводит всё в заметки, которые можно открыть")
            ]
        case .google:
            return [
                ("text.cursor", "Выделите любой текст в любом приложении"),
                ("option", "Нажмите Right Option (R⌥)"),
                ("magnifyingglass", "Google откроется с вашим запросом")
            ]
        }
    }

    let off = "Выкл"
    func connectedLabel(title: String) -> String { "\(title) подключён" }
    func connectLabel(title: String) -> String { "Подключить \(title)" }

    let meetingsTakeNotes = "Записать заметки"
    let meetingsSkip = "Пропустить"
    let meetingsCaption = "«Записать заметки / Пропустить» появляется прямо под Dynamic Island, когда начинается звонок."

    let googleSampleSelection = "квартальный отчёт"
    let googleCaption = "Работает в любом приложении — без копирования и переключения окон."

    let howItWorksHeading = "КАК ЭТО РАБОТАЕТ"

    let back = "Назад"
    let ccontinue = "Продолжить"
}

private func onboardingSkillsCopy(for language: OnboardingUILanguage) -> OnboardingSkillsCopy {
    switch language {
    case .en: return OnboardingSkillsCopyEN()
    case .ru: return OnboardingSkillsCopyRU()
    }
}

/// Which capability a Skills card governs. Drives the left-hand feature
/// list and the right-hand detail panel. All three are OFF by default —
/// the user opts in explicitly here (or later in Settings).
///
/// User-facing prose (title / blurb / detail / how-it-works) lives in the
/// `OnboardingSkillsCopy` provider above so it can be localized; this enum
/// keeps only the language-agnostic bits (case set, SF Symbol icons).
enum OnboardingSkillCapability: String, CaseIterable, Hashable {
    case agent
    case meetings
    case google

    /// SF Symbol shown on the feature card.
    var icon: String {
        switch self {
        case .agent: return "command"
        case .meetings: return "mic.fill"
        case .google: return "magnifyingglass"
        }
    }
}

/// Onboarding "Skills" step. Replaces the old Try-Agent screen with a
/// master-detail layout: a vertical list of feature cards (Agent /
/// Meetings / Google) on the left, and a detail panel on the right that
/// describes the selected feature and carries a Connect action. Connecting
/// flips the per-user capability opt-in on and lights the card green.
///
/// The screen never touches the cache — opt-ins go through `onToggle`,
/// which the host turns into a local preferences write. Generic over the
/// agent setup surface so the Agent detail can host the real Connect flow
/// while the preview drives a mock.
struct OnboardingSkillsScreen<AgentSurface: OnboardingAgentSetupSurface>: View {
    @ObservedObject var agentSurface: AgentSurface
    let onToggle: (OnboardingSkillCapability, Bool) -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var selectedFeature: OnboardingSkillCapability
    @State private var agentOn: Bool
    @State private var meetingsOn: Bool
    @State private var googleOn: Bool

    @EnvironmentObject private var locale: OnboardingLocale
    private var copy: OnboardingSkillsCopy { onboardingSkillsCopy(for: locale.language) }

    private static var green: Color { Color(red: 0.31, green: 0.78, blue: 0.51) }

    init(
        agentSurface: AgentSurface,
        initialAgentEnabled: Bool,
        initialMeetingsEnabled: Bool,
        initialGoogleEnabled: Bool,
        onToggle: @escaping (OnboardingSkillCapability, Bool) -> Void,
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.agentSurface = agentSurface
        self.onToggle = onToggle
        self.onBack = onBack
        self.onContinue = onContinue
        _selectedFeature = State(initialValue: .agent)
        _agentOn = State(initialValue: initialAgentEnabled)
        _meetingsOn = State(initialValue: initialMeetingsEnabled)
        _googleOn = State(initialValue: initialGoogleEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .top, spacing: 16) {
                featureList.frame(width: 304)
                detailPanel
            }
            .padding(.top, 22)
            Spacer(minLength: 16)
            footer
        }
        .padding(EdgeInsets(top: 40, leading: 48, bottom: 22, trailing: 48))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            (Text(copy.headline).font(OnboardingTheme.serifItalic(42, language: locale.language)))
                .foregroundColor(OnboardingTheme.ink)
                .kerning(-0.6)
            Text(copy.subtitle)
                .font(OnboardingTheme.sans(13.5))
                .foregroundColor(OnboardingTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Left: feature cards

    private var featureList: some View {
        VStack(spacing: 8) {
            ForEach(OnboardingSkillCapability.allCases, id: \.self) { featureCard($0) }
        }
    }

    private func featureCard(_ cap: OnboardingSkillCapability) -> some View {
        let on = isEnabled(cap)
        let selected = selectedFeature == cap
        return Button(action: { withAnimation(.easeInOut(duration: 0.16)) { selectedFeature = cap } }) {
            HStack(spacing: 12) {
                Image(systemName: cap.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(on ? Self.green : OnboardingTheme.muted)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.capabilityTitle(cap))
                        .font(OnboardingTheme.sans(14, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink)
                    Text(copy.capabilityBlurb(cap))
                        .font(OnboardingTheme.sans(11.5))
                        .foregroundColor(OnboardingTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                cardStatusToggle(cap, on: on)
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(on ? Self.green.opacity(0.12) : OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(
                selected ? OnboardingTheme.accent.opacity(0.6) : (on ? Self.green.opacity(0.5) : OnboardingTheme.border),
                lineWidth: selected ? 1.5 : (on ? 1 : 0.5)))
        }
        .buttonStyle(.plain)
    }

    /// Card status indicator. For Meetings / Google it doubles as a direct
    /// on/off toggle — tap it to enable/disable the capability straight from
    /// the card (tapping the card body still just selects it, so viewing a
    /// detail never flips state). Agent is status-only: it connects through
    /// its setup checklist (needs the CLI installed), so its glyph just
    /// reflects state and isn't a direct toggle.
    @ViewBuilder
    private func cardStatusToggle(_ cap: OnboardingSkillCapability, on: Bool) -> some View {
        if cap == .agent {
            statusGlyph(on: on)
        } else {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) { setEnabled(cap, !on) }
            }) {
                statusGlyph(on: on)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func statusGlyph(on: Bool) -> some View {
        if on {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(Self.green)
        } else {
            Text(copy.off)
                .font(OnboardingTheme.mono(9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(OnboardingTheme.faint)
        }
    }

    // MARK: - Right: detail panel

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(copy.capabilityTitle(selectedFeature))
                .font(OnboardingTheme.sans(18, weight: .semibold))
                .foregroundColor(OnboardingTheme.ink)
            Text(copy.capabilityDetail(selectedFeature))
                .font(OnboardingTheme.sans(13.5))
                .foregroundColor(OnboardingTheme.muted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            if selectedFeature == .agent {
                OnboardingAgentConnectPane(
                    surface: agentSurface,
                    initiallyConnected: agentOn,
                    onConnected: { setEnabled(.agent, true) }
                )
                .padding(.top, 18)
            } else {
                featureVisual(selectedFeature).padding(.top, 18)
                howItWorksSection(selectedFeature).padding(.top, 18)
            }

            Spacer(minLength: 16)

            if selectedFeature != .agent {
                connectButton(selectedFeature)
            }
        }
        .padding(EdgeInsets(top: 20, leading: 22, bottom: 20, trailing: 22))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingTheme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
    }

    /// Connect CTA for Meetings / Google (the Agent flow has its own Connect
    /// inside the pane). Toggles the capability — a second press turns it off.
    private func connectButton(_ cap: OnboardingSkillCapability) -> some View {
        let on = isEnabled(cap)
        return Button(action: { withAnimation(.easeInOut(duration: 0.2)) { setEnabled(cap, !on) } }) {
            if on {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    Text(copy.connectedLabel(title: copy.capabilityTitle(cap))).font(OnboardingTheme.sans(12.5, weight: .medium))
                }
                .foregroundColor(Self.green)
                .padding(.horizontal, 16)
                .frame(height: 32)
                .background(Capsule(style: .continuous).fill(Self.green.opacity(0.14)))
            } else {
                Text(copy.connectLabel(title: copy.capabilityTitle(cap)))
                    .font(OnboardingTheme.sans(12.5, weight: .medium))
                    .foregroundColor(OnboardingTheme.bg)
                    .padding(.horizontal, 16)
                    .frame(height: 32)
                    .background(Capsule(style: .continuous).fill(OnboardingTheme.ink))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail extras (Meetings / Google): visual mock + how-it-works

    @ViewBuilder
    private func featureVisual(_ cap: OnboardingSkillCapability) -> some View {
        switch cap {
        case .meetings: meetingsVisual
        case .google: googleVisual
        case .agent: EmptyView()
        }
    }

    /// "Take notes / Skip" nudge glued under the Dynamic Island — same shape as
    /// the real meeting nudge (mirrors OnboardingHelpersScreen's scripted mock /
    /// `MeetingNudgeView`): a black menu-bar island plate with a split
    /// white "Take notes" | black "Skip" button hanging off its flat bottom edge.
    private var meetingsVisual: some View {
        let nudgeWidth: CGFloat = 234
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Self.green)
                        Text("Whytap")
                            .font(OnboardingTheme.mono(8, weight: .semibold))
                            .tracking(0.5)
                            .foregroundColor(.white.opacity(0.55))
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, 13)
                    .frame(width: nudgeWidth, height: 26)
                    .background(Rectangle().fill(Color.black))
                    HStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: "note.text").font(.system(size: 11, weight: .semibold))
                            Text(copy.meetingsTakeNotes).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(Color(red: 0.04, green: 0.04, blue: 0.04))
                        .frame(width: nudgeWidth * 0.6).frame(maxHeight: .infinity)
                        .background(Color.white)
                        Text(copy.meetingsSkip)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: nudgeWidth * 0.4).frame(maxHeight: .infinity)
                            .background(Color(red: 0.04, green: 0.04, blue: 0.04))
                    }
                    .frame(width: nudgeWidth, height: 30)
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: 0, bottomLeadingRadius: 13,
                        bottomTrailingRadius: 13, topTrailingRadius: 0, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 7)
                }
                Spacer(minLength: 0)
            }
            Text(copy.meetingsCaption)
                .font(OnboardingTheme.sans(11))
                .foregroundColor(OnboardingTheme.faint)
        }
    }

    /// "Selected text → R⌥ → Google" mock.
    private var googleVisual: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text(copy.googleSampleSelection)
                    .font(OnboardingTheme.sans(12))
                    .foregroundColor(OnboardingTheme.ink)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(OnboardingTheme.accent.opacity(0.22)))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OnboardingTheme.faint)
                keycap("R⌥")
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(OnboardingTheme.faint)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                    Text("Google").font(OnboardingTheme.sans(12, weight: .medium))
                }
                .foregroundColor(OnboardingTheme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).frame(height: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(OnboardingTheme.border, lineWidth: 0.5))
            Text(copy.googleCaption)
                .font(OnboardingTheme.sans(11))
                .foregroundColor(OnboardingTheme.faint)
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(OnboardingTheme.sans(11.5, weight: .semibold))
            .foregroundColor(OnboardingTheme.ink)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(OnboardingTheme.surface2))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(OnboardingTheme.borderStrong, lineWidth: 0.5))
    }

    private func howItWorksSection(_ cap: OnboardingSkillCapability) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(copy.howItWorksHeading)
                .font(OnboardingTheme.mono(9, weight: .semibold))
                .tracking(0.8)
                .foregroundColor(OnboardingTheme.faint)
            ForEach(Array(copy.capabilityHowItWorks(cap).enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: step.icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Self.green)
                        .frame(width: 18, height: 18)
                    Text(step.text)
                        .font(OnboardingTheme.sans(13))
                        .foregroundColor(OnboardingTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - State

    private func isEnabled(_ cap: OnboardingSkillCapability) -> Bool {
        switch cap {
        case .agent: return agentOn
        case .meetings: return meetingsOn
        case .google: return googleOn
        }
    }

    private func setEnabled(_ cap: OnboardingSkillCapability, _ on: Bool) {
        switch cap {
        case .agent: agentOn = on
        case .meetings: meetingsOn = on
        case .google: googleOn = on
        }
        onToggle(cap, on)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                    Text(copy.back)
                }
                .font(OnboardingTheme.sans(13, weight: .medium)).foregroundColor(OnboardingTheme.muted)
                .padding(.horizontal, 12).frame(height: 34)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Text(copy.ccontinue)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(13, weight: .medium)).foregroundColor(OnboardingTheme.bg)
                .padding(.horizontal, 18).frame(height: 34)
                .background(Capsule(style: .continuous).fill(OnboardingTheme.ink))
            }
            .buttonStyle(.plain)
        }
    }
}

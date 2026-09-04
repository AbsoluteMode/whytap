import SwiftUI

/// Screen 02 of the onboarding flow — Agent introduction. Same 960×600
/// chrome as the welcome screen but the orb runs in the agent palette
/// (pink-violet via `.agentVoice` / `.agentProcessing`) and the right
/// pane shows a faux chat window that surfaces only what the user sees
/// in the real Sidekey agent flow: the action the agent is performing
/// and the answer it writes back. The user's spoken query streams as
/// a live transcript UNDER the orb — exactly where the real Sidekey
/// shows it during voice input.
struct OnboardingAgentScreen: View {
    @ObservedObject var orb: OnboardingAgentController
    let onBack: () -> Void
    let onNext: () -> Void

    @EnvironmentObject private var locale: OnboardingLocale
    private var copy: OnboardingAgentCopy { onboardingAgentCopy(for: locale.language) }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
                .background(OnboardingTheme.bg)
                .overlay(
                    Rectangle()
                        .fill(OnboardingTheme.border)
                        .frame(width: 0.5),
                    alignment: .trailing
                )
            rightPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { orb.start() }
        .onDisappear { orb.stop() }
    }

    // MARK: - Left pane

    private var leftPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Agent.")
                    .font(OnboardingTheme.serifItalic(42, language: locale.language))
                    .foregroundColor(OnboardingTheme.ink)
                    .kerning(-0.6)
                Text(copy.subtitle)
                    .font(OnboardingTheme.sans(14))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                OnboardingAgentStepRow(
                    n: 1,
                    label: copy.step1Label,
                    desc: copy.step1Desc,
                    keycap: .rightCmd,
                    flashing: holdHighlightActive
                )
                OnboardingAgentStepRow(
                    n: 2,
                    label: copy.step2Label,
                    desc: copy.step2Desc,
                    keycap: nil,
                    flashing: false
                )
                OnboardingAgentStepRow(
                    n: 3,
                    label: copy.step3Label,
                    desc: copy.step3Desc,
                    keycap: nil,
                    flashing: false
                )
            }
            .padding(.top, 28)

            Spacer(minLength: 0)

            footer
        }
        .padding(EdgeInsets(top: 40, leading: 36, bottom: 22, trailing: 28))
    }

    /// The hold keycap stays lit for the whole "user is talking" beat
    /// (from the press flash through the audio playback). Mimics how
    /// the real Sidekey UI shows the modifier as held while the user
    /// dictates.
    private var holdHighlightActive: Bool {
        switch orb.phase {
        case .pressFlash, .recording: return true
        default: return false
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text(copy.back)
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onNext) {
                HStack(spacing: 6) {
                    Text(copy.next)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.bg)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .fixedSize(horizontal: true, vertical: false)
                .background(Capsule(style: .continuous).fill(OnboardingTheme.ink))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Right pane

    private var rightPane: some View {
        ZStack {
            AgentRightPaneBackdrop()
            VStack(spacing: 22) {
                FakeAgentChatWindow(
                    sample: orb.currentSample,
                    chatNameTyped: orb.typedChatName,
                    actionVisible: orb.actionVisible,
                    visibleStepCount: orb.visibleStepCount,
                    typedResponse: orb.typedResponse,
                    linkVisible: orb.linkVisible,
                    phase: orb.phase,
                    placeholder: copy.demoPlaceholder,
                    language: locale.language
                )
                .frame(maxWidth: 460)

                VStack(spacing: 12) {
                    AgentOrbStage(orb: orb)
                    AgentLiveTranscript(
                        text: orb.typedQuery,
                        fullText: orb.currentSample?.query ?? "",
                        visible: transcriptVisible
                    )
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Live transcript stays visible from the moment the orb starts
    /// listening through to the end of the cycle so the user can read
    /// the prompt the agent is acting on. It only fades out when the
    /// next sample resets state at the start of a fresh cycle.
    private var transcriptVisible: Bool {
        guard orb.phase != .idle && orb.phase != .pressFlash else { return false }
        return !orb.typedQuery.isEmpty
    }
}

// MARK: - Step row

private enum AgentKeycap { case rightCmd }

private struct OnboardingAgentStepRow: View {
    let n: Int
    let label: String
    let desc: String
    let keycap: AgentKeycap?
    let flashing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", n))
                .font(OnboardingTheme.mono(10.5))
                .tracking(0.6)
                .foregroundColor(OnboardingTheme.faint)
                .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Text("\(label).")
                        .font(OnboardingTheme.serifItalic(20))
                        .foregroundColor(OnboardingTheme.ink)
                    if keycap == .rightCmd {
                        RightCmdChord(flashing: flashing)
                    }
                }
                Text(desc)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct RightCmdChord: View {
    let flashing: Bool

    var body: some View {
        HStack(spacing: 4) {
            cap("R\u{2009}\(HotkeyGlyph.command)")
        }
    }

    private func cap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(flashing ? OnboardingTheme.bg : OnboardingTheme.ink)
            .frame(minHeight: 22)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(flashing ? Color.white : OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(OnboardingTheme.borderStrong, lineWidth: 0.5)
            )
            .animation(.easeOut(duration: 0.28), value: flashing)
    }
}

// MARK: - Right pane backdrop (agent palette — pink + violet wash)

private struct AgentRightPaneBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.97, green: 0.60, blue: 0.85).opacity(0.22), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.80, y: 0.10),
                        startRadius: 0,
                        endRadius: 620
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.55, green: 0.36, blue: 1.0).opacity(0.20), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.10, y: 1.0),
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            )
    }
}

// MARK: - Faux agent chat window

private struct FakeAgentChatWindow: View {
    let sample: OnboardingAgentController.Sample?
    let chatNameTyped: String
    let actionVisible: Bool
    let visibleStepCount: Int
    let typedResponse: String
    let linkVisible: Bool
    let phase: OnboardingAgentController.Phase
    /// Localized placeholder shown before the agent starts acting.
    let placeholder: String
    /// Active onboarding UI language — selects the Cyrillic-capable serif
    /// for the localized placeholder.
    let language: OnboardingUILanguage

    private var copy: OnboardingAgentCopy { onboardingAgentCopy(for: language) }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            body_
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.40), radius: 30, x: 0, y: 20)
        .shadow(color: .black.opacity(0.20), radius: 8, x: 0, y: 4)
    }

    private var titleBar: some View {
        HStack(spacing: 6) {
            Circle().fill(OnboardingTheme.trafficRed).frame(width: 9, height: 9)
            Circle().fill(OnboardingTheme.trafficYellow).frame(width: 9, height: 9)
            Circle().fill(OnboardingTheme.trafficGreen).frame(width: 9, height: 9)
            HStack(spacing: 6) {
                Text("AGENT")
                    .font(OnboardingTheme.mono(10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundColor(OnboardingTheme.faint)
                if !chatNameTyped.isEmpty {
                    Text("·")
                        .font(OnboardingTheme.mono(10))
                        .foregroundColor(OnboardingTheme.faint)
                    Text(chatNameTyped)
                        .font(OnboardingTheme.serifItalic(13))
                        .foregroundColor(OnboardingTheme.ink2)
                }
            }
            .padding(.leading, 8)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(OnboardingTheme.surface2)
        .overlay(
            Rectangle().fill(OnboardingTheme.border).frame(height: 0.5),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var body_: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let sample, actionVisible {
                if let steps = sample.actionSteps {
                    ForEach(Array(steps.prefix(visibleStepCount).enumerated()), id: \.offset) { _, step in
                        actionStepCard(step)
                    }
                } else {
                    actionCard(sample)
                }
            }
            if !typedResponse.isEmpty {
                Text(typedResponse)
                    .font(OnboardingTheme.serif(17))
                    .foregroundColor(OnboardingTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
                    .transition(.opacity)
            } else if !actionVisible {
                Text(placeholder)
                    .font(OnboardingTheme.serifItalic(17, language: language))
                    .foregroundColor(OnboardingTheme.faint)
            }
            if let sample, linkVisible {
                VStack(alignment: .leading, spacing: 8) {
                    AgentSourceLinkChip(link: sample.link)
                    AgentLinkHotkeyHint(insert: copy.linkInsert, open: copy.linkOpen)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .padding(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
        .background(OnboardingTheme.surface)
    }

    private func actionCard(_ sample: OnboardingAgentController.Sample) -> some View {
        HStack(spacing: 10) {
            Image(systemName: sample.actionIcon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(red: 0.97, green: 0.60, blue: 0.85))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.06)))
            Text(sample.actionText)
                .font(OnboardingTheme.sans(12.5, weight: .medium))
                .foregroundColor(OnboardingTheme.ink2)
            Spacer()
            if phase == .processing {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(red: 0.79, green: 0.55, blue: 1.0))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // One completed step in a multi-step run (close task, message PM).
    private func actionStepCard(_ step: OnboardingAgentController.ActionStep) -> some View {
        let green = Color(red: 0.31, green: 0.78, blue: 0.51)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: step.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(green)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(green.opacity(0.16)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title)
                        .font(OnboardingTheme.sans(12.5, weight: .medium))
                        .foregroundColor(OnboardingTheme.ink)
                    if let detail = step.detail {
                        HStack(spacing: 4) {
                            if let detailIcon = step.detailIcon {
                                Image(systemName: detailIcon)
                                    .font(.system(size: 10))
                            }
                            Text(detail)
                                .font(OnboardingTheme.sans(11))
                        }
                        .foregroundColor(OnboardingTheme.muted)
                    }
                }
                Spacer(minLength: 0)
                if let linkLabel = step.linkLabel {
                    HStack(spacing: 4) {
                        Text(linkLabel)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(OnboardingTheme.sans(11, weight: .medium))
                    .foregroundColor(Color(red: 0.72, green: 0.60, blue: 0.98))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(Color(red: 0.55, green: 0.36, blue: 1.0).opacity(0.14))
                    )
                }
            }
            if let message = step.message {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color(red: 0.61, green: 0.35, blue: 0.71))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Text("A")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white)
                        )
                    Text(message)
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                    Spacer(minLength: 0)
                }
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

// MARK: - Source link chip + hotkey hint

/// Mock of the production `UsefulLinkChipView`. Frosted material chip
/// with provider icon + title + subtitle. Onboarding-only — no
/// favicon fetch, no NSWorkspace.open wiring.
private struct AgentSourceLinkChip: View {
    let link: OnboardingAgentController.LinkPreview

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: link.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Color(red: 0.79, green: 0.55, blue: 1.0))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 1) {
                Text(link.title)
                    .font(OnboardingTheme.sans(12.5, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                    .lineLimit(1)
                Text(link.subtitle)
                    .font(OnboardingTheme.sans(11))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
    }
}

/// Teaching-flavour hotkey hint for the onboarding. The production
/// `HotkeyHintView` is intentionally compact (frosted capsule sized
/// for the Pill 1/2 surface) — here we have plenty of room and a
/// learning audience, so the hint reads as two clear labelled rows
/// of flat keycaps stacked vertically:
///
///     Insert   ⌥  ‹
///     Open     ⌥  ›
///
/// Same key bindings as the production rolling hint
/// (`UsefulLinksRollingHintView`), but visually quieter so it does
/// not compete with the response copy above it.
private struct AgentLinkHotkeyHint: View {
    let insert: String
    let open: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OnboardingHotkeyRow(
                label: insert,
                keys: [.glyph(HotkeyGlyph.option), .symbol("chevron.left")]
            )
            OnboardingHotkeyRow(
                label: open,
                keys: [.glyph(HotkeyGlyph.option), .symbol("chevron.right")]
            )
        }
    }
}

private enum OnboardingKeyContent: Hashable {
    case glyph(String)
    case symbol(String)
}

private struct OnboardingHotkeyRow: View {
    let label: String
    let keys: [OnboardingKeyContent]

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(OnboardingTheme.sans(11.5, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
                .frame(width: 40, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    OnboardingKeyCap(content: key)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct OnboardingKeyCap: View {
    let content: OnboardingKeyContent

    var body: some View {
        Group {
            switch content {
            case .glyph(let value):
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .foregroundColor(OnboardingTheme.ink)
        .frame(minWidth: 24, minHeight: 22)
        .padding(.horizontal, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(OnboardingTheme.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(OnboardingTheme.borderStrong, lineWidth: 0.5)
        )
    }
}

// MARK: - Agent orb stage

private struct AgentOrbStage: View {
    @ObservedObject var orb: OnboardingAgentController

    var body: some View {
        VoiceOrbView(
            mode: Self.mode(for: orb.phase),
            levels: orb.levels,
            isDarkBackground: true
        )
        .frame(width: 96, height: 96)
    }

    static func mode(for phase: OnboardingAgentController.Phase) -> VoiceOrbMode {
        switch phase {
        case .recording: return .agentVoice
        case .processing, .responding: return .agentProcessing
        default: return .idle
        }
    }
}

// MARK: - Live transcript under the orb

/// Live transcript of the current voice sample. Uses an invisible
/// ZStack base that always renders the FULL query so the layout
/// reserves enough vertical / horizontal space up front — the visible
/// typed text grows inside that fixed envelope and never reflows mid
/// word. (Earlier version used `Text(typed).lineLimit(2)` which
/// re-laid out on every character and produced a visible flicker
/// just before long sentences finished.)
private struct AgentLiveTranscript: View {
    let text: String
    let fullText: String
    let visible: Bool

    var body: some View {
        ZStack(alignment: .top) {
            // Invisible footprint sized to the full sentence.
            quoted(fullText)
                .opacity(0)
                .accessibilityHidden(true)

            // Actual visible transcript. The opacity transition fires
            // only on `visible` changes, never on text edits, so the
            // streamed characters appear in-place without animating.
            quoted(text)
                .opacity(visible ? 1 : 0)
                .animation(.easeInOut(duration: 0.22), value: visible)
        }
        .frame(maxWidth: 420)
    }

    @ViewBuilder
    private func quoted(_ raw: String) -> some View {
        Text(raw.isEmpty ? " " : "\u{201C}\(raw)\u{201D}")
            .font(OnboardingTheme.serifItalic(15))
            .foregroundColor(OnboardingTheme.muted)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

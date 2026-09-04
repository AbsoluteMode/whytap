import SwiftUI

/// Screen 01 of the onboarding flow. Auto-cycling visual demo —
/// flashes the Drop hotkey (config-driven, post-cutover the Space cap),
/// lights up the real `VoiceOrbView` against the bundled voice sample,
/// swaps into thinking spin, then drops the transcript into the faux
/// Notes window. No real input is read.
///
/// Receives a pre-built `OnboardingOrbController` so callers can
/// observe / drive it from outside (preview's mute button) without
/// the screen owning its own lifecycle.
struct OnboardingWelcomeScreen: View {
    @ObservedObject var orb: OnboardingOrbController
    let onNext: () -> Void
    /// The Drop shortcut keycaps flashed in the demo step rows, injected
    /// from the live hotkey config by the production flow
    /// (`OnboardingFlowView` passes `dropVoiceShortcut.contents`). Defaults
    /// to the canonical hold-Space cap so the standalone onboarding preview
    /// executable — which has no `HotkeyPreferences` — renders the right
    /// chord without depending on that type.
    let dropChord: [KeycapContent]

    init(
        orb: OnboardingOrbController,
        onNext: @escaping () -> Void,
        dropChord: [KeycapContent] = [.text("Space")]
    ) {
        self.orb = orb
        self.onNext = onNext
        self.dropChord = dropChord
    }

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
                headline
                Text("Whytap turns your voice into text in any app — Slack, Gmail, Notes, your code editor.")
                    .font(OnboardingTheme.sans(14))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                OnboardingStepRow(
                    n: 1,
                    label: "Hold",
                    desc: "Press your Whytap hotkey to start listening.",
                    showKeycaps: true,
                    flashing: orb.phase == .pressFlash,
                    chord: dropChord
                )
                OnboardingStepRow(
                    n: 2,
                    label: "Speak",
                    desc: "Say what you want to write.",
                    showKeycaps: false,
                    flashing: false,
                    chord: dropChord
                )
                OnboardingStepRow(
                    n: 3,
                    label: "Release",
                    desc: "Your text appears at the cursor.",
                    showKeycaps: true,
                    flashing: orb.phase == .pressFlashAgain,
                    chord: dropChord
                )
            }
            .padding(.top, 28)

            Spacer(minLength: 0)

            footer
        }
        .padding(EdgeInsets(top: 40, leading: 36, bottom: 22, trailing: 28))
    }

    private var headline: some View {
        Text("Drop.")
            .font(OnboardingTheme.serifItalic(42))
            .foregroundColor(OnboardingTheme.ink)
            .kerning(-0.6)
            .lineSpacing(-6)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onNext) {
                HStack(spacing: 6) {
                    Text("Next")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(13, weight: .medium))
                .foregroundColor(OnboardingTheme.bg)
                .padding(.horizontal, 18)
                .frame(height: 34)
                .background(
                    Capsule(style: .continuous).fill(OnboardingTheme.ink)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Right pane

    private var rightPane: some View {
        ZStack {
            OnboardingRightPaneBackdrop()
            VStack(spacing: 22) {
                FakeNotesWindow(
                    phase: orb.phase,
                    typed: orb.typed
                )
                .frame(maxWidth: 460)

                BareOrbStage(orb: orb)
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Step row

private struct OnboardingStepRow: View {
    let n: Int
    let label: String
    let desc: String
    let showKeycaps: Bool
    let flashing: Bool
    let chord: [KeycapContent]

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
                    if showKeycaps {
                        OnboardingHotkeyChord(flashing: flashing, contents: chord)
                    }
                }
                Text(desc)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(2)
            }
        }
    }
}

// MARK: - Hotkey chord (config-driven — post-cutover a single "Space" cap)

private struct OnboardingHotkeyChord: View {
    let flashing: Bool
    /// Keycaps to render, sourced from `dropVoiceShortcut.contents` so the
    /// demo chord follows the binding instead of a hardcoded ⌥ /.
    let contents: [KeycapContent]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(contents.enumerated()), id: \.offset) { _, content in
                cap(for: content)
            }
        }
    }

    @ViewBuilder
    private func cap(for content: KeycapContent) -> some View {
        capChrome {
            switch content {
            case .text(let value):
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
            case .symbol(let name, _):
                Image(systemName: name)
                    .font(.system(size: 10, weight: .semibold))
            case .prefixedGlyph(let prefix, let glyph, _):
                HStack(spacing: 3) {
                    Text(prefix)
                        .font(.system(size: 8, weight: .medium))
                        .opacity(0.85)
                    Text(glyph)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
    }

    private func capChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundColor(flashing ? OnboardingTheme.bg : OnboardingTheme.ink)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(flashing ? Color.white : OnboardingTheme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(OnboardingTheme.borderStrong, lineWidth: 0.5)
            )
            .animation(.easeOut(duration: 0.38), value: flashing)
    }
}

// MARK: - Right pane backdrop (radial gradient wash)

private struct OnboardingRightPaneBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: OnboardingTheme.accent.opacity(0.28), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.80, y: 0.10),
                        startRadius: 0,
                        endRadius: 620
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.03), location: 0),
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

// MARK: - Faux Notes window

private struct FakeNotesWindow: View {
    let phase: OnboardingOrbController.Phase
    let typed: String

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
            Text("NOTES — UNTITLED")
                .font(OnboardingTheme.mono(10, weight: .medium))
                .tracking(0.6)
                .foregroundColor(OnboardingTheme.faint)
                .padding(.leading, 8)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(OnboardingTheme.surface2)
        .overlay(
            Rectangle().fill(OnboardingTheme.border).frame(height: 0.5),
            alignment: .bottom
        )
    }

    @ViewBuilder
    private var body_: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .idle, .pressFlash:
                Text("Your transcript will appear here…")
                    .font(OnboardingTheme.serifItalic(18))
                    .foregroundColor(OnboardingTheme.faint)
            case .recording, .pressFlashAgain:
                Text("capturing audio…")
                    .font(OnboardingTheme.serifItalic(18))
                    .foregroundColor(OnboardingTheme.faint)
            case .thinking:
                Text("thinking…")
                    .font(OnboardingTheme.serifItalic(18))
                    .foregroundColor(OnboardingTheme.faint)
            case .done:
                Text(typed)
                    .font(OnboardingTheme.serif(18))
                    .foregroundColor(OnboardingTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
        .background(OnboardingTheme.surface)
    }
}

// MARK: - Bare orb stage (real VoiceOrbView, fake-fed)

private struct BareOrbStage: View {
    @ObservedObject var orb: OnboardingOrbController

    var body: some View {
        VoiceOrbView(
            mode: Self.mode(for: orb.phase),
            levels: orb.levels,
            isDarkBackground: true
        )
        // VoiceOrbView's intrinsic canvas (`VoiceOrbView.canvasSize`)
        // is 57pt; we pad slightly so the bloom never touches the
        // surrounding Notes window edge.
        .frame(width: 96, height: 96)
    }

    /// Maps the controller's scripted phase onto the orb's production
    /// modes. `pressFlashAgain` keeps the orb in `.dropVoice` (silent —
    /// `levels` are already zeroed) so the keycap flash visibly
    /// PRECEDES the thinking spin. Only after the flash settles does
    /// `.thinking` flip the orb to `.dropProcessing`, mirroring the
    /// real Sidekey flow where the user presses to end the recording
    /// first and the transcription spin starts a beat later.
    static func mode(for phase: OnboardingOrbController.Phase) -> VoiceOrbMode {
        switch phase {
        case .recording, .pressFlashAgain: return .dropVoice
        case .thinking: return .dropProcessing
        default: return .idle
        }
    }
}

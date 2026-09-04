import SwiftUI

// MARK: - Copy provider (ROO-261)

/// Localized copy for the Drop demo screen. The brand word "Drop" stays
/// English in both locales (it is the product's name for the feature).
protocol OnboardingDropCopy {
    /// The "Drop." headline — kept as the English brand word.
    var headline: String { get }
    var subtitle: String { get }
    /// Step 1 verb. `gestureWord` is the live hotkey verb ("hold"/"tap"),
    /// already lowercased; the provider maps it to a display label.
    func step1Label(gestureWord: String) -> String
    var step1Desc: String { get }
    var step2Label: String { get }
    var step2Desc: String { get }
    var step3Label: String { get }
    var step3Desc: String { get }
    var demoIdle: String { get }
    var demoCapturing: String { get }
    var demoTranscribing: String { get }
    var islandHint: String { get }
    var back: String { get }
    var ccontinue: String { get }
}

struct OnboardingDropCopyEN: OnboardingDropCopy {
    let headline = "Drop."
    let subtitle = "Your voice becomes text in any app — Slack, Gmail, Notes, your editor. Hold, speak, release."
    func step1Label(gestureWord: String) -> String { gestureWord.capitalized }
    let step1Desc = "Press and keep it held down — don't let go yet."
    let step2Label = "Speak"
    let step2Desc = "Keep holding while you say what you want to write."
    let step3Label = "Release"
    let step3Desc = "Let go — your text appears at the cursor."
    let demoIdle = "Hold Space and speak — your words appear right here…"
    let demoCapturing = "capturing audio…"
    let demoTranscribing = "transcribing…"
    let islandHint = "Whytap shows up in the Dynamic Island while you talk."
    let back = "Back"
    let ccontinue = "Continue"
}

struct OnboardingDropCopyRU: OnboardingDropCopy {
    let headline = "Drop."
    let subtitle = "Ваш голос превращается в текст в любом приложении — Slack, Gmail, Notes, ваш редактор. Зажмите, говорите, отпустите."
    func step1Label(gestureWord: String) -> String {
        // Map the live English hotkey verb to its Russian display label.
        switch gestureWord.lowercased() {
        case "tap", "toggle": return "Нажмите"
        default: return "Зажмите"
        }
    }
    let step1Desc = "Нажмите и удерживайте — пока не отпускайте."
    let step2Label = "Говорите"
    let step2Desc = "Удерживая, скажите то, что хотите написать."
    let step3Label = "Отпустите"
    let step3Desc = "Отпустите — текст появится у курсора."
    let demoIdle = "Зажмите Space и говорите — ваши слова появятся прямо здесь…"
    let demoCapturing = "запись звука…"
    let demoTranscribing = "расшифровка…"
    let islandHint = "Пока вы говорите, Whytap появляется в Dynamic Island."
    let back = "Назад"
    let ccontinue = "Продолжить"
}

func onboardingDropCopy(for language: OnboardingUILanguage) -> OnboardingDropCopy {
    switch language {
    case .en: return OnboardingDropCopyEN()
    case .ru: return OnboardingDropCopyRU()
    }
}

/// Drop demo screen — pure, auto-playing demonstration of what Drop
/// does. The left pane explains the three steps (the Drop keycaps flash
/// in time with the demo); the right pane is a Notes window that the
/// orb-driven demo types a sample transcript into. No interaction here —
/// the hands-on attempt lives on the next step (`OnboardingTryDropScreen`).
///
/// Receives a pre-built `OnboardingOrbController` so the host can drive /
/// mute it from outside.
struct OnboardingDropScreen: View {
    @ObservedObject var orb: OnboardingOrbController
    let onBack: () -> Void
    let onContinue: () -> Void
    /// Drop shortcut keycaps, injected from the live hotkey config.
    let dropChord: [KeycapContent]
    /// Gesture verb for the Drop binding ("hold" / "tap").
    let dropGestureWord: String

    @EnvironmentObject private var locale: OnboardingLocale
    private var copy: OnboardingDropCopy { onboardingDropCopy(for: locale.language) }

    init(
        orb: OnboardingOrbController,
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void,
        dropChord: [KeycapContent] = [.text("Space")],
        dropGestureWord: String = "hold"
    ) {
        self.orb = orb
        self.onBack = onBack
        self.onContinue = onContinue
        self.dropChord = dropChord
        self.dropGestureWord = dropGestureWord
    }

    var body: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
                .background(OnboardingTheme.bg)
                .overlay(
                    Rectangle().fill(OnboardingTheme.border).frame(width: 0.5),
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
                Text(copy.headline)
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
                DropStepRow(
                    n: 1,
                    label: copy.step1Label(gestureWord: dropGestureWord),
                    desc: copy.step1Desc,
                    chord: dropChord,
                    capState: (orb.phase == .pressFlash || orb.phase == .recording) ? .held : .rest,
                    holdLevel: CGFloat(orb.levels.last ?? 0)
                )
                DropStepRow(
                    n: 2,
                    label: copy.step2Label,
                    desc: copy.step2Desc,
                    chord: nil
                )
                DropStepRow(
                    n: 3,
                    label: copy.step3Label,
                    desc: copy.step3Desc,
                    chord: dropChord,
                    capState: orb.phase == .pressFlashAgain ? .flash : .rest
                )
            }
            .padding(.top, 28)

            Spacer(minLength: 0)

            footer
        }
        .padding(EdgeInsets(top: 40, leading: 36, bottom: 22, trailing: 28))
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

            Spacer(minLength: 0)

            Button(action: onContinue) {
                HStack(spacing: 6) {
                    Text(copy.ccontinue)
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
            DropBackdrop()
            VStack(spacing: 22) {
                notesCard
                orbStage
                dynamicIslandHint
            }
            .frame(maxWidth: 420)
            .padding(EdgeInsets(top: 34, leading: 28, bottom: 34, trailing: 28))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notesCard: some View {
        VStack(spacing: 0) {
            notesTitleBar
            notesBody
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.40), radius: 30, x: 0, y: 20)
        .shadow(color: .black.opacity(0.20), radius: 8, x: 0, y: 4)
    }

    private var notesTitleBar: some View {
        HStack(spacing: 6) {
            Circle().fill(OnboardingTheme.trafficRed).frame(width: 9, height: 9)
            Circle().fill(OnboardingTheme.trafficYellow).frame(width: 9, height: 9)
            Circle().fill(OnboardingTheme.trafficGreen).frame(width: 9, height: 9)
            Text("NOTES — UNTITLED")
                .font(OnboardingTheme.mono(10, weight: .medium))
                .tracking(0.6)
                .foregroundColor(OnboardingTheme.faint)
                .padding(.leading, 8)
            Spacer(minLength: 0)
            DropKeycapChord(
                contents: dropChord,
                state: (orb.phase == .pressFlash || orb.phase == .recording) ? .held : .rest,
                holdLevel: CGFloat(orb.levels.last ?? 0)
            )
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(OnboardingTheme.surface2)
        .overlay(
            Rectangle().fill(OnboardingTheme.border).frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var notesBody: some View {
        demoText
            .padding(EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16))
            .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
            .background(OnboardingTheme.surface)
    }

    @ViewBuilder
    private var demoText: some View {
        switch orb.phase {
        case .idle, .pressFlash:
            Text(copy.demoIdle)
                .font(OnboardingTheme.serifItalic(15, language: locale.language))
                .foregroundColor(OnboardingTheme.faint)
        case .recording, .pressFlashAgain:
            Text(copy.demoCapturing)
                .font(OnboardingTheme.serifItalic(15, language: locale.language))
                .foregroundColor(OnboardingTheme.faint)
        case .thinking:
            Text(copy.demoTranscribing)
                .font(OnboardingTheme.serifItalic(15, language: locale.language))
                .foregroundColor(OnboardingTheme.faint)
        case .done:
            // The typed transcript is the demo's pre-recorded English
            // sample (driven by the bundled audio clip); it stays in
            // Instrument Serif regardless of UI language.
            Text(orb.typed)
                .font(OnboardingTheme.serif(15))
                .foregroundColor(OnboardingTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
        }
    }

    private var orbStage: some View {
        VoiceOrbView(
            mode: Self.mode(for: orb.phase),
            levels: orb.levels,
            isDarkBackground: true
        )
        .frame(width: 88, height: 88)
    }

    private var dynamicIslandHint: some View {
        HStack(spacing: 8) {
            Capsule(style: .continuous)
                .fill(Color.black)
                .frame(width: 46, height: 15)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(OnboardingTheme.accent.opacity(0.5), lineWidth: 0.75)
                )
                .overlay(
                    Circle()
                        .fill(OnboardingTheme.accent.opacity(0.85))
                        .frame(width: 7, height: 7)
                )
            Text(copy.islandHint)
                .font(OnboardingTheme.sans(11.5))
                .foregroundColor(OnboardingTheme.muted)
        }
    }

    /// Maps the demo controller's scripted phase onto the orb's
    /// production modes.
    private static func mode(for phase: OnboardingOrbController.Phase) -> VoiceOrbMode {
        switch phase {
        case .recording, .pressFlashAgain: return .dropVoice
        case .thinking: return .dropProcessing
        default: return .idle
        }
    }
}

// MARK: - Step row (keycaps + flash)

private struct DropStepRow: View {
    let n: Int
    let label: String
    let desc: String
    let chord: [KeycapContent]?
    var capState: DropCapState = .rest
    var holdLevel: CGFloat = 0

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
                    if let chord {
                        DropKeycapChord(contents: chord, state: capState, holdLevel: holdLevel)
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

// MARK: - Keycap chord (config-driven)

/// Visual state of a Drop keycap during the demo:
/// - `rest`  — raised, idle key.
/// - `held`  — pressed *and kept down*: the cap sinks, picks up an accent
///   tint, and emits an accent glow that pulses with `holdLevel` (the live
///   voice level) so it reads as "holding while speaking", not a tap.
/// - `flash` — a brief white pop used for the release beat.
private enum DropCapState: Equatable {
    case rest
    case held
    case flash
}

private struct DropKeycapChord: View {
    let contents: [KeycapContent]
    var state: DropCapState = .rest
    /// Live voice level [0…1] driving the held-glow pulse. Ignored unless `held`.
    var holdLevel: CGFloat = 0

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
                Text(value).font(.system(size: 12, weight: .semibold))
            case .symbol(let name, _):
                Image(systemName: name).font(.system(size: 10, weight: .semibold))
            case .prefixedGlyph(let prefix, let glyph, _):
                HStack(spacing: 3) {
                    Text(prefix).font(.system(size: 8, weight: .medium)).opacity(0.85)
                    Text(glyph).font(.system(size: 12, weight: .semibold))
                }
            }
        }
    }

    private func capChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundColor(foregroundColor)
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(strokeColor, lineWidth: state == .held ? 1 : 0.5)
            )
            // Held key sinks slightly, as if physically pressed and kept down.
            .offset(y: state == .held ? 1.5 : 0)
            // Accent glow only while held; its strength tracks the live voice
            // level so the cap visibly "breathes" with speech instead of
            // flashing once. No repeatForever timer (avoids main-thread stalls).
            .shadow(
                color: state == .held ? OnboardingTheme.accent.opacity(0.30 + 0.45 * holdLevel) : .clear,
                radius: state == .held ? 5 + 9 * holdLevel : 0,
                x: 0,
                y: 0
            )
            .animation(.easeOut(duration: 0.30), value: state)
            .animation(.easeOut(duration: 0.12), value: holdLevel)
    }

    private var foregroundColor: Color {
        switch state {
        case .rest, .held: return OnboardingTheme.ink
        case .flash: return OnboardingTheme.bg
        }
    }

    private var fillColor: Color {
        switch state {
        case .rest: return OnboardingTheme.surface
        case .held: return OnboardingTheme.accent.opacity(0.22)
        case .flash: return Color.white
        }
    }

    private var strokeColor: Color {
        switch state {
        case .rest, .flash: return OnboardingTheme.borderStrong
        case .held: return OnboardingTheme.accent.opacity(0.70)
        }
    }
}

// MARK: - Backdrop (blue accent wash)

private struct DropBackdrop: View {
    var body: some View {
        OnboardingTheme.surface2
            .overlay(
                ZStack {
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(red: 0.55, green: 0.79, blue: 1.0).opacity(0.18), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.18, y: 0.18),
                        startRadius: 0,
                        endRadius: 560
                    )
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color.white.opacity(0.03), location: 0),
                            .init(color: .clear, location: 0.6)
                        ]),
                        center: UnitPoint(x: 0.85, y: 0.85),
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            )
    }
}

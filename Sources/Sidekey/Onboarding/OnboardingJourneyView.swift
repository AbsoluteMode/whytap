import AppKit
import SwiftUI

/// The new onboarding's one small window: a progress bar, one step, a
/// footer with Back. Layout and controls only; the final visual design and
/// motion replace this frame without changing the model.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
struct OnboardingJourneyView: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var hotkeys = HotkeyPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 560, height: 460)

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                content(model.step)
                    .id(model.step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24)),
                        removal: .opacity.combined(with: .offset(x: -24))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .clipped()
            .animation(reduceMotion ? .linear(duration: 0.12) : .easeOut(duration: 0.28), value: model.step)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(OnboardingTheme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            OnboardingJourneyProgress(fraction: model.fraction)
            HStack {
                Text(Self.label(model.step).uppercased())
                    .font(OnboardingTheme.mono(10, weight: .medium))
                    .tracking(1.4)
                    .foregroundColor(OnboardingTheme.faint)
                Spacer()
                if let index = model.steps.firstIndex(of: model.step) {
                    Text("\(index + 1) / \(model.steps.count)")
                        .font(OnboardingTheme.mono(10, weight: .medium))
                        .foregroundColor(OnboardingTheme.faint)
                        .accessibilityLabel("Step \(index + 1) of \(model.steps.count)")
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 40)
        .padding(.bottom, 18)
    }

    static func label(_ step: OnboardingStep) -> String {
        switch step {
        case .source: return "Speech"
        case .speechKey: return "Speech key"
        case .llmKey: return "Language model"
        case .search: return "Search"
        case .language: return "Language"
        case .keyboard: return "Keyboard control"
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Keyboard access"
        case .screenRecording: return "Screen Recording"
        case .tryDrop: return "Try Drop"
        case .hotkeys: return "Shortcuts"
        case .toolbox: return "Toolbox"
        case .help: return "Help"
        case .thanks: return "Done"
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private func content(_ step: OnboardingStep) -> some View {
        switch step {
        case .source: OnboardingSourceStep(model: model, onDevice: model.onDevice)
        case .speechKey:
            OnboardingKeyStep(model: model, step: .speechKey, title: "Your speech key",
                              lede: "One key for Drop, Agent voice, Voice search and Meetings.",
                              providers: OnboardingJourneyModel.speechProviders, selection: $model.speechProvider) { key, kind in
                await model.useSpeechKey(key, provider: kind)
            }
        case .llmKey:
            OnboardingKeyStep(model: model, step: .llmKey, title: "A language model",
                              lede: "Optional. Cleans up Smart dictation, writes meeting notes, runs the Agent and translates.",
                              providers: OnboardingJourneyModel.llmProviders, selection: $model.llmProvider) { key, kind in
                await model.useLLMKey(key, provider: kind)
            }
        case .search: OnboardingSearchStep(model: model)
        case .language:
            OnboardingStepFrame(title: "Which language do you speak?", lede: "Auto works too: the provider listens for it.") {
                OnboardingLanguageList(selected: model.language, rowsHeight: 120) { model.setLanguage($0) }
            }
        case .keyboard:
            OnboardingPermissionStep(model: model, step: step, icon: "keyboard", title: "Keyboard control",
                                     lede: "To hear your Drop shortcut and type the text where your cursor is.",
                                     action: model.requestKeyboard)
        case .microphone:
            OnboardingPermissionStep(model: model, step: step, icon: "mic", title: "Microphone",
                                     lede: "To hear you, only while you hold the shortcut.",
                                     action: model.requestMicrophone)
        case .inputMonitoring:
            OnboardingPermissionStep(model: model, step: step, icon: "keyboard.badge.eye", title: "Keyboard access",
                                     lede: "This Mac also asks for Input Monitoring before Drop can see its shortcut.",
                                     action: model.requestInputMonitoring)
        case .screenRecording:
            OnboardingPermissionStep(model: model, step: step, icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                                     lede: "Optional. For Shot and when you ask the Agent about your screen.",
                                     action: model.requestScreenRecording)
        case .tryDrop: OnboardingTryStep(model: model, configuration: hotkeys.configuration)
        case .hotkeys:
            OnboardingStepFrame(title: "Every tool has a shortcut", lede: "Give any tool its own keys in Settings → Hotkeys.") {
                OnboardingOutlineButton(title: "Open Hotkeys") { model.openSettings(.hotkeys, nil) }
            }
        case .toolbox:
            OnboardingStepFrame(title: "Tools above the island", lede: "Hover the island to reach them. Pick yours in Settings → Toolbox.") {
                OnboardingOutlineButton(title: "Open Toolbox") { model.openSettings(.toolbox, nil) }
            }
        case .help:
            OnboardingStepFrame(title: "Questions?", lede: "The agent on whytap.ai answers them with step-by-step instructions.") {
                Link("Open whytap.ai", destination: URL(string: "https://whytap.ai")!)
                    .font(OnboardingTheme.sans(13, weight: .medium))
                    .foregroundColor(OnboardingTheme.accent)
            }
        case .thanks:
            OnboardingStepFrame(title: "Thank you for choosing Whytap", lede: model.summary) { EmptyView() }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .trailing, spacing: 8) {
            OnboardingOutcomeLine(outcome: model.outcome(model.step), notes: model.notes)
            HStack(spacing: 10) {
                if model.canGoBack {
                    OnboardingQuietButton(title: "Back", systemImage: "chevron.left", action: model.back)
                        .help("Back (←)")
                }
                Spacer(minLength: 0)
                if model.step.isInformational {
                    OnboardingPrimaryButton(title: model.step == .thanks ? "Done" : "Next", action: model.next)
                } else if !model.outcome(model.step).isDone {
                    OnboardingQuietButton(title: model.step.isOptional ? "Skip" : "Set up later", action: model.next)
                }
            }
        }
        .frame(height: 64, alignment: .bottom)
        .padding(.horizontal, 32)
        .padding(.bottom, 22)
    }
}

// MARK: - Pieces

struct OnboardingJourneyProgress: View {
    let fraction: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(OnboardingTheme.surface3)
                Capsule().fill(OnboardingTheme.accent)
                    .frame(width: max(4, proxy.size.width * fraction))
            }
        }
        .frame(height: 3)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: fraction)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

struct OnboardingStepFrame<Content: View>: View {
    let title: String
    let lede: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(OnboardingTheme.serif(34))
                .foregroundColor(OnboardingTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !lede.isEmpty {
                Text(lede)
                    .font(OnboardingTheme.sans(13))
                    .foregroundColor(OnboardingTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            content.padding(.top, 22)
        }
    }
}

struct OnboardingOutcomeLine: View {
    let outcome: OnboardingStepOutcome
    let notes: [String]

    var body: some View {
        HStack(spacing: 6) {
            switch outcome {
            case .idle:
                if let note = notes.first { text(note, OnboardingTheme.muted) }
            case .working(let message):
                ProgressView().controlSize(.mini)
                text(message, OnboardingTheme.muted)
            case .done(let message):
                Image(systemName: "checkmark.circle.fill").foregroundColor(OnboardingTheme.green)
                text(message, OnboardingTheme.ink2)
            case .failed(let message):
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(OnboardingTheme.orange)
                text(message, OnboardingTheme.orange)
            }
        }
        .font(OnboardingTheme.sans(12))
        .frame(minHeight: 16)
        .accessibilityElement(children: .combine)
    }

    private func text(_ string: String, _ color: Color) -> some View {
        Text(string).foregroundColor(color).lineLimit(2).multilineTextAlignment(.trailing)
    }
}

struct OnboardingChoiceCard: View {
    let icon: String
    let title: String
    let detail: String
    var selected = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon).font(.system(size: 20, weight: .medium)).foregroundColor(OnboardingTheme.accent)
                Text(title).font(OnboardingTheme.sans(15, weight: .semibold)).foregroundColor(OnboardingTheme.ink)
                Text(detail).font(OnboardingTheme.sans(12)).foregroundColor(OnboardingTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(hovered ? OnboardingTheme.surface2 : OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? OnboardingTheme.accent : OnboardingTheme.border, lineWidth: selected ? 1.2 : 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 1. Source

struct OnboardingSourceStep: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController

    var body: some View {
        OnboardingStepFrame(title: "Where should speech run?", lede: "You can change it any time in Settings.") {
            HStack(spacing: 12) {
                OnboardingChoiceCard(icon: "laptopcomputer", title: "On this Mac",
                                     detail: onDevice.status == .ready ? "The model is here. Nothing leaves this Mac."
                                                                       : "A 470 MB download. Nothing leaves this Mac.",
                                     selected: model.progress.source == .onThisMac, action: model.chooseOnThisMac)
                OnboardingChoiceCard(icon: "key", title: "Your key",
                                     detail: "Soniox, Deepgram or ElevenLabs. Often more accurate, with free credit.",
                                     selected: model.progress.source == .yourKey, action: model.chooseYourKey)
            }
        }
    }
}

// MARK: - 2–3. Keys

struct OnboardingKeyStep: View {
    @ObservedObject var model: OnboardingJourneyModel
    let step: OnboardingStep
    let title: String
    let lede: String
    let providers: [AIProviderKind]
    @Binding var selection: AIProviderKind
    let use: (String, AIProviderKind) async -> Void
    @State private var key = ""
    @FocusState private var focused: Bool

    var body: some View {
        let working: Bool = { if case .working = model.outcome(step) { return true } else { return false } }()
        let saved = model.keySaved(selection)
        OnboardingStepFrame(title: title, lede: lede) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $selection) {
                    ForEach(providers, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                HStack(spacing: 8) {
                    SecureField(saved ? "Saved — press Use, or paste a new key" : "Paste your \(selection.displayName) key", text: $key)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit(submit)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OnboardingTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(focused ? OnboardingTheme.accent.opacity(0.8) : OnboardingTheme.borderStrong,
                                          lineWidth: focused ? 1.2 : 0.75))
                        .disabled(working)
                    OnboardingOutlineButton(title: "Use", action: submit)
                        .fixedSize()
                        .disabled(working || (!saved && key.trimmingCharacters(in: .whitespaces).isEmpty))
                }
                if let hint = APIHintsView.hints.first(where: { $0.provider == selection.displayName }) {
                    Link("Get a key · \(hint.allowance) \(hint.cadence)", destination: hint.url)
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.accent)
                }
                if step == .llmKey, let model = self.model.preselectedModel(selection) {
                    Text("Model: \(model)")
                        .font(OnboardingTheme.mono(11))
                        .foregroundColor(OnboardingTheme.faint)
                }
            }
        }
        .onChange(of: selection) { _ in key = "" }
    }

    private func submit() {
        let candidate = key
        let kind = selection
        Task {
            await use(candidate, kind)
            if model.outcome(step).isDone { key = "" }
        }
    }
}

// MARK: - 4. Search

struct OnboardingSearchStep: View {
    @ObservedObject var model: OnboardingJourneyModel
    @State private var key = ""

    var body: some View {
        OnboardingStepFrame(title: "Web search for the Agent",
                            lede: "Optional. A free Tavily key lets the Agent look things up.") {
            HStack(spacing: 8) {
                SecureField("Paste your Tavily key", text: $key)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(OnboardingTheme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(OnboardingTheme.borderStrong, lineWidth: 0.75))
                OnboardingOutlineButton(title: "Use", action: submit)
                    .fixedSize()
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submit() {
        let candidate = key
        Task { await model.useSearchKey(candidate) }
    }
}

// MARK: - 6–8. Permissions

struct OnboardingPermissionStep: View {
    @ObservedObject var model: OnboardingJourneyModel
    let step: OnboardingStep
    let icon: String
    let title: String
    let lede: String
    let action: () -> Void

    var body: some View {
        let done = model.outcome(step).isDone
        OnboardingStepFrame(title: title, lede: lede) {
            HStack(spacing: 14) {
                Image(systemName: done ? "checkmark.circle.fill" : icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(done ? OnboardingTheme.green : OnboardingTheme.accent)
                    .frame(width: 40)
                if !done {
                    OnboardingPrimaryButton(title: "Allow", chevron: false, action: action)
                }
            }
        }
    }
}

// MARK: - 9. Try Drop

struct OnboardingTryStep: View {
    @ObservedObject var model: OnboardingJourneyModel
    let configuration: HotkeyConfiguration

    var body: some View {
        let copy = OnboardingTryPage.Copy(shortcut: configuration.dropVoiceShortcut.title,
                                          gesture: configuration.normalizedDropGesture)
        OnboardingStepFrame(title: "Try Drop", lede: "\(copy.pressVerb) your shortcut and say a sentence.") {
            VStack(alignment: .leading, spacing: 10) {
                OnboardingKeycaps(contents: configuration.dropVoiceShortcut.contents)
                OnboardingTryField(placeholder: copy.placeholder, onDictated: model.noteDictated)
                    .padding(10)
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(OnboardingTheme.surface))
            }
        }
    }
}

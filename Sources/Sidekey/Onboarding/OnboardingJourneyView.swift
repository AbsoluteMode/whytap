import AppKit
import SwiftUI

/// The onboarding's one small window: a fixed Back slot, the grouped progress
/// rail and the step count; one step on a stage; a footer with Skip or Set up
/// later on the left and the dwell pill on the right. A successful action
/// moves on by itself; the pointer over the stage holds it.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
struct OnboardingJourneyView: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var dwell: OnboardingDwellController
    @ObservedObject var hotkeys: HotkeyPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = OnboardingTheme.compactCanvas

    init(model: OnboardingJourneyModel) {
        self.model = model
        self.dwell = model.dwell
        self.hotkeys = model.hotkeys
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .topLeading) {
                stage(model.step)
                    .id(model.step)
                    .transition(.onboardingStep(direction: model.direction, reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, OnboardingTheme.compactHorizontalInset)
            .clipped()
            .contentShape(Rectangle())
            // The Dwell Latch: a pointer on the step holds the automatic move.
            .onHover { inside in inside ? dwell.latch() : dwell.resume() }
            .animation(OnboardingMotion.resolve(OnboardingMotion.stepGlide, reduceMotion: reduceMotion, allowFade: true),
                       value: model.step)
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(OnboardingTheme.bg)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            OnboardingBackButton(isVisible: model.canGoBack,
                                 destination: OnboardingJourney.previous(before: model.step, in: model.steps)?.shortTitle,
                                 action: model.back)
            OnboardingProgressRail(segments: model.segments, dwellFraction: dwell.fraction, isLatched: dwell.isLatched)
            Text(counter)
                .font(OnboardingTheme.mono(10.5, weight: .medium))
                .foregroundColor(OnboardingTheme.faint)
                .monospacedDigit()
                .frame(minWidth: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .frame(height: OnboardingTheme.compactHeaderHeight)
        .padding(.top, 14)
    }

    private var counter: String {
        let segments = model.segments
        let index = (segments.firstIndex { $0.state == .current } ?? 0) + 1
        return String(format: "%02d / %02d", index, segments.count)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            leftAction
            if let note = model.notes.first, model.step == .speechKey || model.step == .llmKey || model.step == .source {
                Text(note)
                    .font(OnboardingTheme.sans(11))
                    .foregroundColor(OnboardingTheme.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.notes.joined(separator: "\n"))
            }
            Spacer(minLength: 0)
            rightAction
        }
        .padding(.horizontal, OnboardingTheme.compactHorizontalInset)
        .frame(height: OnboardingTheme.compactFooterHeight)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var leftAction: some View {
        let outcome = model.outcome(model.step)
        if model.step == .hotkeys {
            OnboardingOutlineButton(title: "Open Hotkeys") { model.openSettings(.hotkeys, nil) }.fixedSize()
        } else if model.step == .toolbox {
            OnboardingOutlineButton(title: "Open Toolbox") { model.openSettings(.toolbox, nil) }.fixedSize()
        } else if !model.step.isInformational, !outcome.isDone, dwell.state == .idle {
            Button(model.step.isOptional ? "Skip" : "Set up later", action: model.next)
                .buttonStyle(.plain)
                .font(OnboardingTheme.sans(12, weight: .medium))
                .foregroundColor(OnboardingTheme.muted)
                .help(model.step.isOptional ? "Skip this step" : "Continue without it; it's in Settings any time")
        }
    }

    @ViewBuilder private var rightAction: some View {
        if dwell.state != .idle {
            OnboardingDwellPill(dwell: dwell)
        } else if model.step != .thanks, model.step.isInformational || model.outcome(model.step).isDone {
            OnboardingPrimaryButton(title: "Next", action: model.next)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private func stage(_ step: OnboardingStep) -> some View {
        switch step {
        case .source:
            OnboardingJourneyStep(act: step.act, title: "Where should speech run?",
                                  lede: "Change it any time in Settings → API & Models.") {
                OnboardingSourceChoice(model: model, onDevice: model.onDevice)
            }
        case .speechKey:
            OnboardingJourneyStep(act: step.act, title: "Your speech key",
                                  lede: "One key runs Drop, Agent voice, Voice search and Meetings.") {
                OnboardingKeySlot(providers: Self.options(model.speechProviders),
                                  selected: providerBinding(\.speechProvider),
                                  outcome: model.outcome(.speechKey),
                                  savedKey: model.keySaved(model.speechProvider)) { key in
                    let provider = model.speechProvider
                    Task { await model.useSpeechKey(key, provider: provider) }
                }
            }
        case .llmKey:
            OnboardingJourneyStep(act: step.act, title: "A language model",
                                  lede: "Optional. Smart dictation, meeting notes, the Agent and Translate.") {
                VStack(alignment: .leading, spacing: 10) {
                    OnboardingKeySlot(providers: Self.options(OnboardingJourneyModel.llmProviders),
                                      selected: providerBinding(\.llmProvider),
                                      outcome: model.outcome(.llmKey),
                                      savedKey: model.keySaved(model.llmProvider)) { key in
                        let provider = model.llmProvider
                        Task { await model.useLLMKey(key, provider: provider) }
                    }
                    if !model.outcome(.llmKey).isDone, let preselected = model.preselectedModel(model.llmProvider) {
                        Text("Model: \(preselected) · change it later in Models")
                            .font(OnboardingTheme.mono(10.5))
                            .foregroundColor(OnboardingTheme.faint)
                            .lineLimit(1)
                    }
                }
            }
        case .search:
            OnboardingJourneyStep(act: step.act, title: "Web search for the Agent",
                                  lede: "Optional. A Tavily key lets the Agent look things up.") {
                OnboardingKeySlot(providers: [Self.tavilyOption], selected: .constant(Self.tavilyOption.name),
                                  outcome: model.outcome(.search), savedKey: false) { key in
                    Task { await model.useSearchKey(key) }
                }
            }
        case .language:
            OnboardingJourneyStep(act: step.act, title: "Which language do you speak?",
                                  lede: "Auto works too: the provider listens for it.") {
                OnboardingLanguageList(selected: model.language, rowsHeight: 150) { model.setLanguage($0) }
            }
        case .keyboard:
            permission(step, icon: "keyboard", title: "Keyboard control",
                       purpose: "To hear your Drop shortcut and type the text where your cursor is.",
                       section: "PRIVACY & SECURITY › ACCESSIBILITY", request: model.requestKeyboard)
        case .microphone:
            permission(step, icon: "mic", title: "Microphone",
                       purpose: "To hear you, only while Drop is recording.",
                       section: "PRIVACY & SECURITY › MICROPHONE", request: model.requestMicrophone)
        case .inputMonitoring:
            permission(step, icon: "keyboard.badge.eye", title: "Input Monitoring",
                       purpose: "This Mac also asks for it before Drop can see its shortcut.",
                       section: "PRIVACY & SECURITY › INPUT MONITORING", request: model.requestInputMonitoring)
        case .screenRecording:
            permission(step, icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                       purpose: "Optional. For Shot, and when you ask the Agent about your screen.",
                       section: "PRIVACY & SECURITY › SCREEN RECORDING", request: model.requestScreenRecording)
        case .tryDrop: tryDropStage
        case .hotkeys:
            OnboardingJourneyStep(act: step.act, title: "Every tool has a shortcut",
                                  lede: "These are yours now. Change them in Settings → Hotkeys.") {
                OnboardingShortcutList(configuration: hotkeys.configuration, agentEnabled: model.agentEnabled())
            }
        case .toolbox:
            OnboardingJourneyStep(act: step.act, title: "Tools above the island",
                                  lede: "Hover the island at the top of the screen. Pick yours in Settings → Toolbox.") {
                OnboardingToolboxPreview(slots: model.toolbox.slots)
            }
        case .help:
            OnboardingJourneyStep(act: step.act, title: "Questions?",
                                  lede: "The agent on whytap.ai answers with steps for your setup.") {
                OnboardingHelpCard()
            }
        case .thanks:
            OnboardingJourneyStep(act: step.act, title: "Thank you for choosing Whytap", lede: "") {
                OnboardingThankYouCard(receipt: model.receipt,
                                       hint: "Settings has everything you set here.",
                                       finish: model.finish)
            }
        }
    }

    private var tryDropStage: some View {
        let model = self.model
        let problem: String? = { if case .failed(let reason) = model.outcome(.tryDrop) { return reason } else { return nil } }()
        var simulate: (() -> Void)?
        if model.isPreview { simulate = { model.noteDictated() } }
        return OnboardingJourneyStep(act: OnboardingStep.tryDrop.act, title: "Try Drop", lede: "Your own shortcut, in a real text field.") {
            OnboardingTryStage(shortcut: hotkeys.configuration.dropVoiceShortcut,
                               gesture: hotkeys.configuration.normalizedDropGesture,
                               dictated: model.outcome(.tryDrop).isDone,
                               problem: problem,
                               onDictated: model.noteDictated,
                               simulate: simulate)
        }
    }

    private func permission(_ step: OnboardingStep, icon: String, title: String, purpose: String, section: String,
                            request: @escaping () -> Void) -> some View {
        let phase: OnboardingPermissionPhase = model.outcome(step).isDone ? .granted
            : model.requested.contains(step) ? .awaitingSystem : .ready
        return OnboardingJourneyStep(act: step.act, title: title, lede: "macOS asks once. Whytap waits here.") {
            OnboardingPermissionCard(icon: icon, title: title, purpose: purpose, section: section, phase: phase,
                                     request: request, recheck: model.recheckPermissions)
        }
    }

    private func providerBinding(_ path: ReferenceWritableKeyPath<OnboardingJourneyModel, AIProviderKind>) -> Binding<String> {
        Binding(get: { model[keyPath: path].displayName },
                set: { name in
                    if let kind = (model.speechProviders + OnboardingJourneyModel.llmProviders)
                        .first(where: { $0.displayName == name }) { model[keyPath: path] = kind }
                })
    }

    /// The provider strip with each provider's real offer from API hints;
    /// a provider without a free offer shows none.
    static func options(_ kinds: [AIProviderKind]) -> [OnboardingProviderOption] {
        kinds.map { kind in
            let hint = APIHintsView.hints.first { $0.provider == kind.displayName && $0.access == .noCard }
            return OnboardingProviderOption(kind: kind, name: kind.displayName,
                                            hint: hint.map { shortOffer($0) }, offerURL: hint?.url ?? signUpURL(kind))
        }
    }

    static let tavilyOption: OnboardingProviderOption = {
        let hint = APIHintsView.hints.first { $0.provider == "Tavily" }
        return OnboardingProviderOption(kind: nil, name: "Tavily", hint: hint.map { shortOffer($0) },
                                        offerURL: hint?.url ?? URL(string: "https://www.tavily.com")!)
    }()

    /// "$200 credit", "10,000 credits / mo", "50 free / day", "1,000 free / mo".
    static func shortOffer(_ hint: APIHintsView.Hint) -> String {
        let cadence = hint.cadence
        if cadence.contains("one-time") { return "\(hint.allowance) credit" }
        let parts = hint.allowance.components(separatedBy: " / ")
        if parts.count == 2 { return "\(parts[0]) free / \(parts[1])" }
        if cadence.contains("each month") { return "\(hint.allowance) free / mo" }
        return "\(hint.allowance) free"
    }

    static func signUpURL(_ kind: AIProviderKind) -> URL? {
        switch kind {
        case .soniox: return URL(string: "https://console.soniox.com")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openAI: return URL(string: "https://platform.openai.com/api-keys")
        case .openRouter: return URL(string: "https://openrouter.ai/keys")
        case .deepgram: return URL(string: "https://console.deepgram.com")
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        default: return nil
        }
    }
}

// MARK: - Step frame

/// The act label, a serif title, an optional lede and the step's stage.
struct OnboardingJourneyStep<Content: View>: View {
    let act: OnboardingAct
    let title: String
    let lede: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(act.rawValue)
                .font(OnboardingTheme.mono(9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundColor(OnboardingTheme.faint)
                .accessibilityHidden(true)
            Text(title)
                .font(OnboardingTheme.serif(30))
                .foregroundColor(OnboardingTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            if !lede.isEmpty {
                Text(lede)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            content.padding(.top, 18)
        }
        .padding(.top, 14)
    }
}

// MARK: - 1. Source

struct OnboardingSourceChoice: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController

    var body: some View {
        let source = model.progress.source
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if model.start.onDeviceSupported {
                    OnboardingChoiceCard(title: "On this Mac", summary: "Free. Works offline. Your voice never leaves this Mac.",
                                         spec: onDeviceSpec, isSelected: source == .onThisMac,
                                         isDimmed: source == .yourKey, action: model.chooseOnThisMac) {
                        HStack(spacing: 8) {
                            Image(systemName: "laptopcomputer").font(.system(size: 13, weight: .medium))
                                .foregroundColor(OnboardingTheme.ink2)
                            Spacer(minLength: 0)
                            OnboardingBadge(text: "OFFLINE")
                        }
                    }
                }
                OnboardingChoiceCard(title: "Your API key", summary: "Soniox, Deepgram or ElevenLabs. You pay the provider for what you use.",
                                     spec: "KEY STAYS IN YOUR KEYCHAIN", isSelected: source == .yourKey,
                                     isDimmed: source == .onThisMac, action: model.chooseYourKey) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal").font(.system(size: 13, weight: .medium))
                            .foregroundColor(OnboardingTheme.ink2)
                        Spacer(minLength: 0)
                        Text("SONIOX · DEEPGRAM · ELEVENLABS")
                            .font(OnboardingTheme.mono(8.5, weight: .medium))
                            .foregroundColor(OnboardingTheme.faint)
                            .lineLimit(1)
                    }
                }
            }
            if case .failed(let reason) = model.outcome(.source) {
                OnboardingStageStatus(tone: .warning, text: reason)
            }
        }
    }

    private var onDeviceSpec: String {
        switch onDevice.status {
        case .ready: return "PARAKEET TDT V3 · DOWNLOADED"
        case .downloading(let fraction): return "DOWNLOADING · \(Int((fraction * 100).rounded()))%"
        case .notDownloaded, .failed: return "PARAKEET TDT V3 · 470 MB"
        }
    }
}

// MARK: - 10. Shortcuts

/// Drop, Agent and Shot with the person's own keys from HotkeyConfiguration.
struct OnboardingShortcutList: View {
    let configuration: HotkeyConfiguration
    let agentEnabled: Bool

    var body: some View {
        let drop = OnboardingTryPage.Copy(shortcut: configuration.dropVoiceShortcut.title,
                                          gesture: configuration.normalizedDropGesture)
        VStack(spacing: 8) {
            OnboardingInfoRow(title: "Drop", detail: "\(drop.pressVerb) in any text field and speak") {
                OnboardingKeycaps(contents: configuration.dropVoiceShortcut.contents)
            }
            OnboardingInfoRow(title: "Agent", detail: agentEnabled
                              ? "Tap to type a question, hold to ask by voice"
                              : "Turn it on in Settings → Other") {
                OnboardingKeycaps(contents: configuration.agentTextShortcut.contents)
            }
            OnboardingInfoRow(title: "Shot", detail: "Capture, mark up and copy part of the screen") {
                if let shot = configuration.toolShortcuts[.screenshot] {
                    OnboardingKeycaps(contents: shot.contents)
                } else {
                    Text("No shortcut yet")
                        .font(OnboardingTheme.sans(11.5))
                        .foregroundColor(OnboardingTheme.faint)
                }
            }
        }
    }
}

// MARK: - 11. Toolbox

/// The person's own hover tools, in their saved order.
struct OnboardingToolboxPreview: View {
    let slots: [HoverTool]

    var body: some View {
        let tools = slots.filter { $0 != .settings && !$0.isComingSoon }.prefix(6)
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Array(tools), id: \.self) { tool in
                    let info = HoverToolRegistry.info(for: tool)
                    VStack(spacing: 6) {
                        Image(systemName: info.sfSymbol)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(OnboardingTheme.accent)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.white.opacity(0.92)))
                        Text(info.title)
                            .font(OnboardingTheme.sans(11, weight: .medium))
                            .foregroundColor(OnboardingTheme.ink2)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                    .onboardingElevatedCard(cornerRadius: 12)
                    .help(info.description)
                }
            }
        }
    }
}

// MARK: - 12. Help

/// A real question and its real answer, then the link.
struct OnboardingHelpCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Text("How do I give Shot its own shortcut?")
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(OnboardingTheme.surface3))
                }
                Text("Open Settings → Hotkeys → Tools, click the field next to Shot and press the keys.")
                    .font(OnboardingTheme.sans(12))
                    .foregroundColor(OnboardingTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .onboardingRecessed(cornerRadius: 10)
            }
            .padding(12)
            .onboardingElevatedCard(cornerRadius: 13)
            Link(destination: URL(string: "https://whytap.ai")!) {
                HStack(spacing: 4) {
                    Text("Ask on whytap.ai")
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .font(OnboardingTheme.sans(12.5, weight: .medium))
                .foregroundColor(OnboardingTheme.accent)
            }
            .buttonStyle(.plain)
        }
    }
}

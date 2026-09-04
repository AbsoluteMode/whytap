import SwiftUI

final class OnboardingLifecycleEvents: ObservableObject {
    @Published private(set) var stopAudioRequest: UUID?

    func stopAudio() {
        stopAudioRequest = UUID()
    }
}

/// Top-level switcher between onboarding screens. Active order is
/// `permissions → tryDrop (live) → skills → helpers`; `.language`, `.drop`
/// (demo), `.agent` and `.tryAgent` are reachable only via Back / resume
/// state. There is no sign-in: the app is fully local, so a first run lands
/// straight on the permissions step. Each step has its own screen file;
/// this view owns the cross-step state (permissions surface, selected
/// language).
struct OnboardingFlowView: View {
    /// Initial step. The host (`AppDelegate` via `OnboardingWindowController`)
    /// passes `.permissions` on a fresh run, or a resumed step.
    let initialStep: OnboardingFlowStep
    let onTryStepRuntimeRequired: () -> Void
    let onTryStepRuntimeNoLongerRequired: () -> Void
    let onStepChanged: (OnboardingFlowStep) -> Void
    let onCapabilityToggle: (OnboardingSkillCapability, Bool) -> Void
    let onFinish: () -> Void

    @ObservedObject private var lifecycleEvents: OnboardingLifecycleEvents
    // Live hotkey config so the welcome/try-Drop screens flash the real
    // Drop chord (post-cutover: hold Space) from the single source of
    // truth. The onboarding-preview executable uses the screens' default
    // chord instead (it has no `HotkeyPreferences`).
    @ObservedObject private var hotkeys: HotkeyPreferences = .shared
    @State private var step: OnboardingFlowStep
    @StateObject private var agentOrb = OnboardingAgentController(
        samples: OnboardingAgentController.Sample.demoSet,
        audioURLProvider: OnboardingAudioResources.url(forSample:)
    )
    // Drives the auto-demo on the merged Drop screen (idle state) until
    // the user engages the field. Dictation-flavoured sample transcript.
    @StateObject private var dropOrb = OnboardingOrbController(
        transcript: "Hey, just confirming our sync moved to Thursday at 3 — I’ll send an updated invite shortly. Thanks!",
        audioURL: OnboardingAudioResources.welcomeVoiceURL()
    )
    @StateObject private var permissions: RealOnboardingPermissionsSurface
    @StateObject private var agentSetup = RealOnboardingAgentSetupSurface()
    @State private var selectedLanguage: AppLanguage? = nil
    // Onboarding UI language (EN/RU). Independent of `selectedLanguage`
    // (the transcription language). Injected so every step reads it and
    // re-renders live when the top-trailing toggle flips. ROO-261.
    @StateObject private var uiLocale = OnboardingLocale()

    init(
        initialStep: OnboardingFlowStep = .permissions,
        lifecycleEvents: OnboardingLifecycleEvents = OnboardingLifecycleEvents(),
        onTryStepRuntimeRequired: @escaping () -> Void = {},
        onTryStepRuntimeNoLongerRequired: @escaping () -> Void = {},
        onStepChanged: @escaping (OnboardingFlowStep) -> Void = { _ in },
        onCapabilityToggle: @escaping (OnboardingSkillCapability, Bool) -> Void = { _, _ in },
        onExternalPermissionHandoff: @escaping () -> Void = {},
        onExternalPermissionReturn: @escaping () -> Void = {},
        onFinish: @escaping () -> Void
    ) {
        self.initialStep = initialStep
        self.lifecycleEvents = lifecycleEvents
        self.onTryStepRuntimeRequired = onTryStepRuntimeRequired
        self.onTryStepRuntimeNoLongerRequired = onTryStepRuntimeNoLongerRequired
        self.onStepChanged = onStepChanged
        self.onCapabilityToggle = onCapabilityToggle
        self.onFinish = onFinish
        _permissions = StateObject(
            wrappedValue: RealOnboardingPermissionsSurface(
                onExternalPermissionHandoff: onExternalPermissionHandoff,
                onExternalPermissionReturn: onExternalPermissionReturn
            )
        )
        _step = State(
            initialValue: OnboardingResumeStore.resolvedInitialStep(
                fallback: initialStep,
                needsPermissions: initialStep == .permissions
            )
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                stepBody
            }
            .environmentObject(uiLocale)
            // Top-trailing controls, laid out right-to-left: the EN/RU
            // language toggle is the outermost (far corner, present on
            // every step); the demo mute button — when shown — sits to
            // its left so the two never overlap.
            HStack(spacing: 10) {
                if showsDemoMuteButton {
                    OnboardingMuteButton(
                        isMuted: isDemoMuted,
                        onToggle: toggleDemoMute
                    )
                }
                OnboardingLanguageToggle()
                    .environmentObject(uiLocale)
            }
            .padding(.top, 8)
            .padding(.trailing, 10)
        }
        .frame(
            width: OnboardingTheme.canvasWidth,
            height: OnboardingTheme.canvasHeight
        )
        .background(OnboardingTheme.bg)
        .preferredColorScheme(.dark)
        .onAppear {
            onStepChanged(step)
            syncWhytapSurface(for: step)
        }
        .onDisappear {
            stopDemoAudio()
            onTryStepRuntimeNoLongerRequired()
        }
        .onChange(of: lifecycleEvents.stopAudioRequest) { _, request in
            guard request != nil else { return }
            stopDemoAudio()
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .agent:
            OnboardingAgentScreen(
                orb: agentOrb,
                onBack: { advance(to: .tryDrop) },
                onNext: { advance(to: .tryAgent) }
            )
        case .tryAgent:
            // Retired from the active flow (Skills page replaced it);
            // kept so resume state and source guards stay valid.
            OnboardingAgentTryScreen(
                surface: agentSetup,
                onBack: { advance(to: .tryDrop) },
                onContinue: { advance(to: .helpers) }
            )
        case .skills:
            OnboardingSkillsScreen(
                agentSurface: agentSetup,
                initialAgentEnabled: UserPreferencesCache.shared.currentAgentEnabled,
                initialMeetingsEnabled: UserPreferencesCache.shared.currentMeetingsEnabled,
                initialGoogleEnabled: UserPreferencesCache.shared.currentGoogleEnabled,
                onToggle: onCapabilityToggle,
                onBack: { advance(to: .tryDrop) },
                onContinue: { advance(to: .helpers) }
            )
        case .helpers:
            OnboardingSuperAssistantScreen(
                onBack: { advance(to: .skills) },
                onContinue: finishOnboarding
            )
        case .permissions:
            OnboardingPermissionsScreen(
                surface: permissions,
                onBack: nil,
                onContinue: { advance(to: .tryDrop) }
            )
        case .language:
            OnboardingLanguageScreen(
                selected: Binding(
                    get: { selectedLanguage },
                    set: { newValue in
                        selectedLanguage = newValue
                    }
                ),
                onBack: { advance(to: .permissions) },
                onContinue: continueFromLanguage
            )
        case .drop:
            OnboardingDropScreen(
                orb: dropOrb,
                onBack: { advance(to: .language) },
                onContinue: { advance(to: .tryDrop) },
                dropChord: hotkeys.dropVoiceShortcut.contents,
                dropGestureWord: hotkeys.configuration.normalizedDropGesture.voiceTitle.lowercased()
            )
        case .tryDrop:
            OnboardingTryDropScreen(
                onBack: { advance(to: .permissions) },
                onContinue: { advance(to: .skills) },
                dropChord: hotkeys.dropVoiceShortcut.contents,
                dropGestureWord: hotkeys.configuration.normalizedDropGesture.voiceTitle.lowercased()
            )
        }
    }

    /// Terminal of the tour: hand off to the host's completion callback.
    /// Separate from `advance(to:)` because there is no `.completed` step —
    /// finishing `.helpers` ends the flow.
    private func finishOnboarding() {
        onFinish()
    }

    private func advance(to next: OnboardingFlowStep) {
        guard next != step else { return }
        stopDemoAudio()
        syncWhytapSurface(for: next)
        OnboardingResumeStore.save(next)
        onStepChanged(next)
        withAnimation(.easeInOut(duration: 0.24)) {
            step = next
        }
    }

    private func syncWhytapSurface(for step: OnboardingFlowStep) {
        if step.isTryStep {
            onTryStepRuntimeRequired()
        } else {
            onTryStepRuntimeNoLongerRequired()
        }
    }

    private var showsDemoMuteButton: Bool {
        switch step {
        case .agent, .drop:
            return true
        default:
            return false
        }
    }

    private var isDemoMuted: Bool {
        switch step {
        case .agent:
            return agentOrb.isMuted
        default:
            return dropOrb.isMuted
        }
    }

    private func toggleDemoMute() {
        let next = !isDemoMuted
        agentOrb.isMuted = next
        dropOrb.isMuted = next
    }

    private func continueFromLanguage() {
        PrivacyPreferences.shared.selectedLanguage = selectedLanguage
        advance(to: .drop)
    }

    private func stopDemoAudio() {
        agentOrb.stop()
        dropOrb.stop()
    }
}

private struct OnboardingMuteButton: View {
    let isMuted: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
                .overlay(
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(isMuted ? "Unmute onboarding audio" : "Mute onboarding audio")
        .accessibilityLabel(isMuted ? "Unmute onboarding audio" : "Mute onboarding audio")
    }
}

enum OnboardingFlowStep: String, Hashable {
    case permissions
    case language
    case drop
    case tryDrop
    case agent
    case tryAgent
    /// Capability opt-in page (Agent / Meetings / Google). Replaced the
    /// active Try-Agent step; `.tryAgent` is retired but kept valid for
    /// resume state.
    case skills
    case helpers

    var isTryStep: Bool {
        switch self {
        case .tryDrop, .tryAgent:
            return true
        default:
            return false
        }
    }
}

import AppKit
import SwiftUI

/// The onboarding's one small window: a fixed Back slot, the grouped progress
/// rail and the step count; one step on a stage; a footer with Skip or Set up
/// later on the left and Next on the right only when nothing moves on by
/// itself. A successful action moves on by itself, with no chip; Return goes
/// on at once.
// WHY: .project-docs/decisions/2026-11-22-onboarding-journey.md
@MainActor
struct OnboardingJourneyView: View {
    @ObservedObject var model: OnboardingJourneyModel
    @ObservedObject var dwell: OnboardingDwellController
    @ObservedObject var hotkeys: HotkeyPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Steps 1 and 2 share one scene, so the chosen key flies between them.
    @State private var wireScene = OnboardingWireScene()

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
                    .transition(flowsWithTheKey ? .onboardingKeyFlow(reduceMotion: reduceMotion)
                                : .onboardingStep(direction: model.direction, reduceMotion: reduceMotion))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, Self.isWireframe(model.step) ? 0 : OnboardingTheme.compactHorizontalInset)
            .clipped()
            .contentShape(Rectangle())
            .animation(OnboardingMotion.resolve(flowsWithTheKey ? OnboardingMotion.keyFlow : OnboardingMotion.stepGlide,
                                                reduceMotion: reduceMotion, allowFade: true),
                       value: model.step)
            footer
        }
        .coordinateSpace(name: OnboardingWireScene.space)
        .overlay {
            if let sceneStep = Self.wireSceneStep(model.step) {
                OnboardingWireSceneLayer(scene: wireScene, step: sceneStep)
                    .transition(.opacity)
            }
        }
        .animation(OnboardingMotion.resolve(OnboardingMotion.crossDissolve, reduceMotion: reduceMotion),
                   value: Self.isWireframe(model.step))
        .frame(width: Self.size.width, height: Self.size.height)
        .background(ground)
        // The page fills the window, title bar included: inside the safe area
        // the fixed page was centred and its footer ran past the bottom edge.
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }

    /// Step 1 and the two key steps draw on a softly lit ground (the
    /// wireframe pass); its edge is the window's own colour, so nothing shows
    /// a seam.
    static func isWireframe(_ step: OnboardingStep) -> Bool { true }

    /// The steps with their own capsule (Continue, Finish) and Skip: the
    /// footer adds no Next or Skip of its own there.
    static func hasOwnActions(_ step: OnboardingStep) -> Bool {
        [.tryDrop, .toolbox, .thanks].contains(step)
    }

    /// Between wireframe steps the key stays on the page (it flies from step 1
    /// to its lock, and the lock closes again for the language model key); the
    /// rest of the page flows under it as one slow dissolve, not a slide.
    private var flowsWithTheKey: Bool {
        guard Self.isWireframe(model.step) else { return false }
        let from = model.direction == .forward
            ? OnboardingJourney.previous(before: model.step, in: model.steps)
            : OnboardingJourney.next(after: model.step, in: model.steps)
        return from.map(Self.isWireframe) ?? false
    }

    /// Both key steps show the same key over the same padlock.
    static func wireSceneStep(_ step: OnboardingStep) -> OnboardingWireScene.Step? {
        switch step {
        case .source: return .source
        case .speechKey, .llmKey, .search: return .speechKey
        default: return nil
        }
    }

    private var ground: some View {
        ZStack {
            OnboardingTheme.bg
            Group {
                RadialGradient(colors: [OnboardingWireframeInk.groundCenter, OnboardingTheme.bg],
                               center: UnitPoint(x: 0.5, y: 0.47), startRadius: 10, endRadius: 330)
            }
            .opacity(Self.isWireframe(model.step) ? 1 : 0)
            .animation(OnboardingMotion.resolve(OnboardingMotion.crossDissolve, reduceMotion: reduceMotion), value: model.step)
            OnboardingGrain()
        }
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
        .padding(.top, 24)
    }

    private var counter: String {
        let segments = model.segments
        let index = (segments.firstIndex { $0.state == .current || $0.state == .revisited } ?? 0) + 1
        return String(format: "%02d / %02d", index, segments.count)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            leftAction
            if let note = model.notes.first, model.step == .llmKey {
                Text(note)
                    .font(OnboardingTheme.sans(11))
                    .foregroundColor(OnboardingTheme.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.notes.joined(separator: "\n"))
            } else if model.progress.source == .onThisMac, model.step != .source {
                // On the source step the laptop's caption says the same.
                OnboardingModelProgressStrip(onDevice: model.onDevice)
            }
            Spacer(minLength: 0)
            rightAction
        }
        // On the centred steps the secondary action lines up with the field.
        .padding(.horizontal, Self.isWireframe(model.step) ? OnboardingKeyStage.fieldInset
                                                           : OnboardingTheme.compactHorizontalInset)
        .frame(height: OnboardingTheme.compactFooterHeight)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var leftAction: some View {
        let outcome = model.outcome(model.step)
        // Toolbox names its Settings tab in the lede; a second "Open …"
        // button here said it twice.
        if model.step != .language, model.step != .source, model.step != .screenRecording, !Self.hasOwnActions(model.step),
                  !model.step.isInformational, !outcome.isDone, dwell.state == .idle {
            // Step 1 has no skip: its two figures are the choice. Screen
            // Recording and Try Drop have their own Skip under the capsule.
            Button(model.step.isOptional ? "Skip" : "Set up later", action: model.skip)
                .buttonStyle(OnboardingFeedbackButtonStyle(shape: .text))
                .font(OnboardingTheme.sans(12, weight: .medium))
                .help(model.step.isOptional ? "Skip this step" : "Continue without it; it's in Settings any time")
        }
    }

    /// No chip while a step moves on by itself (the owner removed "Next: …",
    /// "Paused" and "Continue · …" on every step): the move is the animation,
    /// and Return still goes on at once. A step reached by Back, or one that is
    /// done with no move pending, offers the plain Next.
    @ViewBuilder private var rightAction: some View {
        switch dwell.state {
        case .counting, .latched:
            Button("", action: dwell.commitNow)
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityLabel("Continue")
        case .reviewing:
            if model.step != .source, !Self.hasOwnActions(model.step) {
                OnboardingPrimaryButton(title: "Next", action: dwell.commitNow)
                    .keyboardShortcut(.defaultAction)
            }
        case .idle:
            if model.step != .source, !Self.hasOwnActions(model.step),
               model.step.isInformational || model.outcome(model.step).isDone {
                OnboardingPrimaryButton(title: "Next", action: model.next)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private func stage(_ step: OnboardingStep) -> some View {
        switch step {
        case .source:
            OnboardingSourceStage(model: model, onDevice: model.onDevice, scene: wireScene)
        case .speechKey:
            OnboardingKeyStage(kind: .speech, model: model, scene: wireScene)
        case .llmKey:
            OnboardingKeyStage(kind: .languageModel, model: model, scene: wireScene)
        case .search:
            OnboardingKeyStage(kind: .search, model: model, scene: wireScene)
        case .language:
            OnboardingLanguageStage(model: model)
        case .keyboard, .microphone, .inputMonitoring, .screenRecording:
            if let kind = OnboardingAccessKind(step: step) { OnboardingAccessStage(kind: kind, model: model) }
        case .tryDrop:
            OnboardingTryDropStage(model: model, shortcut: hotkeys.configuration.dropVoiceShortcut,
                                   gesture: hotkeys.configuration.normalizedDropGesture)
        case .toolbox:
            OnboardingToolboxStage(model: model)
        case .thanks:
            OnboardingFinishStage(model: model)
        }
    }

    /// "$200 credit", "10,000 credits / mo", "50 free / day", "1,000 free / mo".
    static func shortOffer(_ hint: APIHintsView.Hint) -> String {
        let cadence = hint.cadence
        if cadence.contains("one-time") { return "\(hint.allowance) credit" }
        let parts = hint.allowance.components(separatedBy: " / ")
        if parts.count == 2 { return "\(parts[0]) free / \(parts[1])" }
        if cadence.contains("each month") { return "\(hint.allowance) free / mo" }
        return "\(hint.allowance) free"
    }
}

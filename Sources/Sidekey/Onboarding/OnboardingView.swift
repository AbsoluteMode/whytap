import AVFoundation
import SwiftUI

/// Two halves, as in the former paid onboarding: on the left a serif headline,
/// one thought and the page's controls; on the right a stage that shows what
/// the page is about (Drop at work, the switch in System Settings, the note to
/// dictate into, the feature's clip). Always dark, like the island.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var hotkeys = HotkeyPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = OnboardingTheme.canvas

    var body: some View {
        let configuration = hotkeys.configuration
        ZStack {
            OnboardingTheme.bg
            Group {
                switch model.page {
                case .speech:
                    OnboardingSpeechPage(model: model, demo: model.demo, configuration: configuration)
                case .permissions:
                    OnboardingPermissionsPage(model: model, permissions: model.permissions, onDevice: model.onDevice)
                case .tryDrop:
                    OnboardingTryPage(model: model, onDevice: model.onDevice, permissions: model.permissions,
                                      configuration: configuration)
                case .features:
                    OnboardingFeaturesPage(model: model, configuration: configuration)
                }
            }
            .id(model.page)
            .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: model.page)
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

// MARK: - Layout

/// The two halves of a page. The left half reads top to bottom and ends in its
/// actions; the stage fills the rest of the window up to the title bar.
struct OnboardingSplit<Left: View, Footer: View, Stage: View>: View {
    let step: String
    let index: Int
    let count: Int
    @ViewBuilder var left: Left
    @ViewBuilder var footer: Footer
    @ViewBuilder var stage: Stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(step.uppercased()) · \(index + 1) / \(count)")
                    .font(OnboardingTheme.mono(10.5, weight: .medium))
                    .tracking(1.6)
                    .foregroundColor(OnboardingTheme.faint)
                    .padding(.bottom, 18)
                    .accessibilityLabel("Step \(index + 1) of \(count): \(step)")
                left
                Spacer(minLength: 12)
                HStack(spacing: 10) { footer }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(EdgeInsets(top: 72, leading: 40, bottom: 26, trailing: 32))
            .frame(width: OnboardingTheme.leftPaneWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(OnboardingTheme.bg)
            .overlay(Rectangle().fill(OnboardingTheme.border).frame(width: 0.5), alignment: .trailing)
            .offset(x: shown || reduceMotion ? 0 : -10)
            .opacity(shown ? 1 : 0)

            stage
                .padding(EdgeInsets(top: 52, leading: 40, bottom: 40, trailing: 40))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(shown || reduceMotion ? 1 : 0.985)
        }
        .onAppear {
            if reduceMotion { shown = true } else {
                withAnimation(.easeOut(duration: 0.35)) { shown = true }
            }
        }
    }
}

/// Subtitle under a headline.
struct OnboardingLede: View {
    let text: String

    var body: some View {
        Text(text)
            .font(OnboardingTheme.sans(14))
            .foregroundColor(OnboardingTheme.muted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A numbered line: 01, an italic verb, an optional shortcut, one sentence.
struct OnboardingStepRow: View {
    let number: Int
    let verb: String
    let detail: String
    var chord: [KeycapContent]?
    var held = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(String(format: "%02d", number))
                .font(OnboardingTheme.mono(10.5))
                .tracking(0.6)
                .foregroundColor(OnboardingTheme.faint)
                .frame(width: 18, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text("\(verb).")
                        .font(OnboardingTheme.serifItalic(22))
                        .foregroundColor(OnboardingTheme.ink)
                    if let chord { OnboardingKeycaps(contents: chord, held: held) }
                }
                Text(detail)
                    .font(OnboardingTheme.sans(12.5))
                    .foregroundColor(OnboardingTheme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A dark card on the left half.
struct OnboardingCard<Content: View>: View {
    var highlighted = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(highlighted ? OnboardingTheme.accent.opacity(0.75) : OnboardingTheme.border,
                              lineWidth: highlighted ? 1.2 : 0.75))
    }
}

/// The rounded square holding a card's symbol.
struct OnboardingIconTile: View {
    let systemImage: String
    var tint: Color = OnboardingTheme.ink2

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(tint)
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(OnboardingTheme.surface3))
            .accessibilityHidden(true)
    }
}

// MARK: - 1. Speech

@MainActor
struct OnboardingSpeechPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var demo: OnboardingDropDemo
    let configuration: HotkeyConfiguration

    var body: some View {
        if model.showsKeyForm {
            OnboardingSpeechKeyPage(model: model, models: model.models)
        } else {
            OnboardingOnDevicePage(model: model, onDevice: model.onDevice, demo: demo, configuration: configuration)
        }
    }
}

@MainActor
struct OnboardingOnDevicePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    @ObservedObject var demo: OnboardingDropDemo
    let configuration: HotkeyConfiguration

    /// The card's copy for a model state. Pure, so it is tested without a view.
    struct Presentation: Equatable {
        let detail: String
        let action: String

        init(_ status: OnDeviceSpeechModelStatus, model: OnDeviceSpeechModel = .parakeetTdtV3) {
            switch status {
            case .notDownloaded:
                detail = "\(model.displayName), \(model.approximateSize). No account; works offline."
                action = "Download and use for Drop"
            case .downloading(let fraction):
                detail = OnDeviceSpeechCard.Presentation.isStarting(fraction)
                    ? "Starting the download… \(model.approximateSize)."
                    : "Downloading: \(OnDeviceSpeechCard.Presentation.percent(fraction))% of \(model.approximateSize)."
                action = "Use for Drop"
            case .ready:
                detail = "\(model.displayName) is already on this Mac and works offline."
                action = "Use for Drop"
            case .failed:
                detail = "The download didn't finish. Check your connection and try again."
                action = "Download and use for Drop"
            }
        }

        /// What the button changes, said before it is pressed.
        static let scope = "Sets the speech model of Drop only. Other features stay as they are."
    }

    var body: some View {
        let presentation = Presentation(onDevice.status)
        let copy = OnboardingTryPage.Copy(shortcut: configuration.dropVoiceShortcut.title,
                                          gesture: configuration.normalizedDropGesture)
        OnboardingSplit(step: "Speech", index: model.pageIndex, count: model.pages.count) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Your voice,", italic: "typed.")
                OnboardingLede(text: copy.pitch)
                    .padding(.top, 12)
                OnboardingCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            OnboardingIconTile(systemImage: "laptopcomputer", tint: OnboardingTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Speech on this Mac")
                                    .font(OnboardingTheme.sans(13.5, weight: .semibold))
                                    .foregroundColor(OnboardingTheme.ink)
                                Text(presentation.detail)
                                    .font(OnboardingTheme.sans(12))
                                    .foregroundColor(OnboardingTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .contentTransition(.numericText())
                            }
                        }
                        if case .downloading(let fraction) = onDevice.status {
                            OnboardingProgressLine(fraction: fraction)
                                .accessibilityLabel("Download progress")
                        }
                        OnboardingPrimaryButton(title: presentation.action, chevron: false, action: model.startOnDevice)
                        Text(Presentation.scope)
                            .font(OnboardingTheme.sans(11.5))
                            .foregroundColor(OnboardingTheme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 26)
                HStack(spacing: 2) {
                    OnboardingQuietButton(title: "I have an API key") { model.showsKeyForm = true }
                    OnboardingQuietButton(title: "Restore from another Mac", action: model.restoreFromAnotherMac)
                }
                .padding(.top, 10)
                .padding(.leading, -10)
            }
        } footer: {
            OnboardingQuietButton(title: "Set up later", action: model.setUpSpeechLater)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(corner: UnitPoint(x: 0.85, y: 0.1))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                OnboardingDropDemoStage(demo: demo, chord: configuration.dropVoiceShortcut.contents)
            }
        }
        .task { await onDevice.refresh() }
    }
}

@MainActor
struct OnboardingSpeechKeyPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var models: APIAndModelsViewModel
    @State private var failure: String?

    private var freeOffers: [APIHintsView.Hint] {
        APIHintsView.hints.filter { $0.category == .speech && $0.access == .noCard }
    }

    var body: some View {
        let provider = model.keyProvider.displayName
        OnboardingSplit(step: "Speech", index: model.pageIndex, count: model.pages.count) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Bring your", italic: "own key.")
                OnboardingLede(text: "Drop sends your audio straight to the speech service you choose. "
                    + "The key stays in this Mac's Keychain and sets the speech model of Drop only.")
                    .padding(.top, 12)
                if !freeOffers.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NO KEY YET? NO CARD NEEDED")
                            .font(OnboardingTheme.mono(10, weight: .medium))
                            .tracking(1.2)
                            .foregroundColor(OnboardingTheme.faint)
                        ForEach(freeOffers, id: \.provider) { hint in
                            Link(destination: hint.url) {
                                HStack(spacing: 6) {
                                    Text(hint.provider).foregroundColor(OnboardingTheme.ink2)
                                    Text("\(hint.allowance) \(hint.cadence)").foregroundColor(OnboardingTheme.muted)
                                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                                        .foregroundColor(OnboardingTheme.faint)
                                }
                                .font(OnboardingTheme.sans(12.5))
                            }
                            .buttonStyle(.plain)
                            .help(hint.detail)
                        }
                    }
                    .padding(.top, 26)
                }
                HStack(spacing: 2) {
                    if model.supportsOnDevice {
                        OnboardingQuietButton(title: "Use this Mac instead", systemImage: "chevron.left") {
                            model.showsKeyForm = false
                        }
                    }
                    OnboardingQuietButton(title: "Restore from another Mac", action: model.restoreFromAnotherMac)
                }
                .padding(.top, 16)
                .padding(.leading, -10)
            }
        } footer: {
            OnboardingQuietButton(title: "Set up later", action: model.setUpSpeechLater)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(corner: UnitPoint(x: 0.2, y: 0.1))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                OnboardingMockWindow(caption: "SPEECH SERVICE") {
                    EmptyView()
                } content: {
                    VStack(alignment: .leading, spacing: 14) {
                        MacSegmented(
                            items: OnboardingDropSpeech.keyProviders.map { .init(value: $0, label: $0.displayName) },
                            selection: $model.keyProvider
                        )
                        if model.keyAvailable(model.keyProvider) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Your \(provider) key is already saved.")
                                    .font(OnboardingTheme.sans(12.5))
                                    .foregroundColor(OnboardingTheme.muted)
                                OnboardingPrimaryButton(title: "Use \(provider) for Drop", chevron: false) {
                                    model.useKey(model.keyProvider)
                                }
                            }
                        } else {
                            ProviderKeyForm(
                                viewModel: models, kind: model.keyProvider,
                                account: OnboardingDropSpeech.account(for: model.keyProvider),
                                onSaveResult: { accepted in
                                    if accepted { failure = nil; model.useKey(model.keyProvider) }
                                },
                                onSaveFailure: { failure = $0 },
                                onClose: {},
                                showsRemove: false
                            )
                            .id(model.keyProvider)
                        }
                        if let failure { OnboardingStageStatus(tone: .warning, text: failure) }
                    }
                    .padding(18)
                }
                .frame(maxWidth: 440)
            }
        }
        .onChange(of: model.keyProvider) { _, _ in failure = nil }
    }
}

// MARK: - 2. Permissions

@MainActor
struct OnboardingPermissionsPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var permissions: PermissionsSettingsViewModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController

    var body: some View {
        let microphone = permissions.snapshot.microphoneGranted
        let keyboard = permissions.snapshot.accessibilityGranted
        OnboardingSplit(step: "Permissions", index: model.pageIndex, count: model.pages.count) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Two quick", italic: "permissions.", stacked: true)
                OnboardingLede(text: "Whytap listens only while you hold the shortcut, and types where your cursor is.")
                    .padding(.top, 12)
                VStack(spacing: 10) {
                    card(icon: "mic", title: "Microphone", detail: "So Whytap can hear you.",
                         granted: microphone, requested: false, action: permissions.requestMicrophone)
                    card(icon: "keyboard", title: "Keyboard control",
                         detail: "So it notices your shortcut and types the text.",
                         granted: keyboard, requested: permissions.accessibilityRequested,
                         action: permissions.requestAccessibility)
                }
                .padding(.top, 24)
                // Both allowed but no shortcut: the repair actions, never a
                // second permission request.
                if permissions.snapshot.allRequiredGranted && permissions.dropHotkeyStatus != .ready {
                    DropShortcutStatusSection(viewModel: permissions)
                        .padding(.top, 12)
                }
            }
        } footer: {
            OnboardingQuietButton(title: "Skip", action: model.advance)
            OnboardingPrimaryButton(title: "Continue", isEnabled: permissions.allRequiredGranted, action: model.advance)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(corner: UnitPoint(x: 0.8, y: 0.15))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingPrivacyMock(microphone: microphone, keyboard: keyboard)
                    if !keyboard {
                        Text("For Keyboard control, Allow opens System Settings. Turn on Whytap there, then come back.")
                            .font(OnboardingTheme.sans(12))
                            .foregroundColor(OnboardingTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    OnboardingModelStatusCard(status: onDevice.status)
                }
                .frame(maxWidth: 420)
            }
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(restartRecoveryPolling: false)
        }
    }

    private func card(icon: String, title: String, detail: String, granted: Bool, requested: Bool,
                      action: @escaping () -> Void) -> some View {
        OnboardingCard {
            HStack(alignment: .center, spacing: 12) {
                OnboardingIconTile(systemImage: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OnboardingTheme.sans(13.5, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink)
                    Text(detail)
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(OnboardingTheme.green)
                        .accessibilityLabel("\(title): Allowed")
                } else {
                    // The first press asks macOS; the next one opens its pane.
                    // WHY: .project-docs/decisions/2026-11-19-permission-request-before-settings.md
                    OnboardingPrimaryButton(title: requested ? "Open Settings" : "Allow", chevron: false, action: action)
                        .accessibilityLabel(requested ? "Open System Settings for \(title)" : "Allow \(title)")
                }
            }
        }
    }
}

/// System Settings as the person will see it: the one switch to turn on for
/// each permission, lit when it is on.
struct OnboardingPrivacyMock: View {
    let microphone: Bool
    let keyboard: Bool

    var body: some View {
        OnboardingMockWindow(caption: "PRIVACY & SECURITY") {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                section("MICROPHONE", on: microphone)
                section("ACCESSIBILITY", on: keyboard)
                    .padding(.top, 6)
            }
            .padding(16)
        }
        .accessibilityHidden(true)
    }

    private func section(_ title: String, on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(OnboardingTheme.mono(10, weight: .medium))
                .tracking(1)
                .foregroundColor(OnboardingTheme.faint)
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(OnboardingTheme.accent, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
                Text("Whytap")
                    .font(OnboardingTheme.sans(14, weight: .semibold))
                    .foregroundColor(OnboardingTheme.ink)
                Spacer()
                Capsule()
                    .fill(on ? OnboardingTheme.green : Color.white.opacity(0.14))
                    .frame(width: 34, height: 20)
                    .overlay(Circle().fill(Color.white).frame(width: 16, height: 16)
                        .offset(x: on ? 7 : -7))
                    .animation(.easeOut(duration: 0.25), value: on)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? Color.white.opacity(0.03) : OnboardingTheme.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(on ? OnboardingTheme.border : OnboardingTheme.accent.opacity(0.45), lineWidth: 0.75))
        }
    }
}

/// The speech model's download, shown while the person does something else.
struct OnboardingModelStatusCard: View {
    let status: OnDeviceSpeechModelStatus

    var body: some View {
        switch status {
        case .downloading(let fraction):
            card {
                HStack {
                    Text("Speech model")
                        .font(OnboardingTheme.sans(13, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink)
                    Spacer()
                    Text(OnDeviceSpeechCard.Presentation.isStarting(fraction)
                         ? "Starting…" : "\(OnDeviceSpeechCard.Presentation.percent(fraction))%")
                        .font(OnboardingTheme.mono(12, weight: .medium))
                        .foregroundColor(OnboardingTheme.muted)
                        .contentTransition(.numericText())
                }
                OnboardingProgressLine(fraction: fraction)
                Text("Downloading in the background. Drop works as soon as it lands.")
                    .font(OnboardingTheme.sans(11.5))
                    .foregroundColor(OnboardingTheme.faint)
            }
        case .ready:
            card {
                OnboardingStageStatus(tone: .success, text: "The speech model is on this Mac.")
            }
        case .notDownloaded, .failed:
            EmptyView()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OnboardingTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OnboardingTheme.border, lineWidth: 0.75))
    }
}

// MARK: - 3. Try

@MainActor
struct OnboardingTryPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    @ObservedObject var permissions: PermissionsSettingsViewModel
    let configuration: HotkeyConfiguration

    /// Copy for the user's own Drop shortcut and gesture. Pure for tests.
    struct Copy: Equatable {
        /// The first page's promise.
        let pitch: String
        let pressVerb: String
        let pressDetail: String
        let releaseVerb: String
        let releaseDetail: String
        let placeholder: String

        init(shortcut: String, gesture: HotkeyGesture) {
            switch gesture {
            case .hold:
                pitch = "Hold \(shortcut) in any text field, speak, and let go. The words land where your cursor is."
                pressVerb = "Hold"
                pressDetail = "Keep it down while you speak. Your words show in the island."
                releaseVerb = "Let go"
                releaseDetail = "The text lands at the cursor."
                placeholder = "Click here, hold \(shortcut) and say a sentence"
            case .tap:
                pitch = "Press \(shortcut) in any text field, speak, and press it again. The words land where your cursor is."
                pressVerb = "Press"
                pressDetail = "Speak after the press. Your words show in the island."
                releaseVerb = "Press again"
                releaseDetail = "The text lands at the cursor."
                placeholder = "Click here, press \(shortcut) and say a sentence"
            }
        }
    }

    var body: some View {
        let chord = configuration.dropVoiceShortcut.contents
        let copy = Copy(shortcut: configuration.dropVoiceShortcut.title, gesture: configuration.normalizedDropGesture)
        OnboardingSplit(step: "Try it", index: model.pageIndex, count: model.pages.count) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Try", italic: "Drop.")
                OnboardingLede(text: "Say a sentence into the note on the right.")
                    .padding(.top, 12)
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingStepRow(number: 1, verb: "Click", detail: "Put the cursor in the note.")
                    OnboardingStepRow(number: 2, verb: copy.pressVerb, detail: copy.pressDetail, chord: chord)
                    OnboardingStepRow(number: 3, verb: copy.releaseVerb, detail: copy.releaseDetail)
                }
                .padding(.top, 30)
                .accessibilityLabel("Drop shortcut: \(configuration.dropVoiceShortcut.title)")
            }
        } footer: {
            if !model.dictated { OnboardingQuietButton(title: "Skip", action: model.advance) }
            OnboardingPrimaryButton(title: "Continue", action: model.advance)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(tint: model.dictated ? OnboardingTheme.green : OnboardingTheme.accent,
                                        corner: UnitPoint(x: 0.25, y: 0.1))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                    .animation(.easeInOut(duration: 0.6), value: model.dictated)
                VStack(alignment: .leading, spacing: 18) {
                    OnboardingMockWindow(caption: "NOTES — TRY DROP") {
                        OnboardingKeycaps(contents: chord)
                    } content: {
                        OnboardingTryField(placeholder: copy.placeholder, onDictated: model.noteDictated)
                            .padding(10)
                            .frame(height: 210)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(model.dictated ? OnboardingTheme.green.opacity(0.55) : .clear, lineWidth: 1))
                    status
                        .frame(minHeight: 44, alignment: .top)
                }
                .frame(maxWidth: 440)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if model.dictated {
            OnboardingStageStatus(tone: .success,
                                  text: "That's Drop. It works in any app: click into a text field and use the same shortcut.")
        } else if !model.dropReady, case .downloading(let fraction) = onDevice.status {
            VStack(alignment: .leading, spacing: 9) {
                OnboardingStageStatus(tone: .neutral, text: OnDeviceSpeechCard.Presentation.isStarting(fraction)
                    ? "The speech model is starting to download. Drop works as soon as it's on this Mac."
                    : "The speech model is downloading: \(OnDeviceSpeechCard.Presentation.percent(fraction))%. Drop works as soon as it's on this Mac.")
                OnboardingProgressLine(fraction: fraction)
                    .frame(maxWidth: 260)
            }
        } else if !model.dropReady || model.dropSetupFailure != nil {
            HStack(spacing: 12) {
                OnboardingStageStatus(tone: .warning, text: model.dropReady
                    ? "Drop couldn’t start with these speech settings."
                    : "Drop has no speech model yet.")
                OnboardingQuietButton(title: model.dropReady ? "Check settings" : "Choose a model",
                                      action: model.openDropSpeechSettings)
            }
        } else if permissions.dropHotkeyStatus != .ready {
            HStack(spacing: 12) {
                OnboardingStageStatus(tone: .warning, text: "Your Drop shortcut isn't active yet.")
                OnboardingQuietButton(title: "Fix", action: model.showPermissions)
            }
        }
    }
}

// MARK: - 4. Features

@MainActor
struct OnboardingFeaturesPage: View {
    @ObservedObject var model: OnboardingModel
    let configuration: HotkeyConfiguration
    @State private var selected: FeatureVideo = .googleSearch

    var body: some View {
        let _ = model.revision
        OnboardingSplit(step: "More", index: model.pageIndex, count: model.pages.count) {
            VStack(alignment: .leading, spacing: 0) {
                OnboardingHeadline(plain: "Make it", italic: "yours.")
                OnboardingLede(text: "Three more things on the same keyboard. Each stays off until you turn it on.")
                    .padding(.top, 12)
                VStack(spacing: 8) {
                    row(.googleSearch, icon: "magnifyingglass", title: "Google search",
                        detail: "Type or say a query.") {
                        MacSwitch(isOn: Binding(get: { model.googleOn }, set: model.setGoogle), label: "Google search")
                    }
                    row(.meetings, icon: "waveform", title: "Meeting Notes",
                        detail: "Notes from your calls.") {
                        switch model.meetingsAction {
                        case .toggle:
                            MacSwitch(isOn: Binding(get: { model.meetingsOn }, set: model.setMeetings), label: "Meeting Notes")
                        case .addModel(let feature):
                            OnboardingOutlineButton(title: "Add a model") { model.addModel(feature) }
                        }
                    }
                    row(.agent, icon: "command", title: "Agent",
                        detail: "Ask; it answers in the island.") {
                        switch model.agentAction {
                        case .toggle:
                            HStack(spacing: 8) {
                                if model.agentConnecting { ProgressView().controlSize(.small) }
                                MacSwitch(isOn: Binding(get: { model.agentOn }, set: model.setAgent), label: "Agent")
                                    .disabled(model.agentConnecting)
                            }
                        case .addModel(let feature):
                            OnboardingOutlineButton(title: "Add a model") { model.addModel(feature) }
                        }
                    }
                }
                .padding(.top, 24)
                if let problem = model.agentProblem {
                    OnboardingStageStatus(tone: .warning, text: problem)
                        .padding(.top, 10)
                }
            }
        } footer: {
            OnboardingPrimaryButton(title: "Done", chevron: false, action: model.finish)
                .keyboardShortcut(.defaultAction)
        } stage: {
            ZStack {
                OnboardingStageBackdrop(corner: UnitPoint(x: 0.5, y: 0.0))
                    .padding(EdgeInsets(top: -52, leading: -40, bottom: -40, trailing: -40))
                OnboardingFeatureStage(video: selected, shortcuts: shortcuts(for: selected))
                    .id(selected)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.25), value: selected)
        }
    }

    private func row<Trailing: View>(_ video: FeatureVideo, icon: String, title: String, detail: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        OnboardingCard(highlighted: selected == video) {
            HStack(alignment: .center, spacing: 12) {
                OnboardingIconTile(systemImage: icon, tint: selected == video ? OnboardingTheme.accent : OnboardingTheme.ink2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(OnboardingTheme.sans(13.5, weight: .semibold))
                        .foregroundColor(OnboardingTheme.ink)
                    Text(detail)
                        .font(OnboardingTheme.sans(12))
                        .foregroundColor(OnboardingTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                trailing()
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture { selected = video }
        .accessibilityAddTraits(selected == video ? .isSelected : [])
        .accessibilityAction(named: "Watch how \(title) works") { selected = video }
    }

    private func shortcuts(for video: FeatureVideo) -> [FeatureVideoShortcut] {
        switch video {
        case .googleSearch: return SettingsOtherView.googleSearchVideoShortcuts(configuration)
        case .meetings: return [FeatureVideoShortcut(label: "Record", contents: configuration.meetingRecordShortcut.contents)]
        case .agent: return AgentOtherSection.videoShortcuts(configuration)
        default: return []
        }
    }
}

/// The selected feature's bundled clip, looping silently, with the person's
/// own keys under it. Reduce Motion shows its first frame instead.
struct OnboardingFeatureStage: View {
    let video: FeatureVideo
    let shortcuts: [FeatureVideoShortcut]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var poster: NSImage?

    /// Offscreen review images draw the poster: a player has no frame to capture.
    nonisolated(unsafe) static var playsVideo = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(video.featureTitle + ".")
                .font(OnboardingTheme.serifItalic(30))
                .foregroundColor(OnboardingTheme.ink)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black)
                if let poster {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fit)
                }
                if Self.playsVideo, !reduceMotion, let url = video.url() {
                    LoopingVideoView(url: url)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OnboardingTheme.borderStrong, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 18)
            .accessibilityHidden(true)
            if !shortcuts.isEmpty {
                HStack(spacing: 14) {
                    Text("YOUR SHORTCUT")
                        .font(OnboardingTheme.mono(10, weight: .medium))
                        .tracking(1.2)
                        .foregroundColor(OnboardingTheme.faint)
                    ForEach(shortcuts) { shortcut in
                        HStack(spacing: 6) {
                            Text(shortcut.label)
                                .font(OnboardingTheme.sans(12))
                                .foregroundColor(OnboardingTheme.muted)
                            OnboardingKeycaps(contents: shortcut.contents)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(shortcut.label)
                    }
                }
            }
        }
        .frame(maxWidth: 480)
        .task(id: video) { poster = await Self.poster(for: video) }
    }

    static func poster(for video: FeatureVideo) async -> NSImage? {
        guard let url = video.url() else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        guard let image = try? await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

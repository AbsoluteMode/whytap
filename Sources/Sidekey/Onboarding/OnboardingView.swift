import SwiftUI

/// One column: a serif heading, one thought, the page's controls, and a
/// footer with the way on. Built from the Settings components so it follows
/// light and dark appearance like Settings does.
// WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
@MainActor
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var hotkeys = HotkeyPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 600, height: 540)

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(count: model.pages.count, current: model.pageIndex)
                .padding(.top, 14)
                .frame(height: 30)
            Group {
                switch model.page {
                case .speech: OnboardingSpeechPage(model: model)
                case .permissions: OnboardingPermissionsPage(model: model, permissions: model.permissions)
                case .tryDrop: OnboardingTryPage(model: model, onDevice: model.onDevice, permissions: model.permissions,
                                                 configuration: hotkeys.configuration)
                case .features: OnboardingFeaturesPage(model: model)
                }
            }
            .id(model.page)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)),
                removal: .opacity.combined(with: .offset(x: -24))))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.page)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(MacSettingsTheme.bgContent)
    }
}

// MARK: - Shared pieces

/// Heading, thought, content and footer of every page.
struct OnboardingPageLayout<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.custom("InstrumentSerif-Regular", size: 38))
                    .foregroundStyle(MacSettingsTheme.text)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 26)
            content
            Spacer(minLength: 12)
            HStack(spacing: 12) { footer }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 44)
        .padding(.top, 18)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct OnboardingProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? MacSettingsTheme.accent : MacSettingsTheme.sepStrong)
                    .frame(width: index == current ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

/// A quiet text action: secondary paths such as Set up later.
struct OnboardingLinkButton: View {
    let title: String
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(MacSettingsTheme.text2)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(MacButtonInteractionStyle(focused: focused))
        .focused($focused)
    }
}

struct OnboardingStatusLine: View {
    enum Tone { case success, warning, neutral }
    let tone: Tone
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(MacSettingsTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch tone {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .neutral: return "info.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .success: return MacSettingsTheme.green
        case .warning: return MacSettingsTheme.orange
        case .neutral: return MacSettingsTheme.text2
        }
    }
}

// MARK: - 1. Speech

@MainActor
struct OnboardingSpeechPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        if model.showsKeyForm {
            OnboardingSpeechKeyPage(model: model, models: model.models)
        } else {
            OnboardingOnDevicePage(model: model, onDevice: model.onDevice)
        }
    }
}

@MainActor
struct OnboardingOnDevicePage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The card's copy for a model state. Pure, so it is tested without a view.
    struct Presentation: Equatable {
        let detail: String
        let action: String

        init(_ status: OnDeviceSpeechModelStatus, model: OnDeviceSpeechModel = .parakeetTdtV3) {
            switch status {
            case .notDownloaded:
                detail = "\(model.displayName), \(model.approximateSize). Downloads once, then works offline."
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
        OnboardingPageLayout(
            title: "Dictate without a key",
            subtitle: "Speech is recognized on this Mac: no account, and your audio never leaves it."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11).fill(MacSettingsTheme.accent.opacity(0.13))
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 19, weight: .medium))
                                .foregroundStyle(MacSettingsTheme.accent)
                        }
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("On this Mac")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(MacSettingsTheme.text)
                            Text(presentation.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(MacSettingsTheme.text2)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentTransition(.numericText())
                        }
                    }
                    if case .downloading(let fraction) = onDevice.status {
                        OnDeviceDownloadBar(fraction: fraction,
                                            starting: OnDeviceSpeechCard.Presentation.isStarting(fraction),
                                            animated: !reduceMotion)
                            .accessibilityLabel("Download progress")
                    }
                    HStack(alignment: .center, spacing: 12) {
                        MacButton(title: presentation.action, style: .primary, action: model.startOnDevice)
                        Text(Presentation.scope)
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MacSettingsTheme.bgCard, in: RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard))
                .overlay {
                    RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard)
                        .strokeBorder(MacSettingsTheme.sep, lineWidth: 0.5)
                }

                HStack(spacing: 4) {
                    OnboardingLinkButton(title: "I have an API key") { model.showsKeyForm = true }
                    OnboardingLinkButton(title: "Restore from another Mac", action: model.restoreFromAnotherMac)
                }
                .padding(.leading, -8)
            }
        } footer: {
            OnboardingLinkButton(title: "Set up later", action: model.setUpSpeechLater)
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
        OnboardingPageLayout(
            title: "Connect a speech service",
            subtitle: "Your key stays in this Mac's Keychain and goes only to \(provider). Saving it sets the speech model of Drop only."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                MacSegmented(
                    items: OnboardingDropSpeech.keyProviders.map { .init(value: $0, label: $0.displayName) },
                    selection: $model.keyProvider
                )
                .frame(maxWidth: 360)
                if model.keyAvailable(model.keyProvider) {
                    HStack(spacing: 12) {
                        MacButton(title: "Use \(provider) for Drop", style: .primary) { model.useKey(model.keyProvider) }
                        Text("Your \(provider) key is already saved.")
                            .font(.system(size: 12))
                            .foregroundStyle(MacSettingsTheme.text2)
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
                if let failure { OnboardingStatusLine(tone: .warning, text: failure) }
                if !freeOffers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No key yet? These start without a card:")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(MacSettingsTheme.text2)
                        ForEach(freeOffers, id: \.provider) { hint in
                            Link(destination: hint.url) {
                                Text("\(hint.provider): \(hint.allowance) \(hint.cadence)")
                                    .font(.system(size: 12))
                            }
                            .help(hint.detail)
                        }
                    }
                }
                HStack(spacing: 4) {
                    if model.supportsOnDevice {
                        OnboardingLinkButton(title: "Use On this Mac instead") { model.showsKeyForm = false }
                    }
                    OnboardingLinkButton(title: "Restore from another Mac", action: model.restoreFromAnotherMac)
                }
                .padding(.leading, -8)
            }
        } footer: {
            OnboardingLinkButton(title: "Set up later", action: model.setUpSpeechLater)
        }
        .onChange(of: model.keyProvider) { _, _ in failure = nil }
    }
}

// MARK: - 2. Permissions

@MainActor
struct OnboardingPermissionsPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var permissions: PermissionsSettingsViewModel

    var body: some View {
        OnboardingPageLayout(
            title: "Two permissions",
            subtitle: "Whytap listens only while you hold the shortcut, and types the text where your cursor is."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                MacCard {
                    row(icon: "mic.fill", title: "Microphone", subtitle: "To hear what you say.",
                        granted: permissions.snapshot.microphoneGranted, requested: false,
                        action: permissions.requestMicrophone)
                    MacRowSeparator()
                    row(icon: "keyboard.fill", title: "Keyboard control",
                        subtitle: "To notice your shortcut and type the text. Turn on Whytap in System Settings, then come back.",
                        granted: permissions.snapshot.accessibilityGranted, requested: permissions.accessibilityRequested,
                        action: permissions.requestAccessibility)
                }
                // Both allowed but no shortcut: the repair actions, never a
                // second permission request.
                if permissions.snapshot.allRequiredGranted && permissions.dropHotkeyStatus != .ready {
                    DropShortcutStatusSection(viewModel: permissions)
                }
            }
        } footer: {
            OnboardingLinkButton(title: "Skip", action: model.advance)
            MacButton(title: "Continue", style: .primary, isEnabled: permissions.allRequiredGranted, action: model.advance)
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(restartRecoveryPolling: false)
        }
    }

    private func row(icon: String, title: String, subtitle: String, granted: Bool, requested: Bool,
                     action: @escaping () -> Void) -> some View {
        MacRow(title: title, subtitle: subtitle, leading: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(MacSettingsTheme.text2)
                .frame(width: 22)
        }, trailing: {
            Group {
                if granted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.green)
                        .accessibilityLabel("\(title): Allowed")
                } else {
                    // The first press asks macOS; the next one opens its pane.
                    // WHY: .project-docs/decisions/2026-11-19-permission-request-before-settings.md
                    MacButton(title: requested ? "Open Settings" : "Allow", style: .default, action: action)
                        .fixedSize()
                        .accessibilityLabel(requested ? "Open System Settings for \(title)" : "Allow \(title)")
                }
            }
            .frame(minWidth: 60, minHeight: 26)
        })
    }
}

// MARK: - 3. Try

@MainActor
struct OnboardingTryPage: View {
    @ObservedObject var model: OnboardingModel
    @ObservedObject var onDevice: OnDeviceSpeechModelController
    @ObservedObject var permissions: PermissionsSettingsViewModel
    let configuration: HotkeyConfiguration

    /// Title and hint for the user's own Drop shortcut. Pure for tests.
    struct Copy: Equatable {
        let title: String
        let subtitle: String
        let placeholder: String

        init(shortcut: String, gesture: HotkeyGesture) {
            switch gesture {
            case .hold:
                title = "Hold \(shortcut) and speak"
                subtitle = "Your words appear in the island while you speak and land here when you let go."
                placeholder = "Click here, hold \(shortcut) and say a few words"
            case .tap:
                title = "Press \(shortcut) and speak"
                subtitle = "Your words appear in the island while you speak. Press \(shortcut) again and they land here."
                placeholder = "Click here, press \(shortcut) and say a few words"
            }
        }
    }

    var body: some View {
        let copy = Copy(shortcut: configuration.dropVoiceShortcut.title, gesture: configuration.normalizedDropGesture)
        OnboardingPageLayout(title: copy.title, subtitle: copy.subtitle) {
            VStack(alignment: .leading, spacing: 14) {
                HotkeyHintView(label: configuration.normalizedDropGesture == .hold ? "Hold" : "Press",
                               contents: configuration.dropVoiceShortcut.contents)
                    .accessibilityLabel("Drop shortcut: \(configuration.dropVoiceShortcut.title)")
                OnboardingTryField(placeholder: copy.placeholder, onDictated: model.noteDictated)
                    .padding(12)
                    .frame(height: 132)
                    .background(MacSettingsTheme.fieldBg, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(model.dictated ? MacSettingsTheme.green.opacity(0.6) : MacSettingsTheme.sepStrong,
                                          lineWidth: model.dictated ? 1 : 0.5)
                    }
                status
            }
        } footer: {
            if !model.dictated { OnboardingLinkButton(title: "Skip", action: model.advance) }
            MacButton(title: "Continue", style: model.dictated ? .primary : .default, action: model.advance)
        }
    }

    @ViewBuilder private var status: some View {
        if model.dictated {
            OnboardingStatusLine(tone: .success,
                                 text: "That's Drop. It works in any app: click into a text field and use the same shortcut.")
        } else if !model.dropReady, case .downloading(let fraction) = onDevice.status {
            VStack(alignment: .leading, spacing: 8) {
                OnboardingStatusLine(tone: .neutral, text: OnDeviceSpeechCard.Presentation.isStarting(fraction)
                    ? "The speech model is starting to download. Drop works as soon as it's on this Mac."
                    : "The speech model is downloading: \(OnDeviceSpeechCard.Presentation.percent(fraction))%. Drop works as soon as it's on this Mac.")
                OnDeviceDownloadBar(fraction: fraction, starting: OnDeviceSpeechCard.Presentation.isStarting(fraction))
                    .frame(maxWidth: 260)
            }
        } else if !model.dropReady {
            HStack(spacing: 10) {
                OnboardingStatusLine(tone: .warning, text: "Drop has no speech model yet.")
                MacButton(title: "Choose a model", style: .default) { model.addModel(.dropFast) }
            }
        } else if permissions.dropHotkeyStatus != .ready {
            HStack(spacing: 10) {
                OnboardingStatusLine(tone: .warning, text: "Your Drop shortcut isn't active yet.")
                MacButton(title: "Fix", style: .default, action: model.showPermissions)
            }
        }
    }
}

// MARK: - 4. Features

@MainActor
struct OnboardingFeaturesPage: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let hotkeys = HotkeyPreferences.shared.configuration
        let _ = model.revision
        OnboardingPageLayout(
            title: "More on the same keyboard",
            subtitle: "Each is off until you turn it on. The rest of Whytap is in the island: hover it."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                MacCard {
                    MacRow(title: "Google search", subtitle: "Type or say a query; it opens in Google.") {
                        FeatureVideoButton(video: .googleSearch,
                                           shortcuts: { SettingsOtherView.googleSearchVideoShortcuts(hotkeys) })
                    } trailing: {
                        MacSwitch(isOn: Binding(get: { model.googleOn }, set: model.setGoogle), label: "Google search")
                    }
                    MacRowSeparator()
                    MacRow(title: "Meeting Notes", subtitle: "Detects calls, records them and writes notes.") {
                        FeatureVideoButton(video: .meetings, shortcuts: {
                            [FeatureVideoShortcut(label: "Record", contents: hotkeys.meetingRecordShortcut.contents)]
                        })
                    } trailing: {
                        switch model.meetingsAction {
                        case .toggle:
                            MacSwitch(isOn: Binding(get: { model.meetingsOn }, set: model.setMeetings), label: "Meeting Notes")
                        case .addModel(let feature):
                            MacButton(title: "Add a model", style: .default) { model.addModel(feature) }
                        }
                    }
                    MacRowSeparator()
                    MacRow(title: "Agent", subtitle: "Ask by text or voice; the answer appears in the island.") {
                        FeatureVideoButton(video: .agent, shortcuts: { AgentOtherSection.videoShortcuts(hotkeys) })
                    } trailing: {
                        switch model.agentAction {
                        case .toggle:
                            HStack(spacing: 10) {
                                if model.agentConnecting { ProgressView().controlSize(.small) }
                                MacSwitch(isOn: Binding(get: { model.agentOn }, set: model.setAgent), label: "Agent")
                                    .disabled(model.agentConnecting)
                            }
                        case .addModel(let feature):
                            MacButton(title: "Add a model", style: .default) { model.addModel(feature) }
                        }
                    }
                }
                if let problem = model.agentProblem {
                    OnboardingStatusLine(tone: .warning, text: problem)
                }
            }
        } footer: {
            MacButton(title: "Done", style: .primary, action: model.finish)
                .keyboardShortcut(.defaultAction)
        }
    }
}

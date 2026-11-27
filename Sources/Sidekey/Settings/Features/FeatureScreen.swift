import SwiftUI

/// What every feature screen reads and does: the Mac's state as a snapshot,
/// the two Settings view models, the host's environment and navigation.
/// One value, so a new screen is its settings and nothing else.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
@MainActor
struct FeatureScreenContext {
    let snapshot: FeatureSetupSnapshot
    let selection: SettingsWindowSelection
    let models: APIAndModelsViewModel
    let permissions: PermissionsSettingsViewModel
    let environment: FeaturesEnvironment

    var downloadFraction: Double? {
        if case .downloading(let fraction) = environment.onDevice.status { return fraction }
        return nil
    }

    /// The one step that satisfies a requirement, done from the screen.
    func perform(_ action: FeatureSetupAction) {
        switch action {
        case .downloadOnDeviceModel(let feature):
            // The download takes minutes; a model picked meanwhile (here or
            // in Keys & models) is the newer choice and stays.
            let startedFrom = models.currentRoute(for: feature)
            let models = models
            let onDevice = environment.onDevice
            Task {
                if await onDevice.download() { models.useOnDeviceModel(for: feature, ifRouteIs: startedFrom) }
            }
        case .useOnDeviceModel(let feature):
            models.useOnDeviceModel(for: feature)
        case .chooseModel(let feature):
            selection.focus(feature)
        case .addKey, .fixKey, .addOpenAIKey:
            selection.showAPIKeys()
        case .allow(.keyboard):
            permissions.requestAccessibility()
        case .allow(.microphone):
            permissions.requestMicrophone()
        case .allow(.screenRecording):
            let permissions = permissions
            Task { await permissions.requestScreenRecording() }
        case .allow(.systemAudio):
            break
        case .openInputMonitoring:
            permissions.requestInputMonitoring()
        case .restartWhytap:
            permissions.restartWhytap()
        case .retryShortcut:
            permissions.retryDropShortcut()
        }
    }

    /// What the catalog's one sentence cannot know: this Mac's own limits and
    /// the steps macOS 27.3 wants.
    func note(for check: FeatureCheck, of feature: AppFeature) -> String? {
        switch check.requirement.kind {
        case .model(let aiFeature):
            let speech = aiFeature.modelUse(on: .onDevice) != nil
            if speech, !check.state.isMet, snapshot.onDevice == .unsupported {
                return "The free model that runs on a Mac needs Apple Silicon. Add a key from Soniox, Deepgram, ElevenLabs or OpenAI."
            }
            return models.rows.first { $0.feature == aiFeature }?.message
        case .permission(.keyboard):
            if permissions.keyboardNeedsRestart { return permissions.restartBlocked }
            // Override is on: only the last step is left to say.
            if snapshot.keyboardSetup == .inputMonitoring {
                return "Override is on. Add Whytap under Input Monitoring, then restart Whytap."
            }
            return permissions.settingsOnly && !permissions.keyboardReady
                ? PermissionsSettingsViewModel.keyboardSettingsGuide : nil
        case .dropShortcut:
            guard case .unmet = check.state else { return nil }
            return FeatureCatalog.consequence(of: check, for: feature, snapshot: snapshot)
        case .permission, .subtitlesKey:
            return nil
        }
    }
}

/// The scroll view and column every feature screen sits in.
struct FeatureScreenScaffold<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(maxWidth: SettingsFeaturesView.contentWidth, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// "‹ Features", the feature's name and kind, and what it does.
struct FeatureScreenHeader: View {
    let info: FeatureInfo
    let about: String
    let back: () -> Void
    @FocusState private var backFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: back) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Features").font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(MacSettingsTheme.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            // The same hover, press and focus feedback as the Features rows.
            .buttonStyle(MacButtonInteractionStyle(highlight: MacSettingsTheme.accent, focused: backFocused))
            .focused($backFocused)
            .padding(.leading, -6)
            .accessibilityLabel("Back to Features")
            HStack(alignment: .center, spacing: 8) {
                FeatureIcon(feature: info.feature, size: .header)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(info.name)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(info.kind)
                        .font(.system(size: 13))
                        .foregroundStyle(MacSettingsTheme.text2)
                }
            }
            Text(about)
                .font(.system(size: 13))
                .foregroundStyle(MacSettingsTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The feature at work: a clip that plays in place on click, or, until the
/// clip is made, a quiet row saying what it will show. Nothing plays by itself.
// WHY: .project-docs/decisions/2026-11-20-other-feature-videos.md
struct FeatureVideoStrip: View {
    let clip: FeatureClip
    var shortcuts: [FeatureVideoShortcut] = []
    var bundle: Bundle = FeatureVideo.resourceBundle
    @Environment(\.isEnabled) private var isEnabled
    @State private var playing = false
    @State private var poster: NSImage?
    @FocusState private var focused: Bool

    /// The feature's first clip.
    init(info: FeatureInfo, shortcuts: [FeatureVideoShortcut] = [], bundle: Bundle = FeatureVideo.resourceBundle) {
        self.init(clip: info.clips[0], shortcuts: shortcuts, bundle: bundle)
    }

    init(clip: FeatureClip, shortcuts: [FeatureVideoShortcut] = [], bundle: Bundle = FeatureVideo.resourceBundle) {
        self.clip = clip
        self.shortcuts = shortcuts
        self.bundle = bundle
    }

    /// The bundled clip, or nil while it is not made.
    static func url(for info: FeatureInfo, in bundle: Bundle = FeatureVideo.resourceBundle) -> URL? {
        info.video?.url(in: bundle)
    }

    var body: some View {
        let url = clip.video?.url(in: bundle)
        let card = RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if url != nil {
                    Button { playing.toggle() } label: {
                        strip(available: true).opacity(isEnabled ? 1 : 0.42)
                    }
                    .buttonStyle(MacButtonInteractionStyle(outline: MacSettingsTheme.text, focused: focused,
                                                          cornerRadius: MacSettingsTheme.radiusCard))
                    .focused($focused)
                    .accessibilityLabel(playing ? "Close the video" : "Watch how \(clip.name) works")
                } else {
                    strip(available: false)
                        .accessibilityElement(children: .combine)
                }
            }
            // Keep the card behind the button's interaction outline. An outline
            // leaves the caption and accent label readable in both appearances.
            .background {
                card.fill(MacSettingsTheme.bgCard)
                    .overlay { card.strokeBorder(MacSettingsTheme.sep, lineWidth: 1) }
                    .allowsHitTesting(false)
            }
            if playing, let url {
                FeatureVideoPopover(url: url, shortcuts: shortcuts)
                    .padding(-12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: url) {
            guard let url, let video = clip.video else { poster = nil; return }
            poster = FeatureVideoPoster.cached(url)
            if poster == nil {
                let image = await FeatureVideoPoster.load(video, url: url)
                if !Task.isCancelled { poster = image }
            }
        }
    }

    /// The clip's frame with a play mark, or a quiet tile until it is read
    /// (and for a clip not made yet).
    // WHY: .project-docs/decisions/2026-11-25-feature-clip-posters.md
    private func thumbnail(available: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let image = available ? (poster ?? clip.video?.url(in: bundle).flatMap(FeatureVideoPoster.cached)) : nil
        return ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.posterSize.width, height: Self.posterSize.height)
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(MacSettingsTheme.sep, lineWidth: 1) }
                Circle()
                    .fill(.black.opacity(0.55))
                    .frame(width: 24, height: 24)
                    .overlay {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: playing ? 0 : 1)
                    }
            } else {
                shape
                    .fill(MacSettingsTheme.hover)
                    .frame(width: Self.posterSize.width, height: Self.posterSize.height)
                Image(systemName: available ? "play.fill" : "film")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(available ? MacSettingsTheme.text : MacSettingsTheme.text3)
            }
        }
        .accessibilityHidden(true)
    }

    /// 16:9, like the clips.
    static let posterSize = CGSize(width: 96, height: 54)

    private func strip(available: Bool) -> some View {
        HStack(spacing: 12) {
            thumbnail(available: available)
            VStack(alignment: .leading, spacing: 2) {
                Text("Watch how \(clip.name) works")
                    .font(.system(size: 13))
                    .foregroundStyle(available ? MacSettingsTheme.text : MacSettingsTheme.text2)
                Text(clip.caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 12)
            Text(available ? (playing ? "Close" : "Watch") : "Video coming")
                .font(.system(size: 12, weight: available ? .medium : .regular))
                .foregroundStyle(available ? MacSettingsTheme.accent : MacSettingsTheme.text3)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// The feature's own shortcuts, changed in place. Rows share one recording
/// session so a second recording ends the first.
@MainActor
struct FeatureShortcutsGroup: View {
    let hotkeys: [FeatureHotkey]
    let preferences: HotkeyPreferences
    /// A line beside the title, e.g. where the rest of the feature's keys are.
    var trailing: String?
    @StateObject private var recording = HotkeyRecordingSession<FeatureHotkey>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: hotkeys.count > 1 ? "Shortcuts" : "Shortcut", trailing: trailing)
            MacCard {
                ForEach(Array(hotkeys.enumerated()), id: \.element) { index, hotkey in
                    if index > 0 { MacRowSeparator() }
                    OwnedFeatureShortcutRow(hotkey: hotkey, preferences: preferences, recording: recording)
                }
            }
        }
    }

    /// What a shortcut row says under its name.
    static func detail(for hotkey: FeatureHotkey, in configuration: HotkeyConfiguration) -> String {
        switch hotkey {
        case .dropVoice:
            return HotkeysSettingsView.dropDetail(for: hotkey.gesture(in: configuration),
                                                  shortcut: configuration.dropVoiceShortcut)
        case .agentVoice, .googleVoice:
            return hotkey.gesture(in: configuration) == .hold
                ? "Hold to speak; let go to send." : "Press to start speaking, press again to send."
        case .agentText: return "Opens a field to type to the Agent."
        case .agentClose: return "Hides the Agent’s answer."
        case .googleText: return "Opens a field to type a search."
        case .meetingRecord: return "Works any time, also when no call was detected."
        case .agentLinkInsert: return "While an answer shows links: pastes the chosen one where you were typing."
        case .agentLinkOpen: return "While an answer shows links: opens the chosen one."
        case .agentLinkNext: return "While an answer shows links: chooses the next one."
        case .agentLinkPrevious: return "While an answer shows links: chooses the previous one."
        case .tool(let tool):
            return hotkey.shortcut(in: configuration) == nil
                ? "No shortcut yet. Record one, or open \(HoverToolRegistry.info(for: tool).title) from the island."
                : "Opens it from anywhere."
        }
    }
}

/// A shortcut row that owns its editor for as long as it is shown.
@MainActor
private struct OwnedFeatureShortcutRow: View {
    @StateObject private var editor: FeatureShortcutEditor
    @ObservedObject private var preferences: HotkeyPreferences

    init(hotkey: FeatureHotkey, preferences: HotkeyPreferences, recording: HotkeyRecordingSession<FeatureHotkey>) {
        _editor = StateObject(wrappedValue: FeatureShortcutEditor(hotkey: hotkey, preferences: preferences, recording: recording))
        self.preferences = preferences
    }

    var body: some View {
        FeatureShortcutRow(editor: editor,
                           detail: FeatureShortcutsGroup.detail(for: editor.hotkey, in: preferences.configuration))
            .onDisappear { editor.cancel() }
    }
}

/// "What it needs": every requirement with its state or its action, and the
/// model dropdown of Keys & models in place.
@MainActor
struct FeatureNeedsGroup: View {
    let feature: AppFeature
    let context: FeatureScreenContext

    static func requiredSummary(_ checks: [FeatureCheck]) -> String {
        let required = checks.filter { !$0.requirement.optional }
        guard !required.isEmpty else { return "Nothing is required" }
        let done = required.filter { $0.state.isMet }.count
        return done == required.count ? "All required are set" : "\(done) of \(required.count) required"
    }

    static func offersOnDevice(_ check: FeatureCheck) -> Bool {
        switch check.action {
        case .downloadOnDeviceModel, .useOnDeviceModel: return true
        default: return false
        }
    }

    var body: some View {
        let checks = FeatureCatalog.checks(for: feature, snapshot: context.snapshot)
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "What it needs", trailing: Self.requiredSummary(checks))
            MacCard {
                ForEach(Array(checks.enumerated()), id: \.element.id) { index, check in
                    if index > 0 { MacRowSeparator() }
                    FeatureRequirementRow(
                        check: check,
                        note: context.note(for: check, of: feature),
                        download: context.downloadFraction,
                        perform: context.perform
                    ) { modelMenu(for: check) }
                }
            }
        }
    }

    /// Picking a model here is the same choice as picking it in Keys & models.
    @ViewBuilder
    private func modelMenu(for check: FeatureCheck) -> some View {
        if case .model(let aiFeature) = check.requirement.kind,
           context.snapshot.selectableModels.contains(aiFeature) {
            ModelMenu(viewModel: context.models, feature: aiFeature,
                      label: context.models.rows.first { $0.feature == aiFeature }?.selectionLabel ?? "Choose a model",
                      onAddKey: { context.selection.showAPIKeys() },
                      // Beside the free model's button the list is the other way.
                      width: Self.offersOnDevice(check) ? 150 : 230)
        }
    }
}

/// The first missing step of a feature that is on, or nothing.
@MainActor
struct FeatureNeedsBanner: View {
    let feature: AppFeature
    let context: FeatureScreenContext

    var body: some View {
        if case .needsSetup(let missing) = FeatureCatalog.status(for: feature, snapshot: context.snapshot),
           let first = missing.first {
            FeatureNeedsBox(
                consequence: FeatureCatalog.consequence(of: first, for: feature, snapshot: context.snapshot),
                more: missing.count - 1,
                action: first.action,
                download: context.downloadFraction,
                modelSize: OnDeviceSpeechModel.parakeetTdtV3.approximateSize,
                perform: context.perform)
        }
    }
}

/// How the feature is turned on, with its status in words: a switch, or for
/// island tools the way to show them in the island.
struct FeatureSwitchCard: View {
    let info: FeatureInfo
    let status: FeatureStatus
    /// The switch's value and setter; nil for a feature without a switch.
    var isOn: Binding<Bool>?
    /// While the switch is busy (the Agent connects).
    var busy = false
    /// A line that replaces the usual subtitle, e.g. why it did not turn on.
    var problem: String?
    var openIslandTools: () -> Void = {}

    static func statusWord(_ info: FeatureInfo, _ status: FeatureStatus) -> String {
        switch info.activation {
        case .alwaysOn: return "Always on"
        case .islandTools: return status.isReady ? "Ready" : "Not set up"
        case .userSwitch:
            switch status {
            case .ready: return "On · Ready"
            case .needsSetup: return "On · Needs setup"
            case .off, .notSetUp: return "Off"
            }
        }
    }

    static func subtitle(_ info: FeatureInfo, isOn: Bool) -> String {
        switch info.activation {
        case .alwaysOn: return "There is nothing to switch: it waits for its shortcut."
        case .islandTools(let tools):
            return tools.count > 1 ? "Show or hide them in Toolbox; their shortcuts work either way."
                : "Show or hide it in Toolbox; its shortcut works either way."
        case .userSwitch: return isOn ? "Turn it off if you don’t use it." : "Turn it on to use it."
        }
    }

    var body: some View {
        MacCard {
            MacRow(title: info.name,
                   subtitle: problem ?? Self.subtitle(info, isOn: isOn?.wrappedValue ?? false)) {
                HStack(spacing: 10) {
                    Text(Self.statusWord(info, status))
                        .font(.system(size: 12.5, weight: isNeed ? .semibold : .regular))
                        .foregroundStyle(isNeed || status.isReady ? MacSettingsTheme.text : MacSettingsTheme.text3)
                        .fixedSize()
                    if busy { ProgressView().controlSize(.small) }
                    if let isOn {
                        MacSwitch(isOn: isOn, label: info.name).disabled(busy)
                    } else if case .islandTools = info.activation {
                        MacButton(title: "Toolbox", action: openIslandTools).fixedSize()
                    }
                }
            }
        }
    }

    private var isNeed: Bool {
        if case .needsSetup = status { return true }
        return false
    }
}

/// Things to ask or do, as plain examples the person can copy.
struct FeatureExamplesGroup: View {
    let title: String
    let examples: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: title)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      alignment: .leading, spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Text(example)
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(MacSettingsTheme.bgCard,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(MacSettingsTheme.sep, lineWidth: 1)
                        }
                }
            }
        }
    }
}

/// A feature's screen from the template: what it does, how it is turned on,
/// its clip, its shortcuts, what it needs, its own settings and examples.
/// Drop has its own order (the field to try it) and its own view.
@MainActor
struct FeatureScreenView<Settings: View>: View {
    let feature: AppFeature
    let context: FeatureScreenContext
    var isOn: Binding<Bool>?
    var busy = false
    var problem: String?
    var videoShortcuts: [FeatureVideoShortcut] = []
    @ViewBuilder var settings: Settings

    var body: some View {
        let info = FeatureCatalog.info(for: feature)
        let status = FeatureCatalog.status(for: feature, snapshot: context.snapshot)
        FeatureScreenScaffold {
            FeatureScreenHeader(info: info, about: info.about) { context.selection.shownFeature = nil }
            if info.activation != .alwaysOn {
                FeatureSwitchCard(info: info, status: status, isOn: isOn, busy: busy, problem: problem,
                                  openIslandTools: { context.selection.select(.toolbox) })
            }
            FeatureNeedsBanner(feature: feature, context: context)
            // One strip per clip: Translate & Subtitles shows both tools.
            ForEach(Array(info.clips.enumerated()), id: \.offset) { index, clip in
                FeatureVideoStrip(clip: clip, shortcuts: index == 0 ? videoShortcuts : [])
            }
            if !info.hotkeys.isEmpty {
                FeatureShortcutsGroup(hotkeys: info.hotkeys, preferences: context.environment.hotkeys)
            }
            if !FeatureCatalog.requirements(for: feature, snapshot: context.snapshot).isEmpty {
                FeatureNeedsGroup(feature: feature, context: context)
            }
            settings
            if !info.examples.isEmpty {
                FeatureExamplesGroup(title: info.examplesTitle, examples: info.examples)
            }
        }
    }
}

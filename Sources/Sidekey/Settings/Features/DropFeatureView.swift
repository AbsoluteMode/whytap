import SwiftUI

/// Settings -> Features -> Drop: what dictation does, its shortcut and Hold
/// or Toggle, a field to try it, what it needs with the action in place, and
/// its options. Everything Drop-related that was spread over Keys & models,
/// Hotkeys, Permissions, Other and the island is reachable from this screen.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
@MainActor
struct DropFeatureView: View {
    let snapshot: FeatureSetupSnapshot
    @ObservedObject var selection: SettingsWindowSelection
    @ObservedObject var models: APIAndModelsViewModel
    @ObservedObject var permissions: PermissionsSettingsViewModel
    /// Observed so the download's progress redraws the screen.
    @ObservedObject private var onDevice: OnDeviceSpeechModelController
    @ObservedObject private var hotkeys: HotkeyPreferences
    @StateObject private var shortcut: FeatureShortcutEditor
    private let environment: FeaturesEnvironment

    @State private var language: AppLanguage?
    @State private var targetLanguage: AppLanguage?
    @State private var volumeDuck = false
    @State private var autoStop = false

    init(snapshot: FeatureSetupSnapshot, selection: SettingsWindowSelection, models: APIAndModelsViewModel,
         permissions: PermissionsSettingsViewModel, environment: FeaturesEnvironment,
         shortcutEditor: FeatureShortcutEditor? = nil) {
        self.snapshot = snapshot
        self.selection = selection
        self.models = models
        self.permissions = permissions
        self.environment = environment
        self.onDevice = environment.onDevice
        self.hotkeys = environment.hotkeys
        _shortcut = StateObject(wrappedValue: shortcutEditor
            ?? FeatureShortcutEditor(hotkey: .dropVoice, preferences: environment.hotkeys))
        _language = State(initialValue: environment.language())
        _targetLanguage = State(initialValue: environment.targetLanguage())
        _volumeDuck = State(initialValue: environment.volumeDuck.isEnabled)
        _autoStop = State(initialValue: environment.autoStop.isEnabled)
    }

    private var info: FeatureInfo { FeatureCatalog.info(for: .drop) }
    private var status: FeatureStatus { FeatureCatalog.status(for: .drop, snapshot: snapshot) }
    private var gesture: HotkeyGesture { FeatureHotkey.dropVoice.gesture(in: hotkeys.configuration) }
    private var context: FeatureScreenContext {
        FeatureScreenContext(snapshot: snapshot, selection: selection, models: models,
                             permissions: permissions, environment: environment)
    }

    var body: some View {
        FeatureScreenScaffold {
            FeatureScreenHeader(info: info, about: FeatureCatalog.dropAbout(gesture: gesture)) {
                selection.shownFeature = nil
            }
            FeatureNeedsBanner(feature: .drop, context: context)
            FeatureVideoStrip(info: info)
            shortcutGroup
            // A newcomer meets the steps before the field they unlock;
            // once Drop is ready the field comes first.
            if status.isReady {
                tryGroup
                FeatureNeedsGroup(feature: .drop, context: context)
            } else {
                FeatureNeedsGroup(feature: .drop, context: context)
                tryGroup
            }
            settingsGroup
            wordsGroup
        }
        .onAppear(perform: reload)
        // Output Lang and Input Lang in the island write the same preferences:
        // the open screen shows the value Drop uses now.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            reloadLanguages()
        }
        .onDisappear { shortcut.cancel() }
    }

    private func reload() {
        reloadLanguages()
        volumeDuck = environment.volumeDuck.isEnabled
        autoStop = environment.autoStop.isEnabled
    }

    private func reloadLanguages() {
        let spoken = environment.language()
        if spoken != language { language = spoken }
        let written = environment.targetLanguage()
        if written != targetLanguage { targetLanguage = written }
    }

    // MARK: - Shortcut

    private var shortcutGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Shortcut")
            MacCard {
                FeatureShortcutRow(
                    editor: shortcut,
                    detail: FeatureShortcutsGroup.detail(for: .dropVoice, in: hotkeys.configuration))
            }
        }
    }

    // MARK: - Try it

    private var tryGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Try it here")
            MacCard {
                VStack(alignment: .leading, spacing: 8) {
                    if status.isReady {
                        OnboardingTryField(placeholder: "Click here, then use the shortcut and say a sentence.",
                                           onDictated: {})
                            .frame(height: 46)
                        HStack(spacing: 6) {
                            Text(gesture == .hold ? "Your shortcut: hold" : "Your shortcut: press")
                                .font(.system(size: 11.5))
                                .foregroundStyle(MacSettingsTheme.text2)
                            FeatureShortcutKeys(contents: shortcut.contents)
                        }
                    } else {
                        Text("Finish “What it needs” above, then try dictation here.")
                            .font(.system(size: 13))
                            .foregroundStyle(MacSettingsTheme.text3)
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - What it needs

    static func requiredSummary(_ checks: [FeatureCheck]) -> String {
        FeatureNeedsGroup.requiredSummary(checks)
    }

    // MARK: - Settings

    private var settingsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Settings")
            MacCard {
                MacRow(title: "Mode",
                       subtitle: "Fast types exactly what you said. Smart also fixes slips and punctuation with a text model.") {
                    MacSegmented(
                        items: [.init(value: TranscriptionMode.fast, label: "Fast"),
                                .init(value: TranscriptionMode.smart, label: "Smart")],
                        selection: Binding(get: { snapshot.dropMode }, set: { environment.setDropMode($0) })
                    )
                    .frame(width: 132)
                    .accessibilityLabel("Drop mode")
                }
                MacRowSeparator()
                MacRow(title: "Language you speak",
                       subtitle: "Detect automatically suits most people; choose one if Drop mixes languages up.") {
                    MacPopup(
                        items: [.init(value: "", label: "Detect automatically")]
                            + AppLanguage.all.map { .init(value: $0.code, label: $0.displayName) },
                        selection: Binding(
                            get: { language?.code ?? "" },
                            set: { code in
                                let chosen = AppLanguage.all.first { $0.code == code }
                                language = chosen
                                environment.setLanguage(chosen)
                            })
                    )
                    .accessibilityLabel("Language you speak")
                }
                MacRowSeparator()
                // Smart's output language lived only in the island (Output Lang).
                // WHY: .project-docs/decisions/2026-11-26-every-feature-in-features.md
                MacRow(title: Self.writesInTitle, subtitle: Self.writesInSubtitle(mode: snapshot.dropMode)) {
                    MacPopup(
                        items: [.init(value: "", label: Self.writesInOff)]
                            + AppLanguage.all.map { .init(value: $0.code, label: $0.displayName) },
                        selection: Binding(
                            get: { targetLanguage?.code ?? "" },
                            set: { code in
                                let chosen = AppLanguage.all.first { $0.code == code }
                                targetLanguage = chosen
                                environment.setTargetLanguage(chosen)
                            })
                    )
                    .accessibilityLabel(Self.writesInTitle)
                }
                MacRowSeparator()
                MacRow(title: "Lower other audio while speaking",
                       subtitle: "Lowers built-in-speaker volume while you record voice, restores after. External outputs (USB/Bluetooth DACs) are never touched.") {
                    MacSwitch(isOn: Binding(get: { volumeDuck }, set: {
                        volumeDuck = $0
                        environment.volumeDuck.isEnabled = $0
                    }), label: "Lower other audio while speaking")
                }
                MacRowSeparator()
                // Auto-stop acts only on a Toggle shortcut; with Hold the
                // release already ends the take, so the switch is not offered.
                MacRow(title: "Stop Drop automatically",
                       subtitle: gesture == .tap
                           ? "Press once, speak, and dictation ends when you stop. Press again to stop sooner."
                           : "Works when the shortcut above is set to Toggle. With Hold, letting go already stops it.") {
                    FeatureVideoButton(video: .dropAutoStop, shortcuts: {
                        SettingsOtherView.dropAutoStopVideoShortcuts(hotkeys.configuration)
                    })
                } trailing: {
                    MacSwitch(isOn: Binding(get: { gesture == .tap && autoStop }, set: {
                        autoStop = $0
                        environment.autoStop.isEnabled = $0
                    }), isEnabled: gesture == .tap, label: "Stop Drop automatically")
                }
            }
        }
    }

    static let writesInTitle = "Language Drop writes in"
    static let writesInOff = "As spoken"

    /// The output language is Smart's: Fast types what was said.
    static func writesInSubtitle(mode: TranscriptionMode) -> String {
        switch mode {
        case .smart: return "Smart writes what you said in this language. As spoken keeps your own."
        case .fast: return "Used in Smart mode. Fast types the language you spoke."
        }
    }

    // MARK: - Your words

    private var wordsGroup: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Your words")
            MacCard {
                MacRow(title: "Vocab", subtitle: "Names and terms Whytap should spell right. Opens in the island.") {
                    MacButton(title: "Edit") { environment.openHoverPanel(.vocabularyEditor) }
                        .fixedSize()
                        .accessibilityLabel("Edit Vocab")
                }
                MacRowSeparator()
                MacRow(title: "Filler", subtitle: "Words to cut from your dictation. Opens in the island.") {
                    MacButton(title: "Edit") { environment.openHoverPanel(.fillerEditor) }
                        .fixedSize()
                        .accessibilityLabel("Edit Filler")
                }
            }
        }
    }
}

/// The first missing step of a feature that is on, said as what does not
/// work, with the one action that fixes it. Neutral colours: it is a next
/// step, not an alarm.
// WHY: docs/DESIGN.md — Feature status in words.
struct FeatureNeedsBox: View {
    let consequence: String
    let more: Int
    let action: FeatureSetupAction?
    /// The on-device download's progress while it runs.
    let download: Double?
    let modelSize: String
    let perform: (FeatureSetupAction) -> Void

    static func buttonTitle(_ action: FeatureSetupAction, modelSize: String) -> String {
        if case .downloadOnDeviceModel = action {
            return "Download the free model · \(modelSize.replacingOccurrences(of: "about ", with: ""))"
        }
        return action.title
    }

    static func text(consequence: String, more: Int) -> String {
        more > 0 ? "\(consequence) \(more) more below." : consequence
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Needs setup")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(Self.text(consequence: consequence, more: more))
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if let download {
                    Text(FeatureRequirementRow<EmptyView>.downloadText(download))
                        .font(.system(size: 12))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize()
                } else if let action {
                    MacButton(title: Self.buttonTitle(action, modelSize: modelSize), style: .primary) { perform(action) }
                        .fixedSize()
                }
            }
            if let download {
                OnDeviceDownloadBar(fraction: download,
                                    starting: OnDeviceSpeechCard.Presentation.isStarting(download))
                    .accessibilityLabel("Download progress")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(MacSettingsTheme.bgCard,
                    in: RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MacSettingsTheme.radiusCard, style: .continuous)
                .strokeBorder(MacSettingsTheme.sepStrong, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

/// One requirement: a mark, its name, one sentence, and its state or the
/// action that satisfies it. A model requirement also carries the model
/// dropdown (`menu`).
struct FeatureRequirementRow<Menu: View>: View {
    let check: FeatureCheck
    var note: String?
    var download: Double?
    let perform: (FeatureSetupAction) -> Void
    @ViewBuilder var menu: Menu

    static func downloadText(_ fraction: Double) -> String {
        OnDeviceSpeechCard.Presentation.isStarting(fraction)
            ? "Starting the download…"
            : "Downloading… \(OnDeviceSpeechCard.Presentation.percent(fraction))%"
    }

    /// The short word shown where a done requirement has no control.
    static func doneWord(_ kind: FeatureRequirement.Kind) -> String {
        switch kind {
        case .permission: return "Allowed"
        case .dropShortcut: return "Heard"
        case .model, .subtitlesKey: return "Set"
        }
    }

    private var isModel: Bool {
        if case .model = check.requirement.kind { return true }
        return false
    }

    /// No keyed provider can serve it: there is no list to choose from yet.
    private var needsKey: Bool {
        switch check.action {
        case .addKey, .fixKey, .addOpenAIKey: return true
        default: return false
        }
    }

    private var isOnDeviceAction: Bool {
        switch check.action {
        case .downloadOnDeviceModel, .useOnDeviceModel: return true
        default: return false
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            mark.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(check.requirement.title)
                        .font(.system(size: 13))
                        .foregroundStyle(MacSettingsTheme.text)
                    if check.requirement.optional {
                        Text("· optional")
                            .font(.system(size: 11.5))
                            .foregroundStyle(MacSettingsTheme.text3)
                    }
                }
                Text(check.requirement.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var trailing: some View {
        switch check.state {
        case .met:
            if isModel {
                menu
            } else {
                stateWord(Self.doneWord(check.requirement.kind))
            }
        case .waiting(let reason):
            stateWord(reason)
        case .askedLater(let note):
            stateWord(note)
        case .unmet(_, let action):
            HStack(spacing: 8) {
                if isModel, download != nil, check.action == nil {
                    stateWord(Self.downloadText(download ?? 0))
                }
                if isModel { menu }
                if let action, !isModel || isOnDeviceAction || needsKey {
                    MacButton(title: Self.rowTitle(action)) { perform(action) }
                        .fixedSize()
                        .accessibilityLabel("\(action.title) for \(check.requirement.title)")
                }
            }
        }
    }

    /// Row buttons are short: the row's own title names what is allowed.
    static func rowTitle(_ action: FeatureSetupAction) -> String {
        switch action {
        case .allow: return "Allow"
        case .openInputMonitoring: return "Open Settings"
        case .retryShortcut: return "Retry"
        default: return action.title
        }
    }

    private func stateWord(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(MacSettingsTheme.text2)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 220, alignment: .trailing)
    }

    @ViewBuilder private var mark: some View {
        switch check.state {
        case .met:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MacSettingsTheme.green)
                .accessibilityLabel("Done")
        case .askedLater:
            Text("?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text3)
                .accessibilityLabel("Asked later")
        case .unmet, .waiting:
            Circle()
                .strokeBorder(check.requirement.optional ? MacSettingsTheme.text3 : MacSettingsTheme.text,
                              style: StrokeStyle(lineWidth: 1.4, dash: check.requirement.optional ? [2.5, 2] : []))
                .frame(width: 12, height: 12)
                .accessibilityLabel(check.requirement.optional ? "Optional" : "Missing")
        }
    }
}

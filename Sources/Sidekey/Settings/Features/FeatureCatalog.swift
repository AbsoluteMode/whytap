import Foundation

/// What a person would call a feature of Whytap. Settings is being rebuilt
/// around these: one list of features, one screen per feature with what it
/// does, its shortcut, what it needs and its options. Declaration order is
/// the order of the Features list.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
enum AppFeature: String, CaseIterable, Identifiable {
    case drop
    case agent
    case meetings
    case googleSearch
    case translateSubtitles
    case screenshots

    var id: String { rawValue }
}

/// How a feature is turned on. A switch is listed only where the app really
/// has one: Drop always waits for its shortcut, and the island tools are
/// shown or hidden in Toolbox, which is not an on/off state of the feature.
enum FeatureActivation: Equatable {
    case alwaysOn
    case userSwitch
    case islandTools([HoverTool])
}

/// Where a feature's settings are shown today.
enum FeaturePlace: Equatable {
    /// Its own screen inside Features.
    case screen
    /// A row of an older tab, until the feature gets its own screen.
    case tab(SettingsWindowTab)
    /// A tool pane in Toolbox.
    case tool(HoverTool)
}

/// A shortcut that belongs to a feature. The label says what the shortcut
/// does and never names a key: keys are read live from `HotkeyConfiguration`.
// WHY: .project-docs/decisions/2026-11-20-other-feature-videos.md
enum FeatureHotkey: Hashable {
    case dropVoice
    case agentText
    case agentVoice
    case agentClose
    case googleText
    case googleVoice
    case meetingRecord
    case tool(HoverTool)

    var label: String {
        switch self {
        case .dropVoice: return "Dictate"
        case .agentText: return "Type to the Agent"
        case .agentVoice: return "Talk to the Agent"
        case .agentClose: return "Close the answer"
        case .googleText: return "Type a search"
        case .googleVoice: return "Say a search"
        case .meetingRecord: return "Start or stop taking notes"
        case .tool(.translate): return "Open Translate"
        case .tool(.subtitles): return "Start Subtitles"
        case .tool(.screenshot): return "Capture an area"
        case .tool(let tool): return HoverToolRegistry.info(for: tool).title
        }
    }

    /// The keys now assigned, or nil for a tool without a shortcut.
    func shortcut(in configuration: HotkeyConfiguration) -> HotkeyShortcut? {
        switch self {
        case .dropVoice: return configuration.dropVoiceShortcut
        case .agentText: return configuration.agentTextShortcut
        case .agentVoice: return configuration.agentVoiceShortcut
        case .agentClose: return configuration.agentCloseShortcut
        case .googleText: return configuration.googleSearchTextShortcut
        case .googleVoice: return configuration.googleSearchVoiceShortcut
        case .meetingRecord: return configuration.meetingRecordShortcut
        case .tool(let tool): return configuration.toolShortcuts[tool]
        }
    }

    /// Hold or Toggle for the voice shortcuts; every other one is a tap.
    func gesture(in configuration: HotkeyConfiguration) -> HotkeyGesture {
        switch self {
        case .dropVoice:
            return HotkeyConfiguration.normalizedDropGesture(
                shortcut: configuration.dropVoiceShortcut, gesture: configuration.dropVoiceGesture)
        case .agentVoice: return configuration.agentVoiceGesture
        case .googleVoice: return configuration.googleSearchVoiceGesture
        case .agentText, .agentClose, .googleText, .meetingRecord, .tool: return .tap
        }
    }

    /// Whether the person can choose between Hold and Toggle here.
    var isVoice: Bool {
        switch self {
        case .dropVoice, .agentVoice, .googleVoice: return true
        case .agentText, .agentClose, .googleText, .meetingRecord, .tool: return false
        }
    }
}

/// A macOS permission a feature depends on.
enum FeaturePermission: String, Equatable {
    case keyboard
    case microphone
    case screenRecording
    /// macOS asks when the first recording starts and gives no way to check
    /// it in advance, so it is never shown as allowed or missing.
    case systemAudio

    var title: String {
        switch self {
        case .keyboard: return "Keyboard control"
        case .microphone: return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .systemAudio: return "System audio"
        }
    }
}

/// One thing a feature needs before it works.
struct FeatureRequirement: Equatable, Identifiable {
    enum Kind: Equatable {
        /// A model route of `AIRoutingStore`.
        case model(AIFeature)
        /// Subtitles run only on the OpenAI key (`SubtitleAudioTranslate`).
        case subtitlesKey
        case permission(FeaturePermission)
        /// Drop's shortcut is installed and macOS delivers it.
        case dropShortcut
    }

    let kind: Kind
    let title: String
    let detail: String
    /// The feature works without it; only a part of it does not.
    var optional = false

    var id: String {
        switch kind {
        case .model(let feature): return "model.\(feature.rawValue)"
        case .subtitlesKey: return "subtitlesKey"
        case .permission(let permission): return "permission.\(permission.rawValue)"
        case .dropShortcut: return "dropShortcut"
        }
    }
}

/// The one step that satisfies a requirement, done from the feature's screen.
enum FeatureSetupAction: Equatable {
    /// Download the speech model that runs on this Mac and use it here.
    case downloadOnDeviceModel(AIFeature)
    /// The model is already on this Mac: use it for this feature.
    case useOnDeviceModel(AIFeature)
    /// Pick a model from the providers that have a key.
    case chooseModel(AIFeature)
    /// No provider that can serve the feature has a key yet.
    case addKey(AIFeature)
    /// The route's key is refused and no other model would work: the key
    /// has to be fixed or replaced in API & Models.
    case fixKey(AIFeature)
    case addOpenAIKey
    case allow(FeaturePermission)
    case openInputMonitoring
    case restartWhytap
    case retryShortcut

    var title: String {
        switch self {
        case .downloadOnDeviceModel: return "Download free model"
        case .useOnDeviceModel: return "Use the model on this Mac"
        case .chooseModel: return "Choose a model"
        case .addKey: return "Add a key"
        case .fixKey: return "Fix the key"
        case .addOpenAIKey: return "Add an OpenAI key"
        case .allow(let permission): return "Allow \(permission.title)"
        case .openInputMonitoring: return "Open Input Monitoring"
        case .restartWhytap: return "Restart Whytap"
        case .retryShortcut: return "Retry shortcut"
        }
    }
}

/// Where one requirement stands.
enum FeatureRequirementState: Equatable {
    case met
    /// Not done. `reason` is a few words for the Features list.
    case unmet(reason: String, action: FeatureSetupAction?)
    /// Cannot be done before another requirement of the same feature, which
    /// is already listed as unmet: not counted a second time.
    case waiting(reason: String)
    /// macOS decides later and Whytap cannot check it now.
    case askedLater(note: String)

    var isMet: Bool { self == .met }
}

struct FeatureCheck: Equatable, Identifiable {
    let requirement: FeatureRequirement
    let state: FeatureRequirementState
    var id: String { requirement.id }

    /// A required step the person still has to take.
    var isBlocking: Bool {
        guard !requirement.optional, case .unmet = state else { return false }
        return true
    }

    var reason: String? {
        switch state {
        case .unmet(let reason, _), .waiting(let reason): return reason
        case .met, .askedLater: return nil
        }
    }

    var action: FeatureSetupAction? {
        if case .unmet(_, let action) = state { return action }
        return nil
    }
}

/// The state of a feature in words. `needsSetup` is only for a feature that
/// is on: something the person does not use is `off` (it has a switch) or
/// `notSetUp` (an island tool), both quiet.
enum FeatureStatus: Equatable {
    /// `note` narrows it, e.g. "typing only" for search without a voice model.
    case ready(note: String?)
    case off
    case needsSetup([FeatureCheck])
    case notSetUp([FeatureCheck])

    var word: String {
        switch self {
        case .ready: return "Ready"
        case .off: return "Off"
        case .needsSetup: return "Needs setup"
        case .notSetUp: return "Not set up"
        }
    }

    /// The first missing step and how many more: "No text model +2".
    var reason: String? {
        switch self {
        case .ready(let note): return note
        case .off: return nil
        case .needsSetup(let missing), .notSetUp(let missing):
            guard let first = missing.first?.reason else { return nil }
            return missing.count > 1 ? "\(first) +\(missing.count - 1)" : first
        }
    }

    var missing: [FeatureCheck] {
        switch self {
        case .needsSetup(let missing), .notSetUp(let missing): return missing
        case .ready, .off: return []
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Whether the speech model that runs on this Mac can be the free way in.
enum OnDeviceSpeechAvailability: Equatable {
    /// An Intel Mac: the model needs Apple Silicon.
    case unsupported
    case available(OnDeviceSpeechModelStatus)
}

/// Everything the catalog reads to judge readiness, as plain values, so the
/// same rules run in Settings and in tests without a view or a store.
struct FeatureSetupSnapshot: Equatable {
    var dropMode: TranscriptionMode = .fast
    /// The model row status of each route; a missing entry is `notSet`.
    var models: [AIFeature: ModelRowStatus] = [:]
    /// Features whose model picker has a list at all (the dropdown is shown).
    var selectableModels: Set<AIFeature> = []
    /// Features with a model that would work instead of the current route: a
    /// listed model other than the selected one, or a typed name, under a key
    /// that is not refused. Only then does "Choose a model" fix anything.
    var modelAlternatives: Set<AIFeature> = []
    var subtitlesKeyPresent = false
    var onDevice: OnDeviceSpeechAvailability = .unsupported
    var keyboardReady = false
    /// macOS 27.3: the grant is made, a restart makes it work.
    var keyboardNeedsRestart = false
    /// macOS 27.3: the current step of keyboard control; nil on older macOS.
    var keyboardSetup: PermissionsSettingsViewModel.KeyboardSetup?
    var microphoneGranted = false
    var screenRecordingGranted = false
    var screenNeedsRestart = false
    var dropShortcut: DropHotkeyStatus = .ready
    var agentOn = false
    var meetingsOn = false
    var googleOn = false

    func modelStatus(_ feature: AIFeature) -> ModelRowStatus { models[feature] ?? .notSet }
}

/// One feature as data: what it is called, what it does in one phrase, its
/// clip, its shortcuts, how it is turned on and where its settings are.
struct FeatureInfo: Equatable, Identifiable {
    let feature: AppFeature
    let name: String
    /// A plain word for what it is, beside the product name: "Dictation".
    let kind: String
    /// One phrase for the Features list.
    let line: String
    /// The clip of the feature at work; nil until one is made.
    let video: FeatureVideo?
    let hotkeys: [FeatureHotkey]
    let activation: FeatureActivation
    let place: FeaturePlace

    var id: AppFeature { feature }
    var hasSwitch: Bool { activation == .userSwitch }
}

/// The feature catalog and its readiness rules.
///
/// No text here names a key: shortcuts are remappable, so a fixed key name
/// goes wrong the moment the person rebinds it.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
enum FeatureCatalog {
    static let all: [FeatureInfo] = AppFeature.allCases.map(info(for:))

    static func info(for feature: AppFeature) -> FeatureInfo {
        switch feature {
        case .drop:
            return FeatureInfo(
                feature: feature, name: "Drop", kind: "Dictation",
                line: "Dictation. Use its shortcut in any text field and speak: your words are typed there.",
                // The Drop clip is not made yet; the screen shows no placeholder.
                video: nil, hotkeys: [.dropVoice], activation: .alwaysOn, place: .screen)
        case .agent:
            return FeatureInfo(
                feature: feature, name: "Agent", kind: "Quick tasks on your Mac",
                line: "Ask for a quick task by text or voice: it finds, converts, copies and changes settings.",
                video: .agent, hotkeys: [.agentText, .agentVoice, .agentClose],
                activation: .userSwitch, place: .tab(.agentMode))
        case .meetings:
            return FeatureInfo(
                feature: feature, name: "Meeting Notes", kind: "Notes from your calls",
                line: "Takes notes on your calls: transcript, summary, tasks and decisions.",
                video: .meetings, hotkeys: [.meetingRecord], activation: .userSwitch, place: .tab(.other))
        case .googleSearch:
            return FeatureInfo(
                feature: feature, name: "Google search", kind: "Search from anywhere",
                line: "Type or say a query from anywhere; it opens in Google.",
                video: .googleSearch, hotkeys: [.googleText, .googleVoice],
                activation: .userSwitch, place: .tab(.other))
        case .translateSubtitles:
            return FeatureInfo(
                feature: feature, name: "Translate & Subtitles", kind: "Island tools",
                line: "Translate text in a small window, or show live translated subtitles for a call or video.",
                video: nil, hotkeys: [.tool(.translate), .tool(.subtitles)],
                activation: .islandTools([.translate, .subtitles]), place: .tool(.translate))
        case .screenshots:
            return FeatureInfo(
                feature: feature, name: "Screenshots", kind: "Island tool Shot",
                line: "Capture an area, annotate it, blur text and numbers.",
                video: nil, hotkeys: [.tool(.screenshot)],
                activation: .islandTools([.screenshot]), place: .tool(.screenshot))
        }
    }

    /// The lead paragraph of Drop's screen. It follows the gesture the person
    /// chose, and names no key.
    static func dropAbout(gesture: HotkeyGesture) -> String {
        switch gesture {
        case .hold:
            return "Dictation that works in every app. Hold the shortcut, say what you want to write, let go. "
                + "Whytap types the text where your cursor is."
        case .tap:
            return "Dictation that works in every app. Press the shortcut, say what you want to write, press it again. "
                + "Whytap types the text where your cursor is."
        }
    }

    // MARK: - Requirements

    /// What `feature` needs, in the order its screen lists it.
    static func requirements(for feature: AppFeature, snapshot: FeatureSetupSnapshot) -> [FeatureRequirement] {
        switch feature {
        case .drop:
            // Fast and Smart keep separate speech routes; the active mode's
            // one is required, and Smart also needs its text model.
            var list: [FeatureRequirement]
            switch snapshot.dropMode {
            case .fast:
                list = [FeatureRequirement(kind: .model(.dropFast), title: "Speech-to-text model",
                                           detail: "Turns your voice into text.")]
            case .smart:
                list = [
                    FeatureRequirement(kind: .model(.dropSmart), title: "Speech-to-text model for Smart",
                                       detail: "Turns your voice into text. Smart keeps its own choice."),
                    FeatureRequirement(kind: .model(.dropSmartCleanup), title: "Text model for Smart",
                                       detail: "Fixes slips and punctuation after you speak."),
                    FeatureRequirement(kind: .model(.dropFast), title: "Speech-to-text model for Fast",
                                       detail: "Used when you switch back to Fast.", optional: true),
                ]
            }
            return list + [
                FeatureRequirement(kind: .permission(.keyboard), title: FeaturePermission.keyboard.title,
                                   detail: "To hear your shortcut and type the text where your cursor is."),
                FeatureRequirement(kind: .permission(.microphone), title: FeaturePermission.microphone.title,
                                   detail: "To hear you, only while you are recording."),
                FeatureRequirement(kind: .dropShortcut, title: "Your shortcut is heard",
                                   detail: "macOS delivers Drop's shortcut to Whytap."),
            ]
        case .agent:
            return [
                FeatureRequirement(kind: .model(.agent), title: "Text model that can use tools",
                                   detail: "The Agent thinks and answers with it. OpenAI, Anthropic and OpenRouter models can."),
                FeatureRequirement(kind: .permission(.keyboard), title: FeaturePermission.keyboard.title,
                                   detail: "To hear the shortcut and paste the Agent's results."),
                FeatureRequirement(kind: .model(.agentVoice), title: "Speech-to-text model",
                                   detail: "Only for talking to the Agent. Typing works without it.", optional: true),
                FeatureRequirement(kind: .permission(.microphone), title: FeaturePermission.microphone.title,
                                   detail: "Only for talking to the Agent.", optional: true),
                FeatureRequirement(kind: .permission(.screenRecording), title: FeaturePermission.screenRecording.title,
                                   detail: "Only when you ask the Agent about what is on your screen.", optional: true),
            ]
        case .meetings:
            return [
                FeatureRequirement(kind: .model(.meetings), title: "Speech-to-text model",
                                   detail: "Writes down what was said. Speaker names need Soniox, Deepgram or ElevenLabs."),
                FeatureRequirement(kind: .model(.meetingNotes), title: "Text model",
                                   detail: "Reads the transcript and writes the summary, tasks and decisions."),
                FeatureRequirement(kind: .permission(.microphone), title: FeaturePermission.microphone.title,
                                   detail: "To hear your side of the call."),
                FeatureRequirement(kind: .permission(.systemAudio), title: FeaturePermission.systemAudio.title,
                                   detail: "To hear the other side of a call."),
            ]
        case .googleSearch:
            return [
                FeatureRequirement(kind: .model(.voiceSearch), title: "Speech-to-text model",
                                   detail: "Only for searching by voice. Typing works without it.", optional: true),
                FeatureRequirement(kind: .permission(.microphone), title: FeaturePermission.microphone.title,
                                   detail: "Only for searching by voice.", optional: true),
            ]
        case .translateSubtitles:
            // Two tools that start on their own: each needs only its own
            // part, and either one alone is a working feature.
            return [
                FeatureRequirement(kind: .model(.translation), title: "Text model for Translate",
                                   detail: "Translates the text you type or paste. Subtitles work without it.",
                                   optional: true),
                FeatureRequirement(kind: .subtitlesKey, title: "OpenAI key for Subtitles",
                                   detail: "Live subtitles run only on OpenAI's live translation model. Translate works without it.",
                                   optional: true),
                FeatureRequirement(kind: .permission(.systemAudio), title: FeaturePermission.systemAudio.title,
                                   detail: "Subtitles listen to your Mac's sound.", optional: true),
            ]
        case .screenshots:
            return [
                FeatureRequirement(kind: .permission(.screenRecording), title: FeaturePermission.screenRecording.title,
                                   detail: "To capture the area you pick."),
            ]
        }
    }

    static func checks(for feature: AppFeature, snapshot: FeatureSetupSnapshot) -> [FeatureCheck] {
        requirements(for: feature, snapshot: snapshot).map {
            FeatureCheck(requirement: $0, state: state(of: $0, snapshot: snapshot))
        }
    }

    static func state(of requirement: FeatureRequirement, snapshot: FeatureSetupSnapshot) -> FeatureRequirementState {
        switch requirement.kind {
        case .model(let feature):
            return modelState(feature, snapshot: snapshot)
        case .subtitlesKey:
            return snapshot.subtitlesKeyPresent ? .met : .unmet(reason: "No OpenAI key", action: .addOpenAIKey)
        case .permission(let permission):
            return permissionState(permission, snapshot: snapshot)
        case .dropShortcut:
            return dropShortcutState(snapshot)
        }
    }

    private static func modelState(_ feature: AIFeature, snapshot: FeatureSetupSnapshot) -> FeatureRequirementState {
        let isSpeech = feature.mode == .realtime || feature.mode == .recorded
        switch snapshot.modelStatus(feature) {
        // A model not probed yet, an alias or one that expires later still
        // runs; API & Models says the rest on its own row.
        case .ok, .notVerified, .deprecatedAlias, .expiring:
            return .met
        case .notSet:
            return .unmet(reason: isSpeech ? "No speech-to-text model" : "No text model",
                          action: missingModelAction(feature, snapshot: snapshot))
        // A set route that stopped working: "Choose a model" only when the
        // picker holds a model that would work; a refused key with nothing
        // else to pick is fixed at the key.
        case .keyProblem:
            return .unmet(reason: "Its provider key isn't working",
                          action: snapshot.modelAlternatives.contains(feature) ? .chooseModel(feature) : .fixKey(feature))
        case .removedByProvider:
            return .unmet(reason: "Its model was removed by the provider",
                          action: missingModelAction(feature, snapshot: snapshot))
        case .notSupported(let reason):
            return .unmet(reason: reason, action: missingModelAction(feature, snapshot: snapshot))
        }
    }

    /// The free way first: the model on this Mac, where this Mac can run it
    /// and the feature can use it. Otherwise another model that would work,
    /// or a key when no keyed provider offers one.
    private static func missingModelAction(_ feature: AIFeature, snapshot: FeatureSetupSnapshot) -> FeatureSetupAction? {
        if feature.modelUse(on: .onDevice) != nil, case .available(let status) = snapshot.onDevice {
            switch status {
            case .notDownloaded, .failed: return .downloadOnDeviceModel(feature)
            // The download is running; its progress is the answer.
            case .downloading: return nil
            case .ready: return .useOnDeviceModel(feature)
            }
        }
        return snapshot.modelAlternatives.contains(feature) ? .chooseModel(feature) : .addKey(feature)
    }

    private static func permissionState(_ permission: FeaturePermission,
                                        snapshot: FeatureSetupSnapshot) -> FeatureRequirementState {
        switch permission {
        case .keyboard:
            if snapshot.keyboardNeedsRestart { return .unmet(reason: "Restart Whytap", action: .restartWhytap) }
            if snapshot.keyboardReady { return .met }
            // 27.3 with Override already on: the one step left is Input
            // Monitoring, the same step Permissions shows.
            if snapshot.keyboardSetup == .inputMonitoring {
                return .unmet(reason: "Allow Input Monitoring", action: .openInputMonitoring)
            }
            return .unmet(reason: "Allow \(permission.title)", action: .allow(.keyboard))
        case .microphone:
            return snapshot.microphoneGranted ? .met
                : .unmet(reason: "Allow the \(permission.title)", action: .allow(.microphone))
        case .screenRecording:
            if snapshot.screenNeedsRestart { return .unmet(reason: "Restart Whytap", action: .restartWhytap) }
            return snapshot.screenRecordingGranted ? .met
                : .unmet(reason: "Allow \(permission.title)", action: .allow(.screenRecording))
        case .systemAudio:
            return .askedLater(note: "macOS asks at the first recording")
        }
    }

    /// "Ready" has to mean the shortcut really arrives. A status that only
    /// repeats a permission already listed as missing waits for that row.
    private static func dropShortcutState(_ snapshot: FeatureSetupSnapshot) -> FeatureRequirementState {
        let keyboardMissing = !snapshot.keyboardReady || snapshot.keyboardNeedsRestart
        switch snapshot.dropShortcut {
        case .ready:
            return keyboardMissing ? .waiting(reason: "Waits for Keyboard control") : .met
        case .accessibilityRequired:
            return keyboardMissing ? .waiting(reason: "Waits for Keyboard control")
                : .unmet(reason: "Shortcut isn't heard", action: .retryShortcut)
        case .microphoneRequired:
            return snapshot.microphoneGranted ? .unmet(reason: "Shortcut isn't heard", action: .retryShortcut)
                : .waiting(reason: "Waits for the Microphone")
        case .inputMonitoringRequired:
            // On 27.3 that grant is keyboard control's own last step, listed
            // on its row; on older macOS it is this row's step.
            if snapshot.keyboardSetup == .inputMonitoring, !snapshot.keyboardReady {
                return .waiting(reason: "Waits for Input Monitoring")
            }
            return .unmet(reason: "Allow Input Monitoring", action: .openInputMonitoring)
        case .shortcutInUse:
            return .unmet(reason: "Shortcut is in use", action: .retryShortcut)
        case .unavailable:
            return .unmet(reason: "Shortcut isn't heard", action: .retryShortcut)
        }
    }

    // MARK: - Status

    static func isOn(_ feature: AppFeature, snapshot: FeatureSetupSnapshot) -> Bool {
        switch feature {
        case .drop, .translateSubtitles, .screenshots: return true
        case .agent: return snapshot.agentOn
        case .meetings: return snapshot.meetingsOn
        case .googleSearch: return snapshot.googleOn
        }
    }

    static func status(for feature: AppFeature, snapshot: FeatureSetupSnapshot) -> FeatureStatus {
        let info = info(for: feature)
        guard isOn(feature, snapshot: snapshot) else { return .off }
        let checks = checks(for: feature, snapshot: snapshot)
        if feature == .translateSubtitles { return translateSubtitlesStatus(checks) }
        let missing = checks.filter(\.isBlocking)
        guard missing.isEmpty else {
            // An island tool the person never set up is not a problem to
            // report: it stays quiet until they want it.
            if case .islandTools = info.activation { return .notSetUp(missing) }
            return .needsSetup(missing)
        }
        return .ready(note: readyNote(for: feature, checks: checks))
    }

    /// Translate and Subtitles start on their own, so the row says which one
    /// works. System audio is asked by macOS later and never decides it.
    private static func translateSubtitlesStatus(_ checks: [FeatureCheck]) -> FeatureStatus {
        let tools = checks.filter { check in
            switch check.requirement.kind {
            case .model(.translation), .subtitlesKey: return true
            default: return false
            }
        }
        let translate = tools.first { $0.requirement.kind == .model(.translation) }?.state.isMet ?? false
        let subtitles = tools.first { $0.requirement.kind == .subtitlesKey }?.state.isMet ?? false
        switch (translate, subtitles) {
        case (true, true): return .ready(note: nil)
        case (true, false): return .ready(note: "Translate only")
        case (false, true): return .ready(note: "Subtitles only")
        case (false, false): return .notSetUp(tools.filter { !$0.state.isMet })
        }
    }

    /// What a ready feature still cannot do, in two words.
    private static func readyNote(for feature: AppFeature, checks: [FeatureCheck]) -> String? {
        guard feature == .googleSearch else { return nil }
        let voiceMissing = checks.contains { check in
            if case .unmet = check.state { return true }
            return false
        }
        return voiceMissing ? "typing only" : nil
    }

    /// "1 ready · 1 needs setup" above the Features list. Off and not set up
    /// features are not counted: they ask nothing of the person.
    static func summary(_ statuses: [FeatureStatus]) -> String {
        let ready = statuses.filter(\.isReady).count
        let needs = statuses.filter { if case .needsSetup = $0 { return true } else { return false } }.count
        guard needs > 0 else { return "\(ready) ready" }
        return "\(ready) ready · \(needs) \(needs == 1 ? "needs" : "need") setup"
    }

    /// What does not work until `check` is done, as one sentence for the
    /// feature's screen. An optional part names only what it serves, and an
    /// alternative is offered only when it works now.
    static func consequence(of check: FeatureCheck, for feature: AppFeature,
                            snapshot: FeatureSetupSnapshot) -> String {
        let name = info(for: feature).name
        let subject = feature == .agent ? "The Agent" : name
        switch check.requirement.kind {
        case .model(.dropFast), .model(.dropSmart):
            // Which dictation stops: all of Drop in its active mode, or only
            // the other mode (Fast, optional while Smart is on).
            let who: String
            if check.requirement.optional { who = "Fast mode" }
            else if check.requirement.kind == .model(.dropSmart) { who = "Smart mode" }
            else { who = "Drop" }
            if isBroken(check) {
                return "\(who) can’t type what you say: \(lowercasedFirst(check.reason ?? "its model needs attention"))."
            }
            if check.requirement.optional {
                return "Fast mode can’t type what you say until it has its own speech-to-text model. Smart doesn’t use it."
            }
            return "\(who) can’t type what you say until it has a speech-to-text model."
        case .model(.dropSmartCleanup):
            let tidy = "Smart mode can’t tidy your text until it has a text model."
            return isFastWorking(snapshot) ? tidy + " Fast mode has a working model: switch to it to dictate without tidying." : tidy
        case .model(.agent):
            return "The Agent can’t answer until it has a text model that can use tools."
        case .model(.agentVoice):
            return "Talking to the Agent needs a speech-to-text model. Typing to it works without one."
        case .model(.voiceSearch):
            return "Searching by voice needs a speech-to-text model. Typed searches work without one."
        case .model(.meetings):
            return "Calls can’t be transcribed until you pick a speech-to-text model."
        case .model(.meetingNotes):
            return "Notes can’t be written until you pick a text model."
        case .model(.translation):
            return "Translate can’t translate until it has a text model. Subtitles don’t use it."
        case .model:
            return "\(subject) can’t work until it has a model."
        case .subtitlesKey:
            return "Subtitles can’t start until Whytap has an OpenAI key. Translate doesn’t need it."
        case .permission(.keyboard):
            switch check.state {
            case .unmet(_, .restartWhytap):
                return "Keyboard control is allowed. Restart Whytap to make it work."
            case .unmet(_, .openInputMonitoring):
                return "\(subject) can’t hear its shortcut until you allow Input Monitoring."
            default:
                return feature == .drop ? "Drop can’t type into other apps until you allow Keyboard control."
                    : "\(subject) can’t paste its results until you allow Keyboard control."
            }
        case .permission(.microphone):
            if check.requirement.optional {
                return feature == .agent ? "Talking to the Agent needs the Microphone. Typing to it works without it."
                    : "Searching by voice needs the Microphone. Typed searches work without it."
            }
            return "\(subject) can’t hear you until you allow the Microphone."
        case .permission(.screenRecording):
            if case .unmet(_, .restartWhytap) = check.state {
                return "Screen Recording is allowed. Restart Whytap to make it work."
            }
            return "\(subject) can’t see the screen until you allow Screen Recording."
        case .permission(.systemAudio):
            return "macOS asks for system audio when the first recording starts."
        case .dropShortcut:
            switch check.state {
            case .unmet(_, .openInputMonitoring):
                return "Drop can’t see its shortcut until you allow Input Monitoring."
            case .unmet(let reason, _) where reason == "Shortcut is in use":
                return "Another app or another copy of Whytap is using this shortcut. Close it and retry, or record another shortcut."
            default:
                return "macOS isn’t delivering Drop’s shortcut. Retry, or record another shortcut."
            }
        }
    }

    /// A set model that stopped working reads differently from no model.
    private static func isBroken(_ check: FeatureCheck) -> Bool {
        guard case .unmet(let reason, _) = check.state else { return false }
        return reason != "No speech-to-text model" && reason != "No text model"
    }

    /// Fast dictates right now: its speech model works.
    private static func isFastWorking(_ snapshot: FeatureSetupSnapshot) -> Bool {
        modelState(.dropFast, snapshot: snapshot).isMet
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}

import Combine
import SwiftUI

/// What the Features screens read besides the two Settings view models: the
/// switches the host owns, Drop's mode, the speech model on this Mac and the
/// hotkeys. The Settings window passes its live values; tests and offscreen
/// previews pass a Mac in another state (a fresh install, an Intel Mac).
@MainActor
struct FeaturesEnvironment {
    var dropMode: () -> TranscriptionMode
    var agentOn: () -> Bool
    var meetingsOn: () -> Bool
    var googleOn: () -> Bool
    /// False on an Intel Mac: the on-device model is never offered there.
    var supportsOnDevice: Bool
    var onDevice: OnDeviceSpeechModelController
    var hotkeys: HotkeyPreferences
    /// Drop's options, which the island also edits.
    var setDropMode: (TranscriptionMode) -> Void
    var language: () -> AppLanguage?
    var setLanguage: (AppLanguage?) -> Void
    var volumeDuck: VolumeDuckConfig
    var autoStop: DropAutoStopPreferences
    /// Shows an island panel (the Vocab and Filler editors live there).
    var openHoverPanel: (HoverInlinePanel) -> Void
    /// The switches of the features that have one. The Agent's connects the
    /// native Agent and returns why it did not turn on.
    var setAgent: @MainActor (Bool) async -> String?
    var setMeetings: (Bool) -> Void
    var setGoogle: (Bool) -> Void
    /// "Allow file edits and commands".
    var agentSettings: AgentSettingsStore
    /// Hover, Notify and Monitor: the island's tool layout, the Notify
    /// sources and their sounds, Monitor's dashboard files (read locally), where agents put their files, and the clipboard a prompt is
    /// copied to. Tests pass temporary ones; nothing touches the user's own.
    // WHY: .project-docs/decisions/2026-11-24-hover-notify-monitor-screens.md
    var hoverStore: HoverLayoutStore
    var notifySupervisor: NotifyScriptSupervisor
    var meetingNotifications: MeetingReadyNotifications
    var notificationSounds: NotificationSoundSettings
    var monitor: MonitorStore
    var notifyRoot: URL
    var copyText: (String) -> Void
    /// Starts Shot's capture, as its island tool does.
    var openScreenshot: () -> Void

    init(dropMode: @escaping () -> TranscriptionMode = { .fast },
         setDropMode: @escaping (TranscriptionMode) -> Void = { _ in },
         language: @escaping () -> AppLanguage? = { nil },
         setLanguage: @escaping (AppLanguage?) -> Void = { _ in },
         volumeDuck: VolumeDuckConfig? = nil,
         autoStop: DropAutoStopPreferences? = nil,
         openHoverPanel: @escaping (HoverInlinePanel) -> Void = { _ in },
         agentOn: @escaping () -> Bool = { false },
         meetingsOn: @escaping () -> Bool = { false },
         googleOn: @escaping () -> Bool = { false },
         setAgent: @escaping @MainActor (Bool) async -> String? = { _ in nil },
         setMeetings: @escaping (Bool) -> Void = { _ in },
         setGoogle: @escaping (Bool) -> Void = { _ in },
         agentSettings: AgentSettingsStore? = nil,
         openScreenshot: @escaping () -> Void = {},
         supportsOnDevice: Bool = OnDeviceSpeechModelStore.isSupportedHost,
         onDevice: OnDeviceSpeechModelController? = nil,
         hotkeys: HotkeyPreferences? = nil,
         hoverStore: HoverLayoutStore? = nil,
         notifySupervisor: NotifyScriptSupervisor? = nil,
         meetingNotifications: MeetingReadyNotifications? = nil,
         notificationSounds: NotificationSoundSettings? = nil,
         monitor: MonitorStore? = nil,
         notifyRoot: URL = NotifyPaths.root,
         copyText: @escaping (String) -> Void = FeaturesEnvironment.copyToClipboard) {
        self.dropMode = dropMode
        self.agentOn = agentOn
        self.meetingsOn = meetingsOn
        self.googleOn = googleOn
        self.supportsOnDevice = supportsOnDevice
        self.onDevice = onDevice ?? .shared
        self.hotkeys = hotkeys ?? .shared
        self.setDropMode = setDropMode
        self.language = language
        self.setLanguage = setLanguage
        self.volumeDuck = volumeDuck ?? VolumeDuckConfig()
        self.autoStop = autoStop ?? .shared
        self.openHoverPanel = openHoverPanel
        self.setAgent = setAgent
        self.setMeetings = setMeetings
        self.setGoogle = setGoogle
        self.agentSettings = agentSettings ?? .shared
        self.hoverStore = hoverStore ?? .shared
        self.notifySupervisor = notifySupervisor ?? .shared
        self.meetingNotifications = meetingNotifications ?? .shared
        self.openScreenshot = openScreenshot
        self.notificationSounds = notificationSounds ?? .shared
        self.monitor = monitor ?? FeaturesEnvironment.sharedMonitor
        self.notifyRoot = notifyRoot
        self.copyText = copyText
    }

    /// One reader of Monitor's files for every Settings window. It is never
    /// started, so Settings does not connect to servers.
    static let sharedMonitor = MonitorStore()

    /// Fires when a count the Features snapshot reads changes: how many Notify
    /// sources and Monitor dashboards there are. Both stores republish the same
    /// list on every reread (Notify every 2 s, Monitor's screen every 5 s), and
    /// each snapshot reads every provider key from the Keychain on the main
    /// thread, so only a changed count rebuilds it.
    // WHY: .project-docs/decisions/2026-11-25-settings-features-refresh.md
    var snapshotCountChanges: AnyPublisher<Void, Never> {
        notifySupervisor.$sources.map(\.count).removeDuplicates()
            .combineLatest(monitor.$dashboards.map(\.count).removeDuplicates())
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

extension FeatureSetupSnapshot {
    /// The Mac as it is now, read from the same view models the older tabs
    /// show: a feature's status here and its row there cannot disagree.
    @MainActor
    static func live(models: APIAndModelsViewModel, permissions: PermissionsSettingsViewModel,
                     environment: FeaturesEnvironment) -> FeatureSetupSnapshot {
        var statuses: [AIFeature: ModelRowStatus] = [:]
        for row in models.rows { statuses[row.feature] = row.status }
        // "Choose a model" only where the list would not be empty.
        let selectable = Set(AIFeature.activeCases.filter { feature in
            statuses[feature, default: .notSet] != .notSet
                || models.sections(for: feature).contains { !$0.options.isEmpty || $0.acceptsModelName }
        })
        let alternatives = Set(AIFeature.activeCases.filter { hasAlternative(in: models.sections(for: $0)) })
        return FeatureSetupSnapshot(
            dropMode: environment.dropMode(),
            models: statuses,
            selectableModels: selectable,
            modelAlternatives: alternatives,
            subtitlesKeyPresent: models.audioTranslate.isActive,
            onDevice: environment.supportsOnDevice ? .available(environment.onDevice.status) : .unsupported,
            keyboardReady: permissions.keyboardReady,
            keyboardNeedsRestart: permissions.keyboardNeedsRestart,
            keyboardSetup: permissions.settingsOnly ? permissions.keyboardSetup : nil,
            microphoneGranted: permissions.snapshot.microphoneGranted,
            screenRecordingGranted: permissions.screenRecordingGranted,
            screenNeedsRestart: permissions.screenNeedsRestart,
            dropShortcut: permissions.dropHotkeyStatus,
            agentOn: environment.agentOn(),
            meetingsOn: environment.meetingsOn(),
            googleOn: environment.googleOn(),
            notifySources: environment.notifySupervisor.sources.count,
            monitorDashboards: environment.monitor.dashboards.count
                + (environment.monitor.serverStatusListed && environment.monitor.serverError == nil ? 1 : 0)
        )
    }

    /// Whether the picker holds a model that would work instead of the
    /// current one: another listed model the feature can use, or a typed
    /// name, under a key the provider has not refused.
    // WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
    static func hasAlternative(in sections: [PickerSection]) -> Bool {
        sections.contains { section in
            guard section.keyProblem == nil else { return false }
            if section.acceptsModelName { return true }
            return section.options.contains { option in
                guard !option.isSelected else { return false }
                if case .notSupported = option.state { return false }
                return true
            }
        }
    }
}

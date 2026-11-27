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
    /// Smart's output language (the island's Output Lang); nil keeps the
    /// language spoken.
    var targetLanguage: () -> AppLanguage?
    var setTargetLanguage: (AppLanguage?) -> Void
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
    /// Calendar's sources, shown and changed on its screen.
    // WHY: .project-docs/decisions/2026-11-26-every-feature-in-features.md
    var calendarConnections: CalendarConnections

    init(dropMode: @escaping () -> TranscriptionMode = { .fast },
         setDropMode: @escaping (TranscriptionMode) -> Void = { _ in },
         language: @escaping () -> AppLanguage? = { nil },
         setLanguage: @escaping (AppLanguage?) -> Void = { _ in },
         targetLanguage: @escaping () -> AppLanguage? = { nil },
         setTargetLanguage: @escaping (AppLanguage?) -> Void = { _ in },
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
         calendarConnections: CalendarConnections? = nil,
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
        self.targetLanguage = targetLanguage
        self.setTargetLanguage = setTargetLanguage
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
        self.calendarConnections = calendarConnections ?? .shared
        self.notificationSounds = notificationSounds ?? .shared
        self.monitor = monitor ?? FeaturesEnvironment.sharedMonitor
        self.notifyRoot = notifyRoot
        self.copyText = copyText
    }

    /// One reader of Monitor's files for every Settings window. It is never
    /// started, so Settings does not connect to servers.
    static let sharedMonitor = MonitorStore()

    /// Fires when the number of Notify sources or available Monitor dashboards
    /// changes, or Calendar starts or stops showing a calendar. Each snapshot
    /// reads provider keys on the main thread, so a reread with the same
    /// values leaves it alone.
    // WHY: .project-docs/decisions/2026-11-25-settings-features-refresh.md
    var snapshotCountChanges: AnyPublisher<Void, Never> {
        let calendar = calendarConnections
        // Published values arrive before the change is stored: read the
        // connections on the next turn of the run loop.
        let calendarShown = calendar.objectWillChange
            .receive(on: RunLoop.main)
            .map { [calendar] _ in Self.calendarConnected(macAccess: calendar.macAccess,
                                                          hasAccounts: !calendar.accounts.isEmpty) }
            .prepend(Self.calendarConnected(macAccess: calendar.macAccess, hasAccounts: !calendar.accounts.isEmpty))
            .removeDuplicates()
        return notifySupervisor.$sources.map(\.count).removeDuplicates()
            .combineLatest(monitor.$availableDashboardCount, calendarShown)
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
    }

    /// Calendar shows a calendar: macOS lets Whytap read this Mac's
    /// calendars and the list has one (the Calendars card says the same), or
    /// an account an earlier build connected directly is still there. Saved
    /// access that was not checked yet, taken back or with no calendars is not.
    nonisolated static func calendarConnected(macAccess: MacCalendarAccess, hasAccounts: Bool) -> Bool {
        macAccess == .ready || hasAccounts
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
        // Every feature's sections once, in one Keychain pass: this runs on
        // each redraw of Settings -> Features, also while the island switches
        // Drop Mode. WHY: .project-docs/decisions/2026-11-28-drop-mode-switch-motion.md
        let sections = models.withKeyLookupPass {
            Dictionary(uniqueKeysWithValues: AIFeature.activeCases.map { ($0, models.sections(for: $0)) })
        }
        // "Choose a model" only where the list would not be empty.
        let selectable = Set(AIFeature.activeCases.filter { feature in
            statuses[feature, default: .notSet] != .notSet
                || sections[feature, default: []].contains { !$0.options.isEmpty || $0.acceptsModelName }
        })
        let alternatives = Set(AIFeature.activeCases.filter { hasAlternative(in: sections[$0, default: []]) })
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
            systemAudioHeard: SystemAudioAccess.heard(),
            dropShortcut: permissions.dropHotkeyStatus,
            agentOn: environment.agentOn(),
            meetingsOn: environment.meetingsOn(),
            googleOn: environment.googleOn(),
            notifySources: environment.notifySupervisor.sources.count,
            monitorDashboards: environment.monitor.availableDashboardCount,
            calendarConnected: FeaturesEnvironment.calendarConnected(
                macAccess: environment.calendarConnections.macAccess,
                hasAccounts: !environment.calendarConnections.accounts.isEmpty)
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

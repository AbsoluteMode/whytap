import SwiftUI

/// Settings -> Features: what Whytap can do, one row per feature with its
/// status in words. A row opens the feature's own screen, or, until it has
/// one, the place its settings are shown today.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
@MainActor
struct SettingsFeaturesView: View {
    @ObservedObject var selection: SettingsWindowSelection
    @ObservedObject var models: APIAndModelsViewModel
    @ObservedObject var permissions: PermissionsSettingsViewModel
    @ObservedObject private var onDevice: OnDeviceSpeechModelController
    @ObservedObject private var hotkeys: HotkeyPreferences
    private let environment: FeaturesEnvironment
    /// Bumped when a switch or Drop's mode changes outside this view.
    @State private var externalChange = 0

    init(selection: SettingsWindowSelection, models: APIAndModelsViewModel,
         permissions: PermissionsSettingsViewModel, environment: FeaturesEnvironment) {
        self.selection = selection
        self.models = models
        self.permissions = permissions
        self.environment = environment
        self.onDevice = environment.onDevice
        self.hotkeys = environment.hotkeys
    }

    static let contentWidth: CGFloat = 760

    private var snapshot: FeatureSetupSnapshot {
        _ = externalChange
        return .live(models: models, permissions: permissions, environment: environment)
    }

    var body: some View {
        let snapshot = snapshot
        Group {
            if selection.shownFeature == .drop {
                DropFeatureView(snapshot: snapshot, selection: selection, models: models,
                                permissions: permissions, environment: environment)
            } else if let feature = selection.shownFeature, FeatureCatalog.info(for: feature).place == .screen {
                FeatureScreens(feature: feature,
                               context: FeatureScreenContext(snapshot: snapshot, selection: selection, models: models,
                                                             permissions: permissions, environment: environment))
            } else {
                // Features without their own screen yet open their present
                // place (`SettingsWindowSelection.open`); the list stays here.
                FeatureListView(snapshot: snapshot) { selection.open($0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Monitor's files are read, not polled: Settings never connects to servers.
            environment.monitor.reloadFiles()
            await models.onAppear()
            if environment.supportsOnDevice { await onDevice.refresh() }
        }
        .onAppear {
            permissions.refresh(restartRecoveryPolling: false)
            // Calendar's status: macOS access and the calendar list now (no
            // prompt, no events), as the Calendars card checks them.
            // WHY: .project-docs/decisions/2026-11-26-every-feature-in-features.md
            environment.calendarConnections.prepareMacCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(restartRecoveryPolling: false)
            environment.calendarConnections.prepareMacCalendars()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyCapabilityFlagsChanged)) { _ in
            externalChange += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyDropModeChanged)) { _ in
            externalChange += 1
        }
        // The first sound a capture hears turns System audio into Allowed.
        .onReceive(NotificationCenter.default.publisher(for: SystemAudioAccess.didChange)) { _ in
            externalChange += 1
        }
        // WHY: .project-docs/decisions/2026-11-25-settings-features-refresh.md
        .onReceive(environment.snapshotCountChanges) { _ in externalChange += 1 }
        .onReceive(AgentProviderStore.shared.objectWillChange) { _ in
            // The Agent counts as on only while its native provider is connected.
            DispatchQueue.main.async { externalChange += 1 }
        }
    }
}

/// The screen of each feature that has one, other than Drop: the template
/// with the feature's own settings. A new screen is one case here and its
/// `place: .screen` in the catalog.
// WHY: .project-docs/decisions/2026-11-24-settings-around-features.md
@MainActor
struct FeatureScreens: View {
    let feature: AppFeature
    let context: FeatureScreenContext

    var body: some View {
        switch feature {
        case .agent:
            SwitchFeatureScreen(feature: .agent, context: context) {
                AgentFeatureSettings(settings: context.environment.agentSettings)
            }
        case .meetings:
            SwitchFeatureScreen(feature: .meetings, context: context) {
                MeetingsFeatureSettings(notifications: context.environment.meetingNotifications,
                                        openNotes: { context.selection.select(.notes) })
            }
        case .googleSearch:
            SwitchFeatureScreen(feature: .googleSearch, context: context) { EmptyView() }
        case .hover:
            HoverFeatureView(selection: context.selection, environment: context.environment)
        case .notify:
            NotifyFeatureView(selection: context.selection, environment: context.environment)
        case .monitor:
            MonitorFeatureView(selection: context.selection, environment: context.environment)
        case .translateSubtitles:
            FeatureScreenView(feature: feature, context: context) {
                IslandToolActions(rows: [
                    .init(title: "Translate", subtitle: "Type or paste text and translate it, right in Settings.",
                          button: "Try Translate") { context.selection.focus(.translate) },
                    .init(title: "Subtitles", subtitle: "Start live subtitles for what your Mac is playing.",
                          button: "Try Subtitles") { context.selection.focus(.subtitles) },
                ])
            }
        case .screenshots:
            FeatureScreenView(feature: feature, context: context) {
                IslandToolActions(rows: [
                    .init(title: "Capture an area now", subtitle: "The screen freezes; drag over the area you want.",
                          button: "Capture") { context.environment.openScreenshot() },
                ])
            }
        // WHY: .project-docs/decisions/2026-11-26-every-feature-in-features.md
        case .history:
            FeatureScreenView(feature: feature, context: context) {
                IslandToolActions(rows: [
                    .init(title: "Your history", subtitle: "Copies, dictations and the Agent’s answers. Opens in the island.",
                          button: "Open History") { context.environment.openHoverPanel(.history) },
                ])
            }
        case .display:
            FeatureScreenView(feature: feature, context: context) {
                IslandToolActions(rows: [
                    .init(title: "Brightness slider", subtitle: "Opens Display in the island.",
                          button: "Open Display") { context.environment.openHoverPanel(.brightness) },
                ])
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "Settings")
                    DisplayBrightnessSettings()
                }
            }
        case .calendar:
            FeatureScreenView(feature: feature, context: context) {
                IslandToolActions(rows: [
                    .init(title: "Today", subtitle: CalendarAvailability.isOpen
                              ? "Today’s events. Opens in the island." : CalendarAvailability.message,
                          button: "Open Calendar", isEnabled: CalendarAvailability.isOpen) {
                        context.environment.openHoverPanel(.calendar)
                    },
                ])
                SettingsCalendarIntegrationsView(connections: context.environment.calendarConnections)
            }
        case .todo:
            FeatureScreenView(feature: feature, context: context) {
                IslandToolActions(rows: [
                    .init(title: "Your tasks", subtitle: "Opens To-do in the island.",
                          button: "Open To-do") { context.environment.openHoverPanel(.tasks) },
                ])
            }
        case .caseVault:
            FeatureScreenView(feature: feature, context: context) {
                IslandToolActions(rows: [
                    .init(title: "Your keys", subtitle: "Add keys, group them by project and choose whether each command asks you first. Opens in the island.",
                          button: "Open Case") { context.environment.openHoverPanel(.caseVault) },
                ])
            }
        case .drop:
            // Drawn by DropFeatureView; never reached.
            EmptyView()
        }
    }
}

/// An island tool's screen: the buttons that open or start it.
struct IslandToolActions: View {
    struct Row: Identifiable {
        let title: String
        let subtitle: String
        let button: String
        var isEnabled = true
        let action: () -> Void
        var id: String { title }
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacGroupTitle(title: "Use it")
            MacCard {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { MacRowSeparator() }
                    MacRow(title: row.title, subtitle: row.subtitle) {
                        MacButton(title: row.button, isEnabled: row.isEnabled, action: row.action)
                            .fixedSize()
                            .accessibilityLabel(row.button)
                    }
                }
            }
        }
    }
}

/// The list itself, drawn from a snapshot: no stores, so the same view is
/// what tests and previews render.
struct FeatureListView: View {
    let snapshot: FeatureSetupSnapshot
    let open: (AppFeature) -> Void

    var body: some View {
        let rows = FeatureCatalog.all.map { ($0, FeatureCatalog.status(for: $0.feature, snapshot: snapshot)) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Features")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 0) {
                    MacGroupTitle(title: "What Whytap can do",
                                  trailing: FeatureCatalog.summary(rows.map(\.1)))
                    MacCard {
                        ForEach(Array(rows.enumerated()), id: \.element.0.feature) { index, row in
                            if index > 0 { MacRowSeparator() }
                            FeatureListRow(info: row.0, status: row.1) { open(row.0.feature) }
                        }
                    }
                }
            }
            .frame(maxWidth: SettingsFeaturesView.contentWidth, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// One feature: name, one phrase, status, and a chevron saying it opens.
struct FeatureListRow: View {
    let info: FeatureInfo
    let status: FeatureStatus
    let action: () -> Void
    @FocusState private var focused: Bool

    /// A feature the person does not use reads quieter than one in use.
    private var isQuiet: Bool {
        switch status {
        case .off, .notSetUp: return true
        case .ready, .needsSetup: return false
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                FeatureIcon(feature: info.feature, size: .row)
                    .opacity(isQuiet ? 0.78 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text)
                    Text(info.line)
                        .font(.system(size: 11.5))
                        .foregroundStyle(MacSettingsTheme.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .opacity(isQuiet ? 0.78 : 1)
                Spacer(minLength: 12)
                FeatureStatusLabel(status: status)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MacSettingsTheme.text3)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(MacButtonInteractionStyle(focused: focused))
        .focused($focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(info.name)
        .accessibilityValue(Self.accessibilityValue(info: info, status: status))
        .accessibilityHint("Opens \(info.name)")
    }

    static func accessibilityValue(info: FeatureInfo, status: FeatureStatus) -> String {
        [status.word, status.reason, info.line].compactMap { $0 }.joined(separator: ". ")
    }
}

/// A feature's status as a sign and a word, with the reason under it.
/// Colour carries nothing here: Needs setup is heavier text, the unused
/// states are grey.
// WHY: docs/DESIGN.md — Feature status in words.
struct FeatureStatusLabel: View {
    let status: FeatureStatus

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            HStack(spacing: 5) {
                sign
                Text(status.word)
                    .font(.system(size: 12.5, weight: isNeed ? .semibold : .regular))
                    .foregroundStyle(isUnused ? MacSettingsTheme.text3 : MacSettingsTheme.text)
            }
            // An unused tool stays quiet in the list: its reason is on its
            // own screen and in the accessibility value.
            if let reason = status.reason, !isUnused {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var isNeed: Bool {
        if case .needsSetup = status { return true }
        return false
    }

    private var isUnused: Bool {
        switch status {
        case .off, .notSetUp: return true
        case .ready, .needsSetup: return false
        }
    }

    @ViewBuilder private var sign: some View {
        switch status {
        case .ready:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MacSettingsTheme.text)
        case .needsSetup:
            Circle()
                .strokeBorder(MacSettingsTheme.text, lineWidth: 1.4)
                .frame(width: 9, height: 9)
        case .off, .notSetUp:
            Rectangle()
                .fill(MacSettingsTheme.text3)
                .frame(width: 7, height: 1.4)
        }
    }
}

/// A feature's icon: one monochrome symbol, the same weight everywhere, no
/// coloured plate. The list rows and the feature's own header use it.
// WHY: .project-docs/decisions/2026-11-25-feature-icons.md
struct FeatureIcon: View {
    enum Size { case row, header }

    let feature: AppFeature
    let size: Size

    var body: some View {
        Image(systemName: feature.symbol)
            .font(.system(size: size == .row ? 15 : 19, weight: .regular))
            .foregroundStyle(MacSettingsTheme.text2)
            .frame(width: size == .row ? 22 : 26, height: size == .row ? 22 : 26)
            .accessibilityHidden(true)
    }
}

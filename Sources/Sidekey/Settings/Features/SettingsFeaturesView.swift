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
            FeatureListView(snapshot: snapshot) { selection.open($0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            await models.onAppear()
            if environment.supportsOnDevice { await onDevice.refresh() }
        }
        .onAppear { permissions.refresh(restartRecoveryPolling: false) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(restartRecoveryPolling: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyCapabilityFlagsChanged)) { _ in
            externalChange += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .sidekeyDropModeChanged)) { _ in
            externalChange += 1
        }
        .onReceive(AgentProviderStore.shared.objectWillChange) { _ in
            // The Agent counts as on only while its native provider is connected.
            DispatchQueue.main.async { externalChange += 1 }
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

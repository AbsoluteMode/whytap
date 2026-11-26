import AppKit
import SwiftUI

@MainActor
struct SettingsBackupView: View {
    @ObservedObject var model: BackupViewModel
    @ObservedObject var settingsSync: SettingsSyncService
    var openIntegrations: () -> Void
    @State private var showRestore: Bool
    @State private var restoreCode = ""
    @FocusState private var isRestoreCodeFocused: Bool
    @FocusState private var isGitHubFocused: Bool

    init(model: BackupViewModel = .shared, settingsSync: SettingsSyncService = .shared, showRestore: Bool = false,
         openIntegrations: @escaping () -> Void = {}) {
        self.model = model
        self.settingsSync = settingsSync
        self.openIntegrations = openIntegrations
        _showRestore = State(initialValue: showRestore)
    }

    private var actionsEnabled: Bool {
        model.canUseGitHubBackup && !model.isBusy && !model.needsRestart && !model.hasPendingMaintenance
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Backup").font(.system(size: 20, weight: .semibold))
                    Spacer()
                    if model.isBusy {
                        ProgressView().controlSize(.small)
                        if model.canCancelOperation {
                            MacButton(title: "Cancel", style: .default) { model.cancelCurrentOperation() }
                        }
                    }
                }
                Text("Restore your keys, passwords and settings. Backups are encrypted on your Mac and saved in your private GitHub repository, so GitHub cannot read your secrets. Your first backup turns on hourly automatic sync. Keep your recovery code to restore.")
                    .font(.system(size: 13))
                    .foregroundStyle(MacSettingsTheme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                MacCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 8) {
                            Label(model.syncState.title, systemImage: model.syncState.systemImage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(model.syncState == .synced ? MacSettingsTheme.green : MacSettingsTheme.text)
                            Spacer()
                            if let url = model.githubBackupURL {
                                Link(destination: url) {
                                    Text("GitHub ↗").underline()
                                        .padding(.horizontal, 6).padding(.vertical, 5)
                                }
                                    .buttonStyle(MacButtonInteractionStyle(focused: isGitHubFocused))
                                    .focused($isGitHubFocused)
                                    .font(.system(size: 12))
                                    .foregroundStyle(MacSettingsTheme.text)
                                    .help("Open your private backup repository on GitHub")
                                    .accessibilityLabel("Open backup on GitHub")
                            }
                            if !model.canUseGitHubBackup {
                                MacButton(title: "Connect GitHub", style: .tinted, isEnabled: !model.isBusy) {
                                    openIntegrations()
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            MacButton(title: "Back up", style: .primary, isEnabled: actionsEnabled) {
                                showRestore = false; restoreCode = ""
                                Task { await model.backupEverything() }
                            }
                            MacButton(title: "Restore backup", style: .default, isEnabled: actionsEnabled) {
                                model.hideRecoveryCode(); model.clearError(); showRestore = true
                            }
                            if model.lastBackupAt != nil {
                                MacButton(title: model.hasPresentedRecoveryCode ? "Show recovery code" : "Save recovery code",
                                          style: .ghost, isEnabled: !model.isBusy && !model.isRevealingRecoveryCode) {
                                    Task { await model.showRecoveryCode() }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                // Back up, restore and the recovery code: a row Lil Bro leads to (REV 15).
                .lilBroCatalogRow("Back up and restore")
                if model.showsAutomaticBackup {
                    MacCard {
                        MacRow(title: "Automatic backup", subtitle: automaticBackupSubtitle) {
                            MacSwitch(isOn: Binding(get: { model.isEnabled }, set: { model.setAutomaticBackup($0) }),
                                      isEnabled: model.canChangeAutomaticBackup, label: "Automatic backup")
                        }
                    }
                }
                // Also on a Mac that only restored, and always while on, so it can be turned off.
                // WHY: .project-docs/decisions/2026-11-20-settings-sync.md
                if model.showsSettingsSync || settingsSync.isEnabled {
                    MacCard {
                        MacRow(title: "Sync settings between Macs", subtitle: settingsSyncSubtitle) {
                            MacSwitch(isOn: Binding(get: { settingsSync.isEnabled }, set: { settingsSync.setEnabled($0) }),
                                      isEnabled: !model.needsRestart, label: "Sync settings between Macs")
                        }
                    }
                }
                if showRestore && !model.needsRestart {
                    MacCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SecureField("Recovery code", text: $restoreCode)
                                .lilBroControl("Recovery code")
                                .textFieldStyle(.roundedBorder)
                                .focused($isRestoreCodeFocused)
                                .onSubmit { restore() }
                                .accessibilityLabel("Recovery code")
                            MacButton(title: "Restore", style: .primary,
                                      isEnabled: actionsEnabled && !restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                                restore()
                            }
                        }.padding(14)
                    }
                }
                if !model.recoveryCode.isEmpty {
                    MacCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Recovery code").font(.system(size: 13, weight: .semibold))
                            Text(model.recoveryCode).font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text("Keep this code to restore your backup.")
                                    .font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                                Spacer()
                                MacButton(title: "Copy code", style: .default) { model.copyRecoveryCode() }
                            }
                        }.padding(14)
                    }
                }
                if model.isBusy {
                    Text(model.statusText).font(.system(size: 12)).foregroundStyle(MacSettingsTheme.text2)
                }
                if let error = model.errorMessage {
                    MacBanner(tone: .warn, systemImage: "exclamationmark.triangle", title: "Couldn't finish", text: error)
                }
                if model.needsRestart {
                    MacBanner(tone: .info, systemImage: "arrow.clockwise", title: "Restore is ready",
                              text: "Quit Whytap and open it again to finish.")
                    MacButton(title: "Cancel restore", style: .default, isEnabled: !model.isBusy) {
                        model.cancelPlannedRestore()
                    }
                }
                if model.hasPendingMaintenance {
                    HStack {
                        MacButton(title: "Finish backup management", style: .default, isEnabled: !model.isBusy) {
                            Task { await model.resumeBackupManagement() }
                        }
                        MacButton(title: "Stop and keep copies", style: .ghost, isEnabled: !model.isBusy) {
                            Task { await model.stopBackupManagement() }
                        }
                    }
                }
                if let warning = model.managementWarning {
                    MacBanner(tone: .warn, systemImage: "exclamationmark.triangle", title: "Previous backups", text: warning)
                    MacButton(title: "Show kept copies", style: .default) { model.showRetainedBackups() }
                }
                if let notice = model.restoreNotice {
                    MacBanner(tone: notice.state == .applied ? .info : .warn,
                              systemImage: "arrow.counterclockwise", title: notice.message,
                              text: notice.warnings.joined(separator: " "))
                    MacButton(title: "Dismiss", style: .ghost) { model.dismissRestoreNotice() }
                }
                if model.recoveryCheckpoint != nil {
                    MacButton(title: "Show previous data", style: .default) { model.showRecoveryFiles() }
                }
                ForEach(model.parkedItems) { item in
                    MacCard {
                        MacRow(title: item.title, subtitle: "Restored · paused") {
                            MacButton(title: "Show files", style: .default) { model.showParkedFiles(item) }
                            MacButton(title: "Enable", style: .tinted, isEnabled: !model.isBusy && !model.needsRestart) {
                                model.activateRecoveredItem(item)
                            }
                        }
                    }
                }
                .lilBroItems()
            }
            .foregroundStyle(MacSettingsTheme.text)
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .focusable(false)
        .task { await model.checkGitHubConnection() }
        .onChange(of: showRestore) { _, shown in isRestoreCodeFocused = shown }
        .onDisappear { clearCode() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if let window = notification.object as? NSWindow, window.title.contains("Settings") { clearCode() }
        }
    }

    // WHY: .project-docs/decisions/2026-10-21-backup-capture-pacing.md
    private var automaticBackupSubtitle: String {
        guard model.isEnabled else { return "Paused. Back up still saves one copy and keeps this off." }
        guard let next = model.nextAutomaticCapture else { return "At most hourly, only when something changed." }
        return "At most hourly, only when something changed. Next check after \(next.formatted(date: .omitted, time: .shortened))."
    }

    private var settingsSyncSubtitle: String {
        switch settingsSync.status {
        case .off:
            return "Models, provider keys, hotkeys, Toolbox and vocabulary stay the same on Macs with this recovery code. Turn it on first on the Mac whose settings you want everywhere. Wait for “Settings synced” before enabling sync on another Mac: that Mac takes them."
        case .synced(let date):
            return "Settings synced · \(date.formatted(date: .omitted, time: .shortened))"
        default:
            return settingsSync.status.text
        }
    }

    private func restore() {
        guard actionsEnabled, !restoreCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let code = restoreCode; restoreCode = ""
        Task { await model.restoreEverything(code: code) }
    }

    private func clearCode() { restoreCode = ""; model.hideRecoveryCode() }
}

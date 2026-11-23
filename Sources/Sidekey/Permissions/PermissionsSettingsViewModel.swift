import Foundation
import Combine
import SwiftUI

/// Live permission state shared by Settings and runtime permission repair.
@MainActor
final class PermissionsSettingsViewModel: ObservableObject {
    @Published private(set) var snapshot: PermissionsHelper.Snapshot
    @Published private(set) var screenRecordingGranted: Bool
    @Published private(set) var isRequestingScreenRecording = false
    /// Set by the first Allow of this launch. The next press of the same
    /// button opens System Settings instead of asking macOS again.
    // WHY: .project-docs/decisions/2026-11-19-permission-request-before-settings.md
    @Published private(set) var accessibilityRequested = false
    @Published private(set) var screenRecordingRequested = false
    @Published private(set) var dropHotkeyStatus = AppState.shared.dropHotkeyStatus
    /// What this process started with: on 27.3 a later grant needs a restart.
    let launchGrants: PermissionsHelper.LaunchGrants

    private var onComplete: () -> Void
    private var didComplete = false
    private let snapshotProvider: () -> PermissionsHelper.Snapshot
    private let screenRecordingAccessProvider: () -> Bool
    private let screenRecordingRequester: () async -> Void
    private let accessibilityRequester: () -> Void
    private let openAccessibilitySettings: () -> Void
    private let usesProtectionOverridePane: () -> Bool
    private let openScreenRecordingSettings: () -> Void
    private let openInputMonitoringPane: () -> Void
    private let runtimeRefresh: (_ retry: Bool, _ resumePolling: Bool) -> Void
    private var statusSubscription: AnyCancellable?
    private let relaunchApp: @MainActor () -> Void
    /// When `false`, `completeIfReady` is a no-op even when every
    /// required permission is granted. Used by the Settings path so
    /// the view stays on screen showing the All Set state instead of
    /// auto-closing the window.
    let autoComplete: Bool

    init(
        onComplete: @escaping () -> Void,
        autoComplete: Bool = true,
        snapshotProvider: @escaping () -> PermissionsHelper.Snapshot = PermissionsHelper.snapshot,
        screenRecordingAccessProvider: @escaping () -> Bool = PermissionsHelper.screenRecordingGranted,
        screenRecordingRequester: @escaping () async -> Void = PermissionsHelper.requestScreenRecording,
        accessibilityRequester: @escaping () -> Void = { PermissionsHelper.promptAccessibility() },
        openAccessibilitySettings: @escaping () -> Void = PermissionsHelper.openAccessibilitySettings,
        usesProtectionOverridePane: @escaping () -> Bool = { PermissionsHelper.usesProtectionOverridePane },
        openScreenRecordingSettings: @escaping () -> Void = PermissionsHelper.openScreenRecordingSettings,
        launchGrants: PermissionsHelper.LaunchGrants? = nil,
        openInputMonitoringSettings: @escaping () -> Void = PermissionsHelper.openInputMonitoringSettings,
        relaunch: @escaping @MainActor () -> Void = { AppRelauncher.relaunch() },
        runtimeRefresh: @escaping (Bool, Bool) -> Void = { retry, resumePolling in
            NotificationCenter.default.post(name: .sidekeyRuntimePermissionsRefresh, object: nil,
                userInfo: ["retry": retry, "resumePolling": resumePolling])
        }
    ) {
        self.onComplete = onComplete
        self.autoComplete = autoComplete
        self.snapshotProvider = snapshotProvider
        self.screenRecordingAccessProvider = screenRecordingAccessProvider
        self.screenRecordingRequester = screenRecordingRequester
        self.accessibilityRequester = accessibilityRequester
        self.openAccessibilitySettings = openAccessibilitySettings
        self.usesProtectionOverridePane = usesProtectionOverridePane
        self.openScreenRecordingSettings = openScreenRecordingSettings
        self.runtimeRefresh = runtimeRefresh
        self.openInputMonitoringPane = openInputMonitoringSettings
        self.relaunchApp = relaunch
        let snapshot = snapshotProvider()
        let screen = screenRecordingAccessProvider()
        self.snapshot = snapshot
        self.screenRecordingGranted = screen
        self.launchGrants = launchGrants ?? PermissionsHelper.launchGrants
            ?? .init(snapshot: snapshot, screenRecording: screen)
        statusSubscription = AppState.shared.$dropHotkeyStatus.dropFirst().sink { [weak self] status in
            self?.dropHotkeyStatus = status
            self?.completeIfReady()
        }
    }

    func updateOnComplete(_ onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    /// 27.3 and later: keyboard control and Screen Recording are given in
    /// System Settings with +, never by a request.
    var settingsOnly: Bool { usesProtectionOverridePane() }

    /// Keyboard control as Drop needs it on this macOS.
    var keyboardReady: Bool { PermissionsHelper.keyboardReady(snapshot, settingsOnly: settingsOnly) }

    /// A keyboard grant made after launch: on 27.3 it works after a restart.
    var keyboardNeedsRestart: Bool {
        Self.needsRestart(keyboard: snapshot, launch: launchGrants, settingsOnly: settingsOnly)
    }

    /// A Screen Recording grant made after launch, on 27.3.
    var screenNeedsRestart: Bool {
        Self.needsRestart(screen: screenRecordingGranted, launch: launchGrants, settingsOnly: settingsOnly)
    }

    static func needsRestart(keyboard snapshot: PermissionsHelper.Snapshot,
                             launch: PermissionsHelper.LaunchGrants, settingsOnly: Bool) -> Bool {
        settingsOnly && PermissionsHelper.keyboardReady(snapshot, settingsOnly: true)
            && !PermissionsHelper.keyboardReady(launch.snapshot, settingsOnly: true)
    }

    static func needsRestart(screen: Bool, launch: PermissionsHelper.LaunchGrants, settingsOnly: Bool) -> Bool {
        settingsOnly && screen && !launch.screenRecording
    }

    /// Where keyboard control stands on 27.3, from this process's own grants.
    enum KeyboardSetup: Equatable {
        /// Nothing usable yet: add Whytap with + under Override.
        case addWhytap
        /// Started with Accessibility but no posting: "Choose Apps" was
        /// picked instead of Override System Protections (VoiceInk #1089).
        case chooseAppsOnly
        /// Override is on; Input Monitoring is still missing.
        case inputMonitoring
        /// Everything is on; a restart makes it work.
        case restart
        case ready
    }

    var keyboardSetup: KeyboardSetup {
        Self.keyboardSetup(now: snapshot, launch: launchGrants.snapshot)
    }

    static func keyboardSetup(now: PermissionsHelper.Snapshot, launch: PermissionsHelper.Snapshot) -> KeyboardSetup {
        let ready = PermissionsHelper.keyboardReady(now, settingsOnly: true)
        if ready { return PermissionsHelper.keyboardReady(launch, settingsOnly: true) ? .ready : .restart }
        if now.accessibilityGranted, now.postEventGranted { return .inputMonitoring }
        if launch.accessibilityGranted, !launch.postEventGranted, !now.postEventGranted { return .chooseAppsOnly }
        return .addWhytap
    }

    /// One line for Settings and Drop's repair window: what to do on 27.3.
    static let keyboardSettingsGuide = "In System & App Protection Override click +, choose Whytap, pick Override System Protections and confirm. Then add Whytap under Input Monitoring and restart Whytap."
    static let screenSettingsGuide = "Click + under Screen & System Audio Recording and choose Whytap, then restart Whytap."

    /// Quits and reopens Whytap so a 27.3 grant takes effect.
    func restartWhytap() { relaunchApp() }

    func openInputMonitoring() { openInputMonitoringPane() }

    var allRequiredGranted: Bool {
        snapshot.allRequiredGranted && dropHotkeyStatus == .ready
    }

    var microphoneLabel: String {
        switch snapshot.microphoneStatus {
        case .authorized:
            return "Allowed"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        case .notDetermined:
            return "Not requested"
        @unknown default:
            return "Unknown"
        }
    }

    func refresh(restartRecoveryPolling: Bool = true) {
        snapshot = snapshotProvider()
        screenRecordingGranted = screenRecordingAccessProvider()
        runtimeRefresh(false, restartRecoveryPolling)
        completeIfReady()
    }

    func requestScreenRecording() async {
        guard !isRequestingScreenRecording else { return }
        guard !screenRecordingAccessProvider() else { return refresh() }
        // 27.3: the request shows nothing; the pane with + is the way.
        // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
        guard !settingsOnly else {
            screenRecordingRequested = true
            openScreenRecordingSettings()
            return refresh()
        }
        guard !screenRecordingRequested else {
            openScreenRecordingSettings()
            return refresh()
        }
        isRequestingScreenRecording = true
        defer { isRequestingScreenRecording = false }
        screenRecordingRequested = true
        await screenRecordingRequester()
        refresh()
    }

    func retryDropShortcut() {
        snapshot = snapshotProvider()
        runtimeRefresh(true, true)
    }

    func openHotkeys() {
        NotificationCenter.default.post(name: .sidekeyOpenHotkeySettings, object: nil)
    }

    func requestInputMonitoring() {
        if !PermissionsHelper.inputMonitoringGranted(prompt: true) {
            PermissionsHelper.openInputMonitoringSettings()
        }
        refresh()
    }

    func requestAccessibility() {
        if PermissionsHelper.keyboardReady(snapshotProvider(), settingsOnly: settingsOnly) {
            // Nothing to ask.
        } else if settingsOnly {
            // 27.3: no dialog, no row. The request stays (a later build may ask
            // again) and the press opens System & App Protection Override,
            // where the step's guide says what to click.
            // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
            accessibilityRequested = true
            if !snapshotProvider().accessibilityGranted { accessibilityRequester() }
            openAccessibilitySettings()
        } else if accessibilityRequested {
            openAccessibilitySettings()
        } else {
            accessibilityRequested = true
            accessibilityRequester()
        }
        refresh()
    }

    /// Whether the keyboard button's next press opens System Settings.
    var keyboardOpensSettings: Bool { accessibilityRequested || settingsOnly }

    func requestMicrophone() {
        // Branch on the live status so a denied/restricted user is
        // routed to System Settings instead of silently no-op'ing:
        // `AVCaptureDevice.requestAccess` only surfaces the native
        // prompt while status is `.notDetermined`.
        let status = PermissionsHelper.microphoneStatus()
        switch status {
        case .notDetermined:
            Task { @MainActor in
                _ = await PermissionsHelper.requestMicrophone()
                refresh()
            }
        case .denied, .restricted:
            PermissionsHelper.openMicrophoneSettings()
            refresh()
        case .authorized:
            refresh()
        @unknown default:
            refresh()
        }
    }

    private func completeIfReady() {
        guard autoComplete else { return }
        guard allRequiredGranted, !didComplete else { return }
        didComplete = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            guard self.allRequiredGranted else {
                self.didComplete = false
                return
            }
            self.onComplete()
        }
    }
}

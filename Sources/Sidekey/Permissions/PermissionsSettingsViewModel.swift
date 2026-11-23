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

    private var onComplete: () -> Void
    private var didComplete = false
    private let snapshotProvider: () -> PermissionsHelper.Snapshot
    private let screenRecordingAccessProvider: () -> Bool
    private let screenRecordingRequester: () async -> Void
    private let accessibilityRequester: () -> Void
    private let openAccessibilitySettings: () -> Void
    private let accessibilityIsAddedByHand: () -> Bool
    private let openScreenRecordingSettings: () -> Void
    private let runtimeRefresh: (_ retry: Bool, _ resumePolling: Bool) -> Void
    private var statusSubscription: AnyCancellable?
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
        accessibilityIsAddedByHand: @escaping () -> Bool = { PermissionsHelper.accessibilityIsAddedByHand },
        openScreenRecordingSettings: @escaping () -> Void = PermissionsHelper.openScreenRecordingSettings,
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
        self.accessibilityIsAddedByHand = accessibilityIsAddedByHand
        self.openScreenRecordingSettings = openScreenRecordingSettings
        self.runtimeRefresh = runtimeRefresh
        self.snapshot = snapshotProvider()
        self.screenRecordingGranted = screenRecordingAccessProvider()
        statusSubscription = AppState.shared.$dropHotkeyStatus.dropFirst().sink { [weak self] status in
            self?.dropHotkeyStatus = status
            self?.completeIfReady()
        }
    }

    func updateOnComplete(_ onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

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
        // Stay menu-bar-only — no Dock icon flip. The first press only asks
        // macOS, whose dialog leads to System Settings itself.
        if snapshotProvider().accessibilityGranted {
            // Nothing to ask.
        } else if accessibilityRequested {
            openAccessibilitySettings()
        } else {
            accessibilityRequested = true
            accessibilityRequester()
            // macOS 27.3 shows no dialog and adds no row, so nothing can race
            // the pane: open it now, where the person adds Whytap with +.
            // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
            if accessibilityIsAddedByHand() { openAccessibilitySettings() }
        }
        refresh()
    }

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

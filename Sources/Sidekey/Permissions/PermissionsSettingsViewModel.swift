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
    /// Requests this macOS refused without a dialog (27.3 beta), shared by
    /// the onboarding, Settings and Drop's repair window.
    let refusals: PermissionRequestRefusals

    private var onComplete: () -> Void
    private var didComplete = false
    private let snapshotProvider: () -> PermissionsHelper.Snapshot
    private let screenRecordingAccessProvider: () -> Bool
    private let screenRecordingRequester: () async -> Void
    private let accessibilityRequester: () -> Void
    private let openAccessibilitySettings: () -> Void
    private let usesProtectionOverridePane: () -> Bool
    private let openScreenRecordingSettings: () -> Void
    private let runtimeRefresh: (_ retry: Bool, _ resumePolling: Bool) -> Void
    private var statusSubscription: AnyCancellable?
    private var refusalSubscription: AnyCancellable?
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
        refusals: PermissionRequestRefusals? = nil,
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
        // Without an override pane this macOS asks normally: nothing to watch.
        self.refusals = refusals ?? (usesProtectionOverridePane()
            ? .shared : PermissionRequestRefusals(applies: { false }, defaults: nil))
        self.snapshot = snapshotProvider()
        self.screenRecordingGranted = screenRecordingAccessProvider()
        refusalSubscription = self.refusals.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        statusSubscription = AppState.shared.$dropHotkeyStatus.dropFirst().sink { [weak self] status in
            self?.dropHotkeyStatus = status
            self?.completeIfReady()
        }
    }

    func updateOnComplete(_ onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    /// Keyboard control can't be given on this macOS for now: the request
    /// was refused without a dialog and access is still off.
    var keyboardUnavailable: Bool {
        refusals.refused.contains(.keyboard) && !snapshot.accessibilityGranted
    }

    /// Screen Recording can't be given on this macOS for now.
    var screenUnavailable: Bool {
        refusals.refused.contains(.screen) && !screenRecordingGranted
    }

    /// The honest line for a refused request, shown instead of a button.
    static let unavailableLine = "This macOS beta doesn’t let new apps get this access yet. Whytap asks again after a macOS update."

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
        if snapshot.accessibilityGranted { refusals.clear(.keyboard) }
        if screenRecordingGranted { refusals.clear(.screen) }
        runtimeRefresh(false, restartRecoveryPolling)
        completeIfReady()
    }

    func requestScreenRecording() async {
        guard !isRequestingScreenRecording else { return }
        guard !screenRecordingAccessProvider() else { return refresh() }
        // A refused request leads nowhere: no second request, no "+" list.
        guard !screenUnavailable else { return refresh() }
        guard !screenRecordingRequested else {
            openScreenRecordingSettings()
            return refresh()
        }
        isRequestingScreenRecording = true
        defer { isRequestingScreenRecording = false }
        screenRecordingRequested = true
        await screenRecordingRequester()
        refresh()
        await checkRefusal(.screen)
    }

    /// After a request: whether macOS showed its dialog. A request answered
    /// with neither a dialog nor access is recorded as refused.
    // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
    func checkRefusal(_ kind: PermissionRequestRefusals.Kind) async {
        let snapshotProvider = self.snapshotProvider
        let screen = self.screenRecordingAccessProvider
        await refusals.check(kind, granted: {
            kind == .keyboard ? snapshotProvider().accessibilityGranted : screen()
        })
        refresh(restartRecoveryPolling: false)
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
        if snapshotProvider().accessibilityGranted || keyboardUnavailable || refusals.checking.contains(.keyboard) {
            // Nothing to ask, refused without a dialog, or its answer is being watched.
        } else if usesProtectionOverridePane() {
            // 27.3 beta: macOS's own dialog or nothing. The pane would list
            // Whytap only after "+", so the button never opens it.
            // WHY: .project-docs/decisions/2026-11-23-keyboard-control-protection-override.md
            accessibilityRequested = true
            accessibilityRequester()
            Task { @MainActor [weak self] in await self?.checkRefusal(.keyboard) }
        } else if accessibilityRequested {
            openAccessibilitySettings()
        } else {
            accessibilityRequested = true
            accessibilityRequester()
        }
        refresh()
    }

    /// Whether the keyboard button's next press opens System Settings.
    var keyboardOpensSettings: Bool { accessibilityRequested && !usesProtectionOverridePane() }

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

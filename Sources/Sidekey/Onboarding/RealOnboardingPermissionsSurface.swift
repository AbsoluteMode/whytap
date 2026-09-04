import AVFoundation
import Foundation
import SwiftUI

/// Live permissions surface backed by `PermissionsHelper`. Polls the
/// snapshot once per second so external grants made in System Settings
/// reflect in the onboarding UI without the user manually refreshing. The
/// mic prompt is requested in-process via `AVCaptureDevice.requestAccess`;
/// Accessibility opens the relevant System Settings pane (macOS does not
/// surface an in-process prompt for that bucket).
///
/// Lives in the app target only. The preview executable uses
/// `MockPermissionsSurface` instead — it does not link `PermissionsHelper`.
@MainActor
final class RealOnboardingPermissionsSurface: ObservableObject, OnboardingPermissionsSurface {
    @Published private(set) var mic: OnboardingPermissionStatus = .pending
    @Published private(set) var accessibility: OnboardingPermissionStatus = .pending

    private var pollTimer: Timer?
    private let onExternalPermissionHandoff: () -> Void
    private let onExternalPermissionReturn: () -> Void

    init(
        onExternalPermissionHandoff: @escaping () -> Void = {},
        onExternalPermissionReturn: @escaping () -> Void = {}
    ) {
        self.onExternalPermissionHandoff = onExternalPermissionHandoff
        self.onExternalPermissionReturn = onExternalPermissionReturn
        refresh()
    }

    var allRequiredGranted: Bool {
        mic == .granted && accessibility == .granted
    }

    func start() {
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func requestMic() {
        OnboardingResumeStore.save(.permissions)
        // Branch on the live AVCaptureDevice status so the button behaves
        // correctly across all three TCC states:
        //   - .notDetermined -> request the native prompt (only path where
        //     macOS surfaces the in-process dialog)
        //   - .denied/.restricted -> open Privacy -> Microphone in System
        //     Settings (no native re-prompt exists for an already-denied
        //     status; without this the click would silently no-op)
        //   - .authorized -> already granted; no-op (the button should be
        //     hidden anyway, but stay defensive)
        let status = PermissionsHelper.microphoneStatus()
        switch status {
        case .notDetermined:
            mic = .requesting
            onExternalPermissionHandoff()
            Task { @MainActor in
                _ = await PermissionsHelper.requestMicrophone()
                refresh()
                onExternalPermissionReturn()
            }
        case .denied, .restricted:
            onExternalPermissionHandoff()
            PermissionsHelper.openMicrophoneSettings()
            refresh()
        case .authorized:
            refresh()
        @unknown default:
            refresh()
        }
    }

    func requestAccessibility() {
        OnboardingResumeStore.save(.permissions)
        if accessibility == .pending { accessibility = .requesting }
        onExternalPermissionHandoff()
        PermissionsHelper.requestAccessibility()
        refresh()
    }

    private func refresh() {
        let snapshot = PermissionsHelper.snapshot()
        mic = Self.status(forMic: snapshot.microphoneStatus)
        accessibility = snapshot.accessibilityGranted ? .granted : .pending
    }

    private static func status(forMic status: AVAuthorizationStatus) -> OnboardingPermissionStatus {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .pending
        @unknown default: return .pending
        }
    }
}

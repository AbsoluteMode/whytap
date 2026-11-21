import AVFoundation
import Carbon.HIToolbox
import Foundation

/// Installation failures are distinct from a permission grant. In particular,
/// a Carbon collision must never send the user to Privacy & Security.
enum HotkeyRegistrationError: Error, Equatable {
    case tapUnavailable
    case modifierMonitorUnavailable
    case carbonHandler(OSStatus)
    case carbonRegistration(OSStatus)
}

enum DropHotkeyStatus: Equatable {
    case ready
    case accessibilityRequired
    case microphoneRequired
    case inputMonitoringRequired
    case shortcutInUse
    case unavailable

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .accessibilityRequired: return "Allow keyboard control"
        case .microphoneRequired: return "Allow microphone"
        case .inputMonitoringRequired: return "Allow keyboard access"
        case .shortcutInUse: return "Shortcut is in use"
        case .unavailable: return "Shortcut unavailable"
        }
    }

    var message: String {
        switch self {
        case .ready: return "Your Drop shortcut is ready."
        case .accessibilityRequired:
            return "Allow Whytap under Privacy & Security → Accessibility (called Device Control and Data Access on newer macOS). If it is already on after an update, remove that entry and add this copy of Whytap again."
        case .microphoneRequired: return "Allow Whytap to record your voice, then press your shortcut again."
        case .inputMonitoringRequired:
            return "macOS could not enable your hold shortcut. Retry, or allow Whytap in System Settings → Privacy & Security → Input Monitoring."
        case .shortcutInUse:
            return "Another app or another copy of Whytap is using this shortcut. Close that copy and retry, or choose another shortcut in Hotkeys."
        case .unavailable: return "Retry to enable your Drop shortcut. You can also choose another shortcut in Hotkeys."
        }
    }
}

enum DropHotkeyRecovery {
    enum ReconcileDecision: Equatable { case none, install, rebuild, deferRebuild }

    static func reconcileDecision(
        installed: Bool,
        accessibilityChanged: Bool,
        forceRebuild: Bool,
        rebuildPending: Bool,
        captureActive: Bool
    ) -> ReconcileDecision {
        if accessibilityChanged || forceRebuild || rebuildPending {
            return captureActive ? .deferRebuild : .rebuild
        }
        return installed ? .none : .install
    }

    /// Carbon can keep a tap shortcut callable while AX is missing, so pressing
    /// it explains the missing permission instead of silently doing nothing.
    static func canRegister(shortcut: HotkeyShortcut, gesture: HotkeyGesture, accessibilityGranted: Bool) -> Bool {
        if case .combo = shortcut, gesture == .tap { return true }
        return accessibilityGranted
    }

    static func status(
        snapshot: PermissionsHelper.Snapshot,
        installed: Bool,
        failure: DropHotkeyStatus?
    ) -> DropHotkeyStatus {
        if let failure, failure == .shortcutInUse { return failure }
        if !snapshot.accessibilityGranted { return .accessibilityRequired }
        if let failure { return failure }
        if !snapshot.microphoneGranted { return .microphoneRequired }
        return installed ? .ready : .unavailable
    }

    static func failure(for error: Error, inputMonitoringGranted: Bool) -> DropHotkeyStatus {
        guard let error = error as? HotkeyRegistrationError else { return .unavailable }
        switch error {
        case .carbonRegistration(let status) where status == OSStatus(eventHotKeyExistsErr): return .shortcutInUse
        case .tapUnavailable where !inputMonitoringGranted: return .inputMonitoringRequired
        default: return .unavailable
        }
    }

    enum StartGate: Equatable {
        case proceed
        /// A permission is missing or refused: explain and repair.
        case explain
        /// The microphone was never asked: ask now and start nothing. The
        /// system dialog then never opens in the middle of a take.
        case askMicrophone
    }

    // WHY: .project-docs/decisions/2026-11-21-first-launch-onboarding.md
    static func startGate(_ snapshot: PermissionsHelper.Snapshot) -> StartGate {
        guard snapshot.accessibilityGranted else { return .explain }
        switch snapshot.microphoneStatus {
        case .authorized: return .proceed
        case .notDetermined: return .askMicrophone
        case .denied, .restricted: return .explain
        @unknown default: return .explain
        }
    }

    /// Only starting a NEW take needs permission. Stop/finalize/cancel must
    /// remain usable if permission changes during an existing recording.
    static func requiresStartPermission(_ route: DropFlowRoute) -> Bool {
        switch route {
        case .startStreamingSession, .startRecording, .discardFailedTakeAndStart: return true
        default: return false
        }
    }
}

/// A repair session polls quietly for at most two minutes. User interaction
/// (Refresh, Retry, reopening Whytap) may start another bounded session.
struct DropHotkeyRecoveryPollBudget {
    private(set) var remaining = 120
    mutating func consume() -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

extension Notification.Name {
    static let sidekeyRuntimePermissionsRefresh = Notification.Name("sidekey.permissions.refresh")
    static let sidekeyOpenHotkeySettings = Notification.Name("sidekey.hotkeys.open")
}

import Foundation

/// What one Screenshot press does about Screen Recording access.
///
/// The request itself is `ScreenRecordingAccess.requestOnce()`, shared with the
/// onboarding, so a launch asks macOS once whichever surface asks first. The
/// press that asks shows nothing of Whytap's own. A press within a second of
/// the request is a repeat of the same press (a held shortcut, a double
/// delivery) and does nothing, so the help never opens beside the system
/// dialog. Later presses without access show Whytap's help. A granted Mac
/// captures.
// WHY: .project-docs/decisions/2026-11-22-shot-single-permission-prompt.md
@MainActor
final class ScreenshotPermissionGate {
    enum Step: Equatable {
        case capture
        case requestOnly
        case showHelp
        case ignoreRepeat
    }

    /// Presses this soon after the request belong to the same press.
    static let repeatInterval: TimeInterval = 1

    private let access: ScreenRecordingAccess

    init(access: ScreenRecordingAccess = .shared) {
        self.access = access
    }

    /// A gate for injected captures that never asks the system.
    static var granted: ScreenshotPermissionGate {
        ScreenshotPermissionGate(access: ScreenRecordingAccess(isGranted: { true }, request: {}))
    }

    /// Decides this press; `requestOnly` means macOS is being asked now.
    func step() -> Step {
        switch access.requestOnce() {
        case .granted: return .capture
        case .requested: return .requestOnly
        case .alreadyRequested(let secondsAgo):
            return secondsAgo < Self.repeatInterval ? .ignoreRepeat : .showHelp
        }
    }
}

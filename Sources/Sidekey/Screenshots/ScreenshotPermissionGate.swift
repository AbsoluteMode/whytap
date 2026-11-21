import Foundation

/// What one Screenshot press does about Screen Recording access.
///
/// The first press of a launch without access only asks macOS, through the
/// same ScreenCaptureKit request as Settings -> Permissions, and shows nothing
/// of Whytap's own: the system dialog has its own button to System Settings.
/// Later presses without access show Whytap's help instead of asking again,
/// because macOS shows its dialog only once. A press within a second of the
/// request is a repeat of the same press (a held shortcut, a double delivery)
/// and does nothing, so the help never opens beside the system dialog.
/// A granted Mac captures.
/// The "already asked" state lives in memory only, like the Settings button.
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

    private let isGranted: () -> Bool
    private let request: () async -> Void
    private let now: () -> Date
    private var requestedAt: Date?
    var requested: Bool { requestedAt != nil }

    init(isGranted: @escaping () -> Bool = PermissionsHelper.screenRecordingGranted,
         request: @escaping () async -> Void = { await ScreenRecordingPermissionRequest.request() },
         now: @escaping () -> Date = Date.init) {
        self.isGranted = isGranted
        self.request = request
        self.now = now
    }

    /// A gate for injected captures that never asks the system.
    static var granted: ScreenshotPermissionGate {
        ScreenshotPermissionGate(isGranted: { true }, request: {})
    }

    /// Decides this press. `requestOnly` marks the launch as asked; the
    /// caller then runs `performRequest()` and shows nothing else.
    func step() -> Step {
        if isGranted() { return .capture }
        let time = now()
        guard let requestedAt else {
            self.requestedAt = time
            return .requestOnly
        }
        return time.timeIntervalSince(requestedAt) < Self.repeatInterval ? .ignoreRepeat : .showHelp
    }

    func performRequest() async {
        await request()
    }
}

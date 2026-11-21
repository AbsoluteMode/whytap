import Foundation

/// The one Screen Recording request of a launch, shared by every surface that
/// asks at first use (Screenshot, the onboarding's permissions page).
///
/// `requestOnce()` asks macOS through the same ScreenCaptureKit request as
/// Settings -> Permissions (`ScreenRecordingPermissionRequest`) and remembers
/// that it did, in memory only. macOS shows its dialog once, and the request
/// returns while that dialog is still on screen, so a caller must show nothing
/// of its own beside it: the dialog has its own button to System Settings.
/// After `.requested`, the caller's next step is its own help or Open Settings,
/// never a second request.
// WHY: .project-docs/decisions/2026-11-22-shot-single-permission-prompt.md
@MainActor
final class ScreenRecordingAccess {
    enum Outcome: Equatable {
        /// Access is granted; nothing was asked.
        case granted
        /// This call asked macOS. Show nothing else now.
        case requested
        /// This launch already asked; macOS will not show its dialog again.
        case alreadyRequested(secondsAgo: TimeInterval)
    }

    static let shared = ScreenRecordingAccess()

    private let isGrantedProvider: () -> Bool
    private let request: () async -> Void
    private let now: () -> Date
    private var requestedAt: Date?

    init(isGranted: @escaping () -> Bool = PermissionsHelper.screenRecordingGranted,
         request: @escaping () async -> Void = { await ScreenRecordingPermissionRequest.request() },
         now: @escaping () -> Date = Date.init) {
        self.isGrantedProvider = isGranted
        self.request = request
        self.now = now
    }

    /// Passive check; never asks.
    var isGranted: Bool { isGrantedProvider() }

    /// Whether this launch already asked macOS.
    var requested: Bool { requestedAt != nil }

    /// Asks macOS at most once per launch. The decision is synchronous, so a
    /// second call arriving before the request runs is already `.alreadyRequested`.
    @discardableResult
    func requestOnce() -> Outcome {
        if isGrantedProvider() { return .granted }
        let time = now()
        if let requestedAt {
            return .alreadyRequested(secondsAgo: time.timeIntervalSince(requestedAt))
        }
        requestedAt = time
        let request = self.request
        Task { await request() }
        return .requested
    }
}

import AppKit
import Sparkle
import os.log

/// Custom `SPUUserDriver` that drives the whole update experience through the
/// Dynamic Island (no Sparkle windows). Owns NO UI and NO AppState — it
/// translates Sparkle's callbacks into `DriverStage` emits and holds the
/// `reply` blocks until the user acts in the island. `UpdateController`
/// wires the emits into `AppState.updateAvailable`.
///
/// On scheduled discovery: `showUpdateFound` → `handleUpdateFound` stores the
/// reply and emits `.available`. On user click: `invokeDownload()` fires the
/// held reply with `.install` — Sparkle begins downloading immediately.
///
/// WHY: docs/decisions/2026-06-17-update-download-on-action.md
@MainActor
final class IslandUpdateUserDriver: NSObject, SPUUserDriver {
    /// Host-facing stage stream. Primitive payloads only (no Sparkle types)
    /// so the host + tests stay decoupled from `SUAppcastItem`.
    enum DriverStage: Equatable {
        case available
        case downloading(fractionCompleted: Double)
        case readyToInstall
        case installing
        case cleared
    }

    private let onStage: (DriverStage) -> Void
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "update-driver")

    private var updateFoundReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0

    init(onStage: @escaping (DriverStage) -> Void) {
        self.onStage = onStage
        super.init()
    }

    // MARK: - Internal entry points (testable; primitives only)

    func handleUpdateFound(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        updateFoundReply = reply
        expectedLength = 0
        receivedLength = 0
        onStage(.available)
    }

    /// Fires the held `updateFound` reply with `.install`, starting the download
    /// immediately. Called by `UpdateController` when the user clicks the pill.
    func invokeDownload() { updateFoundReply?(.install) }

    /// Invoked by the host when the user clicks ✕ ("Skip this version") in the
    /// island. Replies `.skip` to the held `showUpdateFound` reply — Sparkle
    /// records this build as skipped and stops re-prompting for it, while
    /// FUTURE versions still surface normally.
    func invokeSkip() { updateFoundReply?(.skip) }

    func handleDownloadExpectedLength(_ length: UInt64) {
        expectedLength = length
        receivedLength = 0
        onStage(.downloading(fractionCompleted: 0.0))
    }

    func handleDownloadReceived(length: UInt64) {
        receivedLength += length
        let fraction = expectedLength > 0
            ? min(1.0, Double(receivedLength) / Double(expectedLength))
            : 0.0
        onStage(.downloading(fractionCompleted: fraction))
    }

    // MARK: - SPUUserDriver (required)

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        handleUpdateFound(reply: reply)
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    func showUpdaterError(
        _ error: Error,
        acknowledgement: @escaping () -> Void
    ) {
        onStage(.cleared)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { onStage(.downloading(fractionCompleted: 0.0)) }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        handleDownloadExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        handleDownloadReceived(length: length)
    }

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func handleReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        readyReply = reply
        onStage(.readyToInstall)
    }

    /// Invoked by the host when the user clicks «Restart» in the island.
    func invokeInstall() { readyReply?(.install) }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        handleReadyToInstall(reply: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        onStage(.installing)
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        onStage(.cleared)
    }
}

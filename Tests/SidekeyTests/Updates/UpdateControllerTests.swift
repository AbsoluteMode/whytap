import XCTest
import Sparkle
@testable import Sidekey

/// Tests for the download-on-action update flow.
///
/// Sparkle is configured with `automaticallyDownloadsUpdates = false`, so a
/// scheduled discovery surfaces as `.available` (pill shows «Update») WITHOUT
/// starting a download. When the user clicks «Update», the controller fires the
/// held `updateFound` reply directly with `.install` via `driver.invokeDownload()`.
/// At download completion, idle user-requested updates install immediately;
/// busy work and resumed downloads require an explicit safe Restart click.
///
/// The full flow exercised here:
///
///   1. `handleDiscovered(version:build:)` (forwarded from
///      `SPUUpdaterDelegate.updater(_:didFindValidUpdate:)`)
///      → `PendingUpdate(stage: .available)` (pill shows «Update», no download).
///   2. User clicks → `startDownload()` → `driver.invokeDownload()` →
///      held reply fires `.install` → Sparkle begins downloading immediately.
///   3. `applyDriverStage(.readyToInstall)` installs while idle, or publishes
///      Ready with Restart / Later when activity must finish first.
///
/// `SPUUserUpdateState.init` is `NS_UNAVAILABLE`, so we exercise the host-side
/// entry points (`handleDiscovered(version:build:)` and `applyDriverStage(_:)`)
/// directly; the protocol methods are thin `nonisolated` forwarders.
@MainActor
final class UpdateControllerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppState.shared.updateAvailable = nil
        AppState.shared.updateController = nil
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .idle
        AppState.shared.translationActive = false
        AppState.shared.screenshotActive = false
        AppState.shared.plannerActive = false
        AppState.shared.todoActive = false
        AppState.shared.calendarHoverActive = false
        AppState.shared.calendarConnectionActive = false
        AppState.shared.clearMeetingRecordingState()
    }

    override func tearDown() {
        AppState.shared.updateAvailable = nil
        AppState.shared.updateController = nil
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .idle
        AppState.shared.translationActive = false
        AppState.shared.screenshotActive = false
        AppState.shared.plannerActive = false
        AppState.shared.todoActive = false
        AppState.shared.calendarHoverActive = false
        AppState.shared.calendarConnectionActive = false
        AppState.shared.clearMeetingRecordingState()
        super.tearDown()
    }

    // MARK: - Sparkle configuration

    func test_configuresScheduledChecks_setsAutomaticAndInterval() {
        let controller = UpdateController(appState: AppState.shared)
        XCTAssertTrue(
            controller.updater.automaticallyChecksForUpdates,
            "Background scheduled checks must be enabled."
        )
        XCTAssertEqual(
            controller.updater.updateCheckInterval,
            3600,
            "Interval must be 3600s (1 hour)."
        )
    }

    func test_configuresDownloadOnAction_setsAutomaticallyDownloadsUpdatesToFalse() {
        let controller = UpdateController(appState: AppState.shared)
        XCTAssertFalse(
            controller.updater.automaticallyDownloadsUpdates,
            "Download must NOT start automatically — it must wait for user action."
        )
    }

    // MARK: - Stage transitions: discovery → .available

    func test_discovery_publishes_available_stage_without_downloading() {
        AppState.shared.updateAvailable = nil
        let controller = UpdateController(appState: .shared)
        controller.handleDiscovered(version: "1.9.3", build: "1358")
        guard case .available = AppState.shared.updateAvailable?.stage else {
            return XCTFail("expected .available, got \(String(describing: AppState.shared.updateAvailable?.stage))")
        }
        XCTAssertEqual(AppState.shared.updateAvailable?.displayVersion, "1.9.3")
    }

    @MainActor
    func test_available_download_invokes_the_download_action() {
        AppState.shared.updateAvailable = nil
        var downloads = 0
        let controller = UpdateController(appState: .shared, downloadAction: {
            XCTAssertEqual(AppState.shared.updateAvailable?.stage, .downloading(fractionCompleted: 0),
                           "The click must show feedback before Sparkle starts delivering bytes")
            downloads += 1
        })
        controller.handleDiscovered(version: "1.9.1", build: "1356")
        let available = AppState.shared.updateAvailable
        available?.startDownload()
        available?.startDownload()
        XCTAssertEqual(downloads, 1, "clicking Update invokes the injected download action")
    }

    /// Proves the production download path: clicking the pill fires the held
    /// updateFound reply directly with .install (direct-install fix). The old
    /// broken path dismissed + waited for didFinishUpdateCycleFor, which Sparkle
    /// never called after reply(.dismiss), hanging the download silently.
    ///
    /// Uses the real default downloadAction (no override) and arms the controller's
    /// driver with a captured reply, then confirms the pill click fires .install.
    func test_available_download_firesDirectInstall_notDismissThenFreshCheck() {
        AppState.shared.updateAvailable = nil

        // Create the controller with no download-action override so the
        // production default path runs.
        let controller = UpdateController(appState: .shared)

        // Arm the driver's held updateFound reply — mirrors Sparkle calling
        // showUpdateFound(with:state:reply:) after a scheduled check.
        var capturedReply: SPUUserUpdateChoice?
        controller.driver.handleUpdateFound(reply: { capturedReply = $0 })

        controller.handleDiscovered(version: "1.9.5", build: "1405")

        // Simulate user clicking the pill (calls the default downloadAction).
        AppState.shared.updateAvailable?.startDownload()

        XCTAssertEqual(
            capturedReply,
            .install,
            "Download click must fire reply(.install) directly on the held updateFound reply, not reply(.dismiss)"
        )
        XCTAssertNotEqual(
            capturedReply,
            .dismiss,
            "reply(.dismiss) is the old broken path that hung the download"
        )
    }

    @MainActor
    func test_available_skip_invokes_the_skip_action() {
        AppState.shared.updateAvailable = nil
        var skips = 0
        let controller = UpdateController(appState: .shared, skipAction: { skips += 1 })
        controller.handleDiscovered(version: "1.9.1", build: "1356")
        AppState.shared.updateAvailable?.skip()
        XCTAssertEqual(skips, 1, "clicking ✕ skips this version (driver.invokeSkip)")
    }

    func test_didFindValidUpdate_setsAvailableStage() {
        let controller = UpdateController(appState: AppState.shared)

        controller.handleDiscovered(version: "9.9.9", build: "9901")

        XCTAssertEqual(AppState.shared.updateAvailable?.displayVersion, "9.9.9")
        XCTAssertEqual(AppState.shared.updateAvailable?.buildVersion, "9901")
        guard case .available = AppState.shared.updateAvailable?.stage else {
            return XCTFail("Stage must be .available after discovery; download has not started.")
        }
    }

    // MARK: - Stage transitions: driver stage → readyToInstall

    func test_applyDriverStage_downloading_transitionsStage() {
        let controller = UpdateController(appState: AppState.shared)
        controller.handleDiscovered(version: "9.9.9", build: "9901")

        controller.applyDriverStage(.downloading(fractionCompleted: 0.5))

        XCTAssertEqual(
            AppState.shared.updateAvailable?.stage,
            .downloading(fractionCompleted: 0.5)
        )
        XCTAssertEqual(AppState.shared.updateAvailable?.displayVersion, "9.9.9")
        XCTAssertEqual(AppState.shared.updateAvailable?.buildVersion, "9901")
    }

    func test_readyToInstall_autoInstallsOnlyAfterUserRequestedDownloadWhileIdle() {
        var installs = 0
        let controller = UpdateController(
            appState: AppState.shared,
            installAction: { installs += 1 }
        )
        controller.handleDiscovered(version: "9.9.9", build: "9901")
        AppState.shared.updateAvailable?.startDownload()
        controller.applyDriverStage(.downloading(fractionCompleted: 1.0))

        controller.applyDriverStage(.readyToInstall)

        XCTAssertEqual(installs, 1)
        if case .readyToInstall = AppState.shared.updateAvailable?.stage {
            XCTFail("An idle user-requested download can keep the one-click flow.")
        }
        controller.applyDriverStage(.readyToInstall)
        XCTAssertEqual(installs, 1, "Duplicate completion must not restart twice.")
    }

    func test_readyUpdateResumedFromEarlierSessionRequiresExplicitRestart() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        controller.applyDriverStage(.readyToInstall)
        XCTAssertEqual(installs, 0, "Launching with a downloaded update must not restart the app.")
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_meetingIncludingPausedRecordingDefersUntilExplicitIdleRestart() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        AppState.shared.updateAvailable?.startDownload()
        AppState.shared.updateMeetingRecordingState(audioLevel: 0, duration: 12, paused: true)
        controller.applyDriverStage(.readyToInstall)
        XCTAssertEqual(installs, 0)
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("meeting") == true)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0, "Restart clicks must also respect a paused meeting.")
        AppState.shared.clearMeetingRecordingState()
        controller.applyDriverStage(.readyToInstall)
        XCTAssertEqual(installs, 0, "A duplicate Ready callback after becoming idle is not authorization.")
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_dictationAndAgentActivitiesBlockBothReadyAndRestart() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        AppState.shared.updateAvailable?.startDownload()
        AppState.shared.phase = .transcribing
        controller.applyDriverStage(.readyToInstall)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0)
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("dictation") == true)
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .executing
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0)
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("agent") == true)
        AppState.shared.agentPhase = .idle
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_translationAndSubtitlesDeferUpdateUntilExplicitRestart() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        AppState.shared.updateAvailable?.startDownload()
        AppState.shared.translationActive = true
        controller.applyDriverStage(.readyToInstall)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(controller.updater))
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("translation") == true)
        AppState.shared.translationActive = false
        XCTAssertEqual(installs, 0)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_sparkleFinalRelaunchGuardRejectsActivityStartedAfterReadyCheck() {
        let controller = UpdateController(appState: .shared, updatesEnabled: false)
        XCTAssertTrue(controller.updaterShouldRelaunchApplication(controller.updater))
        AppState.shared.phase = .recording
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(controller.updater))
        AppState.shared.phase = .idle
        AppState.shared.agentPhase = .textInputActive
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(controller.updater))
    }

    func test_plannerDefersUpdateAndIdleStillRequiresExplicitRestart() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        AppState.shared.updateAvailable?.startDownload()
        AppState.shared.plannerActive = true
        controller.applyDriverStage(.readyToInstall)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(controller.updater))
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("Planner") == true)
        AppState.shared.plannerActive = false
        AppState.shared.todoActive = false
        XCTAssertEqual(installs, 0)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_calendarSignInDefersRestartAfterSettingsCloses() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        AppState.shared.updateAvailable?.startDownload()
        AppState.shared.calendarConnectionActive = true
        controller.applyDriverStage(.readyToInstall)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(controller.updater))
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("calendar sign-in") == true)
        AppState.shared.calendarConnectionActive = false
        XCTAssertEqual(installs, 0)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_todoDefersUpdateAndIdleStillRequiresExplicitRestart() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        AppState.shared.updateAvailable?.startDownload()
        AppState.shared.todoActive = true
        controller.applyDriverStage(.readyToInstall)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(controller.updater))
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("To-do") == true)
        AppState.shared.todoActive = false
        XCTAssertEqual(installs, 0)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_calendarHoverDefersUpdateUntilClosedAndExplicitRestart() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        AppState.shared.updateAvailable?.startDownload()
        AppState.shared.calendarHoverActive = true
        defer { AppState.shared.calendarHoverActive = false }
        controller.applyDriverStage(.readyToInstall)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(controller.updater))
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("Calendar") == true)
        AppState.shared.calendarHoverActive = false
        XCTAssertEqual(installs, 0)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_screenshotDefersUpdateUntilExplicitRestart() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        AppState.shared.updateAvailable?.startDownload()
        AppState.shared.screenshotActive = true
        controller.applyDriverStage(.readyToInstall)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 0)
        XCTAssertFalse(controller.updaterShouldRelaunchApplication(controller.updater))
        XCTAssertTrue(AppState.shared.updateAvailable?.restartDeferralReason?.contains("screenshot") == true)
        AppState.shared.screenshotActive = false
        XCTAssertEqual(installs, 0)
        AppState.shared.updateAvailable?.install()
        XCTAssertEqual(installs, 1)
    }

    func test_deferredLaterCancelsInstallationAndOldRestartCannotInstall() {
        var installs = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false, installAction: { installs += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        var replied: SPUUserUpdateChoice?
        controller.driver.handleReadyToInstall(reply: { replied = $0 })
        let old = AppState.shared.updateAvailable
        old?.dismiss()
        XCTAssertNil(AppState.shared.updateAvailable)
        XCTAssertEqual(replied, .skip, "At Ready, Later must cancel installation rather than arm install-on-quit.")
        old?.install()
        XCTAssertEqual(installs, 0)
        controller.handleDiscovered(version: "2.3", build: "2300")
        XCTAssertEqual(AppState.shared.updateAvailable?.buildVersion, "2300")
    }

    func test_oldPillActionsCannotAffectNewDiscoveryEvenIfBuildRepeats() {
        var downloads = 0
        var installs = 0
        var skips = 0
        let controller = UpdateController(appState: .shared, updatesEnabled: false,
            downloadAction: { downloads += 1 }, installAction: { installs += 1 }, skipAction: { skips += 1 })
        controller.handleDiscovered(version: "2.2", build: "2200")
        let oldAvailable = AppState.shared.updateAvailable
        controller.applyDriverStage(.readyToInstall)
        let oldReady = AppState.shared.updateAvailable
        controller.applyDriverStage(.cleared)
        controller.handleDiscovered(version: "2.2", build: "2200")
        oldAvailable?.startDownload()
        oldAvailable?.skip()
        oldReady?.install()
        oldReady?.dismiss()
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(skips, 0)
        XCTAssertEqual(AppState.shared.updateAvailable?.buildVersion, "2200")
    }

    func test_applyDriverStage_cleared_removesUpdateAvailable() {
        let controller = UpdateController(appState: AppState.shared)
        controller.handleDiscovered(version: "9.9.9", build: "9901")
        XCTAssertNotNil(AppState.shared.updateAvailable)

        controller.applyDriverStage(.cleared)

        XCTAssertNil(AppState.shared.updateAvailable)
    }

    func test_applyDriverStage_cleared_allowsNextDiscoveryToSurfaceAsAvailable() {
        let controller = UpdateController(appState: .shared)
        controller.handleDiscovered(version: "1.9.5", build: "1405")

        controller.applyDriverStage(.cleared)
        controller.handleDiscovered(version: "1.10.0", build: "1410")

        XCTAssertEqual(AppState.shared.updateAvailable?.displayVersion, "1.10.0")
        XCTAssertEqual(AppState.shared.updateAvailable?.stage, .available(download: {}))
    }

    // MARK: - with(stage:) helper

    func test_pendingUpdate_withStage_preservesIdentityAndChangesStage() {
        let original = PendingUpdate(
            displayVersion: "1.2.3",
            buildVersion: "1230",
            stage: .available(download: {}),
            dismiss: {},
            skip: {}
        )
        let updated = original.with(stage: .downloading(fractionCompleted: 0.3))

        XCTAssertEqual(updated.displayVersion, "1.2.3")
        XCTAssertEqual(updated.buildVersion, "1230")
        XCTAssertEqual(updated.stage, .downloading(fractionCompleted: 0.3))
    }

    func test_pendingUpdate_withStage_preservesSkipClosure() {
        var skipped = false
        let original = PendingUpdate(
            displayVersion: "1.2.3",
            buildVersion: "1230",
            stage: .available(download: {}),
            dismiss: {},
            skip: { skipped = true }
        )
        let updated = original.with(stage: .downloading(fractionCompleted: 0.3))
        updated.skip()
        XCTAssertTrue(skipped, "with(stage:) must thread the skip closure through")
    }

    // MARK: - Idempotency / build dedup

    func test_secondDiscoveryOfSameBuild_isNoop() {
        let controller = UpdateController(appState: AppState.shared)
        controller.handleDiscovered(version: "1.0", build: "1001")
        guard case .available = AppState.shared.updateAvailable?.stage else {
            return XCTFail("First discovery must set .available")
        }

        // Transition to downloading to show idempotency doesn't regress stage.
        controller.applyDriverStage(.downloading(fractionCompleted: 0.5))

        // A second discovery for the same build must not reset to .available.
        controller.handleDiscovered(version: "1.0", build: "1001")

        XCTAssertEqual(
            AppState.shared.updateAvailable?.stage,
            .downloading(fractionCompleted: 0.5),
            "Re-discovery of the same build must not regress the stage."
        )
    }

    func test_secondDiscoveryOfSameBuild_whileDismissed_isNoop() {
        let controller = UpdateController(appState: AppState.shared)
        controller.handleDiscovered(version: "1.0", build: "1001")
        controller.dismissPendingUpdate()
        XCTAssertNil(AppState.shared.updateAvailable)

        // Sparkle may keep retrying discovery.
        controller.handleDiscovered(version: "1.0", build: "1001")

        XCTAssertNil(
            AppState.shared.updateAvailable,
            "Re-discovery of a build dismissed this session must not resurface."
        )
    }

    func test_discoveryOfNewVersion_afterDismiss_setsState() {
        let controller = UpdateController(appState: AppState.shared)
        controller.handleDiscovered(version: "1.0", build: "1001")
        controller.dismissPendingUpdate()
        XCTAssertNil(AppState.shared.updateAvailable)

        controller.handleDiscovered(version: "1.1", build: "1101")

        XCTAssertEqual(AppState.shared.updateAvailable?.displayVersion, "1.1")
        guard case .available = AppState.shared.updateAvailable?.stage else {
            return XCTFail("New-version discovery must set .available")
        }
    }

    func test_discoveryOfNewBuildWithSameDisplayVersion_updatesPendingState() {
        let controller = UpdateController(appState: AppState.shared)
        controller.handleDiscovered(version: "1.4.4", build: "1205")

        controller.handleDiscovered(version: "1.4.4", build: "1207")

        XCTAssertEqual(AppState.shared.updateAvailable?.displayVersion, "1.4.4")
        XCTAssertEqual(AppState.shared.updateAvailable?.buildVersion, "1207")
    }

    func test_dismissedBuild_doesNotSurface_afterReadyToInstall() {
        let controller = UpdateController(appState: AppState.shared)
        controller.handleDiscovered(version: "1.0", build: "1001")
        controller.applyDriverStage(.readyToInstall)
        AppState.shared.updateAvailable?.dismiss()
        XCTAssertNil(AppState.shared.updateAvailable)
        XCTAssertEqual(controller.dismissedBuildVersionString, "1001")

        controller.handleDiscovered(version: "1.0", build: "1001")
        XCTAssertNil(
            AppState.shared.updateAvailable,
            "Once dismissed, the same build must not resurface in this session."
        )
    }

    func test_skipState_isNotPersisted_acrossControllerInstances() {
        let controllerA = UpdateController(appState: AppState.shared)
        controllerA.handleDiscovered(version: "1.0", build: "1001")
        controllerA.dismissPendingUpdate()
        XCTAssertEqual(controllerA.dismissedBuildVersionString, "1001")

        let controllerB = UpdateController(appState: AppState.shared)
        XCTAssertNil(
            controllerB.dismissedBuildVersionString,
            "Dismissed flag must NOT survive controller re-creation (in-memory only)."
        )

        controllerB.handleDiscovered(version: "1.0", build: "1001")
        XCTAssertEqual(AppState.shared.updateAvailable?.displayVersion, "1.0")
    }

    // MARK: - Dismiss semantics

    func test_dismissPendingUpdate_clearsStateAndRemembersBuild() {
        let controller = UpdateController(appState: AppState.shared)
        controller.handleDiscovered(version: "1.0", build: "1001")
        XCTAssertNotNil(AppState.shared.updateAvailable)

        AppState.shared.updateAvailable?.dismiss()

        XCTAssertNil(AppState.shared.updateAvailable)
        XCTAssertEqual(controller.dismissedBuildVersionString, "1001")
    }

    // MARK: - Stage distinguishability

    func test_pendingUpdate_stages_are_distinguishable_by_tag() {
        var downloaded = false
        let available = PendingUpdate.Stage.available(download: { downloaded = true })
        let downloading = PendingUpdate.Stage.downloading(fractionCompleted: 0.4)
        let ready = PendingUpdate.Stage.readyToInstall(install: {})

        XCTAssertNotEqual(available, downloading)
        XCTAssertNotEqual(downloading, ready)
        XCTAssertEqual(
            PendingUpdate.Stage.downloading(fractionCompleted: 0.4),
            PendingUpdate.Stage.downloading(fractionCompleted: 0.9),
            "downloading compares by tag only, not fraction (avoids churn)"
        )
        if case .available(let download) = available { download() }
        XCTAssertTrue(downloaded)
    }
}

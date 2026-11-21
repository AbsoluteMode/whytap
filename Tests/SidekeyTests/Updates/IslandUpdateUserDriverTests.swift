import XCTest
import Sparkle
@testable import Sidekey

@MainActor
final class IslandUpdateUserDriverTests: XCTestCase {
    func test_updateFound_emits_available_and_download_invokes_reply_install() {
        var emitted: [IslandUpdateUserDriver.DriverStage] = []
        let driver = IslandUpdateUserDriver(onStage: { emitted.append($0) })

        var replied: SPUUserUpdateChoice?
        driver.handleUpdateFound(reply: { replied = $0 })

        guard case .available = emitted.last else {
            return XCTFail("expected .available, got \(String(describing: emitted.last))")
        }
        XCTAssertNil(replied, "download must not start until the user acts")
        driver.invokeDownload()
        XCTAssertEqual(replied, .install)
    }

    func test_download_progress_emits_increasing_fraction() {
        var emitted: [IslandUpdateUserDriver.DriverStage] = []
        let driver = IslandUpdateUserDriver(onStage: { emitted.append($0) })

        driver.handleDownloadExpectedLength(100)
        driver.handleDownloadReceived(length: 25)
        driver.handleDownloadReceived(length: 25)

        XCTAssertEqual(emitted, [
            .downloading(fractionCompleted: 0.0),
            .downloading(fractionCompleted: 0.25),
            .downloading(fractionCompleted: 0.5),
        ])
    }

    func test_download_received_without_expected_length_stays_indeterminate() {
        var emitted: [IslandUpdateUserDriver.DriverStage] = []
        let driver = IslandUpdateUserDriver(onStage: { emitted.append($0) })
        driver.handleDownloadReceived(length: 999)
        XCTAssertEqual(emitted, [.downloading(fractionCompleted: 0.0)],
                      "no expected length yet → indeterminate 0.0, never NaN")
    }

    func test_readyToInstall_emits_and_install_invokes_reply() {
        var emitted: [IslandUpdateUserDriver.DriverStage] = []
        let driver = IslandUpdateUserDriver(onStage: { emitted.append($0) })

        var replied: SPUUserUpdateChoice?
        driver.handleReadyToInstall(reply: { replied = $0 })
        XCTAssertEqual(emitted.last, .readyToInstall)
        XCTAssertNil(replied, "install waits for the user's Restart click")

        driver.invokeInstall()
        XCTAssertEqual(replied, .install)
    }

    func test_error_clears_pill_and_acknowledges() {
        var emitted: [IslandUpdateUserDriver.DriverStage] = []
        let driver = IslandUpdateUserDriver(onStage: { emitted.append($0) })
        var acked = false
        driver.showUpdaterError(NSError(domain: "t", code: 1), acknowledgement: { acked = true })
        XCTAssertEqual(emitted.last, .cleared)
        XCTAssertTrue(acked, "must acknowledge or Sparkle's cycle hangs")
    }

    func test_dismiss_clears_pill() {
        var emitted: [IslandUpdateUserDriver.DriverStage] = []
        let driver = IslandUpdateUserDriver(onStage: { emitted.append($0) })
        driver.dismissUpdateInstallation()
        XCTAssertEqual(emitted.last, .cleared)
    }

    func test_installing_emits_installing_stage() {
        var emitted: [IslandUpdateUserDriver.DriverStage] = []
        let driver = IslandUpdateUserDriver(onStage: { emitted.append($0) })
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        XCTAssertEqual(emitted.last, .installing)
    }

    func test_not_found_acknowledges() {
        let driver = IslandUpdateUserDriver(onStage: { _ in })
        var acked = false
        driver.showUpdateNotFoundWithError(NSError(domain: "t", code: 0), acknowledgement: { acked = true })
        XCTAssertTrue(acked)
    }

    func test_installed_and_relaunched_acknowledges() {
        let driver = IslandUpdateUserDriver(onStage: { _ in })
        var acked = false
        driver.showUpdateInstalledAndRelaunched(true, acknowledgement: { acked = true })
        XCTAssertTrue(acked)
    }

    func test_permission_opts_into_checks_without_profile() {
        let driver = IslandUpdateUserDriver(onStage: { _ in })
        var response: SUUpdatePermissionResponse?
        driver.show(SPUUpdatePermissionRequest(systemProfile: []), reply: { response = $0 })
        XCTAssertEqual(response?.automaticUpdateChecks, true)
        XCTAssertEqual(response?.sendSystemProfile, false)
    }

    func test_downloadAndInstallRepliesAreOneShot() {
        let driver = IslandUpdateUserDriver(onStage: { _ in })
        var downloads = 0
        var installs = 0
        driver.handleUpdateFound(reply: { _ in downloads += 1 })
        driver.invokeDownload()
        driver.invokeDownload()
        driver.handleReadyToInstall(reply: { _ in installs += 1 })
        driver.invokeInstall()
        driver.invokeInstall()
        driver.invokeLater()
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(installs, 1)
    }

    func test_laterCancelsReadyInstallationWithoutInstallOnQuit() {
        let driver = IslandUpdateUserDriver(onStage: { _ in })
        var replies: [SPUUserUpdateChoice] = []
        driver.handleReadyToInstall(reply: { replies.append($0) })
        driver.invokeLater()
        driver.invokeInstall()
        XCTAssertEqual(replies, [.skip], "At Ready, Skip cancels installation without permanently skipping the version.")
    }

    func test_newDiscoveryAndErrorInvalidateOldReadyReply() {
        let driver = IslandUpdateUserDriver(onStage: { _ in })
        var installs = 0
        driver.handleReadyToInstall(reply: { _ in installs += 1 })
        driver.handleUpdateFound(reply: { _ in })
        driver.invokeInstall()
        driver.handleReadyToInstall(reply: { _ in installs += 1 })
        driver.showUpdaterError(NSError(domain: "test", code: 1), acknowledgement: {})
        driver.invokeInstall()
        XCTAssertEqual(installs, 0)
    }
}

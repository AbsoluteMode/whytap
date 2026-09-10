import XCTest
@testable import Sidekey

final class InstallationGuardTests: XCTestCase {
    func testReadOnlyDiskImageMustBeInstalledBeforeLaunch() {
        XCTAssertTrue(InstallationGuard.requiresInstallation(
            bundleURL: URL(fileURLWithPath: "/Volumes/Whytap/Whytap.app"), volumeIsReadOnly: true))
    }

    func testTranslocatedAppMustBeInstalledEvenWithoutVolumeMetadata() {
        XCTAssertTrue(InstallationGuard.requiresInstallation(
            bundleURL: URL(fileURLWithPath: "/private/var/folders/example/AppTranslocation/random/d/Whytap.app"),
            volumeIsReadOnly: false))
    }

    func testInstalledAndDeveloperCopiesCanLaunch() {
        for path in ["/Applications/Whytap.app", "/Users/example/Applications/Whytap.app",
                     "/Volumes/External/Apps/Whytap.app", "/tmp/build/Whytap-Beta-dev.app"] {
            XCTAssertFalse(InstallationGuard.requiresInstallation(
                bundleURL: URL(fileURLWithPath: path), volumeIsReadOnly: false))
        }
    }

    func testBareExecutableAndTestBundlesAreNotInstallers() {
        XCTAssertFalse(InstallationGuard.requiresInstallation(
            bundleURL: URL(fileURLWithPath: "/tmp/SidekeyPackageTests.xctest"), volumeIsReadOnly: true))
    }
}

import XCTest
@testable import Sidekey

final class FirstLaunchPermissionsTests: XCTestCase {
    func testMissingPermissionsOpenOnceAndStayDismissedAcrossLaunches() {
        let name = "FirstLaunchPermissionsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(FirstLaunchPermissions.consumePresentation(in: defaults,
            requiredPermissionsGranted: false, screenRecordingGranted: false))
        XCTAssertFalse(FirstLaunchPermissions.consumePresentation(in: UserDefaults(suiteName: name)!,
            requiredPermissionsGranted: false, screenRecordingGranted: false))
    }

    func testMissingScreenPermissionShowsSetupEvenWhenVoiceIsReady() {
        let name = "FirstLaunchPermissionsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertTrue(FirstLaunchPermissions.consumePresentation(in: defaults,
            requiredPermissionsGranted: true, screenRecordingGranted: false))
    }

    func testAlreadyAuthorizedMacDoesNotOpenSetupOnUpgrade() {
        let name = "FirstLaunchPermissionsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(FirstLaunchPermissions.consumePresentation(in: defaults,
            requiredPermissionsGranted: true, screenRecordingGranted: true))
        XCTAssertFalse(FirstLaunchPermissions.consumePresentation(in: defaults,
            requiredPermissionsGranted: false, screenRecordingGranted: false))
    }

    func testPortableSettingsExcludePresentationMarker() throws {
        let name = "FirstLaunchPermissionsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: FirstLaunchPermissions.presentedKey)
        XCTAssertNil(try ConfigBackupRegistry.capture(defaults)[FirstLaunchPermissions.presentedKey])
    }
}

@MainActor
final class ScreenRecordingPermissionRequestTests: XCTestCase {
    func testFailedNativeRequestIsNotAnError() async {
        var requests = 0
        await ScreenRecordingPermissionRequest.request(isGranted: { false }, requestContent: {
            requests += 1
            throw NSError(domain: "PermissionTest", code: 1)
        })
        XCTAssertEqual(requests, 1)
    }

    func testAlreadyGrantedDoesNotRequest() async {
        var requests = 0
        await ScreenRecordingPermissionRequest.request(isGranted: { true }, requestContent: { requests += 1 })
        XCTAssertEqual(requests, 0)
    }
}

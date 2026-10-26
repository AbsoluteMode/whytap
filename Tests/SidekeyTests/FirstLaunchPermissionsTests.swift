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
    func testNativeRequestPrecedesSystemSettingsWhenDenied() async {
        var events: [String] = []
        await ScreenRecordingPermissionRequest.request(isGranted: { false }, requestContent: {
            events.append("request")
            throw NSError(domain: "PermissionTest", code: 1)
        }, openSettings: { events.append("settings") })
        XCTAssertEqual(events, ["request", "settings"])
    }

    func testSuccessfulNativeRequestDoesNotOpenSystemSettings() async {
        var events: [String] = []
        await ScreenRecordingPermissionRequest.request(isGranted: { false },
            requestContent: { events.append("request") }, openSettings: { events.append("settings") })
        XCTAssertEqual(events, ["request"])
    }

    func testAlreadyGrantedDoesNotRequestOrOpenAnything() async {
        var events: [String] = []
        await ScreenRecordingPermissionRequest.request(isGranted: { true },
            requestContent: { events.append("request") }, openSettings: { events.append("settings") })
        XCTAssertTrue(events.isEmpty)
    }

    func testErrorAfterGrantDoesNotOpenSystemSettings() async {
        var granted = false
        var openedSettings = false
        await ScreenRecordingPermissionRequest.request(isGranted: { granted }, requestContent: {
            granted = true
            throw NSError(domain: "PermissionTest", code: 2)
        }, openSettings: { openedSettings = true })
        XCTAssertFalse(openedSettings)
    }
}

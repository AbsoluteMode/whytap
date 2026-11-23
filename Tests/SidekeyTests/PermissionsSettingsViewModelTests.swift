import AVFoundation
import XCTest
@testable import Sidekey

@MainActor
final class PermissionsSettingsViewModelTests: XCTestCase {
    private var originalStatus: DropHotkeyStatus = .unavailable

    override func setUp() {
        super.setUp()
        originalStatus = AppState.shared.dropHotkeyStatus
    }

    override func tearDown() {
        AppState.shared.dropHotkeyStatus = originalStatus
        super.tearDown()
    }

    func testRefreshReconcilesRuntimeAndRetryForcesInstallationWithoutChangingPermissions() {
        var calls: [(Bool, Bool)] = []
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: false, microphoneStatus: .authorized) },
            runtimeRefresh: { calls.append(($0, $1)) })
        model.refresh()
        model.refresh(restartRecoveryPolling: false)
        model.retryDropShortcut()
        XCTAssertEqual(calls.map { $0.0 }, [false, false, true])
        XCTAssertEqual(calls.map { $0.1 }, [true, false, true])
        XCTAssertFalse(model.snapshot.accessibilityGranted)
    }

    func testAllowedPermissionsDoNotClaimReadyUntilShortcutActuallyInstalls() {
        AppState.shared.dropHotkeyStatus = .unavailable
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            runtimeRefresh: { _, _ in })
        XCTAssertFalse(model.allRequiredGranted)
        AppState.shared.dropHotkeyStatus = .shortcutInUse
        XCTAssertEqual(model.dropHotkeyStatus, .shortcutInUse)
        XCTAssertFalse(model.allRequiredGranted)
        AppState.shared.dropHotkeyStatus = .ready
        XCTAssertTrue(model.allRequiredGranted)
    }

    func testOptionalScreenRecordingRefreshesWithoutRequestingOrBlockingReadiness() {
        AppState.shared.dropHotkeyStatus = .ready
        var granted = false
        var requests = 0
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            screenRecordingAccessProvider: { granted },
            screenRecordingRequester: { requests += 1 },
            runtimeRefresh: { _, _ in })
        XCTAssertFalse(model.screenRecordingGranted)
        XCTAssertTrue(model.allRequiredGranted)
        granted = true
        model.refresh(restartRecoveryPolling: false)
        XCTAssertTrue(model.screenRecordingGranted)
        granted = false
        model.refresh()
        XCTAssertFalse(model.screenRecordingGranted)
        XCTAssertTrue(model.allRequiredGranted)
        XCTAssertEqual(requests, 0)
    }

    func testScreenRecordingButtonRequestsAndRefreshesPermission() async {
        var granted = false
        var requests = 0
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            screenRecordingAccessProvider: { granted },
            screenRecordingRequester: { requests += 1; granted = true },
            usesProtectionOverridePane: { false },
            runtimeRefresh: { _, _ in })
        XCTAssertEqual(requests, 0)
        await model.requestScreenRecording()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.screenRecordingGranted)
    }

    func testScreenRecordingRequestDoesNotRepeatWhileNativePromptIsPending() async {
        let started = expectation(description: "Native request started")
        var continuation: CheckedContinuation<Void, Never>?
        var requests = 0
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            screenRecordingAccessProvider: { false },
            screenRecordingRequester: {
                requests += 1
                await withCheckedContinuation { pending in
                    continuation = pending
                    started.fulfill()
                }
            }, usesProtectionOverridePane: { false }, runtimeRefresh: { _, _ in })
        let first = Task { await model.requestScreenRecording() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(model.isRequestingScreenRecording)
        await model.requestScreenRecording()
        XCTAssertEqual(requests, 1)
        continuation?.resume()
        await first.value
        XCTAssertFalse(model.isRequestingScreenRecording)
    }

    // A clean Mac: the first Allow must leave macOS alone with its own dialog.
    func testFirstKeyboardAllowOnlyAsksMacOSAndTheNextPressOpensSettings() {
        var events: [String] = []
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: false, microphoneStatus: .authorized) },
            accessibilityRequester: { events.append("request") },
            openAccessibilitySettings: { events.append("settings") },
            usesProtectionOverridePane: { false },
            runtimeRefresh: { _, _ in })
        XCTAssertFalse(model.accessibilityRequested)
        model.requestAccessibility()
        XCTAssertEqual(events, ["request"])
        XCTAssertTrue(model.accessibilityRequested)
        model.requestAccessibility()
        model.requestAccessibility()
        XCTAssertEqual(events, ["request", "settings", "settings"])
    }

    // macOS 27.3: no dialog and no row, so every press opens System & App
    // Protection Override, where the person adds Whytap with +.
    func testOnMacOS27_3EveryKeyboardPressOpensTheOverridePane() {
        var events: [String] = []
        var snapshot = PermissionsHelper.Snapshot(accessibilityGranted: false, microphoneStatus: .authorized,
                                                  postEventGranted: false, listenEventGranted: false)
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { snapshot },
            accessibilityRequester: { events.append("request") },
            openAccessibilitySettings: { events.append("settings") },
            usesProtectionOverridePane: { true }, runtimeRefresh: { _, _ in })
        XCTAssertTrue(model.keyboardOpensSettings)
        model.requestAccessibility()
        model.requestAccessibility()
        XCTAssertEqual(events, ["settings", "settings"], "the pane only: no system request rides along")
        // Choose Apps gives Accessibility without posting: still not ready.
        snapshot = .init(accessibilityGranted: true, microphoneStatus: .authorized,
                         postEventGranted: false, listenEventGranted: true)
        model.refresh()
        XCTAssertFalse(model.keyboardReady)
        model.requestAccessibility()
        XCTAssertEqual(events.last, "settings")
    }

    // The 27.3 keyboard stages, from this process's grants now and at launch.
    func testKeyboardSetupStages() {
        typealias S = PermissionsHelper.Snapshot
        let none = S(accessibilityGranted: false, microphoneStatus: .authorized, postEventGranted: false, listenEventGranted: false)
        let chooseApps = S(accessibilityGranted: true, microphoneStatus: .authorized, postEventGranted: false, listenEventGranted: false)
        let override = S(accessibilityGranted: true, microphoneStatus: .authorized, postEventGranted: true, listenEventGranted: false)
        let all = S(accessibilityGranted: true, microphoneStatus: .authorized)
        XCTAssertEqual(PermissionsSettingsViewModel.keyboardSetup(now: none, launch: none), .addWhytap)
        XCTAssertEqual(PermissionsSettingsViewModel.keyboardSetup(now: chooseApps, launch: chooseApps), .chooseAppsOnly)
        XCTAssertEqual(PermissionsSettingsViewModel.keyboardSetup(now: chooseApps, launch: none), .addWhytap,
                       "a live Accessibility flip is not yet a diagnosis")
        XCTAssertEqual(PermissionsSettingsViewModel.keyboardSetup(now: override, launch: none), .inputMonitoring)
        XCTAssertEqual(PermissionsSettingsViewModel.keyboardSetup(now: all, launch: none), .restart)
        XCTAssertEqual(PermissionsSettingsViewModel.keyboardSetup(now: all, launch: all), .ready)
    }

    // A 27.3 grant made after launch asks for a restart (Settings shows
    // Restart Whytap); one present at launch doesn't; older macOS never does.
    func testA27_3GrantAfterLaunchNeedsARestart() {
        var restarts = 0
        var screen = false
        var snapshot = PermissionsHelper.Snapshot(accessibilityGranted: false, microphoneStatus: .authorized,
                                                  postEventGranted: false, listenEventGranted: false)
        let launch = PermissionsHelper.LaunchGrants(snapshot: snapshot, screenRecording: false)
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { snapshot }, screenRecordingAccessProvider: { screen },
            usesProtectionOverridePane: { true }, launchGrants: launch, relaunch: { restarts += 1; return nil },
            runtimeRefresh: { _, _ in })
        XCTAssertFalse(model.keyboardNeedsRestart)
        snapshot = .init(accessibilityGranted: true, microphoneStatus: .authorized)
        screen = true
        model.refresh()
        XCTAssertTrue(model.keyboardNeedsRestart)
        XCTAssertTrue(model.screenNeedsRestart)
        XCTAssertTrue(model.restartWhytap())
        XCTAssertEqual(restarts, 1)
        XCTAssertNil(model.restartBlocked)
        let atLaunch = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { snapshot }, screenRecordingAccessProvider: { screen },
            usesProtectionOverridePane: { true },
            launchGrants: .init(snapshot: snapshot, screenRecording: true), runtimeRefresh: { _, _ in })
        XCTAssertFalse(atLaunch.keyboardNeedsRestart)
        XCTAssertFalse(atLaunch.screenNeedsRestart)
        let older = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { snapshot }, screenRecordingAccessProvider: { screen },
            usesProtectionOverridePane: { false }, launchGrants: launch, runtimeRefresh: { _, _ in })
        XCTAssertFalse(older.keyboardNeedsRestart)
        XCTAssertFalse(older.screenNeedsRestart)
    }

    // Screen Recording on 27.3: the press opens the pane; nothing is requested.
    func testOnMacOS27_3TheScreenPressOpensThePaneWithoutARequest() async {
        var events: [String] = []
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            screenRecordingAccessProvider: { false },
            screenRecordingRequester: { events.append("request") },
            usesProtectionOverridePane: { true },
            openScreenRecordingSettings: { events.append("settings") },
            runtimeRefresh: { _, _ in })
        await model.requestScreenRecording()
        await model.requestScreenRecording()
        XCTAssertEqual(events, ["settings", "settings"])
    }

    // The update restart's activity rules block the onboarding restart too.
    func testARestartWaitsForAMeetingRecording() {
        let state = AppState()
        XCTAssertNil(UpdateController.restartDeferralReason(state))
        state.updateMeetingRecordingState(audioLevel: 0, duration: 1, paused: false)
        XCTAssertEqual(UpdateController.restartDeferralReason(state), "Ready. Finish the meeting recording, then choose Restart.")
        var started = 0
        XCTAssertEqual(AppRelauncher.relaunch(appState: state, startHelper: { _, _ in started += 1; return {} },
                                              terminate: { XCTFail("quit during a recording") }),
                       "Ready. Finish the meeting recording, then choose Restart.")
        XCTAssertEqual(started, 0)
        XCTAssertFalse(AppRelauncher.restartAccepted, "nothing quits and no reopen helper is armed")
    }

    // The relaunch passes the PID and the bundle path as arguments, never in
    // the script, and opens nothing if the quit was cancelled.
    func testTheRelaunchScriptTakesItsValuesAsArguments() {
        let arguments = AppRelauncher.arguments(pid: 4242, bundlePath: "/Applications/Why tap.app")
        XCTAssertEqual(arguments.first, "-c")
        XCTAssertEqual(Array(arguments.suffix(2)), ["4242", "/Applications/Why tap.app"])
        XCTAssertFalse(AppRelauncher.script.contains("4242"))
        XCTAssertTrue(AppRelauncher.script.contains("|| /usr/bin/open \"$2\""))
    }

    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "Condition never became true", file: file, line: line)
    }

    func testKeyboardAllowAfterGrantNeitherAsksNorOpensSettings() {
        var events: [String] = []
        var granted = false
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: granted, microphoneStatus: .authorized) },
            accessibilityRequester: { events.append("request") },
            openAccessibilitySettings: { events.append("settings") },
            usesProtectionOverridePane: { false },
            runtimeRefresh: { _, _ in })
        model.requestAccessibility()
        granted = true
        model.requestAccessibility()
        XCTAssertEqual(events, ["request"])
        XCTAssertTrue(model.snapshot.accessibilityGranted)
    }

    func testFirstScreenAllowOnlyAsksMacOSAndTheNextPressOpensSettings() async {
        var events: [String] = []
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            screenRecordingAccessProvider: { false },
            screenRecordingRequester: { events.append("request") },
            usesProtectionOverridePane: { false },
            openScreenRecordingSettings: { events.append("settings") },
            runtimeRefresh: { _, _ in })
        await model.requestScreenRecording()
        XCTAssertEqual(events, ["request"])
        XCTAssertTrue(model.screenRecordingRequested)
        await model.requestScreenRecording()
        XCTAssertEqual(events, ["request", "settings"])
        XCTAssertFalse(model.isRequestingScreenRecording)
    }

    func testScreenAllowAfterGrantNeitherAsksNorOpensSettings() async {
        var events: [String] = []
        var granted = false
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            screenRecordingAccessProvider: { granted },
            screenRecordingRequester: { events.append("request") },
            usesProtectionOverridePane: { false },
            openScreenRecordingSettings: { events.append("settings") },
            runtimeRefresh: { _, _ in })
        await model.requestScreenRecording()
        granted = true
        await model.requestScreenRecording()
        XCTAssertEqual(events, ["request"])
        XCTAssertTrue(model.screenRecordingGranted)
    }
}

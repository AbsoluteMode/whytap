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
            }, runtimeRefresh: { _, _ in })
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
            accessibilityIsAddedByHand: { false },
            runtimeRefresh: { _, _ in })
        XCTAssertFalse(model.accessibilityRequested)
        model.requestAccessibility()
        XCTAssertEqual(events, ["request"])
        XCTAssertTrue(model.accessibilityRequested)
        model.requestAccessibility()
        model.requestAccessibility()
        XCTAssertEqual(events, ["request", "settings", "settings"])
    }

    // macOS 27.3: the request shows no dialog and adds no row, so the first
    // Allow also opens System & App Protection Override, where Whytap is
    // added with +; a grant still stops both.
    func testOnMacOS27_3TheFirstKeyboardAllowAsksAndOpensTheOverridePane() {
        var events: [String] = []
        var granted = false
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: granted, microphoneStatus: .authorized) },
            accessibilityRequester: { events.append("request") },
            openAccessibilitySettings: { events.append("settings") },
            accessibilityIsAddedByHand: { true },
            runtimeRefresh: { _, _ in })
        model.requestAccessibility()
        XCTAssertEqual(events, ["request", "settings"])
        model.requestAccessibility()
        XCTAssertEqual(events, ["request", "settings", "settings"])
        granted = true
        model.requestAccessibility()
        XCTAssertEqual(events, ["request", "settings", "settings"])
    }

    func testKeyboardAllowAfterGrantNeitherAsksNorOpensSettings() {
        var events: [String] = []
        var granted = false
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: granted, microphoneStatus: .authorized) },
            accessibilityRequester: { events.append("request") },
            openAccessibilitySettings: { events.append("settings") },
            accessibilityIsAddedByHand: { false },
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
            openScreenRecordingSettings: { events.append("settings") },
            runtimeRefresh: { _, _ in })
        await model.requestScreenRecording()
        granted = true
        await model.requestScreenRecording()
        XCTAssertEqual(events, ["request"])
        XCTAssertTrue(model.screenRecordingGranted)
    }
}

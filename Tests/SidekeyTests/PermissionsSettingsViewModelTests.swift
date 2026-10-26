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
}

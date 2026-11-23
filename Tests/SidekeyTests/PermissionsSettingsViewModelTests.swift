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

    // macOS 27.3 beta: a new app's request shows no dialog and adds no row.
    // Whytap never opens the Override pane (its "+" list); a request answered
    // with neither a dialog nor access is recorded as refused, and the button
    // stops asking.
    func testOnMacOS27_3AKeyboardRequestWithoutADialogIsRefusedAndNeverOpensThePane() async {
        var events: [String] = []
        let refusals = PermissionRequestRefusals(applies: { true }, promptAppeared: { _ in false }, defaults: nil)
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: false, microphoneStatus: .authorized) },
            accessibilityRequester: { events.append("request") },
            openAccessibilitySettings: { events.append("settings") },
            usesProtectionOverridePane: { true }, refusals: refusals,
            runtimeRefresh: { _, _ in })
        model.requestAccessibility()
        XCTAssertEqual(events, ["request"])
        XCTAssertFalse(model.keyboardOpensSettings)
        await eventually { model.keyboardUnavailable }
        model.requestAccessibility()
        model.requestAccessibility()
        XCTAssertEqual(events, ["request"], "refused: no second request, never the pane")
    }

    // With macOS's own dialog on 27.3 nothing is refused; a press after it
    // asks again rather than opening the pane.
    func testOnMacOS27_3ADialogMeansNoRefusal() async {
        var events: [String] = []
        let refusals = PermissionRequestRefusals(applies: { true }, promptAppeared: { _ in true }, defaults: nil)
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: false, microphoneStatus: .authorized) },
            accessibilityRequester: { events.append("request") },
            openAccessibilitySettings: { events.append("settings") },
            usesProtectionOverridePane: { true }, refusals: refusals,
            runtimeRefresh: { _, _ in })
        model.requestAccessibility()
        await eventually { refusals.checking.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.keyboardUnavailable)
        model.requestAccessibility()
        XCTAssertEqual(events, ["request", "request"])
    }

    // Access that arrives while macOS is watched is no refusal.
    func testAGrantDuringTheWatchIsNoRefusal() async {
        var granted = false
        let refusals = PermissionRequestRefusals(applies: { true }, promptAppeared: { _ in
            granted = true
            return false
        }, defaults: nil)
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: granted, microphoneStatus: .authorized) },
            accessibilityRequester: {}, openAccessibilitySettings: {},
            usesProtectionOverridePane: { true }, refusals: refusals,
            runtimeRefresh: { _, _ in })
        model.requestAccessibility()
        await eventually { model.snapshot.accessibilityGranted }
        XCTAssertFalse(model.keyboardUnavailable)
        XCTAssertTrue(refusals.refused.isEmpty)
    }

    // A refusal is remembered for this macOS build only, and a later grant
    // forgets it; where the old pane exists it never applies.
    func testARefusalIsRememberedPerMacOSBuildAndClearedByAGrant() async throws {
        let suite = "refusals-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let first = PermissionRequestRefusals(applies: { true }, promptAppeared: { _ in false },
                                              defaults: defaults, build: "26C5047e")
        let refused = await first.check(.keyboard, granted: { false })
        XCTAssertTrue(refused)
        XCTAssertEqual(PermissionRequestRefusals(applies: { true }, defaults: defaults, build: "26C5047e").refused, [.keyboard])
        XCTAssertEqual(PermissionRequestRefusals(applies: { true }, defaults: defaults, build: "26C5050a").refused, [],
                       "a macOS update asks again")
        XCTAssertEqual(PermissionRequestRefusals(applies: { false }, defaults: defaults, build: "26C5047e").refused, [])
        var granted = false
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: granted, microphoneStatus: .authorized) },
            usesProtectionOverridePane: { true },
            refusals: PermissionRequestRefusals(applies: { true }, defaults: defaults, build: "26C5047e"),
            runtimeRefresh: { _, _ in })
        XCTAssertTrue(model.keyboardUnavailable, "a relaunch shows the refusal without asking again")
        granted = true
        model.refresh()
        XCTAssertFalse(model.keyboardUnavailable)
        XCTAssertEqual(PermissionRequestRefusals(applies: { true }, defaults: defaults, build: "26C5047e").refused, [])
    }

    // Older macOS: no dialog on a repeated request is normal, never a refusal.
    func testWithoutTheOverridePaneNothingIsEverRefused() async {
        let refusals = PermissionRequestRefusals(applies: { false }, promptAppeared: { _ in false }, defaults: nil)
        let refused = await refusals.check(.keyboard, granted: { false })
        XCTAssertFalse(refused)
        XCTAssertTrue(refusals.refused.isEmpty)
    }

    // Screen Recording on 27.3 beta: the same refusal; the next press opens
    // no pane.
    func testOnMacOS27_3AScreenRequestWithoutADialogIsRefusedAndOpensNoPane() async {
        var events: [String] = []
        let model = PermissionsSettingsViewModel(onComplete: {}, autoComplete: false,
            snapshotProvider: { .init(accessibilityGranted: true, microphoneStatus: .authorized) },
            screenRecordingAccessProvider: { false },
            screenRecordingRequester: { events.append("request") },
            usesProtectionOverridePane: { true },
            openScreenRecordingSettings: { events.append("settings") },
            refusals: PermissionRequestRefusals(applies: { true }, promptAppeared: { _ in false }, defaults: nil),
            runtimeRefresh: { _, _ in })
        await model.requestScreenRecording()
        XCTAssertTrue(model.screenUnavailable)
        await model.requestScreenRecording()
        XCTAssertEqual(events, ["request"])
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

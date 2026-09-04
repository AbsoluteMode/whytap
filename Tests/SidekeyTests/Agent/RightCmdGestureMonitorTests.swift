import XCTest
@testable import Sidekey

final class RightCmdGestureMonitorTests: XCTestCase {
    private static let rightCmdFlags: UInt64 = 0x10 | 0x100000 | 0x100
    private static let rightOptionFlags: UInt64 = 0x40 | 0x080000 | 0x100

    func testTapDetectionCapturesSnapshotAndFiresTapOnReleaseBeforeThreshold() {
        let harness = GestureHarness()

        XCTAssertEqual(
            harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags)),
            .passThrough
        )
        XCTAssertEqual(harness.machine.state, .pending)
        XCTAssertEqual(harness.snapshots.count, 1)
        XCTAssertEqual(harness.scheduledTimers, 1)

        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))

        XCTAssertEqual(harness.taps, 1)
        XCTAssertEqual(harness.holdStarts, 0)
        XCTAssertEqual(harness.holdEnds, 0)
        XCTAssertEqual(harness.cancels, 0)
        XCTAssertEqual(harness.cancelledTimers, 1)
        XCTAssertEqual(harness.machine.state, .idle)
    }

    func testHoldDetectionFiresHoldStartAfterThresholdAndHoldEndOnRelease() {
        let harness = GestureHarness()

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags))
        _ = harness.machine.handle(.thresholdElapsed)

        XCTAssertEqual(harness.machine.state, .holding)
        XCTAssertEqual(harness.holdStarts, 1)
        XCTAssertEqual(harness.taps, 0)

        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))

        XCTAssertEqual(harness.holdEnds, 1)
        XCTAssertEqual(harness.cancels, 0)
        XCTAssertEqual(harness.machine.state, .idle)
        XCTAssertEqual(harness.heldChanges, [
            .init(key: .rightCommand, held: true),
            .init(key: .rightCommand, held: false)
        ])
    }

    func testRightCommandHeldStaysHighlightedThroughGestureCancelUntilRelease() {
        let harness = GestureHarness()
        let shiftMask = UInt64(0x020000)

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags))
        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags | shiftMask))
        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))

        XCTAssertEqual(harness.heldChanges, [
            .init(key: .rightCommand, held: true),
            .init(key: .rightCommand, held: false)
        ])
    }

    func testNonModifierKeyDownCancelsAndPassesOriginalEventThrough() {
        let harness = GestureHarness()

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags))
        let disposition = harness.machine.handle(.keyDown(keyCode: 0, rawFlags: Self.rightCmdFlags))

        XCTAssertEqual(disposition, .passThrough)
        XCTAssertEqual(harness.cancels, 1)
        XCTAssertEqual(harness.taps, 0)
        XCTAssertEqual(harness.holdStarts, 0)
        XCTAssertEqual(harness.machine.state, .cancelledWaitingForRelease)

        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))
        XCTAssertEqual(harness.machine.state, .idle)
    }

    func testMouseDownCancelsGestureBeforeRelease() {
        let harness = GestureHarness()

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags))
        _ = harness.machine.handle(.mouseDown)

        XCTAssertEqual(harness.cancels, 1)
        XCTAssertEqual(harness.taps, 0)
        XCTAssertEqual(harness.machine.state, .cancelledWaitingForRelease)

        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))
        XCTAssertEqual(harness.machine.state, .idle)
    }

    func testAdditionalModifierCancelsRightCommandGesture() {
        let harness = GestureHarness()
        let shiftMask = UInt64(0x020000)

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags))
        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags | shiftMask))

        XCTAssertEqual(harness.cancels, 1)
        XCTAssertEqual(harness.taps, 0)
        XCTAssertEqual(harness.machine.state, .cancelledWaitingForRelease)
    }

    func testThresholdAfterTapDoesNotStartHold() {
        let harness = GestureHarness()

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags))
        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))
        _ = harness.machine.handle(.thresholdElapsed)

        XCTAssertEqual(harness.taps, 1)
        XCTAssertEqual(harness.holdStarts, 0)
        XCTAssertEqual(harness.machine.state, .idle)
    }

    func testEscapeDuringHoldingCancelsRecordingWithoutHoldEnd() {
        let harness = GestureHarness()

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags))
        _ = harness.machine.handle(.thresholdElapsed)
        _ = harness.machine.handle(.keyDown(
            keyCode: RightCmdGestureStateMachine.escapeKeyCode,
            rawFlags: Self.rightCmdFlags
        ))

        XCTAssertEqual(harness.holdStarts, 1)
        XCTAssertEqual(harness.cancels, 1)
        XCTAssertEqual(harness.holdEnds, 0)
        XCTAssertEqual(harness.machine.state, .cancelledWaitingForRelease)

        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))
        XCTAssertEqual(harness.holdEnds, 0)
        XCTAssertEqual(harness.machine.state, .idle)
    }

    func testRightCommandRequiresDeviceSpecificRightCommandBit() {
        let leftCommandOnly = UInt64(0x08 | 0x100000 | 0x100)

        XCTAssertFalse(HotkeyFlags.isRightCommandOnly(leftCommandOnly))
        XCTAssertTrue(HotkeyFlags.isRightCommandOnly(Self.rightCmdFlags))
    }

    func testRightOptionGestureCanBeSelectedAsActivationKey() {
        let harness = GestureHarness(activationKey: .rightOption)

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightOptionFlags))
        _ = harness.machine.handle(.thresholdElapsed)
        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))

        XCTAssertEqual(harness.holdStarts, 1)
        XCTAssertEqual(harness.holdEnds, 1)
        XCTAssertEqual(harness.heldChanges, [.init(key: .rightOption, held: true), .init(key: .rightOption, held: false)])
    }

    func testSeparateAgentTextAndVoiceTapKeysDispatchIndependently() {
        let harness = GestureHarness(
            agentTextKey: .rightCommand,
            agentVoiceKey: .rightOption,
            agentVoiceGesture: .tap
        )

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightOptionFlags))
        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))

        XCTAssertEqual(harness.taps, 0)
        XCTAssertEqual(harness.voiceTaps, 1)
        XCTAssertEqual(harness.holdStarts, 0)
        XCTAssertEqual(harness.heldChanges, [
            .init(key: .rightOption, held: true),
            .init(key: .rightOption, held: false)
        ])
    }

    func testSeparateAgentTextKeyDoesNotStartVoiceHold() {
        let harness = GestureHarness(
            agentTextKey: .rightCommand,
            agentVoiceKey: .rightOption,
            agentVoiceGesture: .hold
        )

        _ = harness.machine.handle(.flagsChanged(rawFlags: Self.rightCmdFlags))
        _ = harness.machine.handle(.thresholdElapsed)
        _ = harness.machine.handle(.flagsChanged(rawFlags: 0))

        XCTAssertEqual(harness.taps, 1)
        XCTAssertEqual(harness.voiceTaps, 0)
        XCTAssertEqual(harness.holdStarts, 0)
        XCTAssertEqual(harness.holdEnds, 0)
    }

    func testAgentTextComboTapWaitsForReleaseBeforeDispatching() {
        let harness = AgentComboGestureHarness(tapAction: .text, holdEnabled: false)

        harness.controller.pressed()

        XCTAssertEqual(harness.snapshots.count, 1)
        XCTAssertEqual(harness.taps, 0)

        harness.controller.released()

        XCTAssertEqual(harness.taps, 1)
        XCTAssertEqual(harness.voiceTaps, 0)
    }

    func testAgentSharedComboStartsVoiceHoldAfterThresholdAndSuppressesTextTap() {
        let harness = AgentComboGestureHarness(tapAction: .text, holdEnabled: true)

        harness.controller.pressed()
        harness.controller.thresholdElapsedForTesting()

        XCTAssertEqual(harness.holdStarts, 1)
        XCTAssertEqual(harness.taps, 0)

        harness.controller.released()

        XCTAssertEqual(harness.holdEnds, 1)
        XCTAssertEqual(harness.taps, 0)
    }

    @MainActor
    func testStartInstallsLocalMonitorSoEventsAreObservedWhileSidekeyIsActive() {
        let monitor = RightCmdGestureMonitor()
        defer { monitor.stop() }

        monitor.start(
            onSnapshot: { _ in },
            onTap: {},
            onHoldStart: {},
            onHoldEnd: {},
            onCancel: {}
        )

        // Local monitor never fails to install (no permission requirement).
        // Global monitor requires Accessibility, so its presence is
        // environment-dependent and not asserted here.
        XCTAssertTrue(
            monitor.hasLocalMonitorForTesting,
            "Local NSEvent monitor must be installed so flagsChanged events fire while Sidekey is the active app"
        )
    }

    @MainActor
    func testStopRemovesBothMonitorsSoNoEventsLeakAfterStop() {
        let monitor = RightCmdGestureMonitor()
        monitor.start(
            onSnapshot: { _ in },
            onTap: {},
            onHoldStart: {},
            onHoldEnd: {},
            onCancel: {}
        )
        XCTAssertTrue(monitor.hasLocalMonitorForTesting)

        monitor.stop()

        XCTAssertFalse(monitor.hasLocalMonitorForTesting)
        XCTAssertFalse(monitor.hasGlobalMonitorForTesting)
    }
}

private final class GestureHarness {
    let snapshot: FocusSnapshot
    let machine: RightCmdGestureStateMachine
    private(set) var snapshots: [FocusSnapshot?] = []
    private(set) var taps = 0
    private(set) var voiceTaps = 0
    private(set) var holdStarts = 0
    private(set) var holdEnds = 0
    private(set) var cancels = 0
    private(set) var scheduledTimers = 0
    private(set) var cancelledTimers = 0
    private(set) var heldChanges: [HeldChange] = []

    init(activationKey: HotkeyModifierKey = .rightCommand) {
        let snapshot = FocusSnapshot(
            targetPID: 42,
            bundleID: "com.example.Target",
            appName: "Target",
            selectionText: "selection",
            isEditable: true,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        self.snapshot = snapshot
        machine = RightCmdGestureStateMachine(
            captureSnapshot: { snapshot },
            configuration: HotkeyConfiguration(
                agentTextKey: activationKey,
                agentVoiceKey: activationKey,
                agentVoiceGesture: .hold,
                dropVoiceTapCombo: .optionSlash
            )
        )
        configureMachine()
    }

    init(
        agentTextKey: HotkeyModifierKey,
        agentVoiceKey: HotkeyModifierKey,
        agentVoiceGesture: HotkeyGesture
    ) {
        let snapshot = FocusSnapshot(
            targetPID: 42,
            bundleID: "com.example.Target",
            appName: "Target",
            selectionText: "selection",
            isEditable: true,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        self.snapshot = snapshot
        machine = RightCmdGestureStateMachine(
            captureSnapshot: { snapshot },
            configuration: HotkeyConfiguration(
                agentTextKey: agentTextKey,
                agentVoiceKey: agentVoiceKey,
                agentVoiceGesture: agentVoiceGesture,
                dropVoiceTapCombo: .optionSlash
            )
        )
        configureMachine()
    }

    private func configureMachine() {
        machine.configure(
            onSnapshot: { [weak self] _ in
                self?.snapshots.append(self?.snapshot)
            },
            onTap: { [weak self] in
                self?.taps += 1
            },
            onVoiceTap: { [weak self] in
                self?.voiceTaps += 1
            },
            onHoldStart: { [weak self] in
                self?.holdStarts += 1
            },
            onHoldEnd: { [weak self] in
                self?.holdEnds += 1
            },
            onCancel: { [weak self] in
                self?.cancels += 1
            },
            onScheduleThreshold: { [weak self] in
                self?.scheduledTimers += 1
            },
            onCancelThreshold: { [weak self] in
                self?.cancelledTimers += 1
            },
            onHotkeyKeyHeldChanged: { [weak self] key, isHeld in
                self?.heldChanges.append(HeldChange(key: key, held: isHeld))
            }
        )
    }

    struct HeldChange: Equatable {
        let key: HotkeyModifierKey
        let held: Bool
    }
}

private final class AgentComboGestureHarness {
    let snapshot: FocusSnapshot
    var controller: AgentComboGestureController!
    private(set) var snapshots: [FocusSnapshot?] = []
    private(set) var taps = 0
    private(set) var voiceTaps = 0
    private(set) var holdStarts = 0
    private(set) var holdEnds = 0
    private(set) var cancels = 0

    init(tapAction: AgentComboGestureController.TapAction?, holdEnabled: Bool) {
        let snapshot = FocusSnapshot(
            targetPID: 42,
            bundleID: "com.example.Target",
            appName: "Target",
            selectionText: "selection",
            isEditable: true,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        self.snapshot = snapshot
        controller = AgentComboGestureController(
            captureSnapshot: { snapshot },
            tapAction: tapAction,
            holdEnabled: holdEnabled,
            onSnapshot: { [weak self] snapshot in
                self?.snapshots.append(snapshot)
            },
            onTextTap: { [weak self] in
                self?.taps += 1
            },
            onVoiceTap: { [weak self] in
                self?.voiceTaps += 1
            },
            onVoiceHoldStart: { [weak self] in
                self?.holdStarts += 1
            },
            onVoiceHoldEnd: { [weak self] in
                self?.holdEnds += 1
            },
            onCancel: { [weak self] in
                self?.cancels += 1
            }
        )
    }
}

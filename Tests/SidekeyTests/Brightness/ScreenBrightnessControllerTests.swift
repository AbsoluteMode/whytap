import AppKit
import Combine
import CoreGraphics
import XCTest
@testable import Sidekey

@MainActor
final class ScreenBrightnessControllerTests: XCTestCase {
    // MARK: Reading and the slider

    func testOpeningTheStripOnlyReadsTheLevel() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        XCTAssertEqual(controller.level, 0.4)
        XCTAssertTrue(controller.isAvailable)
        XCTAssertTrue(controller.supportsExtra)
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.events, [])
    }

    func testSliderWritesTheClampedLevel() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        controller.setLevel(0.7)
        XCTAssertEqual(controller.level, 0.7)
        controller.setLevel(1.4)
        XCTAssertEqual(controller.level, 1)
        controller.setLevel(-1)
        XCTAssertEqual(controller.level, 0)
        XCTAssertEqual(device.events, ["write 1 0.7", "write 1 1.0", "write 1 0.0"])
    }

    func testReadsSettleBrieflyAfterAWrite() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.applyWrites = false
        controller.beginInteraction()

        controller.setLevel(0.8)
        controller.refresh()
        XCTAssertEqual(controller.level, 0.8, "A read right after a write can still report the old level.")

        f.clock.advance(ScreenBrightnessController.writeSettleInterval + 0.1)
        controller.refresh()
        XCTAssertEqual(controller.level, 0.4, "After the settle window the hardware reading wins.")
    }

    func testOutsideChangesAreFollowedWhileTheStripIsOpen() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        device.hardware[1] = 0.25
        controller.refresh()
        XCTAssertEqual(controller.level, 0.25)
        XCTAssertEqual(device.events, [])
    }

    func testUnchangedRefreshPublishesNothing() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()
        var announcements = 0
        let subscription = controller.objectWillChange.sink { announcements += 1 }
        defer { subscription.cancel() }

        controller.refresh()
        controller.refresh()
        XCTAssertEqual(announcements, 0, "The strip polls twice a second; unchanged values must not redraw it.")

        device.hardware[1] = 0.6
        controller.refresh()
        XCTAssertGreaterThan(announcements, 0)
    }

    func testPollingRunsWhileAStripIsVisibleOrExtraIsOn() {
        let f = Fixture(), controller = f.controller
        controller.refresh()
        XCTAssertFalse(controller.isPolling, "The capsule status reads once and never polls.")

        controller.beginInteraction()
        controller.beginInteraction()
        XCTAssertTrue(controller.isPolling)
        controller.endInteraction()
        XCTAssertTrue(controller.isPolling)
        controller.endInteraction()
        XCTAssertFalse(controller.isPolling)

        controller.beginInteraction()
        controller.setExtra(true)
        controller.endInteraction()
        XCTAssertTrue(controller.isExtraOn)
        XCTAssertTrue(controller.isPolling, "Extra follows the display while the strip is closed.")
        controller.setExtra(false)
        XCTAssertFalse(controller.isPolling)
        controller.shutdown()
    }

    // MARK: Extra

    func testExtraStartsTheBoostWithoutTouchingTheBacklight() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4, "Extra adds to the current level; it does not raise it.")
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testSwitchingExtraOffLeavesTheBacklightAsItIs() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        controller.setLevel(0.7)

        controller.setExtra(false)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.7)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(device.events, ["boost 1", "write 1 0.7"])
    }

    func testFirstSliderDecreaseOnlyEndsExtraAndTheNextOneLowersTheBacklight() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.setLevel(0.2)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4)
        XCTAssertEqual(device.hardware[1], 0.4)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(device.events, ["boost 1"])

        controller.setLevel(0.2)
        XCTAssertEqual(controller.level, 0.2)
        XCTAssertEqual(device.events, ["boost 1", "write 1 0.2"])

        controller.setLevel(1)
        XCTAssertFalse(controller.isExtraOn, "Increasing brightness does not re-enable Extra.")
    }

    func testTheWholeFirstSliderDragOnlyEndsExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        controller.beginLevelDrag()
        controller.setLevel(0.3)
        controller.setLevel(0.1)
        controller.setLevel(0.6)
        controller.endLevelDrag()

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4)
        XCTAssertEqual(device.hardware[1], 0.4)
        XCTAssertEqual(device.events, ["boost 1"])

        controller.beginLevelDrag()
        controller.setLevel(0.2)
        controller.setLevel(0.1)
        controller.endLevelDrag()
        XCTAssertEqual(controller.level, 0.1)
        XCTAssertEqual(device.events, ["boost 1", "write 1 0.2", "write 1 0.1"])
    }

    func testClosingTheStripEndsAConsumedDrag() {
        let f = Fixture(), controller = f.controllerWithExtra()
        controller.beginLevelDrag()
        controller.setLevel(0.2)
        controller.endInteraction()
        controller.beginInteraction()
        controller.setLevel(0.2)

        XCTAssertEqual(controller.level, 0.2)
    }

    func testAccessibilityDecreaseAtZeroOnlyEndsExtra() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.hardware[1] = 0
        controller.refresh()
        controller.setExtra(true)

        controller.setLevel(-BrightnessCapsuleSlider.accessibilityStep)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testUnchangedAndIncreasedSliderLevelsKeepExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.setLevel(0.4)
        controller.setLevel(0.7)

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.7)
        XCTAssertEqual(device.boosts.first?.isClosed, false)
    }

    func testOutsideDecreaseKeepsExtraWithTheStripClosed() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        controller.endInteraction()
        XCTAssertTrue(controller.isPolling)

        // Readback cannot tell auto-brightness, power-source dimming and native controls apart.
        device.hardware[1] = 0.25
        controller.refresh()

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.25)
        XCTAssertEqual(device.boosts.first?.isClosed, false)
        XCTAssertTrue(controller.isPolling)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.events, ["boost 1"], "Following macOS must not write the backlight.")

        device.hardware[1] = 0.6
        controller.refresh()
        XCTAssertTrue(controller.isExtraOn)
        controller.setLevel(0.5)
        XCTAssertFalse(controller.isExtraOn, "An explicit slider decrease still ends Extra.")
        XCTAssertEqual(controller.level, 0.6, "The first manual decrease leaves the new backlight alone.")
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testPollingFollowsADecreaseWithoutEndingExtraOrOpeningTheStrip() async {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.refresh()
        controller.setExtra(true)
        let followed = expectation(description: "Extra follows a lower backlight in the background")
        let subscription = controller.$level.dropFirst().filter { $0 == 0.25 }.sink { _ in followed.fulfill() }
        defer {
            subscription.cancel()
            controller.shutdown()
        }

        device.hardware[1] = 0.25
        await fulfillment(of: [followed], timeout: 3)

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.25)
        XCTAssertTrue(controller.isPolling)
        XCTAssertEqual(device.boosts.first?.isClosed, false)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testStaleReadbackAfterAnIncreaseDoesNotEndExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        device.applyWrites = false
        controller.setLevel(0.8)
        controller.refresh()
        XCTAssertTrue(controller.isExtraOn, "The old 0.4 reading is still settling.")

        device.hardware[1] = 0.8
        f.clock.advance(ScreenBrightnessController.writeSettleInterval + 0.1)
        controller.refresh()
        XCTAssertTrue(controller.isExtraOn)

        device.hardware[1] = 0.7
        controller.refresh()
        XCTAssertTrue(controller.isExtraOn, "A subsequent automatic decrease keeps Extra.")
        XCTAssertEqual(controller.level, 0.7)
        controller.setLevel(0.6)
        XCTAssertFalse(controller.isExtraOn, "A subsequent manual decrease still ends Extra.")
        XCTAssertEqual(controller.level, 0.7)
    }

    func testStartingExtraUsesTheCurrentBacklightAsItsBaseline() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.refresh()
        device.hardware[1] = 0.2

        controller.setExtra(true)
        controller.refresh()

        XCTAssertTrue(controller.isExtraOn, "The decrease preceded enabling Extra.")
        XCTAssertEqual(controller.level, 0.2)
        controller.shutdown()
    }

    func testFloatRoundoffDoesNotEndExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        controller.setLevel(0.7)
        device.hardware[1] = Double(Float(0.7))
        f.clock.advance(ScreenBrightnessController.writeSettleInterval + 0.1)
        controller.refresh()

        XCTAssertTrue(controller.isExtraOn)
        controller.setLevel(0.7)
        XCTAssertTrue(controller.isExtraOn)
    }

    func testFirstDecreaseNeedsNoBacklightWriteAndTheNextReportsAWriteFailure() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        device.canWrite = false

        controller.setLevel(0.2)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.events, ["boost 1"])

        controller.setLevel(0.2)
        XCTAssertEqual(controller.level, 0.4)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.writeFailedNotice)
    }

    func testOutsideBacklightIncreasesKeepExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        // An outside increase keeps Extra.
        device.hardware[1] = 0.5
        controller.refresh()

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.5)
        XCTAssertEqual(device.boosts.first?.isClosed, false)
        XCTAssertEqual(device.boosts.first?.refreshes, 1, "The boost follows the display on every refresh.")
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testSleepAndASessionSwitchKeepExtra() {
        let f = Fixture()
        f.observesSystem = true
        let device = f.device, controller = f.controllerWithExtra()
        device.hardware[1] = 0.6

        f.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        f.workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        f.workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        f.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertEqual(controller.level, 0.6, "The wake notification reached the controller.")
        XCTAssertTrue(controller.isExtraOn, "Extra never resumes by itself, so sleep must not end it.")
        XCTAssertEqual(device.boosts.first?.isClosed, false)
        XCTAssertEqual(device.events, ["boost 1"])
        controller.shutdown()
    }

    func testClosingTheStripKeepsExtraAndShutdownEndsIt() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.endInteraction()
        XCTAssertTrue(controller.isExtraOn)
        XCTAssertEqual(device.boosts.first?.isClosed, false)

        controller.shutdown()
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testDisplayChangeEndsExtraAndReadsTheNewDisplayImmediately() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.connected.append(ScreenBrightnessDisplay(id: 2, potentialHeadroom: 1))
        device.hardware[2] = 0.7
        controller.beginInteraction()
        controller.setLevel(0.8)
        controller.setExtra(true)

        // Within the settle window of the slider write to display 1.
        f.selected.id = 2
        controller.refresh()

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(controller.display?.id, 2)
        XCTAssertFalse(controller.supportsExtra)
        XCTAssertEqual(controller.level, 0.7, "A write to the old display must not hold the new display's reading.")
        XCTAssertEqual(device.events, ["write 1 0.8", "boost 1"], "Ending Extra writes no backlight.")
    }

    func testDisplayWithoutHeadroomHasNoExtra() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 1)]
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertFalse(controller.supportsExtra)
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.events, [])
    }

    func testThermalPressureBlocksExtraWithoutWrites() {
        let f = Fixture(), device = f.device, controller = f.controller
        f.policy.extraAllowed = false
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.coolingNotice)
        XCTAssertEqual(device.events, [])
    }

    func testStopExtraWithANoticeKeepsTheNotice() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        controller.stopExtra(notice: ScreenBrightnessController.coolingNotice)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.coolingNotice)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testCoolingPausesOnlyAnActiveExtra() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()
        f.policy.extraAllowed = false
        controller.thermalStateDidChange()
        XCTAssertNil(controller.notice, "Nothing is paused while Extra is off.")
        XCTAssertEqual(device.events, [])

        f.policy.extraAllowed = true
        controller.setExtra(true)
        f.policy.extraAllowed = false
        controller.thermalStateDidChange()

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.coolingNotice)
        XCTAssertEqual(device.events, ["boost 1"])
        XCTAssertEqual(controller.level, 0.4)
    }

    // MARK: Failures

    func testUnreadableDisplayIsUnavailableAndNeverWritten() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.hardware = [:]
        controller.beginInteraction()

        controller.setLevel(0.5)
        controller.setExtra(true)

        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.supportsExtra, "No switch next to a slider that cannot work.")
        XCTAssertEqual(controller.level, 0)
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(device.events, [])
    }

    func testNoDisplaysIsUnavailable() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.connected = []
        controller.beginInteraction()

        XCTAssertNil(controller.display)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertFalse(controller.supportsExtra)
    }

    func testFailedWriteShowsANoticeUntilAWriteSucceeds() {
        let f = Fixture(), device = f.device, controller = f.controller
        controller.beginInteraction()

        device.canWrite = false
        controller.setLevel(0.7)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.writeFailedNotice)
        XCTAssertEqual(controller.level, 0.4)

        device.canWrite = true
        controller.setLevel(0.6)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(controller.level, 0.6)
    }

    func testBoostFailureLeavesExtraOffWithANotice() {
        let f = Fixture(), device = f.device, controller = f.controller
        device.canCreateBoost = false
        controller.beginInteraction()

        controller.setExtra(true)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.level, 0.4)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.extraUnavailableNotice)
        XCTAssertEqual(device.events, ["boost-failed 1"])
    }

    func testAnUnavailableBoostEndsExtraWithANotice() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        device.ends[0](.unavailable)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.extraUnavailableNotice)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
        XCTAssertEqual(device.events, ["boost 1"])
    }

    func testAnotherAppAdjustingTheDisplayEndsExtraWithItsNotice() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()

        device.ends[0](.otherApp)

        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.otherAppNotice)
        XCTAssertEqual(device.boosts.first?.isClosed, true)
    }

    func testALateEndFromAClosedBoostKeepsTheNewerExtra() {
        let f = Fixture(), device = f.device, controller = f.controllerWithExtra()
        controller.setExtra(false)
        controller.setExtra(true)

        device.ends[0](.unavailable)

        XCTAssertTrue(controller.isExtraOn)
        XCTAssertNil(controller.notice)
        XCTAssertEqual(device.boosts.count, 2)
        XCTAssertEqual(device.boosts.last?.isClosed, false)
    }

    // MARK: Brightness hold

    func testHoldStartsFromAFreshReadingAndPollsWithTheStripClosed() {
        let f = Fixture(), controller = f.controller
        XCTAssertFalse(controller.isHoldingLevel)
        controller.refresh()
        f.device.hardware[1] = 0.7
        controller.setHoldingLevel(true)
        XCTAssertEqual(controller.level, 0.7)
        XCTAssertTrue(controller.isHoldingLevel)
        XCTAssertTrue(controller.isPolling)
        XCTAssertEqual(f.device.events, [], "Enabling Hold only captures the current level.")
        controller.shutdown()
    }

    func testHoldRestoresAutomaticDecreasesAndIncreasesWithoutRedundantWrites() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        for hardware in [0.3, 0.6] {
            f.device.hardware[1] = hardware
            controller.refresh()
            XCTAssertEqual(f.device.hardware[1], 0.4)
            XCTAssertEqual(controller.level, 0.4)
            f.clock.advance(1)
            controller.refresh()
        }
        XCTAssertEqual(f.device.events, ["write 1 0.4", "write 1 0.4"])
        controller.shutdown()
    }

    func testWhytapAdjustmentsReplaceTheHeldLevelAndUnlockFollowsMacOSAgain() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        controller.setLevel(0.8)
        f.clock.advance(1)
        f.device.hardware[1] = 0.5
        controller.refresh()
        XCTAssertEqual(f.device.hardware[1], 0.8)
        controller.setHoldingLevel(false)
        f.clock.advance(1)
        f.device.hardware[1] = 0.3
        controller.refresh()
        XCTAssertEqual(controller.level, 0.3)
        XCTAssertFalse(controller.isPolling)
        XCTAssertEqual(f.device.events, ["write 1 0.8", "write 1 0.8"])
        controller.shutdown()
    }

    func testHoldKeepsExtrasFirstDecreaseAndThenHoldsTheNewManualLevel() {
        let f = Fixture(), controller = f.controllerWithExtra()
        controller.setHoldingLevel(true)
        controller.setLevel(0.2)
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertTrue(controller.isHoldingLevel)
        XCTAssertEqual(controller.level, 0.4)
        controller.setLevel(0.2)
        f.clock.advance(1)
        f.device.hardware[1] = 0.1
        controller.refresh()
        XCTAssertEqual(f.device.events, ["boost 1", "write 1 0.2", "write 1 0.2"])
        controller.shutdown()
    }

    func testInterceptedBrightnessKeyUpdatesTheHeldLevel() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        let handler = BrightnessKeyHandler(controller: controller, showStrip: {})
        handler.handle(BrightnessKeyEvent(direction: .up, isDown: true, isRepeat: false, step: .normal),
                       at: f.clock.now)
        let selected = controller.level
        XCTAssertGreaterThan(selected, 0.4)
        f.clock.advance(1)
        f.device.hardware[1] = 0.3
        controller.refresh()
        XCTAssertEqual(f.device.hardware[1], selected)
        XCTAssertTrue(controller.isHoldingLevel)
        controller.shutdown()
    }

    func testHoldIgnoresHardwareQuantizationButRestoresAFineKeyStep() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        f.device.hardware[1] = 0.402
        controller.refresh()
        XCTAssertEqual(f.device.events, [])
        f.device.hardware[1] = 0.4 - 1.0 / 64
        controller.refresh()
        XCTAssertEqual(f.device.events, ["write 1 0.4"])
        controller.shutdown()
    }

    func testHoldSettlesWritesAndStopsAfterRepeatedlyIgnoredCorrections() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        f.device.applyWrites = false
        f.device.hardware[1] = 0.2
        for _ in 0..<ScreenBrightnessController.maximumHoldAttempts {
            controller.refresh()
            let count = f.device.events.count
            controller.refresh()
            XCTAssertEqual(f.device.events.count, count, "No repeated write within the settle window.")
            f.clock.advance(1)
        }
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(f.device.events.count, ScreenBrightnessController.maximumHoldAttempts)
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertFalse(controller.isPolling)
        XCTAssertEqual(controller.level, 0.2)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.holdFailedNotice)
        controller.shutdown()
    }

    func testRejectedCorrectionStopsHoldImmediately() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        f.device.canWrite = false
        f.device.hardware[1] = 0.2
        controller.refresh()
        controller.refresh()
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertEqual(controller.level, 0.2)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.holdFailedNotice)
        XCTAssertEqual(f.device.events, ["write-failed 1 0.4"])
        controller.shutdown()
    }

    func testFailedManualAdjustmentReleasesHoldWithoutRestoringItsOldTarget() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        f.device.canWrite = false
        f.device.hardware[1] = 0.2
        controller.setLevel(0.8)
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertEqual(controller.level, 0.2)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.writeFailedNotice)
        XCTAssertEqual(f.device.events, ["write-failed 1 0.8"])
        controller.shutdown()
    }

    func testHoldPausesUntilEverySleepAndSessionPauseEnds() {
        let f = Fixture()
        f.observesSystem = true
        let controller = f.controller
        controller.setHoldingLevel(true)
        f.workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        f.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        f.workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        f.device.hardware[1] = 0.1
        XCTAssertFalse(controller.isPolling)
        f.device.hardware[1] = nil
        controller.refresh()
        controller.setLevel(0.8)
        XCTAssertTrue(controller.isHoldingLevel, "Sleeping hardware may temporarily refuse reads.")
        f.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        f.workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(f.device.events, [])
        f.device.hardware[1] = 0.1
        f.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertTrue(controller.isHoldingLevel)
        XCTAssertTrue(controller.isPolling)
        XCTAssertEqual(f.device.events, ["write 1 0.4"])
        controller.shutdown()
    }

    func testHoldNeverWritesToASleepingDisplayEvenWithoutANotification() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        f.policy.displayAwake = false
        f.device.hardware[1] = 0
        controller.refresh()
        XCTAssertEqual(f.device.events, [])
        f.policy.displayAwake = true
        controller.refresh()
        XCTAssertEqual(f.device.events, ["write 1 0.4"])
        controller.shutdown()
    }

    func testHeatStopsHoldAndExtraWithoutAutomaticResumption() {
        let f = Fixture(), controller = f.controllerWithExtra()
        controller.setHoldingLevel(true)
        f.policy.extraAllowed = false
        f.device.hardware[1] = 0.2
        controller.refresh()
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertFalse(controller.isExtraOn)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.holdCoolingNotice)
        f.policy.extraAllowed = true
        controller.refresh()
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertEqual(f.device.events, ["boost 1"])
        controller.shutdown()
    }

    func testHoldCannotStartOnAnUnavailableHotOrSleepingDisplay() {
        let f = Fixture(), controller = f.controller
        f.device.hardware = [:]
        controller.setHoldingLevel(true)
        XCTAssertFalse(controller.isHoldingLevel)
        f.device.hardware[1] = 0.4
        f.policy.extraAllowed = false
        controller.setHoldingLevel(true)
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertEqual(controller.notice, ScreenBrightnessController.holdCoolingNotice)
        f.policy.extraAllowed = true
        f.policy.displayAwake = false
        controller.setHoldingLevel(true)
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertEqual(f.device.events, [])
        controller.shutdown()
    }

    func testHoldEndsOnDisplaySwitchOrLostReadbackAndNeverTransfersTheTarget() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        f.device.connected.append(ScreenBrightnessDisplay(id: 2, potentialHeadroom: 1))
        f.device.hardware[2] = 0.7
        f.selected.id = 2
        controller.refresh()
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertEqual(controller.level, 0.7)
        controller.setHoldingLevel(true)
        XCTAssertTrue(controller.isHoldingLevel, "SDR displays can hold without Extra.")
        f.device.hardware[2] = .nan
        controller.refresh()
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertFalse(controller.isAvailable)
        XCTAssertEqual(f.device.events, [])
        controller.shutdown()
    }

    func testShutdownReleasesHoldWithoutRestoringOrPersistingALevel() {
        let f = Fixture(), controller = f.controller
        controller.setHoldingLevel(true)
        controller.shutdown()
        XCTAssertFalse(controller.isHoldingLevel)
        XCTAssertFalse(controller.isPolling)
        XCTAssertEqual(f.device.events, [])
        XCTAssertFalse(Fixture().controller.isHoldingLevel)
    }

    // MARK: Scale

    func testScaleClampsLevels() {
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(0.3), 0.3)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(-1), 0)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(2), 1)
        XCTAssertEqual(ScreenBrightnessScale.clampedLevel(.nan), 0)

        XCTAssertFalse(ScreenBrightnessDisplay(id: 1, potentialHeadroom: 1).supportsExtra)
        XCTAssertFalse(ScreenBrightnessDisplay(id: 1, potentialHeadroom: 1.005).supportsExtra)
        XCTAssertTrue(ScreenBrightnessDisplay(id: 1, potentialHeadroom: 1.6).supportsExtra)
    }
}

/// Display 1 at 40% with XDR headroom; display selection, clock and thermal policy are adjustable.
@MainActor
private final class Fixture {
    let device = FakeBrightnessDevice()
    let clock = TestClock()
    let selected = SelectedDisplay()
    let policy = ExtraPolicy()
    /// With `observesSystem`, notifications reach the controller only from these private centers.
    let center = NotificationCenter()
    let workspace = NotificationCenter()
    var observesSystem = false

    lazy var controller: ScreenBrightnessController = {
        let clock = clock, selected = selected, policy = policy
        return ScreenBrightnessController(device: device, selectedDisplayID: { selected.id },
                                          observeSystem: observesSystem, center: center, workspaceCenter: workspace,
                                          extraAllowed: { policy.extraAllowed }, now: { clock.now },
                                          isDisplayAwake: { _ in policy.displayAwake })
    }()

    /// The strip is open with Extra on.
    func controllerWithExtra() -> ScreenBrightnessController {
        controller.beginInteraction()
        controller.setExtra(true)
        return controller
    }
}

@MainActor
private final class FakeBrightnessDevice: ScreenBrightnessDevice {
    var connected = [ScreenBrightnessDisplay(id: 1, potentialHeadroom: 16)]
    var hardware: [CGDirectDisplayID: Double] = [1: 0.4]
    var canWrite = true
    var canCreateBoost = true
    /// A real panel can report the previous level for a moment after a write.
    var applyWrites = true
    private(set) var events: [String] = []
    private(set) var boosts: [FakeBrightnessBoost] = []
    private(set) var ends: [(BrightnessBoostEnd) -> Void] = []

    func displays() -> [ScreenBrightnessDisplay] { connected }

    func read(_ id: CGDirectDisplayID) -> Double? { hardware[id] }

    func write(_ level: Double, to id: CGDirectDisplayID) -> Bool {
        guard canWrite, hardware[id] != nil else {
            events.append("write-failed \(id) \(level)")
            return false
        }
        events.append("write \(id) \(level)")
        if applyWrites { hardware[id] = level }
        return true
    }

    func makeBoost(for id: CGDirectDisplayID, onEnd: @escaping (BrightnessBoostEnd) -> Void) -> BrightnessBoost? {
        guard canCreateBoost else {
            events.append("boost-failed \(id)")
            return nil
        }
        events.append("boost \(id)")
        let boost = FakeBrightnessBoost()
        boosts.append(boost)
        ends.append(onEnd)
        return boost
    }
}

@MainActor
private final class FakeBrightnessBoost: BrightnessBoost {
    private(set) var refreshes = 0
    private(set) var isClosed = false

    func refresh() { refreshes += 1 }
    func close() { isClosed = true }
}

private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

private final class SelectedDisplay {
    var id: CGDirectDisplayID? = 1
}

private final class ExtraPolicy {
    var extraAllowed = true
    var displayAwake = true
}

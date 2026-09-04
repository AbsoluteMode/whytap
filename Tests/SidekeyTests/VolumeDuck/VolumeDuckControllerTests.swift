import XCTest
@testable import Sidekey

@MainActor
final class VolumeDuckControllerTests: XCTestCase {
    private struct FadeCall: Equatable {
        let from: Float
        let to: Float
        let duration: TimeInterval
        let deviceID: UInt32
    }

    private final class Spy {
        var fades: [FadeCall] = []
        var cancels = 0
        var output: OutputDeviceVolume? = OutputDeviceVolume(deviceID: 42, isDuckable: true, volume: 0.8)
        /// Mirrors `VolumeFader.active`: target + device of an in-flight fade.
        var activeFade: (Float, UInt32)?
    }

    private func make(
        toggle: @escaping () -> Bool = { true },
        spy: Spy
    ) -> VolumeDuckController {
        VolumeDuckController(
            toggleEnabled: toggle,
            readOutput: { spy.output },
            fade: { from, to, dur, device in
                spy.fades.append(FadeCall(from: from, to: to, duration: dur, deviceID: device))
            },
            activeFade: { spy.activeFade },
            cancelFade: { spy.cancels += 1 },
            duckFactor: 0.35,
            fadeDownDuration: 1.2,
            fadeUpDuration: 1.0
        )
    }

    func test_ducksDownOnRecordingStart_onBuiltInOutput() {
        let spy = Spy()
        make(spy: spy).update(recording: true)
        XCTAssertEqual(spy.fades.count, 1)
        XCTAssertEqual(spy.fades[0].from, 0.8, accuracy: 0.0001)
        XCTAssertEqual(spy.fades[0].to, 0.28, accuracy: 0.0001)   // 0.8 * 0.35
        XCTAssertEqual(spy.fades[0].duration, 1.2, accuracy: 0.0001)
        XCTAssertEqual(spy.fades[0].deviceID, 42)                 // pinned to the ducked device
    }

    func test_restoresToSavedLevelOnEnd_onSameDevice() {
        let spy = Spy()
        let c = make(spy: spy)
        c.update(recording: true)     // save 0.8, fade down
        // Fade settled at the ducked level; same default device.
        spy.output = OutputDeviceVolume(deviceID: 42, isDuckable: true, volume: 0.28)
        c.update(recording: false)    // restore
        XCTAssertEqual(spy.fades.count, 2)
        XCTAssertEqual(spy.fades[1].from, 0.28, accuracy: 0.0001)
        XCTAssertEqual(spy.fades[1].to, 0.8, accuracy: 0.0001)    // back to saved
        XCTAssertEqual(spy.fades[1].duration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(spy.fades[1].deviceID, 42)                 // pinned to the same device
    }

    func test_doesNotDuck_whenToggleOff() {
        let spy = Spy()
        make(toggle: { false }, spy: spy).update(recording: true)
        XCTAssertTrue(spy.fades.isEmpty)
    }

    func test_doesNotDuck_whenOutputUnreadable() {
        let spy = Spy(); spy.output = nil   // no default device / no settable scalar
        make(spy: spy).update(recording: true)
        XCTAssertTrue(spy.fades.isEmpty)
    }

    func test_doesNotDuck_onExternalOutput() {
        // Wired external DACs audibly click on hardware-gain writes — ducking
        // must not touch any transport `VolumeDuckTransportPolicy` refuses.
        let spy = Spy()
        spy.output = OutputDeviceVolume(deviceID: 42, isDuckable: false, volume: 0.8)
        make(spy: spy).update(recording: true)
        XCTAssertTrue(spy.fades.isEmpty)
    }

    func test_reDuckDuringRestore_keepsOriginalBaseline() {
        // End -> restore fade toward 0.8 is in flight -> a new recording starts
        // before it finishes. The new duck must adopt the ORIGINAL baseline
        // (the restore target), not the mid-fade level, or repeated quick
        // drops ratchet the volume down.
        let spy = Spy()
        let c = make(spy: spy)
        c.update(recording: true)                                             // baseline 0.8
        spy.output = OutputDeviceVolume(deviceID: 42, isDuckable: true, volume: 0.28)
        c.update(recording: false)                                            // restore starts
        spy.activeFade = (0.8, 42)                                            // restore still running
        spy.output = OutputDeviceVolume(deviceID: 42, isDuckable: true, volume: 0.5)
        c.update(recording: true)                                             // re-duck mid-restore
        XCTAssertEqual(spy.fades.count, 3)
        XCTAssertEqual(spy.fades[2].from, 0.5, accuracy: 0.0001)   // fade starts where volume is now
        XCTAssertEqual(spy.fades[2].to, 0.28, accuracy: 0.0001)    // 0.8 * 0.35 — from the true baseline

        // And the restore after it goes back to the ORIGINAL level.
        spy.activeFade = nil
        spy.output = OutputDeviceVolume(deviceID: 42, isDuckable: true, volume: 0.28)
        c.update(recording: false)
        XCTAssertEqual(spy.fades.count, 4)
        XCTAssertEqual(spy.fades[3].to, 0.8, accuracy: 0.0001)
    }

    func test_reDuckDuringRestore_onOtherDevice_usesCurrentVolume() {
        // A leftover fade on a DIFFERENT device must not donate its target:
        // the baseline for a new duck is the current level of the device
        // actually being ducked.
        let spy = Spy()
        let c = make(spy: spy)
        spy.activeFade = (0.9, 99)                                            // stale fade on another device
        spy.output = OutputDeviceVolume(deviceID: 42, isDuckable: true, volume: 0.6)
        c.update(recording: true)
        XCTAssertEqual(spy.fades.count, 1)
        XCTAssertEqual(spy.fades[0].to, 0.21, accuracy: 0.0001)    // 0.6 * 0.35, not 0.9-based
    }

    func test_skipsRestore_whenDefaultDeviceChangedMidRecording_andCancelsFade() {
        let spy = Spy()
        let c = make(spy: spy)
        c.update(recording: true)     // ducked device 42
        // User switched the default output to another device mid-recording:
        // a level captured on one device must never be written to another,
        // and the in-flight fade must stop rather than keep writing.
        spy.output = OutputDeviceVolume(deviceID: 99, isDuckable: false, volume: 0.6)
        c.update(recording: false)
        XCTAssertEqual(spy.fades.count, 1)   // only the duck-down, no restore
        XCTAssertEqual(spy.cancels, 1)

        // The outstanding-duck state is cleared: a later recording on a
        // built-in output ducks fresh instead of being wedged.
        spy.output = OutputDeviceVolume(deviceID: 7, isDuckable: true, volume: 0.5)
        c.update(recording: true)
        XCTAssertEqual(spy.fades.count, 2)
        XCTAssertEqual(spy.fades[1].from, 0.5, accuracy: 0.0001)
    }

    func test_skipsRestore_whenOutputUnreadableAtEnd_andCancelsFade() {
        let spy = Spy()
        let c = make(spy: spy)
        c.update(recording: true)
        spy.output = nil              // device identity unknown at restore time
        c.update(recording: false)
        XCTAssertEqual(spy.fades.count, 1)   // fail-safe: no blind write
        XCTAssertEqual(spy.cancels, 1)

        // State cleared — the next recording ducks fresh.
        spy.output = OutputDeviceVolume(deviceID: 42, isDuckable: true, volume: 0.8)
        c.update(recording: true)
        XCTAssertEqual(spy.fades.count, 2)
    }

    func test_toggleOffMidRecording_stillRestores() {
        // Flipping the Settings toggle off after the duck engaged must not
        // strand the lowered volume: the outstanding restore still runs.
        let spy = Spy()
        var enabled = true
        let c = make(toggle: { enabled }, spy: spy)
        c.update(recording: true)
        enabled = false
        spy.output = OutputDeviceVolume(deviceID: 42, isDuckable: true, volume: 0.28)
        c.update(recording: false)
        XCTAssertEqual(spy.fades.count, 2)
        XCTAssertEqual(spy.fades[1].to, 0.8, accuracy: 0.0001)
    }

    func test_duckIsIdempotentWithinOneRecording() {
        let spy = Spy()
        let c = make(spy: spy)
        c.update(recording: true)
        c.update(recording: true)
        XCTAssertEqual(spy.fades.count, 1)
    }

    func test_doesNotRestore_ifNeverDucked() {
        let spy = Spy()
        make(spy: spy).update(recording: false)
        XCTAssertTrue(spy.fades.isEmpty)
        XCTAssertEqual(spy.cancels, 0)
    }
}

import XCTest
@testable import Sidekey

@MainActor
final class VolumeFaderTests: XCTestCase {
    private final class WriteSpy {
        var calls: [(value: Float, deviceID: UInt32)] = []
    }

    private func make(_ spy: WriteSpy) -> VolumeFader {
        VolumeFader(write: { value, device in spy.calls.append((value, device)) })
    }

    func test_fadeDoesNotWriteSynchronouslyOnStart() {
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.3, to: 0.8, duration: 0.2, on: 42)
        // Writes belong to the timer ticks (the first lands within one ~60 fps
        // frame anyway); an extra synchronous write at call time is one more
        // hardware-gain command than needed.
        XCTAssertTrue(spy.calls.isEmpty)
        fader.cancel()
    }

    func test_allWritesCarryThePinnedDevice() {
        // The fade writes the device it started on, never whatever the default
        // output happens to be mid-fade — switching outputs during the ~1 s
        // window must not redirect gain writes onto an external DAC.
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.2, to: 0.8, duration: 0.1, on: 42)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(spy.calls.isEmpty)
        XCTAssertTrue(spy.calls.allSatisfy { $0.deviceID == 42 })
    }

    func test_positiveDurationFadeLandsExactlyOnTarget() {
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.3, to: 0.8, duration: 0.05, on: 42)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(spy.calls.last?.value, 0.8)   // exact target, not a ramp sample
    }

    func test_equalEndpointsFadeWritesAtMostOnce() {
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.5, to: 0.5, duration: 0.1, on: 42)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        // Every ramp sample equals the last sent value — near-equal writes are
        // suppressed, so a no-op fade must not stream ~60 writes/s.
        XCTAssertLessThanOrEqual(spy.calls.count, 1)
        fader.cancel()
    }

    func test_subQuantumEndpointsCollapseToFewWrites() {
        // Distinct endpoints closer than the write quantum (<0.004): the ~9
        // intermediate ticks all dedupe; only the first write and the forced
        // exact-target write may land.
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.5, to: 0.502, duration: 0.15, on: 42)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertLessThanOrEqual(spy.calls.count, 3)
        XCTAssertEqual(spy.calls.last?.value, 0.502)
    }

    func test_zeroDurationFadeSnapsToTarget() {
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.2, to: 0.9, duration: 0, on: 7)
        XCTAssertEqual(spy.calls.count, 1)
        XCTAssertEqual(spy.calls[0].value, 0.9)
        XCTAssertEqual(spy.calls[0].deviceID, 7)
        fader.cancel()
    }

    func test_activeExposesTargetAndDevice_untilCancelled() {
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.3, to: 0.8, duration: 0.2, on: 42)
        XCTAssertEqual(fader.active?.target, 0.8)
        XCTAssertEqual(fader.active?.deviceID, 42)
        fader.cancel()
        XCTAssertNil(fader.active)
    }

    func test_activeClearsOnCompletion() {
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.3, to: 0.8, duration: 0.05, on: 42)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertNil(fader.active)
    }

    func test_cancelStopsAllFurtherWrites() {
        let spy = WriteSpy()
        let fader = make(spy)
        fader.fade(from: 0.2, to: 0.8, duration: 0.2, on: 42)
        fader.cancel()   // before the first ~16 ms tick fires
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(spy.calls.isEmpty)
    }
}

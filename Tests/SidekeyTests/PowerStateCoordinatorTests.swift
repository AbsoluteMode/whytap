import XCTest
@testable import Sidekey

/// Tests the wake/sleep state machine. The bug under test:
///
/// > User's MacBook went to sleep due to inactivity, and on wake Sidekey
/// > took ~30s to respond — hotkeys and the agent gesture were dead until
/// > the system "caught up".
///
/// Root cause categories the coordinator must handle:
///
/// 1. **Symmetric sleep/wake** — `willSleepNotification` fires, then
///    `didWakeNotification` fires. Coordinator must produce a full
///    re-arm intent on wake.
/// 2. **Wake without preceding will-sleep** — some macOS sleep modes
///    (display-only sleep, dark sleep, suspend without app warning) fire
///    `didWakeNotification` but **do not** fire `willSleepNotification`
///    first. The pre-existing implementation early-exited in this case,
///    leaving stale Carbon hotkey + NSEvent monitor handles. Coordinator
///    must still produce a re-arm intent so monitors get reinstalled.
/// 3. **Double events** — macOS occasionally posts duplicate wake or
///    sleep notifications during the same power transition. Coordinator
///    must be idempotent (one re-arm per wake transition).
///
/// The coordinator is intentionally a pure-logic state machine with
/// injectable clock + dispatch seams so we can test it without standing
/// up `NSWorkspace` or `NSApplication`.
final class PowerStateCoordinatorTests: XCTestCase {
    private final class Recorder {
        var pauseCalls: Int = 0
        var rearmCalls: Int = 0
        var lastRearmReason: PowerStateCoordinator.WakeReason?

        func onPause() {
            pauseCalls += 1
        }

        func onRearm(reason: PowerStateCoordinator.WakeReason) {
            rearmCalls += 1
            lastRearmReason = reason
        }
    }

    // MARK: - Symmetric sleep/wake

    func testWillSleepInvokesPauseOnce() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)

        coordinator.handleWillSleep()

        XCTAssertEqual(recorder.pauseCalls, 1)
        XCTAssertEqual(coordinator.isPausedForSleep, true)
    }

    func testDidWakeAfterWillSleepInvokesRearmWithFullReason() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)

        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        XCTAssertEqual(recorder.rearmCalls, 1)
        XCTAssertEqual(recorder.lastRearmReason, .full)
        XCTAssertEqual(coordinator.isPausedForSleep, false)
    }

    // MARK: - Wake without preceding will-sleep (the actual bug)

    func testDidWakeWithoutWillSleepStillInvokesRearmWithSoftReason() {
        // This is the load-bearing test for the user-reported bug.
        // Some macOS sleep modes do not fire `willSleepNotification`
        // but still kill our Carbon hotkey + NSEvent registrations.
        // The previous implementation early-exited here, leaving the
        // app deaf. The fix is to always re-arm critical monitors on
        // wake, with a "soft" reason indicating no preceding pause —
        // callers can use this to skip heavy work (e.g. full
        // BackgroundLuminanceObserver restart) when it isn't needed.
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)

        coordinator.handleDidWake()

        XCTAssertEqual(recorder.pauseCalls, 0)
        XCTAssertEqual(recorder.rearmCalls, 1)
        XCTAssertEqual(recorder.lastRearmReason, .soft)
        XCTAssertEqual(coordinator.isPausedForSleep, false)
    }

    // MARK: - Idempotence

    func testDoubleWillSleepInvokesPauseOnce() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)

        coordinator.handleWillSleep()
        coordinator.handleWillSleep()
        coordinator.handleWillSleep()

        XCTAssertEqual(recorder.pauseCalls, 1)
    }

    func testDoubleDidWakeInvokesRearmOnce() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        coordinator.handleDidWake()
        coordinator.handleDidWake()

        XCTAssertEqual(recorder.rearmCalls, 1)
    }

    func testDoubleSoftWakeInvokesRearmOnce() {
        // Even without a preceding sleep, two rapid wake notifications
        // (macOS sometimes posts both `didWake` and `screensDidWake`
        // back-to-back) must produce a single re-arm.
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)

        coordinator.handleDidWake()
        coordinator.handleDidWake()

        XCTAssertEqual(recorder.rearmCalls, 1)
        XCTAssertEqual(recorder.lastRearmReason, .soft)
    }

    // MARK: - Multiple full cycles

    func testMultipleSleepWakeCyclesEachInvokeRearm() {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)

        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        coordinator.handleWillSleep()
        coordinator.handleDidWake()
        coordinator.handleWillSleep()
        coordinator.handleDidWake()

        XCTAssertEqual(recorder.pauseCalls, 3)
        XCTAssertEqual(recorder.rearmCalls, 3)
        XCTAssertEqual(recorder.lastRearmReason, .full)
    }

    // MARK: - Soft re-arm window

    func testSoftWakeAfterDoubleWakeWindowResets() {
        // After a soft wake completes, a subsequent fresh `didWake`
        // should re-arm again (the OS may kill registrations on every
        // sleep cycle, even partial ones).
        let recorder = Recorder()
        let coordinator = makeCoordinator(
            recorder: recorder,
            softWakeDebounceSeconds: 0.05
        )

        coordinator.handleDidWake()
        XCTAssertEqual(recorder.rearmCalls, 1)

        // Same wake transition (within debounce): no extra re-arm.
        coordinator.handleDidWake()
        XCTAssertEqual(recorder.rearmCalls, 1)

        // After debounce, treat as a new transition.
        let waited = XCTestExpectation(description: "debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waited.fulfill()
        }
        wait(for: [waited], timeout: 1.0)

        coordinator.handleDidWake()
        XCTAssertEqual(recorder.rearmCalls, 2)
    }

    // MARK: - Helpers

    private func makeCoordinator(
        recorder: Recorder,
        softWakeDebounceSeconds: TimeInterval = 2.0
    ) -> PowerStateCoordinator {
        PowerStateCoordinator(
            softWakeDebounceSeconds: softWakeDebounceSeconds,
            now: { Date() },
            onPause: { recorder.onPause() },
            onRearm: { reason in recorder.onRearm(reason: reason) }
        )
    }
}

import XCTest
@testable import Sidekey

final class AudioCaptureRestartMonitorTests: XCTestCase {
    func test_trigger_while_active_schedules_restart() async {
        let recorder = RestartRecorder()
        let monitor = AudioCaptureRestartMonitor(debounceNanoseconds: 1_000_000) {
            await recorder.record()
        }

        monitor.setActive(true)
        monitor.trigger()

        await waitForCount(1, recorder: recorder)
        let count = await recorder.snapshot()
        XCTAssertEqual(count, 1)
    }

    func test_trigger_while_inactive_is_ignored() async {
        let recorder = RestartRecorder()
        let monitor = AudioCaptureRestartMonitor(debounceNanoseconds: 1_000_000) {
            await recorder.record()
        }

        monitor.trigger()

        try? await Task.sleep(nanoseconds: 50_000_000)
        let count = await recorder.snapshot()
        XCTAssertEqual(count, 0)
    }

    func test_deactivating_cancels_pending_restart() async {
        let recorder = RestartRecorder()
        let monitor = AudioCaptureRestartMonitor(debounceNanoseconds: 100_000_000) {
            await recorder.record()
        }

        monitor.setActive(true)
        monitor.trigger()
        monitor.setActive(false)

        try? await Task.sleep(nanoseconds: 150_000_000)
        let count = await recorder.snapshot()
        XCTAssertEqual(count, 0)
    }

    func test_rapid_triggers_coalesce_to_one_restart() async {
        let recorder = RestartRecorder()
        let monitor = AudioCaptureRestartMonitor(debounceNanoseconds: 20_000_000) {
            await recorder.record()
        }

        monitor.setActive(true)
        monitor.trigger()
        try? await Task.sleep(nanoseconds: 5_000_000)
        monitor.trigger()
        try? await Task.sleep(nanoseconds: 5_000_000)
        monitor.trigger()

        await waitForCount(1, recorder: recorder)
        try? await Task.sleep(nanoseconds: 60_000_000)
        let count = await recorder.snapshot()
        XCTAssertEqual(count, 1)
    }

    private func waitForCount(
        _ expected: Int,
        recorder: RestartRecorder,
        timeout: TimeInterval = 1.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await recorder.snapshot() == expected {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor RestartRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func snapshot() -> Int {
        count
    }
}

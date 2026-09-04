import XCTest
@testable import Sidekey

/// Regression: the manual Meeting-record hotkey (⌥M) and the five positional
/// Hover-slot hotkeys (⌥1..⌥5) went DEAF after sleep/wake and after an
/// Accessibility re-grant, and only came back if the user re-recorded the
/// shortcut in Settings.
///
/// Root cause: all three "resurrect the monitors" paths in `AppDelegate`
/// (`forceReregisterEventMonitors` on a soft wake, `pauseRuntimeForSleep` on a
/// full-wake teardown, and the `onAccessibilityLost` repair closure) nilled
/// only `hotkey` / `helpHotkey` / `historyHotkey`. The Meeting-record and
/// Hover-slot Carbon registrations — which the kernel silently invalidates on
/// wake exactly like Drop — kept a live-but-dead ref, so the idempotency
/// guards in `registerMeetingRecordHotkey()` (`guard meetingRecordHotkey == nil`)
/// and `registerHoverSlotHotkeys()` (`guard hoverSlotHotkeys.isEmpty`)
/// early-returned and never rebuilt them.
///
/// The fix funnels every rebuild path through a single teardown seam that
/// stops AND clears the whole monitor set (Drop / Help / History / Meeting /
/// Hover). These tests pin that seam: the teardown must `stop()` the
/// Meeting-record monitor and every Hover-slot monitor, not just the Drop
/// trio. Before the fix the seam did not exist / did not include them, so a
/// meeting/hover monitor handed in here would survive the teardown untouched.
@MainActor
final class MeetingHotkeyRearmTests: XCTestCase {

    /// Records `stop()` invocations so the test can assert a monitor was torn
    /// down without touching real Carbon / Input Monitoring (`start()` would).
    private final class SpyMonitor: HotkeyShortcutMonitoring {
        private(set) var stopCount = 0
        func start() throws {}
        func stop() { stopCount += 1 }
    }

    func test_teardown_stops_meeting_record_monitor() {
        let drop = SpyMonitor()
        let meeting = SpyMonitor()

        AppDelegate.teardownHotkeyMonitorsForRebuild([drop, meeting])

        XCTAssertEqual(
            meeting.stopCount, 1,
            "The Meeting-record (⌥M) monitor must be stopped by the rebuild teardown — otherwise its ref stays live and registerMeetingRecordHotkey() early-returns on wake."
        )
        XCTAssertEqual(drop.stopCount, 1, "Drop must still be stopped by the same teardown.")
    }

    func test_teardown_stops_every_hover_slot_monitor() {
        let hoverSlots = (0..<5).map { _ in SpyMonitor() }

        AppDelegate.teardownHotkeyMonitorsForRebuild(hoverSlots)

        for (index, slot) in hoverSlots.enumerated() {
            XCTAssertEqual(
                slot.stopCount, 1,
                "Hover slot \(index + 1) (⌥\(index + 1)) monitor must be stopped by the rebuild teardown so registerHoverSlotHotkeys() rebuilds it on wake."
            )
        }
    }

    /// The teardown must tolerate the launch/soft-wake reality that some
    /// monitors are absent (`nil`) — e.g. Drop failed to register, or Hover
    /// slots were never installed. A nil handle is skipped, live ones stop.
    func test_teardown_tolerates_nil_and_mixed_handles() {
        let meeting = SpyMonitor()
        let handles: [HotkeyShortcutMonitoring?] = [nil, meeting, nil]

        AppDelegate.teardownHotkeyMonitorsForRebuild(handles)

        XCTAssertEqual(meeting.stopCount, 1)
    }
}

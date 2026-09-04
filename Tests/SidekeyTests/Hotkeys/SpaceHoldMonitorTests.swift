import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Sidekey

/// `SpaceHoldMonitor` is the Stage 3 glue that drives the pure
/// `SpaceHoldDetector` FSM from a real `CGEventTap`, performing the side
/// effects the FSM only describes: swallow/passthrough the keystroke, run the
/// AX editable check off the tap callback, synthesize Backspace deletions, and
/// fire the Drop start/stop/cancel callbacks.
///
/// These tests exercise the monitor through INJECTED dependencies only — no
/// real `CGEventTap`, no real run-loop timer, no real Accessibility query and
/// no real keystroke synthesis. The monitor exposes a synchronous
/// `handleTapEvent(type:keyCode:isRepeat:)` entry point (the same one the
/// production tap callback calls) plus test-driven hooks to fire the threshold
/// timer and deliver the AX verdict, mirroring how `CarbonHotkeyMonitor`
/// exposes `handleHotKeyEvent()` for unit tests.
final class SpaceHoldMonitorTests: XCTestCase {

    // MARK: - Test doubles

    /// Records every synthesized key event so a test can assert the exact
    /// Backspace down/up sequence without posting real CGEvents.
    private final class PostEventRecorder {
        private(set) var events: [(keyCode: CGKeyCode, down: Bool)] = []
        func post(_ keyCode: CGKeyCode, _ down: Bool) {
            events.append((keyCode, down))
        }
        /// Count of full down+up Backspace pairs (each leaked space = one pair).
        var backspacePairs: Int {
            let deletes = events.filter { $0.keyCode == CGKeyCode(kVK_Delete) }
            let downs = deletes.filter { $0.down }.count
            let ups = deletes.filter { !$0.down }.count
            XCTAssertEqual(downs, ups, "every Backspace down should have a matching up")
            return downs
        }
    }

    /// Captures tap-enable toggles so a test can assert the monitor re-enables
    /// the tap after a `tapDisabledByTimeout` / `tapDisabledByUserInput` event.
    private final class EnableRecorder {
        private(set) var enableCalls: [Bool] = []
        func enable(_ on: Bool) { enableCalls.append(on) }
    }

    /// Builds a monitor wired entirely to injected closures. By default the AX
    /// check returns `true` (editable field) and the tap factory succeeds.
    private func makeMonitor(
        editable: Bool = true,
        tapFactorySucceeds: Bool = true,
        post: PostEventRecorder = PostEventRecorder(),
        enabler: EnableRecorder = EnableRecorder(),
        onHotkey: @escaping () -> Void = {},
        onHotkeyReleased: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {},
        accessibilityTrusted: @escaping () -> Bool = { true },
        onAccessibilityLost: @escaping () -> Void = {}
    ) -> SpaceHoldMonitor {
        SpaceHoldMonitor(
            onHotkey: onHotkey,
            onHotkeyReleased: onHotkeyReleased,
            onCancel: onCancel,
            makeTap: { _ in tapFactorySucceeds ? OpaquePointer(bitPattern: 0x1) : nil },
            enableTap: { on in enabler.enable(on) },
            scheduleThreshold: { _ in /* test fires manually via fireThreshold() */ },
            cancelThreshold: {},
            frontmostApp: { (pid_t(1234), "com.example.app") },
            isEditable: { _, _ in editable },
            postEvent: { code, down in post.post(code, down) },
            runOnDetectorQueue: { work in work() },
            runEditableCheckOffTapThread: { work in work() },   // inline = synchronous
            dispatchCallback: { work in work() },                // inline = synchronous
            log: { _, _ in },
            accessibilityTrusted: accessibilityTrusted,
            onAccessibilityLost: onAccessibilityLost
        )
    }

    private func down(_ keyCode: Int, isRepeat: Bool = false) -> (type: CGEventType, code: CGKeyCode, rep: Bool) {
        (.keyDown, CGKeyCode(keyCode), isRepeat)
    }
    private func up(_ keyCode: Int) -> (type: CGEventType, code: CGKeyCode, rep: Bool) {
        (.keyUp, CGKeyCode(keyCode), false)
    }

    // MARK: - Hold → editable → arm + delete leaked spaces + start recording

    func test_hold_editable_with_three_leaks_deletes_three_and_starts_recording() {
        let post = PostEventRecorder()
        var hotkeyCalls = 0
        let monitor = makeMonitor(
            editable: true,
            post: post,
            onHotkey: { hotkeyCalls += 1 }
        )

        // keyDown (leaked=1) + 2 repeats (leaked=3), all passed through.
        XCTAssertEqual(monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false), .passThrough)
        XCTAssertEqual(monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: true), .passThrough)
        XCTAssertEqual(monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: true), .passThrough)

        // Threshold elapses → monitor runs the AX check (editable=true) and arms.
        monitor.fireThreshold()

        XCTAssertEqual(post.backspacePairs, 3, "should delete exactly the 3 leaked spaces")
        XCTAssertEqual(hotkeyCalls, 1, "arming starts recording exactly once")

        // Subsequent auto-repeat spaces while armed are swallowed.
        XCTAssertEqual(monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: true), .swallow)
        XCTAssertEqual(monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: true), .swallow)
    }

    // MARK: - Synthesized Backspace must NOT be swallowed by our own tap

    /// Regression for the leaked-space deletion bug: while `armed`, the monitor
    /// posts Backspace via `.cghidEventTap`; that synthesized keystroke re-enters
    /// our own `.cgSessionEventTap`. A non-space keyDown in `armed` maps to
    /// `.otherKeyDown` → empty actions → `.swallow`, so the monitor ate its own
    /// Backspace and the leaked space survived. Events we synthesize must be
    /// recognised (tagged) and passed straight through without touching the FSM.
    func test_synthetic_backspace_while_armed_passes_through_not_swallowed() {
        let monitor = makeMonitor(editable: true)

        // Drive to `armed` (one leaked space, threshold elapsed, editable=true).
        _ = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false)
        monitor.fireThreshold()

        // The Backspace WE synthesized comes back through our session tap.
        let down = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Delete), isRepeat: false, isSynthetic: true)
        let up = monitor.handleTapEvent(type: .keyUp, keyCode: CGKeyCode(kVK_Delete), isRepeat: false, isSynthetic: true)

        XCTAssertEqual(down, .passThrough, "our own synthesized Backspace must reach the field, not be swallowed")
        XCTAssertEqual(up, .passThrough, "the synthesized Backspace keyUp must also pass through")

        // The gesture is untouched: a genuine space auto-repeat while still armed
        // is still swallowed (the synthetic event did not reset the FSM).
        XCTAssertEqual(
            monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: true),
            .swallow,
            "a real space auto-repeat while armed is still swallowed after the synthetic passthrough"
        )
    }

    /// A genuine (non-synthetic) space auto-repeat while `armed` must still be
    /// swallowed — the synthetic short-circuit must not loosen the real-event
    /// swallow path.
    func test_real_space_repeat_while_armed_is_still_swallowed() {
        let monitor = makeMonitor(editable: true)

        _ = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false)
        monitor.fireThreshold()

        XCTAssertEqual(
            monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: true, isSynthetic: false),
            .swallow
        )
    }

    // MARK: - Release while armed → stop + transcribe (no cancel)

    func test_key_up_while_armed_stops_and_transcribes() {
        var released = 0
        var cancelled = 0
        let monitor = makeMonitor(
            editable: true,
            onHotkeyReleased: { released += 1 },
            onCancel: { cancelled += 1 }
        )

        _ = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false)
        monitor.fireThreshold()

        let decision = monitor.handleTapEvent(type: .keyUp, keyCode: CGKeyCode(kVK_Space), isRepeat: false)

        XCTAssertEqual(decision, .swallow, "the release that ends the gesture is swallowed")
        XCTAssertEqual(released, 1)
        XCTAssertEqual(cancelled, 0)
    }

    // MARK: - Non-editable focus → no arm, no Backspace, space passes through

    func test_non_editable_focus_does_not_arm_and_passes_space_through() {
        let post = PostEventRecorder()
        var hotkeyCalls = 0
        let monitor = makeMonitor(
            editable: false,
            post: post,
            onHotkey: { hotkeyCalls += 1 }
        )

        let firstDown = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false)
        XCTAssertEqual(firstDown, .passThrough)

        monitor.fireThreshold()   // AX resolves false → cancelPending

        XCTAssertEqual(hotkeyCalls, 0)
        XCTAssertEqual(post.backspacePairs, 0)

        // After cancel, the gesture is reset: a fresh space still passes through.
        XCTAssertEqual(monitor.handleTapEvent(type: .keyUp, keyCode: CGKeyCode(kVK_Space), isRepeat: false), .passThrough)
    }

    // MARK: - Release BEFORE the AX result arrives → arm cancelled

    func test_release_before_ax_result_cancels_arm() {
        // Simulate the AX check resolving AFTER the key is released: defer the
        // off-tap-thread editable work so the monitor sees the keyUp first.
        let post = PostEventRecorder()
        var hotkeyCalls = 0
        var deferredAXWork: (() -> Void)?
        let monitor = SpaceHoldMonitor(
            onHotkey: { hotkeyCalls += 1 },
            onHotkeyReleased: {},
            onCancel: {},
            makeTap: { _ in OpaquePointer(bitPattern: 0x1) },
            enableTap: { _ in },
            scheduleThreshold: { _ in },
            cancelThreshold: {},
            frontmostApp: { (pid_t(1), "com.example.app") },
            isEditable: { _, _ in true },
            postEvent: { code, down in post.post(code, down) },
            runOnDetectorQueue: { work in work() },
            // Capture the AX-resolution work instead of running it inline, to
            // model the result arriving after the release.
            runEditableCheckOffTapThread: { work in deferredAXWork = work },
            dispatchCallback: { work in work() },
            log: { _, _ in }
        )

        _ = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false)
        monitor.fireThreshold()                       // requests AX (captured, not run yet)
        _ = monitor.handleTapEvent(type: .keyUp, keyCode: CGKeyCode(kVK_Space), isRepeat: false)
        deferredAXWork?()                              // late editableResolved(true)

        XCTAssertEqual(hotkeyCalls, 0, "a release before the AX verdict must not arm")
        XCTAssertEqual(post.backspacePairs, 0)
    }

    // MARK: - OS-disabled tap → re-enable

    func test_tap_disabled_with_accessibility_present_reenables() {
        let enabler = EnableRecorder()
        let monitor = makeMonitor(enabler: enabler, accessibilityTrusted: { true })
        let decision = monitor.handleTapEvent(type: .tapDisabledByTimeout, keyCode: 0, isRepeat: false)
        XCTAssertEqual(decision, .passThrough)
        XCTAssertEqual(enabler.enableCalls, [true], "trusted → re-enable")
    }

    func test_tap_disabled_with_accessibility_lost_tears_down_and_signals() {
        let enabler = EnableRecorder()
        var lostCalls = 0
        let monitor = makeMonitor(enabler: enabler, accessibilityTrusted: { false }, onAccessibilityLost: { lostCalls += 1 })
        _ = monitor.handleTapEvent(type: .tapDisabledByUserInput, keyCode: 0, isRepeat: false)
        XCTAssertEqual(enabler.enableCalls, [false], "lost → teardown, NOT re-enable")
        XCTAssertEqual(lostCalls, 1, "lost → surface repair exactly once")
    }

    func test_repeated_reenable_trips_backoff_and_tears_down() {
        let enabler = EnableRecorder()
        var lostCalls = 0
        let monitor = makeMonitor(enabler: enabler, accessibilityTrusted: { true }, onAccessibilityLost: { lostCalls += 1 })
        for _ in 0..<5 { _ = monitor.handleTapEvent(type: .tapDisabledByTimeout, keyCode: 0, isRepeat: false) }
        XCTAssertEqual(enabler.enableCalls, [true, true, true, false], "3 re-enables, then teardown")
        XCTAssertEqual(lostCalls, 1)
    }

    func test_repeated_tap_disabled_while_accessibility_lost_signals_once() {
        let enabler = EnableRecorder()
        var lostCalls = 0
        let monitor = makeMonitor(enabler: enabler, accessibilityTrusted: { false }, onAccessibilityLost: { lostCalls += 1 })
        for _ in 0..<3 { _ = monitor.handleTapEvent(type: .tapDisabledByTimeout, keyCode: 0, isRepeat: false) }
        XCTAssertEqual(enabler.enableCalls, [false], "teardown once, not repeated")
        XCTAssertEqual(lostCalls, 1, "signal repair exactly once")
    }

    // MARK: - Disabled-at-creation → recorded, no crash, retry on next start()

    func test_tap_disabled_at_creation_is_recorded_and_retried() throws {
        var attempts = 0
        let monitor = SpaceHoldMonitor(
            onHotkey: {},
            onHotkeyReleased: {},
            onCancel: {},
            makeTap: { _ in
                attempts += 1
                return attempts < 2 ? nil : OpaquePointer(bitPattern: 0x1)
            },
            enableTap: { _ in },
            scheduleThreshold: { _ in },
            cancelThreshold: {},
            frontmostApp: { nil },
            isEditable: { _, _ in true },
            postEvent: { _, _ in },
            runOnDetectorQueue: { work in work() },
            log: { _, _ in },
            // Accessibility absent → IM fallback does not fire; this test
            // verifies the "uninstalled until next start()" retry path.
            accessibilityTrusted: { false }
        )

        // First start: factory returns nil → must NOT crash, tap not installed.
        XCTAssertNoThrow(try monitor.start())
        XCTAssertFalse(monitor.isTapInstalled)
        XCTAssertEqual(attempts, 1)

        // Second start: factory succeeds → tap installed (retry path).
        XCTAssertNoThrow(try monitor.start())
        XCTAssertTrue(monitor.isTapInstalled)
        XCTAssertEqual(attempts, 2)
    }

    // MARK: - Escape while armed → cancel (discard), no transcribe

    func test_escape_while_armed_cancels_without_transcribe() {
        var released = 0
        var cancelled = 0
        let monitor = makeMonitor(
            editable: true,
            onHotkeyReleased: { released += 1 },
            onCancel: { cancelled += 1 }
        )

        _ = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false)
        monitor.fireThreshold()

        let decision = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Escape), isRepeat: false)

        XCTAssertEqual(decision, .swallow, "Escape that cancels the recording is consumed")
        XCTAssertEqual(cancelled, 1)
        XCTAssertEqual(released, 0)
    }

    // MARK: - Escape OUTSIDE armed is passed through (ordinary Escape)

    func test_escape_outside_armed_passes_through() {
        let monitor = makeMonitor()

        let decision = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Escape), isRepeat: false)

        XCTAssertEqual(decision, .passThrough, "Escape with no recording is an ordinary key")
    }

    // MARK: - Ordinary (non-space) keys pass through by default

    func test_other_key_passes_through() {
        let monitor = makeMonitor()

        let decision = monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_ANSI_A), isRepeat: false)

        XCTAssertEqual(decision, .passThrough)
    }

    // MARK: - Short tap (release before threshold) prints normally, no arm

    func test_short_tap_passes_through_and_does_not_arm() {
        let post = PostEventRecorder()
        var hotkeyCalls = 0
        let monitor = makeMonitor(post: post, onHotkey: { hotkeyCalls += 1 })

        XCTAssertEqual(monitor.handleTapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false), .passThrough)
        XCTAssertEqual(monitor.handleTapEvent(type: .keyUp, keyCode: CGKeyCode(kVK_Space), isRepeat: false), .passThrough)

        XCTAssertEqual(hotkeyCalls, 0)
        XCTAssertEqual(post.backspacePairs, 0)
    }

    // MARK: - Lazy Input Monitoring fallback

    func test_tap_create_fails_with_accessibility_requests_im_once_then_succeeds() {
        var attempts = 0
        var imRequests = 0
        let monitor = SpaceHoldMonitor(
            onHotkey: {}, onHotkeyReleased: {}, onCancel: {},
            makeTap: { _ in attempts += 1; return attempts < 2 ? nil : OpaquePointer(bitPattern: 0x1) },
            enableTap: { _ in }, scheduleThreshold: { _ in }, cancelThreshold: {},
            frontmostApp: { nil }, isEditable: { _, _ in true }, postEvent: { _, _ in },
            runOnDetectorQueue: { $0() }, runEditableCheckOffTapThread: { $0() }, dispatchCallback: { $0() },
            log: { _, _ in },
            accessibilityTrusted: { true }, onAccessibilityLost: {},
            requestInputMonitoring: { imRequests += 1; return true }
        )
        try? monitor.start()
        XCTAssertTrue(monitor.isTapInstalled)
        XCTAssertEqual(imRequests, 1, "IM requested exactly once as fallback")
    }
}

import AppKit
import XCTest
@testable import Sidekey

/// Stage 3 tests for `MeetingPillController` — the NSPanel host + state
/// machine for the meeting suggestion bar. Five tests pinned
/// by the plan's validation gate:
///
/// 1. `test_state_machine_transitions_suggesting_to_hidden_on_dismiss`
/// 2. `test_20s_deadline_emits_dismiss_with_reason_timeout`
/// 3. `test_yes_button_emits_accept_with_buffer_snapshot`
/// 4. `test_no_button_emits_dismiss_with_reason_user`
/// 5. `test_pill_position_top_center_on_active_screen`
///
/// We never spin a real Yes/No button click in XCTest (would require a
/// running RunLoop and key window) — tests poke the controller's
/// internal `_testTapAccept` / `_testTapDismiss` entry points, which are
/// the same code paths the SwiftUI button actions call into.
@MainActor
final class MeetingPillControllerTests: XCTestCase {

    override func tearDown() {
        AppState.shared.meetingSuggestionActive = false
        AppState.shared.meetingSuggestionDeadline = nil
        AppState.shared.clearMeetingRecordingState()
        super.tearDown()
    }

    // MARK: - Stubs

    /// Captures buffer interactions so the Yes-button test can assert
    /// the controller really called `snapshot()` (and not, e.g.,
    /// `gc()` instead).
    final class StubBuffer: MeetingPillBufferAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var _startCalls = 0
        private var _gcCalls = 0
        private var _snapshotCalls = 0
        private var _snapshotReturn: Data = Data([0xDE, 0xAD, 0xBE, 0xEF])

        var startCalls: Int { lock.lock(); defer { lock.unlock() }; return _startCalls }
        var gcCalls: Int { lock.lock(); defer { lock.unlock() }; return _gcCalls }
        var snapshotCalls: Int { lock.lock(); defer { lock.unlock() }; return _snapshotCalls }

        func setSnapshotReturn(_ data: Data) {
            lock.lock(); defer { lock.unlock() }
            _snapshotReturn = data
        }

        func start() async {
            lock.lock(); defer { lock.unlock() }
            _startCalls += 1
        }

        func snapshot() async -> Data {
            lock.lock(); defer { lock.unlock() }
            _snapshotCalls += 1
            return _snapshotReturn
        }

        func gc() async {
            lock.lock(); defer { lock.unlock() }
            _gcCalls += 1
        }
    }

    // MARK: - Helpers

    /// Collects up to `count` events with a deadline so the negative /
    /// no-fire tests never hang. Mirrors the helper pattern from
    /// `MeetingDetectorTests`.
    private func collectEvents(
        from stream: AsyncStream<MeetingPillEvent>,
        count: Int,
        within seconds: Double
    ) async -> [MeetingPillEvent] {
        await withTaskGroup(of: [MeetingPillEvent].self) { group in
            group.addTask {
                var collected: [MeetingPillEvent] = []
                for await event in stream {
                    collected.append(event)
                    if collected.count >= count { return collected }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    private func makeController(buffer: MeetingPillBufferAttaching) -> MeetingPillController {
        // Headless — we never call `installPanel()` in tests so XCTest
        // does not need a key window. The state machine + events stream
        // are fully exercisable without a real NSPanel on screen.
        MeetingPillController(buffer: buffer)
    }

    private func loadSource(named relativePath: String) throws -> String {
        let candidates = candidateSourceURLs(for: relativePath)
        for url in candidates {
            if let data = try? Data(contentsOf: url), let source = String(data: data, encoding: .utf8) {
                return source
            }
        }
        throw XCTSkip(
            "\(relativePath) source not reachable from test bundle — tried: "
                + candidates.map(\.path).joined(separator: ", ")
        )
    }

    private func candidateSourceURLs(for relativePath: String) -> [URL] {
        let env = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        if let srcroot = env["SRCROOT"] { roots.append(URL(fileURLWithPath: srcroot)) }
        if let packagePath = env["PACKAGE_PATH"] { roots.append(URL(fileURLWithPath: packagePath)) }

        let thisFile = URL(fileURLWithPath: #filePath)
        var cursor = thisFile.deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: cursor.appendingPathComponent("Package.swift").path) {
                roots.append(cursor)
                break
            }
            cursor = cursor.deletingLastPathComponent()
        }

        return roots.map { $0.appendingPathComponent("Sources/Sidekey/\(relativePath)") }
    }

    // MARK: - (1) State transitions

    /// `show(.suggesting)` flips `state` to `.suggesting`; `hide()`
    /// flips it back to `.hidden`. Smoke test for the public surface.
    func test_state_machine_transitions_suggesting_to_hidden_on_dismiss() async {
        let buffer = StubBuffer()
        let controller = makeController(buffer: buffer)

        XCTAssertEqual(controller.state, .hidden,
                       "Pill must start hidden so it does not flash on launch")

        let meetingId = UUID()
        let deadline = Date().addingTimeInterval(30)
        controller.show(.suggesting(meetingId: meetingId, deadline: deadline))

        switch controller.state {
        case .suggesting(let id, let d):
            XCTAssertEqual(id, meetingId)
            XCTAssertEqual(d.timeIntervalSince1970, deadline.timeIntervalSince1970, accuracy: 0.001)
        default:
            XCTFail("Expected .suggesting after show, got \(controller.state)")
        }

        controller.hide()
        XCTAssertEqual(controller.state, .hidden,
                       "hide() must reset state to .hidden")
    }

    // MARK: - (2) Nudge timeout emits .dismiss(reason: .timeout)

    /// The suggesting UI owns the countdown so it can pause while the
    /// user hovers either half of the nudge. When that UI reports a
    /// timeout, the controller emits `.dismiss(reason: .timeout)` and
    /// transitions to `.hidden`.
    func test_nudge_timeout_action_emits_dismiss_with_reason_timeout() async {
        let buffer = StubBuffer()
        let controller = makeController(buffer: buffer)
        let stream = controller.events
        let meetingId = UUID()
        let deadline = Date().addingTimeInterval(
            MeetingsConfig.pillDecisionTimeoutSeconds
        )
        controller.show(.suggesting(meetingId: meetingId, deadline: deadline))

        XCTAssertEqual(MeetingsConfig.pillDecisionTimeoutSeconds, 20, accuracy: 0.001)

        controller._testSuggestionTimedOut()

        let events = await collectEvents(from: stream, count: 1, within: 1.0)
        XCTAssertEqual(events.count, 1, "Expected one dismiss event after deadline")
        if case .dismiss(let reason) = events.first {
            XCTAssertEqual(reason, .timeout)
        } else {
            XCTFail("Expected .dismiss(reason: .timeout), got \(String(describing: events.first))")
        }
        XCTAssertEqual(controller.state, .hidden,
                       "After deadline the pill must be hidden")
    }

    func test_suggesting_state_marks_meeting_prompt_active_for_dynamic_island() {
        let buffer = StubBuffer()
        let controller = makeController(buffer: buffer)
        let meetingId = UUID()

        XCTAssertFalse(AppState.shared.meetingSuggestionActive)

        controller.show(
            .suggesting(
                meetingId: meetingId,
                deadline: Date().addingTimeInterval(MeetingsConfig.pillDecisionTimeoutSeconds)
            )
        )

        XCTAssertTrue(AppState.shared.meetingSuggestionActive)
        XCTAssertNotNil(AppState.shared.meetingSuggestionDeadline)

        controller.hide()

        XCTAssertFalse(AppState.shared.meetingSuggestionActive)
        XCTAssertNil(AppState.shared.meetingSuggestionDeadline)
    }

    func test_recording_state_marks_meeting_recorder_active_for_dynamic_island() {
        let buffer = StubBuffer()
        let controller = makeController(buffer: buffer)
        let meetingId = UUID()

        XCTAssertFalse(AppState.shared.meetingRecordingActive)

        controller.show(.recording(meetingId: meetingId, audioLevel: 0.62, duration: 14.4))

        XCTAssertFalse(AppState.shared.meetingSuggestionActive)
        XCTAssertNil(AppState.shared.meetingSuggestionDeadline)
        XCTAssertTrue(AppState.shared.meetingRecordingActive)
        XCTAssertFalse(AppState.shared.meetingRecordingPaused)
        XCTAssertEqual(AppState.shared.meetingRecordingDuration, 14.4, accuracy: 0.001)
        XCTAssertEqual(AppState.shared.meetingRecordingLevels.last ?? -1, 0.62, accuracy: 0.001)

        controller.updateLiveState(audioLevel: 0.27, duration: 15.1)

        XCTAssertEqual(AppState.shared.meetingRecordingDuration, 15.1, accuracy: 0.001)
        XCTAssertEqual(AppState.shared.meetingRecordingLevels.last ?? -1, 0.27, accuracy: 0.001)

        controller.hide()

        XCTAssertFalse(AppState.shared.meetingRecordingActive)
        XCTAssertEqual(AppState.shared.meetingRecordingDuration, 0, accuracy: 0.001)
        XCTAssertTrue(AppState.shared.meetingRecordingLevels.isEmpty)
    }

    func test_suggestion_nudge_positions_below_dynamic_island() {
        let frame = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = NSRect(x: 0, y: 76, width: 1512, height: 868)
        let auxLeft = NSRect(x: 0, y: 944, width: 670, height: 38)
        let auxRight = NSRect(x: 842, y: 944, width: 670, height: 38)

        let islandFrame = IslandFrameLayout.islandFrame(
            frame: frame,
            visibleFrame: visible,
            safeAreaTopInset: 38,
            auxiliaryTopLeftArea: auxLeft,
            auxiliaryTopRightArea: auxRight
        )
        let suggestionFrame = MeetingPillPanel.suggestionFrame(
            frame: frame,
            visibleFrame: visible,
            safeAreaTopInset: 38,
            auxiliaryTopLeftArea: auxLeft,
            auxiliaryTopRightArea: auxRight
        )

        let nudgeSize = MeetingPillPanel.suggestionNudgeSize(forIslandFrame: islandFrame)
        let panelSize = MeetingPillPanel.suggestionPanelSize(forIslandFrame: islandFrame)

        XCTAssertEqual(MeetingPillPanel.suggestionGapBelowIsland, 0, accuracy: 0.001)
        XCTAssertEqual(nudgeSize.width, islandFrame.width, accuracy: 0.001)
        XCTAssertEqual(nudgeSize.height, 32, accuracy: 0.001)
        XCTAssertEqual(MeetingPillPanel.suggestionNudgeTopCornerRadius, 0, accuracy: 0.001)
        XCTAssertEqual(panelSize, nudgeSize)
        XCTAssertEqual(suggestionFrame.width, panelSize.width, accuracy: 0.001)
        XCTAssertEqual(suggestionFrame.height, panelSize.height, accuracy: 0.001)
        XCTAssertEqual(suggestionFrame.midX, islandFrame.midX, accuracy: 0.001)
        XCTAssertEqual(
            suggestionFrame.maxY,
            islandFrame.minY - MeetingPillPanel.suggestionGapBelowIsland,
            accuracy: 0.001
        )
    }

    func test_suggestion_nudge_has_no_inline_progress_surface() throws {
        let nudgeSource = try loadSource(named: "Meetings/MeetingNudgeView.swift")

        XCTAssertFalse(
            nudgeSource.contains("DrainProgressSurface"),
            "The meeting nudge should stay a clean two-action row; the countdown lives in the Dynamic Island right band."
        )
        XCTAssertFalse(
            nudgeSource.contains("Canvas"),
            "Inline canvas progress fought the hover animation; the nudge should not own progress drawing anymore."
        )
    }

    func test_suggestion_nudge_is_keyed_by_meeting_id_for_reconnects() throws {
        let pillSource = try loadSource(named: "Meetings/MeetingPillView.swift")
        let nudgeSource = try loadSource(named: "Meetings/MeetingNudgeView.swift")

        XCTAssertTrue(
            pillSource.contains("case .suggesting(let meetingId, let deadline):"),
            "The suggesting branch must bind meetingId so each reconnect can get fresh SwiftUI state."
        )
        XCTAssertTrue(
            pillSource.contains("MeetingNudgeHostView(")
                && pillSource.contains("meetingId: meetingId")
                && nudgeSource.contains(".id(meetingId)"),
            "MeetingNudgeView must be keyed by meetingId; otherwise leaving/remaining @State can hide the next detected meeting."
        )
    }

    func test_meeting_prompt_and_recording_states_do_not_draw_panel_shadow() {
        XCTAssertFalse(MeetingPillPanel.hasWindowShadow(for: .suggesting(
            meetingId: UUID(),
            deadline: Date().addingTimeInterval(MeetingsConfig.pillDecisionTimeoutSeconds)
        )))
        XCTAssertFalse(MeetingPillPanel.hasWindowShadow(for: .recording(
            meetingId: UUID(),
            audioLevel: 0,
            duration: 0
        )))
        XCTAssertFalse(MeetingPillPanel.hasWindowShadow(for: .paused(
            meetingId: UUID(),
            audioLevel: 0,
            duration: 0
        )))
    }

    // MARK: - (3) Yes button emits .accept with buffer snapshot

    /// The Yes button must:
    /// - Trigger a `buffer.snapshot()` call.
    /// - Emit `.accept(meetingId, snapshot)` carrying the snapshot's
    ///   bytes so Stage 4 MeetingRecorder can splice them at the head
    ///   of the recording.
    /// - Transition the pill to `.hidden`.
    func test_yes_button_emits_accept_with_buffer_snapshot() async {
        let buffer = StubBuffer()
        let expectedSnapshot = Data([0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x02])
        buffer.setSnapshotReturn(expectedSnapshot)

        let controller = makeController(buffer: buffer)
        let stream = controller.events
        let meetingId = UUID()
        controller.show(.suggesting(
            meetingId: meetingId,
            deadline: Date().addingTimeInterval(MeetingsConfig.pillDecisionTimeoutSeconds)
        ))

        await controller._testTapAccept()

        let events = await collectEvents(from: stream, count: 1, within: 1.0)
        XCTAssertEqual(events.count, 1, "Expected one accept event")
        if case .accept(let id, let snapshot) = events.first {
            XCTAssertEqual(id, meetingId, "Accept must carry the meetingId from show()")
            XCTAssertEqual(snapshot, expectedSnapshot,
                           "Accept must carry the bytes returned by buffer.snapshot()")
        } else {
            XCTFail("Expected .accept, got \(String(describing: events.first))")
        }
        XCTAssertEqual(buffer.snapshotCalls, 1, "snapshot() must be called once on Yes")
        XCTAssertEqual(controller.state, .hidden,
                       "Pill must transition to .hidden after accept")
    }

    func test_reconnect_button_emits_previous_meeting_gap_and_snapshot() async {
        let buffer = StubBuffer()
        let expectedSnapshot = Data([0xCA, 0xFE])
        buffer.setSnapshotReturn(expectedSnapshot)
        let controller = makeController(buffer: buffer)
        let stream = controller.events
        let previousId = UUID()
        controller.show(.suggestingReconnect(
            meetingId: UUID(),
            previousMeetingId: previousId,
            gapSeconds: 94,
            deadline: Date().addingTimeInterval(MeetingsConfig.pillDecisionTimeoutSeconds)
        ))

        await controller._testTapReconnect()

        let events = await collectEvents(from: stream, count: 1, within: 1.0)
        guard case .reconnect(let id, let gap, let snapshot)? = events.first else {
            return XCTFail("Expected reconnect event, got \(String(describing: events.first))")
        }
        XCTAssertEqual(id, previousId)
        XCTAssertEqual(gap, 94)
        XCTAssertEqual(snapshot, expectedSnapshot)
        XCTAssertEqual(controller.state, .hidden)
    }

    func test_reconnect_gap_label_is_compact_and_exact() {
        XCTAssertEqual(MeetingNudgeView.gapLabel(94), "after 1m 34s")
        XCTAssertEqual(MeetingNudgeView.gapLabel(8), "after 8s")
    }

    // MARK: - (4) No button emits .dismiss with reason .user

    /// The No button emits `.dismiss(reason: .user)` (distinct from the
    /// deadline's `.timeout`) and transitions to `.hidden`. The
    /// coordinator uses this distinction for the cooldown timer (both
    /// engage cooldown, but observability separates them).
    func test_no_button_emits_dismiss_with_reason_user() async {
        let buffer = StubBuffer()
        let controller = makeController(buffer: buffer)
        let stream = controller.events
        controller.show(.suggesting(
            meetingId: UUID(),
            deadline: Date().addingTimeInterval(MeetingsConfig.pillDecisionTimeoutSeconds)
        ))

        await controller._testTapDismiss()

        let events = await collectEvents(from: stream, count: 1, within: 1.0)
        XCTAssertEqual(events.count, 1, "Expected one dismiss event")
        if case .dismiss(let reason) = events.first {
            XCTAssertEqual(reason, .user,
                           "No-button must emit .user (timeout is the deadline case)")
        } else {
            XCTFail("Expected .dismiss(reason: .user), got \(String(describing: events.first))")
        }
        XCTAssertEqual(controller.state, .hidden,
                       "Pill must transition to .hidden after user dismiss")
    }

    // MARK: - (Stage 4) Pause/resume events transition .recording <-> .paused

    /// `pause()` while in `.recording` must transition the controller to
    /// `.paused` and emit a `.pause(meetingId)` event onto the events stream
    /// so the coordinator can call `recorder.pause()`. Symmetric to
    /// `accept` / `dismiss`: same single-source-of-truth, no silent state
    /// drift between view and coordinator.
    func test_pause_event_transitions_to_paused_state() async {
        let buffer = StubBuffer()
        let controller = makeController(buffer: buffer)
        let stream = controller.events
        let meetingId = UUID()
        controller.show(.recording(meetingId: meetingId, audioLevel: 0.5, duration: 1.0))

        controller.pause()

        let events = await collectEvents(from: stream, count: 1, within: 1.0)
        XCTAssertEqual(events.count, 1, "Expected one pause event")
        if case .pause(let id) = events.first {
            XCTAssertEqual(id, meetingId,
                           "Pause event must carry the meetingId from the recording state")
        } else {
            XCTFail("Expected .pause, got \(String(describing: events.first))")
        }
        switch controller.state {
        case .paused(let id, _, _):
            XCTAssertEqual(id, meetingId)
        default:
            XCTFail("Controller must be in .paused after pause(); got \(controller.state)")
        }
    }

    /// `resume()` while in `.paused` must emit `.resume(meetingId)` and
    /// transition back to `.recording`. The waveform / timer rebind on
    /// the new state without bouncing through `.hidden`.
    func test_resume_event_transitions_back_to_recording() async {
        let buffer = StubBuffer()
        let controller = makeController(buffer: buffer)
        let stream = controller.events
        let meetingId = UUID()
        controller.show(.paused(meetingId: meetingId, audioLevel: 0.0, duration: 5.0))

        controller.resume()

        let events = await collectEvents(from: stream, count: 1, within: 1.0)
        XCTAssertEqual(events.count, 1, "Expected one resume event")
        if case .resume(let id) = events.first {
            XCTAssertEqual(id, meetingId,
                           "Resume event must carry the meetingId from the paused state")
        } else {
            XCTFail("Expected .resume, got \(String(describing: events.first))")
        }
        switch controller.state {
        case .recording(let id, _, _):
            XCTAssertEqual(id, meetingId)
        default:
            XCTFail("Controller must be in .recording after resume(); got \(controller.state)")
        }
    }

    // MARK: - (5) Position top-center on active screen

    /// The pill anchors at top-center, ~60pt below the menu bar (so it
    /// does not collide with the system menu). We test the pure math
    /// helper instead of the live panel so the test does not need a
    /// real `NSScreen`.
    func test_pill_position_top_center_on_active_screen() {
        // Simulate a 1920×1200 visible frame (Retina MBP-ish).
        let screenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1200)
        let pillSize = MeetingPillPanel.panelSize

        let frame = MeetingPillPanel.topCenterFrame(
            on: screenFrame,
            pillSize: pillSize
        )

        // Centered horizontally on the screen midpoint.
        XCTAssertEqual(frame.midX, screenFrame.midX, accuracy: 0.5,
                       "Pill must be horizontally centered on the active screen")
        // Anchored near the top — `frame.maxY` sits below `screenFrame.maxY`
        // by exactly `MeetingPillPanel.topInset`.
        XCTAssertEqual(
            frame.maxY,
            screenFrame.maxY - MeetingPillPanel.topInset,
            accuracy: 0.5,
            "Pill must hang `topInset` points below the top of the visible frame"
        )
        // Pill size unchanged by the position math.
        XCTAssertEqual(frame.size, pillSize,
                       "topCenterFrame must not resize the pill")
    }
}

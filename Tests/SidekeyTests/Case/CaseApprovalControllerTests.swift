import Carbon.HIToolbox
import Combine
import SwiftUI
import CoreGraphics
import XCTest
@testable import Sidekey

// Requests carry obviously fake names; no real secrets or commands.

@MainActor
private final class FakeApprovalKeyTap: CaseApprovalKeyIntercepting {
    var failsToStart = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var armedHistory: [Bool] = []
    private var onKey: (@MainActor (CaseApprovalKey) -> Void)?
    private var onUnarmedKeyDown: (@MainActor () -> Void)?

    var isRunning: Bool { onKey != nil }
    var isArmed: Bool { armedHistory.last ?? false }

    func start(onKey: @escaping @MainActor (CaseApprovalKey) -> Void,
               onUnarmedKeyDown: @escaping @MainActor () -> Void) throws {
        startCount += 1
        if failsToStart { throw CaseApprovalKeyTapError.unavailable }
        self.onKey = onKey
        self.onUnarmedKeyDown = onUnarmedKeyDown
    }

    func stop() {
        stopCount += 1
        onKey = nil
        onUnarmedKeyDown = nil
    }

    func setArmed(_ armed: Bool) { armedHistory.append(armed) }

    /// A physical answer-key press as the real tap delivers it (only while running):
    /// armed, it answers; unarmed, it passes through and only reports typing.
    func press(_ key: CaseApprovalKey) {
        if isArmed { onKey?(key) } else { onUnarmedKeyDown?() }
    }

    /// Any other key going down (a letter typed in the user's editor).
    func type() {
        if !isArmed { onUnarmedKeyDown?() }
    }
}

/// Manual clock: scheduled work fires only when the test advances time.
@MainActor
private final class FakeApprovalClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 1_000)
    private var nextID = 0
    private var items: [(id: Int, at: Date, work: @MainActor () -> Void)] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        items.append((id, now.addingTimeInterval(delay), work))
        return { [weak self] in self?.items.removeAll { $0.id == id } }
    }

    func advance(by seconds: TimeInterval) {
        let target = now.addingTimeInterval(seconds)
        while let next = items.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            items.removeAll { $0.id == next.id }
            now = next.at
            next.work()
        }
        now = target
    }
}

@MainActor
final class CaseApprovalControllerTests: XCTestCase {
    private var tap: FakeApprovalKeyTap!
    private var clock: FakeApprovalClock!
    private var controller: CaseApprovalController!

    override func setUp() async throws {
        tap = FakeApprovalKeyTap()
        clock = FakeApprovalClock()
        let clock = clock!
        controller = CaseApprovalController(
            keyTap: tap,
            now: { clock.now },
            schedule: { delay, work in clock.schedule(after: delay, work) })
    }

    private func request(_ app: String = "Claude Code", project: String = "alpha",
                         keys: [String] = ["API_TOKEN"], command: String = "npm run deploy",
                         minutes: Int = 15) -> CaseApprovalRequest {
        CaseApprovalRequest(appName: app, projectName: project, keyNames: keys,
                            command: command, timedMinutes: minutes)
    }

    /// Starts an approval the way the broker does and waits until it is queued.
    private func ask(_ r: CaseApprovalRequest) async -> Task<CaseApprovalOutcome, Never> {
        let before = controller.queuedCount
        let task = Task { await self.controller.requestApproval(r) }
        for _ in 0..<200 where controller.queuedCount == before { await Task.yield() }
        XCTAssertEqual(controller.queuedCount, before + 1, "request was not queued")
        return task
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - Brief tests

    func test_keys_ignored_during_first_300ms() async {
        let task = await ask(request())
        XCTAssertEqual(controller.current, request())
        XCTAssertFalse(controller.isArmed)
        XCTAssertFalse(tap.isArmed, "the tap must let every key through while unarmed")

        // A person typing in their editor as the prompt appears.
        tap.press(.yes)
        clock.advance(by: 0.1)
        tap.press(.timed)
        controller.choose(.allow)          // a stray click is ignored too
        clock.advance(by: 0.199)
        tap.press(.no)
        XCTAssertEqual(controller.current, request(), "nothing answered while typing")

        // Every press restarted the quiet period: armed 300 ms after the last one.
        clock.advance(by: 0.299)
        XCTAssertFalse(controller.isArmed)
        clock.advance(by: 0.001)
        XCTAssertTrue(controller.isArmed)
        XCTAssertTrue(tap.isArmed)
        tap.press(.yes)
        let outcome = await task.value
        XCTAssertEqual(outcome, .allow)
        XCTAssertNil(controller.current)
    }

    func test_ongoing_typing_never_arms_until_300ms_quiet() async {
        let task = await ask(request())
        // Keys every 100 ms for 3 s, as when someone keeps typing in another app.
        for _ in 0..<30 {
            tap.type()
            clock.advance(by: 0.1)
            XCTAssertFalse(controller.isArmed, "a typist can never answer the prompt")
        }
        tap.press(.yes)                    // the Y of a typed word
        clock.advance(by: 0.29)
        XCTAssertFalse(controller.isArmed)
        XCTAssertNotNil(controller.current)

        clock.advance(by: 0.01)            // 300 ms without a key
        XCTAssertTrue(controller.isArmed)
        tap.type()                         // typing after arming does not disarm
        XCTAssertTrue(controller.isArmed)
        tap.press(.no)
        let outcome = await task.value
        XCTAssertEqual(outcome, .deny)
    }

    func test_typing_does_not_postpone_the_60s_timeout() async {
        let task = await ask(request())
        for _ in 0..<590 {
            tap.type()
            clock.advance(by: 0.1)
        }
        XCTAssertNotNil(controller.current, "still waiting at 59 s")
        clock.advance(by: 1.1)
        let outcome = await task.value
        XCTAssertEqual(outcome, .timedOut)
    }

    // MARK: - Abandoned and covered prompts

    func test_disconnected_client_withdraws_its_queued_and_visible_prompts() async {
        let first = await ask(request("Claude Code"))
        let second = await ask(request("Codex"))
        let third = await ask(request("Cursor"))
        XCTAssertEqual(controller.pendingCount, 2)

        // The client of a waiting prompt hangs up: it is removed, never shown.
        second.cancel()
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .deny)
        XCTAssertEqual(controller.pendingCount, 1)
        XCTAssertEqual(controller.current?.appName, "Claude Code")

        // The client of the visible prompt hangs up: the next one is shown, unarmed.
        first.cancel()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .deny)
        XCTAssertEqual(controller.current?.appName, "Cursor")
        XCTAssertFalse(controller.isArmed)

        clock.advance(by: 0.3)
        tap.press(.yes)
        let thirdOutcome = await third.value
        XCTAssertEqual(thirdOutcome, .allow)
        XCTAssertNil(controller.current)
        XCTAssertFalse(tap.isRunning)
    }

    func test_cancelled_before_queueing_is_denied_without_a_prompt() async {
        let task = Task { () -> CaseApprovalOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await self.controller.requestApproval(self.request())
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .deny)
        await settle()
        XCTAssertNil(controller.current)
        XCTAssertEqual(tap.startCount, 0)
    }

    func test_timed_answer_allows_waiting_prompts_of_same_app_and_project() async {
        let appID = UUID(), otherAppID = UUID(), alpha = UUID(), beta = UUID()
        func r(_ app: String, _ appID: UUID, _ projectID: UUID, _ project: String) -> CaseApprovalRequest {
            CaseApprovalRequest(appName: app, projectName: project, keyNames: ["API_TOKEN"],
                                command: "npm test", timedMinutes: 15, appID: appID, projectID: projectID)
        }
        let first = await ask(r("Claude Code", appID, alpha, "alpha"))
        let sameAgain = await ask(r("Claude Code", appID, alpha, "alpha"))
        let otherProject = await ask(r("Claude Code", appID, beta, "beta"))
        let otherApp = await ask(r("Codex", otherAppID, alpha, "alpha"))
        let sameLater = await ask(r("Claude Code", appID, alpha, "alpha"))

        clock.advance(by: 0.3)
        tap.press(.timed)
        let a = await first.value
        let b = await sameAgain.value
        let e = await sameLater.value
        XCTAssertEqual(a, .allowTimed(minutes: 15))
        XCTAssertEqual([b, e], [.allow, .allow], "covered by the grant just given")

        XCTAssertEqual(controller.current?.projectName, "beta", "another project still asks")
        XCTAssertEqual(controller.pendingCount, 1)
        clock.advance(by: 0.3)
        tap.press(.yes)
        let c = await otherProject.value
        XCTAssertEqual(c, .allow)
        XCTAssertEqual(controller.current?.appName, "Codex", "another app still asks")
        controller.resolve(.deny)
        let d = await otherApp.value
        XCTAssertEqual(d, .deny)
    }

    func test_plain_allow_does_not_cover_waiting_prompts() async {
        let appID = UUID(), alpha = UUID()
        let r = CaseApprovalRequest(appName: "Claude Code", projectName: "alpha", keyNames: ["K"],
                                    command: "true", timedMinutes: 15, appID: appID, projectID: alpha)
        let first = await ask(r)
        let second = await ask(r)
        clock.advance(by: 0.3)
        tap.press(.yes)
        _ = await first.value
        XCTAssertEqual(controller.current, r, "a one-time allow still asks again")
        controller.resolve(.deny)
        _ = await second.value
    }

    func test_answer_keys_allow_deny_and_grant_timed_access() async {
        let cases: [(CaseApprovalKey, CaseApprovalOutcome)] = [
            (.yes, .allow), (.no, .deny), (.timed, .allowTimed(minutes: 15)), (.escape, .deny),
        ]
        for (key, expected) in cases {
            let task = await ask(request())
            clock.advance(by: 0.3)
            tap.press(key)
            let outcome = await task.value
            XCTAssertEqual(outcome, expected, "\(key)")
            XCTAssertNil(controller.current)
        }
    }

    func test_timeout_after_60s_denies() async {
        let task = await ask(request())
        clock.advance(by: 59.9)
        XCTAssertNotNil(controller.current, "still waiting before 60 s")
        XCTAssertEqual(controller.deadline, Date(timeIntervalSinceReferenceDate: 1_060))
        clock.advance(by: 0.1)
        let outcome = await task.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertNil(controller.current)
        XCTAssertFalse(tap.isRunning)

        // A key arriving after the timeout answers nothing.
        tap.press(.yes)
        XCTAssertNil(controller.current)
    }

    func test_queue_shows_one_at_a_time() async {
        let first = await ask(request("Claude Code", project: "alpha"))
        let second = await ask(request("Codex", project: "beta", keys: ["DB_URL", "DB_PASSWORD"]))
        let third = await ask(request("Cursor", project: "gamma"))

        XCTAssertEqual(controller.current?.appName, "Claude Code")
        XCTAssertEqual(controller.pendingCount, 2, "two more wait behind the visible one")

        clock.advance(by: 30)
        tap.press(.yes)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .allow)
        XCTAssertEqual(controller.current?.appName, "Codex", "FIFO")
        XCTAssertEqual(controller.pendingCount, 1)

        // The next prompt is armed afresh: a double Y does not answer it.
        XCTAssertFalse(controller.isArmed)
        tap.press(.yes)
        XCTAssertEqual(controller.current?.appName, "Codex")

        // Its 60 s start when it appears, not when it was queued.
        clock.advance(by: 59)
        XCTAssertEqual(controller.current?.appName, "Codex")
        tap.press(.no)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .deny)

        XCTAssertEqual(controller.current?.appName, "Cursor")
        XCTAssertEqual(controller.pendingCount, 0)
        clock.advance(by: 60)
        let thirdOutcome = await third.value
        XCTAssertEqual(thirdOutcome, .timedOut)
        XCTAssertNil(controller.current)
    }

    func test_tap_stopped_when_queue_empty() async {
        XCTAssertEqual(tap.startCount, 0, "no tap while nothing is asked")

        let first = await ask(request())
        let second = await ask(request("Codex"))
        XCTAssertEqual(tap.startCount, 1)
        XCTAssertTrue(tap.isRunning)

        clock.advance(by: 0.3)
        tap.press(.no)
        _ = await first.value
        XCTAssertTrue(tap.isRunning, "the queue still has a prompt")
        XCTAssertEqual(tap.stopCount, 0)

        clock.advance(by: 0.3)
        tap.press(.yes)
        _ = await second.value
        XCTAssertFalse(tap.isRunning, "stopped once the queue is empty")
        XCTAssertEqual(tap.stopCount, 1)
        XCTAssertFalse(tap.isArmed)

        // A later request installs the tap again.
        let third = await ask(request())
        XCTAssertEqual(tap.startCount, 2)
        controller.resolve(.deny)
        _ = await third.value
        XCTAssertFalse(tap.isRunning)
    }

    // MARK: - Edge cases

    func test_prompt_works_by_click_when_tap_cannot_start() async {
        tap.failsToStart = true
        let task = await ask(request())
        XCTAssertNotNil(controller.current, "the prompt shows without Accessibility")
        XCTAssertFalse(controller.keysAvailable)
        clock.advance(by: 0.3)
        controller.choose(.allowTimed(minutes: 15))
        let outcome = await task.value
        XCTAssertEqual(outcome, .allowTimed(minutes: 15))
    }

    func test_editing_minutes_changes_the_keyboard_bypass_and_resets_for_next_request() async {
        let task = await ask(request())
        controller.setTimedMinutes(37)
        controller.setTimedMinutes(241)
        XCTAssertEqual(controller.selectedTimedMinutes, 37)
        clock.advance(by: 0.3)
        tap.press(.timed)
        let outcome = await task.value
        XCTAssertEqual(outcome, .allowTimed(minutes: 37))
        let next = await ask(request())
        XCTAssertEqual(controller.selectedTimedMinutes, 15)
        controller.resolve(.deny)
        _ = await next.value
    }

    func test_minutes_editing_suspends_answer_keys_even_when_arming_timer_fires() async {
        let task = await ask(request())
        controller.setEditingMinutes(true)
        clock.advance(by: 0.3)
        XCTAssertTrue(controller.isArmed, "click answers remain available")
        XCTAssertFalse(tap.isArmed, "typing in the field must not answer the prompt")
        for key in [CaseApprovalKey.yes, .no, .timed, .escape] { tap.press(key) }
        XCTAssertNotNil(controller.current)
        controller.setTimedMinutes(37)
        controller.setEditingMinutes(false)
        XCTAssertTrue(tap.isArmed)
        tap.press(.timed)
        let outcome = await task.value
        XCTAssertEqual(outcome, .allowTimed(minutes: 37))
        XCTAssertFalse(controller.isEditingMinutes)
    }

    func test_timeout_during_minutes_editing_clears_editor_and_stops_tap() async {
        let task = await ask(request())
        controller.setEditingMinutes(true)
        clock.advance(by: 60)
        let outcome = await task.value
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertFalse(controller.isEditingMinutes)
        XCTAssertFalse(tap.isRunning)
    }

    func test_native_minutes_field_acquires_keyboard_editing_without_a_mouse_click() async throws {
        let task = await ask(request())
        clock.advance(by: 0.3)
        let editor = CaseApprovalMinutesField(value: 15, onChange: { self.controller.setTimedMinutes($0) },
                                             onEditingChange: { self.controller.setEditingMinutes($0) },
                                             onValidityChange: { _ in })
        let coordinator = editor.makeCoordinator()
        let field = CaseApprovalMinutesTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 26))
        field.stringValue = "15"
        field.delegate = coordinator
        field.onEditingChange = { self.controller.setEditingMinutes($0) }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 100, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = field
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertTrue(controller.isEditingMinutes)
        XCTAssertFalse(tap.isArmed, "first response must suspend keys before the first typed character")
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
        tap.press(.no)
        XCTAssertNotNil(controller.current)
        controller.choose(.deny)
        _ = await task.value
    }

    func test_presenting_prompt_does_not_focus_minutes_or_suspend_answer_keys() async throws {
        let panel = CaseApprovalPanel(controller: controller, present: { _ in })
        defer { panel.close() }
        let pending = await ask(request())
        try await Task.sleep(for: .milliseconds(60))
        panel.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(controller.isEditingMinutes, "Showing a request must not begin editing its duration")
        XCTAssertFalse(panel.firstResponder is NSTextView, "The duration must not be selected automatically")
        XCTAssertTrue(panel.initialFirstResponder === panel.contentView, "Default focus belongs to the neutral card, not minutes")
        clock.advance(by: 0.3)
        XCTAssertTrue(tap.isArmed, "Answer shortcuts must work without clicking out of the minutes field")
        tap.press(.yes)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .allow, "The answer key must work without a field click")
        XCTAssertFalse(panel.isVisible || panel.isKeyWindow)
    }

    func test_queued_prompt_releases_previous_native_field_editor_without_presenting_a_panel() async throws {
        let panel = CaseApprovalPanel(controller: controller, present: { _ in })
        defer { panel.close() }
        let first = await ask(request())
        let second = await ask(request("Codex"))
        clock.advance(by: 0.3)
        let field = CaseApprovalMinutesTextField(frame: NSRect(x: 0, y: 0, width: 50, height: 26))
        field.stringValue = "15"
        field.onEditingChange = { self.controller.setEditingMinutes($0) }
        panel.contentView?.addSubview(field)
        XCTAssertTrue(panel.makeFirstResponder(field))
        XCTAssertTrue(controller.isEditingMinutes)
        XCTAssertNotNil(field.currentEditor())
        controller.choose(.allow)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .allow)
        XCTAssertFalse(panel.firstResponder is NSTextView, "old field editor must not capture typing for the next prompt")
        XCTAssertFalse(controller.isEditingMinutes)
        XCTAssertEqual(controller.current?.appName, "Codex")
        XCTAssertFalse(panel.isVisible || panel.isKeyWindow)
        controller.resolve(.deny)
        _ = await second.value
    }

    func test_actual_minutes_editor_rejects_letters_then_return_rearms_answer_keys() async throws {
        let panel = CaseApprovalPanel(controller: controller, present: { _ in })
        defer { panel.close() }
        let pending = await ask(request())
        try await Task.sleep(for: .milliseconds(60))
        panel.contentView?.layoutSubtreeIfNeeded()
        clock.advance(by: 0.3)
        func fields(_ view: NSView) -> [CaseApprovalMinutesTextField] {
            (view as? CaseApprovalMinutesTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try XCTUnwrap(panel.contentView.flatMap { fields($0).first })
        XCTAssertTrue(panel.makeFirstResponder(field))
        XCTAssertTrue(controller.isEditingMinutes)
        XCTAssertFalse(tap.isArmed)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("37", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("A", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "37")
        XCTAssertEqual(controller.selectedTimedMinutes, 37)
        tap.press(.timed)
        XCTAssertNotNil(controller.current, "Rejected letters while editing must not approve the command")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertFalse(controller.isEditingMinutes)
        XCTAssertTrue(tap.isArmed, "Return must restore the answer keys")
        tap.press(.yes)
        let outcome = await pending.value
        XCTAssertEqual(outcome, .allow)
        XCTAssertFalse(panel.isVisible || panel.isKeyWindow)
    }

    func test_click_answers_after_arming() async {
        let task = await ask(request())
        clock.advance(by: 0.3)
        controller.choose(.deny)
        let outcome = await task.value
        XCTAssertEqual(outcome, .deny)
    }

    func test_timed_key_ignored_when_minutes_not_positive() async {
        let task = await ask(request(minutes: 0))
        clock.advance(by: 0.3)
        XCTAssertFalse(controller.offersTimed)
        tap.press(.timed)
        controller.choose(.allowTimed(minutes: 15))
        XCTAssertNotNil(controller.current, "no timed grant to offer")
        tap.press(.yes)
        let outcome = await task.value
        XCTAssertEqual(outcome, .allow)
    }

    func test_cancel_all_denies_every_waiting_request() async {
        let first = await ask(request())
        let second = await ask(request("Codex"))
        controller.cancelAll()
        let a = await first.value
        let b = await second.value
        XCTAssertEqual(a, .deny)
        XCTAssertEqual(b, .deny)
        XCTAssertNil(controller.current)
        XCTAssertFalse(tap.isRunning)
        clock.advance(by: 120)   // stale timers fire nothing
        await settle()
    }

    func test_resolve_without_prompt_is_ignored() {
        controller.resolve(.allow)
        XCTAssertNil(controller.current)
        XCTAssertEqual(tap.startCount, 0)
    }

    func test_active_flag_follows_queue() async {
        var changes: [Bool] = []
        let cancellable = controller.$current.map { $0 != nil }.removeDuplicates().sink { changes.append($0) }
        let task = await ask(request())
        controller.resolve(.deny)
        _ = await task.value
        XCTAssertEqual(changes, [false, true, false])
        cancellable.cancel()
    }

    // MARK: - Key filter (what the real tap swallows)

    private func down(_ code: Int, armed: Bool = true, flags: CGEventFlags = [], isRepeat: Bool = false,
                      _ filter: inout CaseApprovalKeyFilter) -> CaseApprovalKeyFilter.Decision {
        filter.decide(type: .keyDown, keyCode: Int64(code), flags: flags, isRepeat: isRepeat, armed: armed)
    }

    private func up(_ code: Int, armed: Bool = true, _ filter: inout CaseApprovalKeyFilter) -> CaseApprovalKeyFilter.Decision {
        filter.decide(type: .keyUp, keyCode: Int64(code), flags: [], isRepeat: false, armed: armed)
    }

    func test_filter_maps_physical_keys_on_any_layout() {
        for (code, answer) in [(kVK_ANSI_N, CaseApprovalKey.no), (kVK_ANSI_Y, .yes),
                               (kVK_ANSI_A, .timed), (kVK_Escape, .escape)] {
            XCTAssertEqual(CaseApprovalKeyFilter.key(forKeyCode: Int64(code)), answer)
        }
    }

    func test_filter_passes_all_other_keys_including_digits_and_navigation() {
        let answers = Set([kVK_ANSI_N, kVK_ANSI_Y, kVK_ANSI_A, kVK_Escape])
        var filter = CaseApprovalKeyFilter()
        for code in 0...127 where !answers.contains(code) {
            XCTAssertNil(CaseApprovalKeyFilter.key(forKeyCode: Int64(code)))
            XCTAssertEqual(down(code, &filter), .init(swallow: false, key: nil), "key \(code)")
            XCTAssertEqual(down(code, isRepeat: true, &filter), .init(swallow: false, key: nil))
            XCTAssertEqual(up(code, &filter), .init(swallow: false, key: nil))
        }
    }

    func test_filter_swallows_only_answer_presses_and_their_releases_when_armed() {
        var filter = CaseApprovalKeyFilter()
        for (code, answer) in [(kVK_ANSI_N, CaseApprovalKey.no), (kVK_ANSI_Y, .yes),
                               (kVK_ANSI_A, .timed), (kVK_Escape, .escape)] {
            XCTAssertEqual(down(code, &filter), .init(swallow: true, key: answer))
            XCTAssertEqual(up(code, &filter), .init(swallow: true, key: nil), "its key-up goes with it")
        }
    }

    func test_filter_passes_everything_while_unarmed() {
        var filter = CaseApprovalKeyFilter()
        for code in 0...127 {
            XCTAssertEqual(down(code, armed: false, &filter), .init(swallow: false, key: nil))
        }
        // The key-up of a press that went through is not swallowed after arming either.
        XCTAssertEqual(up(kVK_ANSI_Y, armed: true, &filter), .init(swallow: false, key: nil))
    }

    func test_filter_leaves_shortcuts_with_the_active_app_but_shift_still_answers() {
        var filter = CaseApprovalKeyFilter()
        for code in [kVK_ANSI_N, kVK_ANSI_Y, kVK_ANSI_A, kVK_Escape] {
            for flags in [CGEventFlags.maskCommand, .maskControl, .maskAlternate] {
                XCTAssertEqual(down(code, flags: flags, &filter), .init(swallow: false, key: nil))
                XCTAssertEqual(up(code, &filter), .init(swallow: false, key: nil))
            }
        }
        XCTAssertEqual(down(kVK_ANSI_Y, flags: .maskShift, &filter), .init(swallow: true, key: .yes))
    }

    func test_filter_autorepeat_of_a_key_held_before_the_prompt_passes() {
        var filter = CaseApprovalKeyFilter()
        XCTAssertEqual(down(kVK_ANSI_Y, isRepeat: true, &filter), .init(swallow: false, key: nil))
        // A repeat of a press we took is swallowed without answering again.
        XCTAssertEqual(down(kVK_ANSI_N, &filter), .init(swallow: true, key: .no))
        XCTAssertEqual(down(kVK_ANSI_N, isRepeat: true, &filter), .init(swallow: true, key: nil))
        XCTAssertEqual(up(kVK_ANSI_N, &filter), .init(swallow: true, key: nil))
        XCTAssertEqual(up(kVK_ANSI_N, &filter), .init(swallow: false, key: nil))
    }

    // MARK: - Island integration

    func test_case_approval_is_an_idle_blocker() {
        let clear = IslandIdleBlockers(
            dropFlowActive: false, agentPhaseActive: false, agentPanelVisible: false,
            meetingSuggestionActive: false, meetingRecordingActive: false, updateAvailable: false,
            justUpdatedVisible: false, nowPlayingActive: false, rightModifierHeld: false,
            programmaticHoverExpansion: false)
        XCTAssertFalse(clear.isBusy)
        var asking = clear
        asking.caseApprovalActive = true
        XCTAssertTrue(asking.isBusy)
    }

    func test_hover_drawer_does_not_open_over_the_prompt() {
        XCTAssertTrue(IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: false))
        XCTAssertFalse(IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: false, caseApprovalActive: true))
    }

    func test_help_lists_the_approval_keys() {
        let rows = HelpWindowContent.hotkeyRows(for: .defaults)
        func caps(_ title: String) -> [KeycapContent]? { rows.first { $0.title == title }?.contents }
        XCTAssertEqual(caps("Case — allow"), [.text("Y")])
        XCTAssertEqual(caps("Case — deny"), [.text("N")])
        XCTAssertEqual(caps("Case — allow for minutes"), [.text("A")])
    }

    func test_view_copy() {
        let r = request("Claude Code", project: "alpha", keys: ["KEY_A", "KEY_B"], minutes: 15)
        XCTAssertEqual(CaseApprovalView.titleText(r), "Claude Code wants to run a command")
        XCTAssertEqual(CaseApprovalView.keysText(r), "alpha: KEY_A, KEY_B")
        XCTAssertEqual(CaseApprovalView.timedTitle(minutes: 15), "Bypass for 15 min")
        XCTAssertEqual(CaseApprovalView.commandLine("git push\n  --force"), "git push --force",
                       "one line, whitespace collapsed")
    }
}

@MainActor
final class CaseApprovalMinutesFieldTests: XCTestCase {
    func test_native_formatter_blocks_letters_and_paste_but_allows_digit_drafts() throws {
        let field = CaseApprovalMinutesTextField()
        let formatter = try XCTUnwrap(field.formatter as? CaseApprovalMinutesFormatter)
        for text in ["", "0", "15", "240", "999"] {
            XCTAssertTrue(formatter.isPartialStringValid(text, newEditingString: nil, errorDescription: nil), text)
        }
        for text in ["Y", "N", "A", "abc", "15a", "3foo7", "-1", "1.5", " 15", "１５", "١٥"] {
            XCTAssertFalse(formatter.isPartialStringValid(text, newEditingString: nil, errorDescription: nil), text)
        }
    }

    func test_native_editor_rejects_non_digits_without_changing_the_duration() throws {
        _ = NSApplication.shared
        let field = CaseApprovalMinutesTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        field.stringValue = "15"
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 100, height: 60),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = field
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("37", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "37")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("A", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "37", "Letters must never appear in the minutes field")
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.insertText("12abc", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "37", "A mixed paste must be rejected as a whole")
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }

    func test_duration_validation_and_native_edit_commands() {
        for text in ["", "0", "241", "-1", "1.5", "1e2", " 15", "999999999999999999999999"] {
            XCTAssertNil(CaseApprovalMinutesField.minutes(from: text), text)
        }
        XCTAssertEqual(CaseApprovalMinutesField.minutes(from: "1"), 1)
        XCTAssertEqual(CaseApprovalMinutesField.minutes(from: "240"), 240)
        var values: [Int] = []
        var validity: [Bool] = []
        var editing: [Bool] = []
        let editor = CaseApprovalMinutesField(value: 15, onChange: { values.append($0) },
                                             onEditingChange: { editing.append($0) },
                                             onValidityChange: { validity.append($0) })
        let coordinator = editor.makeCoordinator()
        let field = NSTextField()
        coordinator.controlTextDidBeginEditing(Notification(name: NSControl.textDidBeginEditingNotification, object: field))
        field.stringValue = "37"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        field.stringValue = "999"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(values, [37], "invalid drafts never change the duration")
        XCTAssertEqual(validity, [true, false])
        coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        XCTAssertEqual(field.stringValue, "37", "revert to the last valid number, even before SwiftUI's next update")
        XCTAssertEqual(editing, [true, false])
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(values.last, 15, "Escape cancels the duration edit, not the key request")
        XCTAssertEqual(field.stringValue, "15")
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
    }
}

/// Offscreen layout checks of the prompt card; never orders a window front.
/// Set EXODIA_CASE_PROOF_DIR to also write PNGs.
@MainActor
final class CaseApprovalViewRenderTests: XCTestCase {
    private func render(_ request: CaseApprovalRequest, width: CGFloat, pending: Int = 0, armed: Bool = true,
                        name: String) throws -> CGSize {
        _ = NSApplication.shared
        let card = CaseApprovalView(request: request, width: width, pendingCount: pending, isArmed: armed,
                                    onChoose: { _ in })
        let measure = NSHostingView(rootView: card)
        let cardSize = measure.fittingSize

        // The card under a stand-in for the island, on a light desktop.
        let scene = VStack(spacing: 0) {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 0,
                                   topTrailingRadius: 0).fill(Color.black).frame(width: width, height: 32)
            card
        }
        .padding(24)
        .background(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.74)],
                                   startPoint: .top, endPoint: .bottom))
        let host = NSHostingView(rootView: scene)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: host.frame.width,
                                                  height: host.frame.height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible || window.isKeyWindow, "renders stay offscreen")

        if let output = ProcessInfo.processInfo.environment["EXODIA_CASE_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
        window.close()
        return cardSize
    }

    func test_card_keeps_island_width_and_one_line_command() throws {
        let short = CaseApprovalRequest(appName: "Claude Code", projectName: "whytap",
                                        keyNames: ["OPENROUTER_API_KEY", "SONIOX_API_KEY"],
                                        command: "swift test --filter CaseBrokerTests", timedMinutes: 15)
        let long = CaseApprovalRequest(
            appName: "Visual Studio Code Insiders", projectName: "terra-hiring-production-backend",
            keyNames: ["POSTGRES_PASSWORD", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "JWT_SECRET"],
            command: "docker compose -f deploy/compose.prod.yml run --rm migrate && ./scripts/seed.sh --env production --force",
            timedMinutes: 240)
        let noTimed = CaseApprovalRequest(appName: "Codex", projectName: "alpha", keyNames: ["DB_URL"],
                                          command: "psql \"$DB_URL\" -c 'select 1'", timedMinutes: 0)

        let a = try render(short, width: 312, name: "case-approval-312")
        let b = try render(long, width: 310, pending: 2, name: "case-approval-310-long-queue")
        let c = try render(noTimed, width: 312, name: "case-approval-312-no-timed")
        let d = try render(short, width: 312, armed: false, name: "case-approval-312-arming")

        for size in [a, b, c, d] {
            XCTAssertLessThanOrEqual(size.width, 312.5)
            XCTAssertLessThan(size.height, 175, "a compact card with editable minutes")
        }
        XCTAssertEqual(a.height, b.height, accuracy: 0.5, "long text truncates instead of wrapping")
        XCTAssertGreaterThan(a.height, c.height, "timed requests include the duration control")
    }

    func test_prompt_sits_below_the_agent_answer_card_offscreen() throws {
        _ = NSApplication.shared
        // Built-in OpenCode ran `whytap case run`: its answer card and the prompt are both up.
        let island = NSRect(x: 600, y: 1_000, width: 312, height: 32)
        let request = CaseApprovalRequest(appName: "Whytap agent", projectName: "whytap",
                                          keyNames: ["OPENROUTER_API_KEY"],
                                          command: "swift test --filter CaseBrokerTests", timedMinutes: 15)
        let promptHeight = NSHostingView(rootView: CaseApprovalView(
            request: request, width: island.width, pendingCount: 0, isArmed: true, onChoose: { _ in })).fittingSize.height

        for answerHeight: CGFloat in [0, 96, 240, 480] {
            // The answer card hangs agentWingGap under the island, right-aligned to it.
            let card = NSRect(x: island.maxX - IslandFrameLayout.agentAnswerPanelWidth,
                              y: island.minY - IslandFrameLayout.agentWingGap - answerHeight,
                              width: IslandFrameLayout.agentAnswerPanelWidth, height: answerHeight)
            let prompt = CaseApprovalPanel.frame(islandFrame: island, cardHeight: promptHeight,
                                                 meetingNudgeVisible: false, agentAnswerHeight: answerHeight)
            XCTAssertEqual(prompt.width, island.width)
            XCTAssertLessThanOrEqual(prompt.maxY, island.minY + CaseApprovalView.islandSeam)
            if answerHeight > 0 {
                XCTAssertFalse(prompt.intersects(card), "answer \(answerHeight): prompt covers the agent card")
                XCTAssertLessThanOrEqual(prompt.maxY, card.minY - CaseApprovalPanel.agentCardGap + 0.5)
            } else {
                XCTAssertEqual(prompt.maxY, island.minY + CaseApprovalView.islandSeam,
                               "without a card the prompt overlaps the island's edge by the seam: no line between them")
            }
            // A meeting nudge and a card: the prompt goes under the lower of the two.
            let both = CaseApprovalPanel.frame(islandFrame: island, cardHeight: promptHeight,
                                               meetingNudgeVisible: true, agentAnswerHeight: answerHeight)
            // Under the nudge it overlaps the nudge's edge by the same seam.
            XCTAssertLessThanOrEqual(both.maxY, min(prompt.maxY, island.minY - MeetingPillPanel.suggestionNudgeHeight
                + (answerHeight > 0 ? 0 : CaseApprovalView.islandSeam)))
        }

        // Offscreen picture of the 240 pt case (screen y-up mapped to view y-down).
        let answerHeight: CGFloat = 240
        let card = NSRect(x: island.maxX - IslandFrameLayout.agentAnswerPanelWidth,
                          y: island.minY - IslandFrameLayout.agentWingGap - answerHeight,
                          width: IslandFrameLayout.agentAnswerPanelWidth, height: answerHeight)
        let prompt = CaseApprovalPanel.frame(islandFrame: island, cardHeight: promptHeight,
                                             meetingNudgeVisible: false, agentAnswerHeight: answerHeight)
        let originX = card.minX - 24, top = island.maxY + 24
        func place(_ r: NSRect) -> CGPoint { CGPoint(x: r.midX - originX, y: top - r.midY) }
        let size = CGSize(width: card.width + 48, height: top - prompt.minY + 24)
        let scene = ZStack(alignment: .topLeading) {
            Color(white: 0.8)
            RoundedRectangle(cornerRadius: 10).fill(Color.black)
                .frame(width: island.width, height: island.height).position(place(island))
            RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.12))
                .overlay(Text("Agent answer card").foregroundColor(.white))
                .frame(width: card.width, height: card.height).position(place(card))
            CaseApprovalView(request: request, width: island.width, pendingCount: 0, isArmed: true,
                             onChoose: { _ in })
                .frame(width: prompt.width, height: prompt.height).position(place(prompt))
        }
        .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: scene)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertFalse(window.isVisible || window.isKeyWindow, "renders stay offscreen")
        if let output = ProcessInfo.processInfo.environment["EXODIA_CASE_PROOF_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("case-approval-under-agent-card.png"))
        }
        window.contentView = nil
        window.close()
    }
}

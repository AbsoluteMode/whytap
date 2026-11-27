import CoreGraphics
import Foundation
import XCTest
@testable import Sidekey

@MainActor
final class AutoPasteEngineTests: XCTestCase {
    private static let targetA = AutoPasteEngine.RememberedTarget(pid: 100, name: "TextEdit")
    private static let targetB = AutoPasteEngine.RememberedTarget(pid: 200, name: "FloatingPanel")
    private static let cmd: CGKeyCode = 0x37  // kVK_Command
    private static let v: CGKeyCode = 0x09    // kVK_ANSI_V

    // MARK: - Happy path

    func testPasteHappyPathReturnsTrueAndPostsCmdVSequence() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()

        let result = await engine.paste("hello")

        XCTAssertTrue(result)
        XCTAssertEqual(env.pastedText, "hello")
        XCTAssertEqual(env.postedEvents.count, 4)
        XCTAssertEqual(env.postedEvents[0].keyCode, Self.cmd)
        XCTAssertTrue(env.postedEvents[0].down)
        XCTAssertTrue(env.postedEvents[0].flags.isEmpty)
        XCTAssertEqual(env.postedEvents[1].keyCode, Self.v)
        XCTAssertTrue(env.postedEvents[1].down)
        XCTAssertTrue(env.postedEvents[1].flags.contains(.maskCommand))
        XCTAssertEqual(env.postedEvents[2].keyCode, Self.v)
        XCTAssertFalse(env.postedEvents[2].down)
        XCTAssertTrue(env.postedEvents[2].flags.contains(.maskCommand))
        XCTAssertEqual(env.postedEvents[3].keyCode, Self.cmd)
        XCTAssertFalse(env.postedEvents[3].down)
        XCTAssertTrue(env.postedEvents[3].flags.isEmpty)
    }

    func testPasteHappyPathEmitsExpectedLogLineSequence() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()

        _ = await engine.paste("hi")

        XCTAssertTrue(env.logs.contains(where: { $0.message.hasPrefix("autopaste_target_remembered name=TextEdit pid=100") }))
        XCTAssertTrue(env.logs.contains(where: { $0.message.hasPrefix("autopaste_clipboard_updated") && $0.message.contains("chars=2") }))
        XCTAssertTrue(env.logs.contains(where: { $0.message.hasPrefix("autopaste_modifiers_released wait_ms=") }))
        XCTAssertTrue(env.logs.contains(where: { $0.message.hasPrefix("autopaste_focus_restored from=TextEdit to=TextEdit") }))
        XCTAssertTrue(env.logs.contains(where: { $0.message == "autopaste_posted_cmdv" }))
    }

    // MARK: - History multi-paste series (one target for the whole series)

    private static let mixedSeries: [HistoryPasteGroup] = [
        .text("first"),
        .attachments([.file(URL(fileURLWithPath: "/tmp/second.pdf"))]),
        .text("third"),
    ]

    func testHistorySeriesPastesEveryGroupIntoTheTarget() async throws {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        let target = try XCTUnwrap(engine.currentTarget())
        var writes: [HistoryPasteGroup] = []
        let paster = HistoryMultiPaster(
            targetIsCurrent: { engine.isSeriesTargetCurrent(target, requireFrontmost: !$0) },
            write: { writes.append($0) },
            paste: { await engine.pasteAlreadyOnPasteboard(into: target, restoringFocus: $0) },
            sleep: { _ in }
        )

        let posted = await paster.run(Self.mixedSeries)

        XCTAssertEqual(posted, 3)
        XCTAssertEqual(writes, Self.mixedSeries)
        XCTAssertEqual(env.postedEvents.count, 12, "Three Cmd+V sequences")
        XCTAssertTrue(env.postedEvents.allSatisfy { $0.pid == Self.targetA.pid },
                      "Every series key event is addressed to the target, never the global HID stream")
    }

    /// Index in `postedEvents` of the second group's Command-down.
    private static let secondGroupCommandDown = 4

    func testHistorySeriesNeverRoutesVDownToAnAppThatTookFocusInsideCmdV() async throws {
        // Focus moves to B in the 12 ms between the second group's
        // Command-down and V-down. Nothing may reach B, the target gets its
        // Command released, and the third group is never written.
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        let target = try XCTUnwrap(engine.currentTarget())
        env.onSleep = { us in
            if us == AutoPasteEngine.keyEventGapUs,
               env.postedEvents.count == Self.secondGroupCommandDown + 1 {
                env.frontmost = Self.targetB
            }
        }
        var writes: [HistoryPasteGroup] = []
        let paster = HistoryMultiPaster(
            targetIsCurrent: { engine.isSeriesTargetCurrent(target, requireFrontmost: !$0) },
            write: { writes.append($0) },
            paste: { await engine.pasteAlreadyOnPasteboard(into: target, restoringFocus: $0) },
            sleep: { _ in }
        )

        let posted = await paster.run(Self.mixedSeries)

        XCTAssertEqual(posted, 1, "The interrupted group does not count as sent")
        XCTAssertEqual(writes, Array(Self.mixedSeries.prefix(2)), "The third group is never written")
        XCTAssertTrue(env.postedEvents.allSatisfy { $0.pid == Self.targetA.pid }, "Nothing reaches B")
        XCTAssertEqual(Array(env.postedEvents.dropFirst(Self.secondGroupCommandDown)), [
            .init(keyCode: Self.cmd, down: true, flags: [], pid: Self.targetA.pid),
            .init(keyCode: Self.cmd, down: false, flags: [], pid: Self.targetA.pid),
        ], "Command is released in the target; no V-down")
        XCTAssertFalse(env.activatedPids.contains(Self.targetA.pid),
                       "A later paste never takes focus back")
    }

    func testHistorySeriesStopsWhenTheTargetQuitsInsideCmdV() async throws {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        let target = try XCTUnwrap(engine.currentTarget())
        env.onSleep = { us in
            if us == AutoPasteEngine.keyEventGapUs,
               env.postedEvents.count == Self.secondGroupCommandDown + 1 {
                env.terminatedPids.insert(Self.targetA.pid)
                env.frontmost = Self.targetB
            }
        }
        var writes: [HistoryPasteGroup] = []
        let paster = HistoryMultiPaster(
            targetIsCurrent: { engine.isSeriesTargetCurrent(target, requireFrontmost: !$0) },
            write: { writes.append($0) },
            paste: { await engine.pasteAlreadyOnPasteboard(into: target, restoringFocus: $0) },
            sleep: { _ in }
        )

        let posted = await paster.run(Self.mixedSeries)

        XCTAssertEqual(posted, 1)
        XCTAssertEqual(writes, Array(Self.mixedSeries.prefix(2)))
        XCTAssertTrue(env.postedEvents.allSatisfy { $0.pid == Self.targetA.pid }, "Nothing reaches B")
        XCTAssertFalse(env.postedEvents.dropFirst(Self.secondGroupCommandDown)
            .contains { $0.keyCode == Self.v && $0.down }, "No V-down after the target quit")
    }

    func testHistorySeriesStopsWhenTheUserMovesFocusBetweenPastes() async throws {
        // Focus alone moves to B in the pause between groups: the series
        // does not activate A again and writes nothing more.
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        let target = try XCTUnwrap(engine.currentTarget())
        var writes: [HistoryPasteGroup] = []
        let paster = HistoryMultiPaster(
            targetIsCurrent: { engine.isSeriesTargetCurrent(target, requireFrontmost: !$0) },
            write: { writes.append($0) },
            paste: { await engine.pasteAlreadyOnPasteboard(into: target, restoringFocus: $0) },
            sleep: { _ in env.frontmost = Self.targetB }
        )

        let posted = await paster.run(Self.mixedSeries)

        XCTAssertEqual(posted, 1)
        XCTAssertEqual(writes, [.text("first")])
        XCTAssertEqual(env.postedEvents.count, 4)
        XCTAssertTrue(env.activatedPids.isEmpty)
    }

    func testSingleRowHistoryPasteStillUsesTheGlobalCmdV() async {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()

        let posted = await engine.pasteAlreadyOnPasteboard()

        XCTAssertTrue(posted)
        XCTAssertEqual(env.postedEvents.count, 4)
        XCTAssertTrue(env.postedEvents.allSatisfy { $0.pid == nil }, "Unchanged single-row Enter path")
    }

    func testHistorySeriesStopsWhenANewCaptureReplacesTheTargetDuringTheGap() async throws {
        // Between pastes the user starts Drop or reopens History in another
        // app: the engine's remembered target becomes B. The next Cmd+V must
        // not go to B, and the pasteboard must keep what was pasted.
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        let target = try XCTUnwrap(engine.currentTarget())
        var writes: [HistoryPasteGroup] = []
        let paster = HistoryMultiPaster(
            targetIsCurrent: { engine.isSeriesTargetCurrent(target, requireFrontmost: !$0) },
            write: { writes.append($0) },
            paste: { await engine.pasteAlreadyOnPasteboard(into: target, restoringFocus: $0) },
            sleep: { _ in
                env.frontmost = Self.targetB
                engine.rememberTargetBeforeRecording()
            }
        )

        let posted = await paster.run(Self.mixedSeries)

        XCTAssertEqual(posted, 1)
        XCTAssertEqual(writes, [.text("first")], "Nothing else is written once the target changed")
        XCTAssertEqual(env.postedEvents.count, 4, "Only the first Cmd+V, into A")
        XCTAssertFalse(env.activatedPids.contains(Self.targetB.pid))
    }

    func testHistorySeriesStopsWhenTheTargetAppQuitsDuringTheGap() async throws {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        let target = try XCTUnwrap(engine.currentTarget())
        var writes: [HistoryPasteGroup] = []
        let paster = HistoryMultiPaster(
            targetIsCurrent: { engine.isSeriesTargetCurrent(target, requireFrontmost: !$0) },
            write: { writes.append($0) },
            paste: { await engine.pasteAlreadyOnPasteboard(into: target, restoringFocus: $0) },
            sleep: { _ in
                env.terminatedPids.insert(Self.targetA.pid)
                env.frontmost = Self.targetB   // macOS hands focus to another app
            }
        )

        let posted = await paster.run(Self.mixedSeries)

        XCTAssertEqual(posted, 1)
        XCTAssertEqual(writes, [.text("first")])
        XCTAssertEqual(env.postedEvents.count, 4, "No Cmd+V into the app that took focus")
    }

    func testSeriesPasteRefusesATargetReplacedAfterTheSeriesCheck() async throws {
        // The engine checks again itself: even if the caller's check passed,
        // a replaced target gets no key events.
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        let target = try XCTUnwrap(engine.currentTarget())
        env.frontmost = Self.targetB
        engine.rememberTargetBeforeRecording()

        let posted = await engine.pasteAlreadyOnPasteboard(into: target, restoringFocus: true)

        XCTAssertFalse(posted)
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertTrue(env.logs.contains { $0.message == "autopaste_series_stopped reason=target_changed" })
    }

    func testSeriesPasteRefusesWhenFocusCannotReturnToTheTarget() async throws {
        // Ordinary History paste degrades to "wherever focus is"; a series
        // paste must not.
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        let target = try XCTUnwrap(engine.currentTarget())
        env.frontmost = Self.targetB   // activation will not bring A back

        let posted = await engine.pasteAlreadyOnPasteboard(into: target, restoringFocus: true)

        XCTAssertFalse(posted)
        XCTAssertEqual(env.activatedPids, [Self.targetA.pid])
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertTrue(env.logs.contains { $0.message == "autopaste_series_stopped reason=focus_not_restored" })
    }

    // MARK: - Empty / pasteboard

    func testPasteEmptyStringReturnsFalseAndDoesNothing() async {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()

        let result = await engine.paste("")

        XCTAssertFalse(result)
        XCTAssertNil(env.pastedText)
        XCTAssertTrue(env.postedEvents.isEmpty)
    }

    func testPasteReturnsFalseWhenPasteboardWriteFailsAndDoesNotPost() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true,
            pasteboardWriteSucceeds: false
        )
        let engine = env.makeEngine()

        let result = await engine.paste("hello")

        XCTAssertFalse(result)
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertTrue(env.logs.contains(where: { $0.level == .error && $0.message == "autopaste_failed step=pasteboard reason=write_returned_nil" }))
    }

    // MARK: - Permission (advisory)

    /// On macOS Tahoe adhoc-signed builds, `CGPreflightPostEventAccess`
    /// returns `false` even when the post works in practice (Accessibility
    /// is the actual gate; no separate Post Event pane exists in System
    /// Settings). The engine must log the preflight result for diagnosis
    /// but proceed through modifier-wait → focus-restore → post anyway.
    func testPasteProceedsWhenPermissionPreflightFalseWithAdvisoryLog() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: false
        )
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()

        let result = await engine.paste("hello")

        XCTAssertTrue(result, "preflight false is advisory; pipeline should complete")
        XCTAssertEqual(env.pastedText, "hello")
        XCTAssertEqual(env.postedEvents.count, 4, "Cmd+V sequence still posted")
        XCTAssertTrue(env.logs.contains(where: {
            $0.level == .info && $0.message == "autopaste_post_event_preflight_false advisory=true"
        }))
        XCTAssertFalse(env.logs.contains(where: {
            $0.message == "autopaste_failed step=permission reason=post_event_denied"
        }), "old hard-guard log line must not appear")
    }

    // MARK: - Modifier wait

    func testPasteTimesOutWhenModifiersNeverRelease() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[.maskCommand]],  // stuck — always returns Command
            permission: true
        )
        let engine = env.makeEngine()

        let result = await engine.paste("hello")

        XCTAssertFalse(result)
        XCTAssertEqual(env.pastedText, "hello")
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertTrue(env.logs.contains(where: { $0.level == .error && $0.message == "autopaste_failed step=modifiers reason=timeout" }))
    }

    func testPasteSucceedsAfterModifiersClearOnSecondPoll() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[.maskAlternate], []],
            permission: true
        )
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()

        let result = await engine.paste("hi")

        XCTAssertTrue(result)
        XCTAssertEqual(env.postedEvents.count, 4)
        // The first flagsState read sees Option held; we should have slept
        // once with the modifierPollInterval before re-polling.
        let modifierPollUs = UInt32(AutoPasteEngine.modifierPollIntervalMs) * 1000
        XCTAssertTrue(env.sleepCalls.contains(modifierPollUs), "should poll-sleep once when modifiers held")
    }

    // MARK: - Focus restore

    func testPasteSkipsFocusRestoreWhenTargetTerminated() async {
        let env = TestEnv(
            frontmost: Self.targetB,
            modifierFlagsSequence: [[]],
            permission: true,
            terminatedPids: [Self.targetA.pid]
        )
        let engine = env.makeEngine()
        // remember target A explicitly, then simulate that A died: frontmost
        // already moved to B (capture B), engine's remembered is still A.
        env.frontmost = Self.targetA
        engine.rememberTargetBeforeRecording()
        env.frontmost = Self.targetB

        let result = await engine.paste("hi")

        XCTAssertTrue(result)
        XCTAssertTrue(env.activatedPids.isEmpty, "must not try to activate a terminated app")
        XCTAssertTrue(env.logs.contains(where: { $0.message.hasPrefix("autopaste_focus_restored from=FloatingPanel to=(terminated)") }))
    }

    func testPasteSkipsFocusRestoreWhenNoRememberedTarget() async {
        let env = TestEnv(
            frontmost: Self.targetB,
            modifierFlagsSequence: [[]],
            permission: true
        )
        let engine = env.makeEngine()

        let result = await engine.paste("hi")

        XCTAssertTrue(result)
        XCTAssertTrue(env.activatedPids.isEmpty)
        XCTAssertTrue(env.logs.contains(where: { $0.message.hasPrefix("autopaste_focus_restored from=FloatingPanel to=(no_target)") }))
    }

    func testPasteActivatesRememberedTargetWhenFocusHasDrifted() async {
        let env = TestEnv(
            frontmost: Self.targetA,  // remembered later
            modifierFlagsSequence: [[]],
            permission: true
        )
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        // Now simulate that focus has drifted to the floating panel.
        env.frontmost = Self.targetB
        // After activate(targetA.pid), the test environment will return
        // targetA on the next frontmost poll.
        env.frontmostAfterActivate = Self.targetA

        let result = await engine.paste("hi")

        XCTAssertTrue(result)
        XCTAssertEqual(env.activatedPids, [Self.targetA.pid])
        XCTAssertTrue(env.logs.contains(where: { $0.message == "autopaste_focus_restored from=FloatingPanel to=TextEdit" }))
    }

    // MARK: - remember()

    func testRememberCapturesFrontmostInfo() {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()

        engine.rememberTargetBeforeRecording()

        XCTAssertEqual(engine.currentTarget(), Self.targetA)
        XCTAssertTrue(env.logs.contains(where: { $0.message == "autopaste_target_remembered name=TextEdit pid=100" }))
    }

    func testRememberHandlesNoFrontmost() {
        let env = TestEnv(frontmost: nil, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()

        engine.rememberTargetBeforeRecording()

        XCTAssertNil(engine.currentTarget())
        XCTAssertTrue(env.logs.contains(where: { $0.message == "autopaste_target_remembered name=(none) pid=0" }))
    }

    // MARK: - Pasteboard preserve/restore (History Strip feature)

    /// Drop must NOT pollute the user's clipboard history. The happy
    /// path: snapshot current pasteboard → write dictation → synth Cmd+V
    /// → restore snapshot once the paste has settled. After the pending
    /// restore, the system pasteboard should match what was there when
    /// the user pressed the hotkey, not the dictated text.
    func testPasteSnapshotsBeforeWriteAndRestoresAfterSuccess() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        env.initialPasteboardItems = [["public.utf8-plain-text": Data("original".utf8)]]
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()

        let result = await engine.paste("dictated")

        XCTAssertTrue(result)
        XCTAssertTrue(env.restoreCalls.isEmpty, "the restore waits for the target, after paste returns")
        XCTAssertTrue(engine.hasPendingRestore)
        await engine.waitForPendingRestore()
        XCTAssertFalse(engine.hasPendingRestore)
        XCTAssertEqual(env.snapshotCalls, 1, "snapshot must be captured before any write")
        XCTAssertEqual(env.restoreCalls.count, 1, "snapshot must be restored after settle")
        XCTAssertEqual(
            env.restoreCalls.first?.items.first?["public.utf8-plain-text"],
            Data("original".utf8)
        )
        XCTAssertEqual(env.snapshotsTaken.first?.items.first?["public.utf8-plain-text"], Data("original".utf8))
    }

    /// On modifier-wait timeout the engine returns false. The snapshot
    /// should still be restored because we already wrote the dictation
    /// into the pasteboard (step 1) — leaving it there would leak the
    /// dictation into the user's clipboard.
    func testPasteRestoresSnapshotEvenWhenModifierWaitTimesOut() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[.maskCommand]],
            permission: true
        )
        env.initialPasteboardItems = [["public.utf8-plain-text": Data("kept".utf8)]]
        let engine = env.makeEngine()

        let result = await engine.paste("dictated")

        XCTAssertFalse(result)
        XCTAssertEqual(env.snapshotCalls, 1)
        XCTAssertEqual(env.restoreCalls.count, 1, "snapshot must be restored even on failure")
    }

    /// When the pasteboard write itself fails (step 1), we have nothing
    /// to restore — the snapshot is still captured for parity but the
    /// engine returns false without restoring (no write occurred).
    func testPasteSkipsRestoreWhenWriteFailedBeforeMutation() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true,
            pasteboardWriteSucceeds: false
        )
        env.initialPasteboardItems = [["public.utf8-plain-text": Data("kept".utf8)]]
        let engine = env.makeEngine()

        let result = await engine.paste("dictated")

        XCTAssertFalse(result)
        XCTAssertEqual(env.snapshotCalls, 1)
        XCTAssertEqual(
            env.restoreCalls.count,
            0,
            "no write happened, so nothing to restore"
        )
    }

    /// Empty dictation: the engine returns false before snapshotting,
    /// since there is no write to compensate for.
    func testPasteEmptyStringDoesNotSnapshot() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        let engine = env.makeEngine()

        let result = await engine.paste("")

        XCTAssertFalse(result)
        XCTAssertEqual(env.snapshotCalls, 0)
        XCTAssertEqual(env.restoreCalls.count, 0)
    }

    /// The engine sets a suppression flag on its `ClipboardSuppression`
    /// coordinator before any pasteboard mutation, and clears it after
    /// the restore completes. `ClipboardWatcher` reads this flag to skip
    /// capture during the drop window.
    func testPasteSetsAndClearsClipboardSuppressionAcrossDropWindow() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        env.initialPasteboardItems = [["public.utf8-plain-text": Data("o".utf8)]]
        let engine = env.makeEngine()

        let result = await engine.paste("hi")
        await engine.waitForPendingRestore()

        XCTAssertTrue(result)
        XCTAssertEqual(env.suppressionCalls.first, true, "suppression must be set before write")
        XCTAssertEqual(env.suppressionCalls.last, false, "suppression must be cleared after restore")
    }

    /// Race protection: when the entire drop happens between two
    /// `ClipboardWatcher` polls (the watcher polls every 500 ms; a fast
    /// drop completes in <100 ms), the watcher never observes the flag
    /// set — by the time its next poll fires, the flag is already
    /// cleared but changeCount has bumped twice (write + restore).
    /// The engine must therefore raise the `skipThrough` threshold to
    /// the pasteboard's post-restore changeCount BEFORE clearing the
    /// flag, so the watcher's next poll skips on the threshold check
    /// even though the flag is off.
    func testPasteRaisesSuppressionThresholdAfterRestoreBeforeClearingFlag() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        env.initialPasteboardItems = [["public.utf8-plain-text": Data("o".utf8)]]
        // The simulated pasteboard bumps changeCount to 1 for the
        // dictation write and to 2 for the restore.
        let engine = env.makeEngine()

        let result = await engine.paste("hi")
        await engine.waitForPendingRestore()

        XCTAssertTrue(result)
        // Order matters: suppressThrough(2) must land BEFORE
        // setSuppressed(false). Otherwise the next poll sees the flag
        // cleared but the threshold still unset → records the restored
        // pasteboard as a clipboard artefact.
        XCTAssertEqual(
            env.suppressionThresholdCalls,
            [1, 2],
            "threshold covers the dictation write, then the restore"
        )
        XCTAssertEqual(env.suppressionEventOrder.prefix(3), [.flag(true), .threshold(1), .flag(false)],
                       "the write is covered by the threshold before the flag drops")
        guard let thresholdIdx = env.suppressionEventOrder.firstIndex(of: .threshold(2)),
              let clearIdx = env.suppressionEventOrder.lastIndex(of: .flag(false))
        else {
            XCTFail("Expected both threshold and clear events to be recorded")
            return
        }
        XCTAssertLessThan(
            thresholdIdx,
            clearIdx,
            "suppressThrough must precede setSuppressed(false) — else race window remains open"
        )
    }

    // MARK: - Restore after the target reads (Chromium/Electron race)

    private func makeRestoreEnv(initial: [[String: Data]] = [["public.utf8-plain-text": Data("original".utf8)]]) -> TestEnv {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        env.initialPasteboardItems = initial
        return env
    }

    private func restoredLine(_ env: TestEnv) -> String? {
        env.logs.first(where: { $0.message.hasPrefix("autopaste_pasteboard_restored") })?.message
    }

    private func waitMs(in line: String?) -> UInt64? {
        guard let line, let range = line.range(of: "wait_ms=") else { return nil }
        return UInt64(line[range.upperBound...].prefix(while: { $0.isNumber }))
    }

    /// The 2026-11-27 bug: a busy Electron renderer read the pasteboard
    /// later than the old fixed 120 ms restore and pasted the previous
    /// clipboard. The dictation must stay until the reader takes it.
    func testSlowReaderAfter120msStillReadsTheDictation() async {
        let env = makeRestoreEnv()
        env.readerDelaysMs = [400]
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()

        let result = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertTrue(result)
        XCTAssertEqual(env.readerSaw, ["dictated"])
        XCTAssertEqual(env.restoreCalls.count, 1)
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems)
        let line = restoredLine(env)
        XCTAssertTrue(line?.contains("after=read") ?? false, line ?? "no restore line")
        XCTAssertTrue(line?.contains("reads=1") ?? false)
        XCTAssertGreaterThanOrEqual((env.restoreTimesMs.first ?? 0) - (env.readTimesMs.first ?? .max),
                                    AutoPasteEngine.RestoreTiming.standard.afterReadMs)
    }

    func testFastReaderGetsTheClipboardBackSoonAfterItsRead() async {
        let env = makeRestoreEnv()
        env.readerDelaysMs = [20]
        let engine = env.makeEngine()

        _ = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertEqual(env.readerSaw, ["dictated"])
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems)
        XCTAssertLessThan(waitMs(in: restoredLine(env)) ?? .max, 300)
    }

    /// Readers that take several types read them in a burst; the restore
    /// waits for the quiet time after the last one.
    func testReaderTakingSeveralTypesKeepsTheDictationUntilItsLastRead() async {
        let env = makeRestoreEnv()
        env.readerDelaysMs = [300, 420]
        let engine = env.makeEngine()

        _ = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertEqual(env.readerSaw, ["dictated", "dictated"])
        XCTAssertTrue(restoredLine(env)?.contains("reads=2") ?? false)
        XCTAssertGreaterThanOrEqual((env.restoreTimesMs.first ?? 0) - (env.readTimesMs.last ?? .max),
                                    AutoPasteEngine.RestoreTiming.standard.afterReadMs,
                                    "the restore waits for quiet after the LAST read")
    }

    /// No reader at all (the target ignored Cmd+V): the clipboard still
    /// comes back, after the fallback timeout.
    func testNoReaderRestoresAfterTheFallbackTimeout() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()

        let result = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertTrue(result)
        XCTAssertEqual(env.restoreCalls.count, 1)
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems)
        let line = restoredLine(env)
        XCTAssertTrue(line?.contains("after=timeout") ?? false, line ?? "no restore line")
        let fallback = AutoPasteEngine.RestoreTiming.standard.fallbackMs
        XCTAssertGreaterThanOrEqual(waitMs(in: line) ?? 0, fallback)
        XCTAssertLessThan(waitMs(in: line) ?? .max, fallback + 100)
    }

    /// A clipboard manager that reads before Cmd+V is not the target: its
    /// read must not shorten the wait (the target would then be served the
    /// cached dictation without a signal, so only the fallback is safe).
    func testReadBeforeCmdVIsNotTakenForTheTarget() async {
        let env = makeRestoreEnv()
        var earlyReads = 0
        env.onAsyncSleep = { [unowned env] in
            if env.postedEvents.isEmpty, earlyReads == 0 {
                earlyReads += 1
                env.readMonitor.noteRead()
            }
        }
        let engine = env.makeEngine()

        _ = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertEqual(earlyReads, 1)
        XCTAssertTrue(restoredLine(env)?.contains("after=timeout") ?? false, restoredLine(env) ?? "no restore line")
    }

    /// The user copies something while the paste waits for its restore:
    /// the copy stays on the clipboard and reaches clipboard history.
    func testUserCopyWhileTheRestoreWaitsIsNotClobbered() async {
        let env = makeRestoreEnv()
        var flagWhenCopied: Bool?
        var copiedChangeCount: Int?
        env.onAsyncSleep = { [unowned env] in
            guard copiedChangeCount == nil, let vDown = env.vDownAtMs, env.nowForTest >= vDown + 50 else { return }
            env.userCopies("mine")
            copiedChangeCount = env.changeCount
            flagWhenCopied = env.suppressionCalls.last
        }
        let engine = env.makeEngine()

        _ = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertTrue(env.restoreCalls.isEmpty)
        XCTAssertEqual(env.pasteboardItems, [["public.utf8-plain-text": Data("mine".utf8)]])
        XCTAssertEqual(flagWhenCopied, false, "the watcher must not be suppressed while the user copies")
        XCTAssertLessThan(env.suppressionThresholdCalls.max() ?? -1, copiedChangeCount ?? 0,
                          "the threshold must not cover the user's copy")
        XCTAssertTrue(env.logs.contains(where: { $0.message.hasPrefix("autopaste_pasteboard_restore_skipped reason=replaced") }))
    }

    /// Two takes back to back: the second starts while the first waits for
    /// its restore. It must not snapshot the first dictation as "the
    /// user's clipboard"; the original comes back once, at the end.
    func testSecondTakeBeforeTheRestoreKeepsTheUsersClipboard() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()

        _ = await engine.paste("one")
        XCTAssertTrue(engine.hasPendingRestore)
        _ = await engine.paste("two")
        await engine.waitForPendingRestore()

        XCTAssertEqual(env.snapshotCalls, 1, "the second take inherits the pending snapshot")
        XCTAssertEqual(env.restoreCalls.count, 1)
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems)
        XCTAssertTrue(env.logs.contains(where: { $0.message.hasSuffix("inherited=true") }))
    }

    func testSecondTakeAfterAUserCopySnapshotsTheNewClipboard() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()

        _ = await engine.paste("one")
        env.userCopies("mine")
        _ = await engine.paste("two")
        await engine.waitForPendingRestore()

        XCTAssertEqual(env.logs.filter { $0.message.hasSuffix("inherited=false") }.count, 2,
                       "the second take snapshots the user's copy, not the first dictation")
        XCTAssertEqual(env.pasteboardItems, [["public.utf8-plain-text": Data("mine".utf8)]])
    }

    /// The second take inherits the snapshot but its own write fails: the
    /// pasteboard still holds the first dictation, so restore right away.
    func testSecondTakeWhoseWriteFailsStillGivesTheClipboardBack() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()

        _ = await engine.paste("one")
        env.pasteboardWriteSucceeds = false
        let second = await engine.paste("two")
        await engine.waitForPendingRestore()

        XCTAssertFalse(second)
        XCTAssertEqual(env.restoreCalls.count, 1)
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems)
        XCTAssertFalse(engine.hasPendingRestore)
    }

    /// Image-only previous clipboard (the reported case held png/tiff):
    /// the reader gets the text, and the image comes back intact.
    func testImageOnlyPreviousClipboardComesBackAfterTheRead() async {
        let image: [[String: Data]] = [["public.png": Data([0x89, 0x50]), "public.tiff": Data([0x4D, 0x4D])]]
        let env = makeRestoreEnv(initial: image)
        env.readerDelaysMs = [250]
        let engine = env.makeEngine()

        _ = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertEqual(env.readerSaw, ["dictated"])
        XCTAssertEqual(env.pasteboardItems, image)
    }

    func testQuitWhileTheRestoreWaitsGivesTheClipboardBackImmediately() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()

        _ = await engine.paste("dictated")
        engine.flushPendingRestore()
        await engine.waitForPendingRestore()

        XCTAssertEqual(env.restoreCalls.count, 1)
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems)
        XCTAssertTrue(restoredLine(env)?.contains("after=flush") ?? false)
    }

    // MARK: - Clipboard ownership (queue ticket 687 review)

    /// A copy that lands between Drop's write and its ownership check is
    /// not Drop's generation: not pasted, not overwritten, and not hidden
    /// from clipboard history by the threshold.
    func testQueue687FreshCopyAfterWriteDoesNotBecomeDropsOwnedGeneration() async {
        let env = makeRestoreEnv()
        env.onLog = { [unowned env] message in
            guard message.hasPrefix("autopaste_clipboard_updated") else { return }
            env.userCopies("fresh copy")
        }
        let engine = env.makeEngine()

        let result = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertFalse(result)
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertEqual(env.pasteboardItems, [["public.utf8-plain-text": Data("fresh copy".utf8)]])
        XCTAssertTrue(env.restoreCalls.isEmpty)
        XCTAssertLessThan(env.suppressionThresholdCalls.max() ?? -1, 2)
        XCTAssertFalse(engine.hasPendingRestore)
    }

    func testQueue687ClipboardReplacementBeforeCmdVAbortsWithoutPosting() async {
        let env = makeRestoreEnv()
        env.onAsyncSleep = { [unowned env] in
            guard env.asyncSleepCalls.count == 1 else { return }
            env.userCopies("newer copy")
        }
        let engine = env.makeEngine()

        let result = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertFalse(result)
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertEqual(env.pasteboardItems, [["public.utf8-plain-text": Data("newer copy".utf8)]])
        XCTAssertTrue(env.restoreCalls.isEmpty)
    }

    func testQueue687ModifierTimeoutDoesNotOverwriteANewerClipboardOwner() async {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[.maskCommand]], permission: true)
        env.initialPasteboardItems = [["public.utf8-plain-text": Data("original".utf8)]]
        env.onSleep = { [unowned env] _ in
            guard env.sleepCalls.count == 1 else { return }
            env.userCopies("newer copy")
        }
        let engine = env.makeEngine()

        let result = await engine.paste("dictated")

        XCTAssertFalse(result)
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertEqual(env.pasteboardItems, [["public.utf8-plain-text": Data("newer copy".utf8)]])
        XCTAssertTrue(env.restoreCalls.isEmpty)
    }

    /// Quit while the paste waits before Cmd+V: the clipboard comes back at
    /// once and the paste stops without a key event.
    func testQueue687QuitAtThePrePasteAwaitRestoresImmediatelyAndStopsPosting() async {
        let image: [[String: Data]] = [["public.png": Data([0x89, 0x50]), "public.utf8-plain-text": Data("caption".utf8)]]
        let env = makeRestoreEnv(initial: image)
        let engine = env.makeEngine()
        var clipboardAtQuit: [[String: Data]]?
        env.onAsyncSleep = { [unowned env, weak engine] in
            guard env.asyncSleepCalls.count == 1 else { return }
            engine?.flushPendingRestore()
            clipboardAtQuit = env.pasteboardItems
        }

        let result = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertEqual(clipboardAtQuit, image)
        XCTAssertFalse(result)
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertEqual(env.restoreCalls.count, 1)
    }

    func testQuitBeforeCmdVLeavesANewerClipboardOwnerAlone() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()
        env.onAsyncSleep = { [unowned env, weak engine] in
            guard env.asyncSleepCalls.count == 1 else { return }
            env.userCopies("newer copy")
            engine?.flushPendingRestore()
        }

        let result = await engine.paste("dictated")

        XCTAssertFalse(result)
        XCTAssertTrue(env.postedEvents.isEmpty)
        XCTAssertTrue(env.restoreCalls.isEmpty)
        XCTAssertEqual(env.pasteboardItems, [["public.utf8-plain-text": Data("newer copy".utf8)]])
    }

    func testQuitAfterCmdVLeavesANewerClipboardOwnerAlone() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()

        _ = await engine.paste("dictated")
        env.userCopies("newer copy")
        engine.flushPendingRestore()
        await engine.waitForPendingRestore()

        XCTAssertTrue(env.restoreCalls.isEmpty)
        XCTAssertEqual(env.pasteboardItems, [["public.utf8-plain-text": Data("newer copy".utf8)]])
        XCTAssertFalse(engine.hasPendingRestore)
    }

    /// A second Drop must not replace the first dictation before the first
    /// target read it; each target reads its own take, and the user's
    /// clipboard comes back once at the end.
    func testQueue687ASecondDropDoesNotReplaceWhatTheFirstRendererReads() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()

        let first = await engine.paste("take one")
        env.readerDelaysMs = [400]
        env.advanceFixtureClock(by: 300)
        let second = await engine.paste("take two")
        env.readerDelaysMs = [50]                        // the second target reads its take
        await engine.waitForPendingRestore()

        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(env.readerSaw, ["take one", "take two"])
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems)
        XCTAssertEqual(env.restoreCalls.count, 1)
        XCTAssertTrue(env.logs.contains(where: { $0.message.hasPrefix("autopaste_pasteboard_handed_over after=read") }))
    }

    /// Two pastes started together run one after the other.
    func testConcurrentDropPastesRunOneAtATime() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()

        async let one = engine.paste("take one")
        async let two = engine.paste("take two")
        let results = await [one, two]
        await engine.waitForPendingRestore()

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(env.postedEvents.count, 8)
        XCTAssertEqual(env.snapshotCalls, 1, "the later paste inherits the first snapshot")
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems)
    }

    func testQueue687AStillRunningTargetLosingFocusInTheSettleDoesNotRedirectDrop() async {
        let env = makeRestoreEnv()
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()
        env.onAsyncSleep = { [unowned env] in
            guard env.asyncSleepCalls.count == 1 else { return }
            env.frontmost = Self.targetB
        }

        let result = await engine.paste("dictated")
        await engine.waitForPendingRestore()

        XCTAssertFalse(result)
        XCTAssertTrue(env.postedEvents.isEmpty, "Cmd+V must not reach the app that took focus")
        XCTAssertEqual(env.pasteboardItems, env.initialPasteboardItems, "the clipboard comes back at once")
    }

    /// Selection capture snapshots the pending dictation, copies the
    /// selection and writes the dictation back: Drop recognises its
    /// dictation and still gives the user's clipboard back.
    func testQueue687SelectionFallbackDoesNotStrandPromisedDictationOnClipboard() async {
        await assertSelectionRoundTripKeepsTheUsersClipboard(copies: true)
    }

    func testSelectionFallbackWithoutASelectionDoesNotStrandPromisedDictation() async {
        await assertSelectionRoundTripKeepsTheUsersClipboard(copies: false)
    }

    private func assertSelectionRoundTripKeepsTheUsersClipboard(copies: Bool) async {
        let board = NSPasteboard(name: .init("Queue687-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let original = Pasteboard.snapshot(of: board)
        let reads = PasteboardReadMonitor()
        let engine = makeNamedBoardEngine(board, reads: reads)
        let result = await engine.paste("dictated")
        XCTAssertTrue(result)

        let selection = SelectionFallback.Env(
            frontmostPID: { Self.targetA.pid }, canCopy: { _ in true },
            pasteboardSnapshot: { Pasteboard.snapshot(of: board) },
            pasteboardRestore: { Pasteboard.restore($0, into: board) },
            setSuppressed: { _ in }, scheduleUnsuppress: { _, work in work() },
            postCmdC: {
                guard copies else { return }
                board.clearContents()
                board.setString("selected text", forType: .string)
            },
            sleepAfterPost: {}, readPasteboardString: { board.string(forType: .string) },
            currentChangeCount: { board.changeCount }, suppressThrough: { _ in },
            dispatcher: { work in work() }
        )
        var captured: String?
        SelectionFallback.captureAsync(targetPID: Self.targetA.pid, env: selection) { captured = $0 }
        XCTAssertEqual(reads.readCount, 0, "selection capture's own snapshot is not the target's read")
        await engine.waitForPendingRestore()

        XCTAssertEqual(captured, copies ? "selected text" : nil)
        XCTAssertEqual(Pasteboard.snapshot(of: board), original)
        XCTAssertNil(board.string(forType: .string))
    }

    func testQueue687FailedScreenshotTextCopyDoesNotStrandPromisedDictation() async throws {
        let board = NSPasteboard(name: .init("Queue687-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let original = Pasteboard.snapshot(of: board)
        let engine = makeNamedBoardEngine(board, reads: PasteboardReadMonitor(), realTime: true)
        let result = await engine.paste("dictated")
        XCTAssertTrue(result)

        let copy = await ScreenshotTextCopy.perform(source: try Self.blankImage(), size: CGSize(width: 40, height: 20),
            annotations: [], crop: CGRect(x: 0, y: 0, width: 40, height: 20), pasteboard: board,
            recognize: { _ in "recognized text" }, write: { _, _ in false }, isCurrent: { true })
        await engine.waitForPendingRestore()

        XCTAssertEqual(copy, .failed)
        XCTAssertEqual(Pasteboard.snapshot(of: board), original)
        XCTAssertNil(board.string(forType: .string))
    }

    /// A successful explicit Shot text copy is the user's new clipboard:
    /// Drop must not restore over it.
    func testSuccessfulScreenshotTextCopyDuringTheWaitIsKept() async throws {
        let board = NSPasteboard(name: .init("Queue687-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        let engine = makeNamedBoardEngine(board, reads: PasteboardReadMonitor(), realTime: true)
        _ = await engine.paste("dictated")

        let copy = await ScreenshotTextCopy.perform(source: try Self.blankImage(), size: CGSize(width: 40, height: 20),
            annotations: [], crop: CGRect(x: 0, y: 0, width: 40, height: 20), pasteboard: board,
            recognize: { _ in "recognized text" }, isCurrent: { true })
        await engine.waitForPendingRestore()

        XCTAssertEqual(copy, .copied)
        XCTAssertEqual(board.string(forType: .string), "recognized text")
    }

    private func makeNamedBoardEngine(_ board: NSPasteboard, reads: PasteboardReadMonitor, realTime: Bool = false) -> AutoPasteEngine {
        AutoPasteEngine(
            flagsState: { [] }, frontmostAppInfo: { Self.targetA }, activate: { _ in true },
            isTerminated: { _ in false }, permissionGranted: { _ in true },
            pasteboardWrite: { AutoPasteEngine.writePromisedText($0, to: board, reads: reads) },
            postEvent: { _, _, _ in }, sleepUs: { _ in },
            asyncSleepMs: realTime ? { try? await Task.sleep(nanoseconds: $0 * 1_000_000) } : { _ in await Task.yield() },
            nowMs: realTime ? { DispatchTime.now().uptimeNanoseconds / 1_000_000 } : { 0 },
            logEmit: { _, _ in },
            pasteboardSnapshot: { Pasteboard.snapshot(of: board) },
            pasteboardRestore: { Pasteboard.restore($0, into: board) },
            currentChangeCount: { board.changeCount }, readMonitor: reads,
            restoreTiming: realTime ? .init(pollMs: 10, afterReadMs: 50, fallbackMs: 300) : .standard
        )
    }

    private static func blankImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    func testWhytapsOwnSnapshotOfThePendingDictationIsNotARead() {
        let pb = NSPasteboard(name: .init("WhytapPromiseOwnRead-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let reads = PasteboardReadMonitor()
        XCTAssertNotNil(AutoPasteEngine.writePromisedText("dictated", to: pb, reads: reads))

        let snapshot = Pasteboard.snapshot(of: pb)

        XCTAssertEqual(snapshot.items.first?["public.utf8-plain-text"], Data("dictated".utf8))
        XCTAssertNotNil(snapshot.items.first?[PromisedPasteboardPayload.transientMarker.rawValue])
        XCTAssertEqual(reads.readCount, 0)
    }

    // MARK: - Real pasteboard (named, never the user's clipboard)

    func testPromisedTextCountsTheFirstReadOfEachType() {
        let pb = NSPasteboard(name: .init("WhytapPromise-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let reads = PasteboardReadMonitor()

        XCTAssertNotNil(AutoPasteEngine.writePromisedText("dictated", to: pb, reads: reads))
        XCTAssertEqual(reads.readCount, 0, "publishing is not a read")
        XCTAssertTrue(pb.types?.contains(PromisedPasteboardPayload.transientMarker) ?? false)

        XCTAssertEqual(pb.string(forType: .string), "dictated")
        XCTAssertEqual(pb.string(forType: .string), "dictated")
        XCTAssertEqual(reads.readCount, 1, "later reads are served from the pasteboard's cache")
    }

    /// Whytap's own clipboard history must skip the dictation by its
    /// transient marker without reading it (a read would look like the
    /// target's).
    func testClipboardWatcherSkipsTheDictationWithoutReadingIt() {
        let pb = NSPasteboard(name: .init("WhytapPromiseWatcher-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let reads = PasteboardReadMonitor()
        XCTAssertNotNil(AutoPasteEngine.writePromisedText("dictated", to: pb, reads: reads))

        let snapshot = ClipboardWatcher.readSnapshot(from: pb)

        XCTAssertEqual(snapshot.exclusionMarkers, [.transient])
        XCTAssertNil(snapshot.text)
        XCTAssertEqual(reads.readCount, 0)
    }

    /// End to end with a separate process reading 300 ms after Cmd+V (the
    /// old restore fired at 120 ms) from a pasteboard that held only an
    /// image: the reader gets the dictation and the image comes back.
    func testSeparateProcessReadingLateGetsTheDictationAndTheImageReturns() async throws {
        let pb = NSPasteboard(name: .init("WhytapPromiseE2E-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let tiff = Data([0x4D, 0x4D, 0x00, 0x2A])
        pb.setData(png, forType: .png)
        pb.setData(tiff, forType: .tiff)
        let original = Pasteboard.snapshot(of: pb)

        let reads = PasteboardReadMonitor()
        let output = Pipe()
        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        reader.arguments = ["-l", "JavaScript", "-e", """
            ObjC.import('AppKit'); delay(0.3);
            var s = $.NSPasteboard.pasteboardWithName('\(pb.name.rawValue)').stringForType('public.utf8-plain-text');
            s.isNil() ? '(nil)' : ObjC.unwrap(s)
            """]
        reader.standardOutput = output
        reader.standardError = FileHandle.nullDevice
        var logs: [String] = []
        var launchError: Error?
        let engine = AutoPasteEngine(
            flagsState: { [] }, frontmostAppInfo: { nil }, activate: { _ in true }, isTerminated: { _ in false },
            permissionGranted: { _ in true },
            pasteboardWrite: { AutoPasteEngine.writePromisedText($0, to: pb, reads: reads) },
            postEvent: { keyCode, down, _ in
                guard keyCode == 0x09, down else { return }
                do { try reader.run() } catch { launchError = error }
            },
            sleepUs: { _ in },
            asyncSleepMs: { try? await Task.sleep(nanoseconds: $0 * 1_000_000) },
            nowMs: { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
            logEmit: { _, message in logs.append(message) },
            pasteboardSnapshot: { Pasteboard.snapshot(of: pb) },
            pasteboardRestore: { Pasteboard.restore($0, into: pb) },
            currentChangeCount: { pb.changeCount },
            readMonitor: reads,
            // A loaded test machine may start the reader late; only the
            // read itself should end the wait here.
            restoreTiming: .init(pollMs: 10, afterReadMs: 150, fallbackMs: 30_000)
        )

        let result = await engine.paste("dictated")
        await engine.waitForPendingRestore()
        if let launchError { throw XCTSkip("osascript unavailable: \(launchError)") }
        while reader.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        let seen = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(result)
        XCTAssertEqual(seen, "dictated")
        XCTAssertEqual(reads.readCount, 1)
        XCTAssertTrue(logs.contains(where: { $0.hasPrefix("autopaste_pasteboard_restored after=read") }), logs.joined(separator: "\n"))
        XCTAssertEqual(Pasteboard.snapshot(of: pb), original)
        XCTAssertNil(pb.string(forType: .string))
    }

    // MARK: - pasteAlreadyOnPasteboard (ROO-208 iter 15)

    /// Happy-path: the history-strip Enter-paste variant skips the
    /// pasteboard-write step (caller already wrote) and emits the same
    /// Cmd+V 4-event sequence as `paste(_:)`.
    func testPasteAlreadyOnPasteboardEmitsCmdVAndNoPasteboardWrite() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        let engine = env.makeEngine()
        engine.rememberTargetBeforeRecording()

        let result = await engine.pasteAlreadyOnPasteboard()

        XCTAssertTrue(result)
        XCTAssertNil(env.pastedText, "engine must not write to the pasteboard — caller owns the payload")
        XCTAssertEqual(env.postedEvents.count, 4)
        XCTAssertEqual(env.postedEvents[0].keyCode, Self.cmd)
        XCTAssertTrue(env.postedEvents[0].down)
        XCTAssertEqual(env.postedEvents[1].keyCode, Self.v)
        XCTAssertTrue(env.postedEvents[1].down)
        XCTAssertEqual(env.postedEvents[2].keyCode, Self.v)
        XCTAssertFalse(env.postedEvents[2].down)
        XCTAssertEqual(env.postedEvents[3].keyCode, Self.cmd)
        XCTAssertFalse(env.postedEvents[3].down)
    }

    /// Pasteboard snapshot / restore must NOT run in the Enter-paste
    /// variant. When the user picks a history card explicitly, they
    /// expect it to remain on the system pasteboard afterward — the
    /// snapshot/restore dance is for the drop pipeline only.
    func testPasteAlreadyOnPasteboardSkipsSnapshotAndRestore() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        env.initialPasteboardItems = [["public.utf8-plain-text": Data("user_clipboard".utf8)]]
        let engine = env.makeEngine()

        _ = await engine.pasteAlreadyOnPasteboard()

        XCTAssertEqual(env.snapshotCalls, 0, "no snapshot in the explicit-paste flow")
        XCTAssertEqual(env.restoreCalls.count, 0, "no restore in the explicit-paste flow")
    }

    /// Suppression flag / threshold are the drop pipeline's concern —
    /// the explicit Enter-paste flow doesn't mutate the pasteboard
    /// itself, so it must not touch the watcher's coordination state.
    func testPasteAlreadyOnPasteboardSkipsSuppressionState() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            modifierFlagsSequence: [[]],
            permission: true
        )
        let engine = env.makeEngine()

        _ = await engine.pasteAlreadyOnPasteboard()

        XCTAssertEqual(env.suppressionCalls, [], "no flag toggles")
        XCTAssertEqual(env.suppressionThresholdCalls, [], "no threshold raises")
    }

    /// Modifier-wait timeout: Cmd held during the press → wait times
    /// out → no Cmd+V is posted, return false.
    func testPasteAlreadyOnPasteboardReturnsFalseOnModifierWaitTimeout() async {
        let env = TestEnv(
            frontmost: Self.targetA,
            // Stuck Command modifier — wait loop never sees clear flags.
            modifierFlagsSequence: [.maskCommand],
            permission: true
        )
        let engine = env.makeEngine()

        let result = await engine.pasteAlreadyOnPasteboard()

        XCTAssertFalse(result)
        XCTAssertTrue(env.postedEvents.isEmpty, "no Cmd+V on modifier-wait timeout")
    }

    /// Focus restore runs same as `paste(_:)`. When a target was
    /// remembered and the frontmost has drifted (e.g. user Cmd+Tabbed
    /// to a different app between strip-open and Enter), activate is
    /// called on the remembered pid.
    func testPasteAlreadyOnPasteboardRestoresFocusToRememberedTarget() async {
        let env = TestEnv(
            frontmost: Self.targetB,  // drifted away from A
            modifierFlagsSequence: [[]],
            permission: true
        )
        env.frontmostAfterActivate = Self.targetA
        let engine = env.makeEngine()
        // Pretend we captured A before the strip opened. Engine then
        // sees B is frontmost and should activate A.
        env.frontmost = Self.targetA
        engine.rememberTargetBeforeRecording()
        env.frontmost = Self.targetB

        _ = await engine.pasteAlreadyOnPasteboard()

        XCTAssertEqual(env.activatedPids, [Self.targetA.pid], "remembered target reactivated")
    }

    /// `currentTargetName` exposes the last-captured display name so
    /// the strip's hint can fall back to it if NSWorkspace reports
    /// Sidekey itself as frontmost.
    func testCurrentTargetNameReflectsRememberedTarget() {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        XCTAssertNil(engine.currentTargetName)
        engine.rememberTargetBeforeRecording()
        XCTAssertEqual(engine.currentTargetName, Self.targetA.name)
    }

    // MARK: - Drop into one of Whytap's own editors
    // WHY: .project-docs/decisions/2026-11-18-drop-into-whytap-editors.md

    /// The reported defect: the floating Translate input is key while another
    /// app is frontmost. The old path wrote the clipboard, posted Cmd+V and
    /// restored the clipboard before Whytap could handle its own key event.
    func testDropIntoAWhytapEditorInsertsWithoutClipboardKeysOrFocusChange() async {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[.maskCommand]], permission: false)
        env.initialPasteboardItems = [["public.utf8-plain-text": Data("copied-file.pdf".utf8)]]
        env.localEditorAccepts = true
        let engine = env.makeEngine()
        engine.rememberDropTarget()

        // A rich destination profile cannot apply to a Whytap editor either.
        let result = await engine.paste("dictated text", formatting: .slack)

        XCTAssertTrue(result)
        XCTAssertEqual(env.localEditorInsertions, ["dictated text"])
        XCTAssertNil(env.pastedText, "The dictation must not pass through the clipboard")
        XCTAssertEqual(env.snapshotCalls, 0, "The live clipboard must not be read")
        XCTAssertTrue(env.restoreCalls.isEmpty)
        XCTAssertTrue(env.suppressionEventOrder.isEmpty)
        XCTAssertTrue(env.postedEvents.isEmpty, "No Cmd+V: held modifiers and Post Event access do not matter")
        XCTAssertTrue(env.activatedPids.isEmpty)
        XCTAssertTrue(env.sleepCalls.isEmpty)
        XCTAssertTrue(env.logs.contains { $0.message == "autopaste_target_local_editor" })
        XCTAssertTrue(env.logs.contains { $0.message == "autopaste_local_editor_inserted chars=13" })
        XCTAssertFalse(env.logs.contains { $0.message.contains("dictated") }, "Logs carry counts, never the text")
    }

    func testDropWhoseWhytapEditorIsGoneIsDeliveredNowhere() async {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        env.localEditorAccepts = false   // closed palette, moved focus, released window
        let engine = env.makeEngine()
        engine.rememberDropTarget()

        let result = await engine.paste("dictated text")

        XCTAssertFalse(result)
        XCTAssertEqual(env.localEditorInsertions, ["dictated text"])
        XCTAssertNil(env.pastedText)
        XCTAssertEqual(env.snapshotCalls, 0)
        XCTAssertTrue(env.postedEvents.isEmpty, "The frontmost app must not receive the dictation instead")
        XCTAssertTrue(env.activatedPids.isEmpty)
        XCTAssertTrue(env.logs.contains { $0.level == .error && $0.message == "autopaste_failed step=local_editor reason=target_gone" })
    }

    /// Opening History re-captures the frontmost app in the same engine. A
    /// Retry of the take afterwards still belongs to its editor; only the
    /// next take chooses a destination again.
    func testWhytapEditorBelongsToTheTakeUntilTheNextOneStarts() async {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        env.localEditorAccepts = true
        let engine = env.makeEngine()
        engine.rememberDropTarget()

        env.frontmost = Self.targetB
        engine.rememberTargetBeforeRecording()          // History opened
        XCTAssertEqual(engine.currentTarget(), Self.targetB)
        let retried = await engine.paste("first take")
        XCTAssertTrue(retried)
        XCTAssertEqual(env.localEditorInsertions, ["first take"])
        XCTAssertTrue(env.postedEvents.isEmpty)

        env.localEditorAccepts = nil                    // next take starts in another app
        engine.rememberDropTarget()
        let pasted = await engine.paste("second take")
        XCTAssertTrue(pasted)
        XCTAssertEqual(env.localEditorInsertions, ["first take"])
        XCTAssertEqual(env.pastedText, "second take")
        XCTAssertEqual(env.postedEvents.count, 4)
        await engine.waitForPendingRestore()
        XCTAssertEqual(env.restoreCalls.count, 1)
    }

    /// Smart reads Accessibility context and picks a paste format from the
    /// take's app. For a Whytap editor the frontmost app is unrelated.
    func testDropTargetIdentityHidesTheFrontmostAppBehindAWhytapEditor() {
        let env = TestEnv(frontmost: Self.targetA, modifierFlagsSequence: [[]], permission: true)
        let engine = env.makeEngine()
        XCTAssertNil(engine.currentDropTarget().name)
        XCTAssertNil(engine.currentDropTarget().pid)

        engine.rememberDropTarget()
        XCTAssertEqual(engine.currentDropTarget().name, "TextEdit")
        XCTAssertEqual(engine.currentDropTarget().pid, 100)
        XCTAssertFalse(env.logs.contains { $0.message == "autopaste_target_local_editor" })

        env.localEditorAccepts = true
        engine.rememberDropTarget()
        XCTAssertEqual(engine.currentDropTarget().name, "Whytap")
        XCTAssertNil(engine.currentDropTarget().pid)
        XCTAssertEqual(engine.currentTarget(), Self.targetA, "History's app target is still captured")
        XCTAssertEqual(
            SmartFormattingProfile.resolve(bundleID: nil, appName: engine.currentDropTarget().name,
                                           documentURL: nil, focusedRole: nil),
            .plain
        )
    }
}

// MARK: - Test environment

@MainActor
private final class TestEnv {
    struct PostedEvent: Equatable {
        let keyCode: CGKeyCode
        let down: Bool
        let flags: CGEventFlags
        /// The one process the event was addressed to; nil = global HID stream.
        var pid: pid_t? = nil
    }
    /// Runs on every engine sleep, before the clock advances: lets a test
    /// change focus or quit an app inside the 12 ms gaps of a Cmd+V.
    var onSleep: ((UInt32) -> Void)?
    struct LogLine: Equatable {
        let level: AutoPasteEngine.LogLevel
        let message: String
    }

    var frontmost: AutoPasteEngine.RememberedTarget?
    /// If set, the next `frontmostAppInfo` call after `activate` returns this.
    var frontmostAfterActivate: AutoPasteEngine.RememberedTarget?
    private var activateHasRun = false

    /// Iterated by the engine's modifier-wait poll. The last element is
    /// repeated forever (which makes "stuck modifiers" trivial to express
    /// with a single-element `[.maskCommand]` array).
    let modifierFlagsSequence: [CGEventFlags]
    private var modifierFlagsIndex = 0

    let permission: Bool
    var pasteboardWriteSucceeds: Bool
    var terminatedPids: Set<pid_t>

    var pastedText: String?
    var postedEvents: [PostedEvent] = []
    var sleepCalls: [UInt32] = []
    var activatedPids: [pid_t] = []
    var logs: [LogLine] = []
    var onLog: ((String) -> Void)?

    /// Initial pasteboard items returned by the snapshot collaborator.
    /// Empty by default — tests that exercise preserve/restore set this
    /// to a non-empty array of `[type-raw: bytes]` dictionaries.
    var initialPasteboardItems: [[String: Data]] = []
    var snapshotCalls: Int = 0
    var snapshotsTaken: [PasteboardSnapshot] = []
    var restoreCalls: [PasteboardSnapshot] = []
    /// Ordered list of suppression flag changes (true = set, false = clear).
    var suppressionCalls: [Bool] = []
    /// changeCount values handed to `suppressThrough` by the engine.
    var suppressionThresholdCalls: [Int] = []
    /// Combined ordered log of suppression-related calls. Lets a test
    /// assert that `suppressThrough(N)` lands BEFORE `setSuppressed(false)`
    /// in the same drop window.
    enum SuppressionEvent: Equatable {
        case flag(Bool)
        case threshold(Int)
    }
    var suppressionEventOrder: [SuppressionEvent] = []
    /// Simulated system pasteboard: every write or restore bumps the
    /// change count, like `NSPasteboard`.
    var changeCount: Int = 0
    /// What the pasteboard holds now; nil = still `initialPasteboardItems`.
    private var modelItems: [[String: Data]]?
    var pasteboardItems: [[String: Data]] { modelItems ?? initialPasteboardItems }
    /// The user (or another app) copies something.
    func userCopies(_ text: String) {
        modelItems = [["public.utf8-plain-text": Data(text.utf8)]]
        changeCount += 1
    }

    /// Readers of the promised dictation. `readerDelaysMs` lists, relative
    /// to the Cmd+V V-down, when a reader takes the pasteboard; each read
    /// records what the pasteboard held at that moment.
    let readMonitor = PasteboardReadMonitor()
    var readerDelaysMs: [UInt64] = []
    var readerSaw: [String?] = []
    /// Simulated clock at each served read and each restore.
    var readTimesMs: [UInt64] = []
    var restoreTimesMs: [UInt64] = []
    /// Runs on every asynchronous engine sleep, after the clock advanced.
    var onAsyncSleep: (() -> Void)?
    var asyncSleepCalls: [UInt64] = []
    private(set) var vDownAtMs: UInt64?
    var nowForTest: UInt64 { simulatedClockMs }
    func advanceFixtureClock(by milliseconds: UInt64) { simulatedClockMs += milliseconds }
    var restoreTiming = AutoPasteEngine.RestoreTiming.standard

    private func serveDueReaders() {
        guard let vDownAtMs else { return }
        while let next = readerDelaysMs.first, simulatedClockMs >= vDownAtMs + next {
            readerDelaysMs.removeFirst()
            readerSaw.append(pasteboardItems.first?["public.utf8-plain-text"].map { String(decoding: $0, as: UTF8.self) })
            readTimesMs.append(simulatedClockMs)
            readMonitor.noteRead()
        }
    }

    /// nil = the take starts outside Whytap. Otherwise a Whytap editor has
    /// the keyboard at take start and accepts (true) or has gone (false).
    var localEditorAccepts: Bool?
    var localEditorInsertions: [String] = []

    private var simulatedClockMs: UInt64 = 0

    init(
        frontmost: AutoPasteEngine.RememberedTarget?,
        modifierFlagsSequence: [CGEventFlags],
        permission: Bool,
        pasteboardWriteSucceeds: Bool = true,
        terminatedPids: Set<pid_t> = []
    ) {
        self.frontmost = frontmost
        self.modifierFlagsSequence = modifierFlagsSequence
        self.permission = permission
        self.pasteboardWriteSucceeds = pasteboardWriteSucceeds
        self.terminatedPids = terminatedPids
    }

    func makeEngine() -> AutoPasteEngine {
        AutoPasteEngine(
            flagsState: { [weak self] in
                guard let self else { return [] }
                let i = min(self.modifierFlagsIndex, self.modifierFlagsSequence.count - 1)
                self.modifierFlagsIndex += 1
                return self.modifierFlagsSequence[i]
            },
            frontmostAppInfo: { [weak self] in
                guard let self else { return nil }
                if self.activateHasRun, let next = self.frontmostAfterActivate {
                    self.frontmost = next
                    self.activateHasRun = false
                }
                return self.frontmost
            },
            activate: { [weak self] pid in
                self?.activatedPids.append(pid)
                self?.activateHasRun = true
                return true
            },
            isTerminated: { [weak self] pid in
                self?.terminatedPids.contains(pid) ?? false
            },
            permissionGranted: { [weak self] _ in
                self?.permission ?? false
            },
            pasteboardWrite: { [weak self] text in
                guard let self else { return nil }
                guard self.pasteboardWriteSucceeds else { return nil }
                self.pastedText = text
                let before = self.changeCount
                // Like the production writer: text plus the transient marker.
                self.modelItems = [["public.utf8-plain-text": Data(text.utf8),
                                    PromisedPasteboardPayload.transientMarker.rawValue: Data()]]
                self.changeCount += 1
                return (before: before, after: self.changeCount)
            },
            postEvent: { [weak self] keyCode, down, flags in
                guard let self else { return }
                self.postedEvents.append(PostedEvent(keyCode: keyCode, down: down, flags: flags))
                if keyCode == 0x09, down { self.vDownAtMs = self.simulatedClockMs }
            },
            postEventToPid: { [weak self] keyCode, down, flags, pid in
                self?.postedEvents.append(PostedEvent(keyCode: keyCode, down: down, flags: flags, pid: pid))
            },
            sleepUs: { [weak self] us in
                guard let self else { return }
                self.sleepCalls.append(us)
                self.onSleep?(us)
                // Advance the simulated clock by us / 1000 (ms). The poll
                // loops in production use `nowMs` to detect timeout, so
                // advancing here makes timeouts deterministic without
                // wall-clock waiting.
                self.simulatedClockMs += UInt64(us) / 1000
            },
            asyncSleepMs: { [weak self] ms in
                guard let self else { return }
                self.asyncSleepCalls.append(ms)
                self.simulatedClockMs += ms
                self.serveDueReaders()
                self.onAsyncSleep?()
                await Task.yield()
            },
            nowMs: { [weak self] in
                self?.simulatedClockMs ?? 0
            },
            logEmit: { [weak self] level, message in
                self?.logs.append(LogLine(level: level, message: message))
                self?.onLog?(message)
            },
            pasteboardSnapshot: { [weak self] in
                guard let self else { return PasteboardSnapshot(items: []) }
                self.snapshotCalls += 1
                let snap = PasteboardSnapshot(items: self.pasteboardItems)
                self.snapshotsTaken.append(snap)
                return snap
            },
            pasteboardRestore: { [weak self] snapshot in
                guard let self else { return }
                self.restoreCalls.append(snapshot)
                self.restoreTimesMs.append(self.simulatedClockMs)
                self.modelItems = snapshot.items
                self.changeCount += 1
            },
            setClipboardSuppression: { [weak self] flag in
                self?.suppressionCalls.append(flag)
                self?.suppressionEventOrder.append(.flag(flag))
            },
            suppressClipboardThrough: { [weak self] count in
                self?.suppressionThresholdCalls.append(count)
                self?.suppressionEventOrder.append(.threshold(count))
            },
            currentChangeCount: { [weak self] in
                self?.changeCount ?? 0
            },
            localEditor: { [weak self] in
                guard let self, self.localEditorAccepts != nil else { return nil }
                return AutoPasteEngine.LocalEditorTarget(name: "Whytap") { [weak self] text in
                    self?.localEditorInsertions.append(text)
                    return self?.localEditorAccepts ?? false
                }
            },
            readMonitor: readMonitor,
            restoreTiming: restoreTiming
        )
    }
}

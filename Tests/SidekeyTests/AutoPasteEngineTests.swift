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
    /// → restore snapshot once the paste has settled. After the engine
    /// returns, the system pasteboard should match what was there when
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
        // pasteboardWrite returns (before, after) = (0, 1) in TestEnv;
        // the post-restore changeCount stub returns 2 (one further bump
        // for the restore step).
        env.changeCountAfterRestore = 2
        let engine = env.makeEngine()

        let result = await engine.paste("hi")

        XCTAssertTrue(result)
        // Order matters: suppressThrough(2) must land BEFORE
        // setSuppressed(false). Otherwise the next poll sees the flag
        // cleared but the threshold still unset → records the restored
        // pasteboard as a clipboard artefact.
        XCTAssertEqual(
            env.suppressionThresholdCalls,
            [2],
            "threshold must be raised once, with the post-restore changeCount"
        )
        guard let thresholdIdx = env.suppressionEventOrder.firstIndex(of: .threshold(2)),
              let clearIdx = env.suppressionEventOrder.firstIndex(of: .flag(false))
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
}

// MARK: - Test environment

@MainActor
private final class TestEnv {
    struct PostedEvent: Equatable {
        let keyCode: CGKeyCode
        let down: Bool
        let flags: CGEventFlags
    }
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
    let pasteboardWriteSucceeds: Bool
    let terminatedPids: Set<pid_t>

    var pastedText: String?
    var postedEvents: [PostedEvent] = []
    var sleepCalls: [UInt32] = []
    var activatedPids: [pid_t] = []
    var logs: [LogLine] = []

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
    /// changeCount that the engine should observe after the restore step.
    /// Default = 0 (no calls to `changeCount` made before the engine
    /// asks). Tests override to exercise the threshold race path.
    var changeCountAfterRestore: Int = 0

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
                return (before: 0, after: 1)
            },
            postEvent: { [weak self] keyCode, down, flags in
                self?.postedEvents.append(PostedEvent(keyCode: keyCode, down: down, flags: flags))
            },
            sleepUs: { [weak self] us in
                guard let self else { return }
                self.sleepCalls.append(us)
                // Advance the simulated clock by us / 1000 (ms). The poll
                // loops in production use `nowMs` to detect timeout, so
                // advancing here makes timeouts deterministic without
                // wall-clock waiting.
                self.simulatedClockMs += UInt64(us) / 1000
            },
            nowMs: { [weak self] in
                self?.simulatedClockMs ?? 0
            },
            logEmit: { [weak self] level, message in
                self?.logs.append(LogLine(level: level, message: message))
            },
            pasteboardSnapshot: { [weak self] in
                guard let self else { return PasteboardSnapshot(items: []) }
                self.snapshotCalls += 1
                let snap = PasteboardSnapshot(items: self.initialPasteboardItems)
                self.snapshotsTaken.append(snap)
                return snap
            },
            pasteboardRestore: { [weak self] snapshot in
                self?.restoreCalls.append(snapshot)
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
                self?.changeCountAfterRestore ?? 0
            }
        )
    }
}

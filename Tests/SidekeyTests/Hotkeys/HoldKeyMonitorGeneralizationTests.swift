import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import Sidekey

/// Combo-swallow Stage 1: `SpaceHoldMonitor` is generalised from a hardcoded
/// Space trigger to an injectable *(triggerKeyCode, requiredModifiers)* pair so
/// a user-rebound combo Drop (e.g. ⌥D) can be swallowed by the **same** active
/// `CGEventTap` mechanism the default Space hold already uses.
///
/// These tests drive the two pure decision functions directly — `mapEvent`
/// (raw event → FSM vocabulary, now modifier-gated) and `tapDecision`
/// (swallow/pass verdict, now trigger-policy aware) — exactly as
/// `SpaceHoldMonitorTests` already does, with no real tap/timer/AX.
///
/// The Space path (default parameters) is covered by a regression block that
/// re-derives the verdicts asserted in `SpaceHoldMonitorTests`/`...DetectorTests`
/// from the **default** `mapEvent`/`tapDecision` calls, proving the
/// generalisation left Space behaviour bit-for-bit identical.
final class HoldKeyMonitorGeneralizationTests: XCTestCase {

    // MARK: - Fixtures

    /// The ⌥D combo trigger used throughout the combo cases.
    private let optD = (keyCode: CGKeyCode(kVK_ANSI_D), mods: CGEventFlags.maskAlternate)

    /// Records synthesized key events so a test can assert the Backspace count.
    private final class PostEventRecorder {
        private(set) var events: [(keyCode: CGKeyCode, down: Bool)] = []
        func post(_ keyCode: CGKeyCode, _ down: Bool) { events.append((keyCode, down)) }
        var backspacePairs: Int {
            events.filter { $0.keyCode == CGKeyCode(kVK_Delete) && $0.down }.count
        }
    }

    /// Builds a monitor bound to a combo trigger (⌥D), wired entirely to
    /// injected closures — same DI shape as `SpaceHoldMonitorTests.makeMonitor`.
    /// Used for the end-to-end `handleTapEvent` combo assertions.
    private func makeComboMonitor(
        editable: Bool = true,
        post: PostEventRecorder = PostEventRecorder(),
        onHotkey: @escaping () -> Void = {},
        onHotkeyReleased: @escaping () -> Void = {},
        onCancel: @escaping () -> Void = {}
    ) -> SpaceHoldMonitor {
        SpaceHoldMonitor(
            triggerKeyCode: optD.keyCode,
            requiredModifiers: optD.mods,
            onHotkey: onHotkey,
            onHotkeyReleased: onHotkeyReleased,
            onCancel: onCancel,
            makeTap: { _ in OpaquePointer(bitPattern: 0x1) },
            enableTap: { _ in },
            scheduleThreshold: { _ in },
            cancelThreshold: {},
            frontmostApp: { (pid_t(1234), "com.example.app") },
            isEditable: { _, _ in editable },
            postEvent: { code, down in post.post(code, down) },
            runOnDetectorQueue: { work in work() },
            runEditableCheckOffTapThread: { work in work() },
            dispatchCallback: { work in work() },
            log: { _, _ in }
        )
    }

    // MARK: - mapEvent: modifier gate (combo ⌥D)

    func test_mapEvent_armingKey_withRequiredModifier_isTriggerKeyDown() {
        // ⌥D keyDown with exactly the Option modifier held → trigger keyDown.
        let event = SpaceHoldMonitor.mapEvent(
            type: .keyDown,
            keyCode: optD.keyCode,
            isRepeat: false,
            flags: .maskAlternate,
            triggerKeyCode: optD.keyCode,
            requiredModifiers: optD.mods
        )
        XCTAssertEqual(event, .spaceKeyDown(isRepeat: false),
                       "⌥D keyDown is the trigger keyDown for an ⌥D binding")
    }

    func test_mapEvent_bareTriggerKey_withoutModifier_isNotTrigger() {
        // Bare D (no Option) must NOT match an ⌥D binding — it is ordinary
        // typing and maps to `.otherKeyDown` so it flows to the app.
        let event = SpaceHoldMonitor.mapEvent(
            type: .keyDown,
            keyCode: optD.keyCode,
            isRepeat: false,
            flags: [],
            triggerKeyCode: optD.keyCode,
            requiredModifiers: optD.mods
        )
        XCTAssertEqual(event, .otherKeyDown,
                       "bare D (no ⌥) is not the trigger for an ⌥D binding")
    }

    func test_mapEvent_triggerKey_withExtraModifier_isNotTrigger() {
        // ⌘⌥D carries an extra Command modifier — exact-subset gate rejects it
        // so a ⌘⌥D chord does not false-match the ⌥D binding.
        let event = SpaceHoldMonitor.mapEvent(
            type: .keyDown,
            keyCode: optD.keyCode,
            isRepeat: false,
            flags: [.maskAlternate, .maskCommand],
            triggerKeyCode: optD.keyCode,
            requiredModifiers: optD.mods
        )
        XCTAssertEqual(event, .otherKeyDown,
                       "⌘⌥D has an extra modifier and must not match the ⌥D binding")
    }

    func test_mapEvent_combo_ignoresIncidentalCapsLockBit() {
        // Caps Lock (alphaShift) is not a functional hotkey modifier; ⌥D with
        // Caps Lock on must still arm (the gate compares only Cmd/Shift/Ctrl/Opt).
        let event = SpaceHoldMonitor.mapEvent(
            type: .keyDown,
            keyCode: optD.keyCode,
            isRepeat: false,
            flags: [.maskAlternate, .maskAlphaShift],
            triggerKeyCode: optD.keyCode,
            requiredModifiers: optD.mods
        )
        XCTAssertEqual(event, .spaceKeyDown(isRepeat: false),
                       "Caps Lock is incidental and must not break the ⌥D gate")
    }

    func test_mapEvent_combo_otherKeyDown_forNonTriggerKey() {
        // A different key entirely (A) is always `.otherKeyDown` regardless of
        // modifiers — only the bound trigger key can arm.
        let event = SpaceHoldMonitor.mapEvent(
            type: .keyDown,
            keyCode: CGKeyCode(kVK_ANSI_A),
            isRepeat: false,
            flags: .maskAlternate,
            triggerKeyCode: optD.keyCode,
            requiredModifiers: optD.mods
        )
        XCTAssertEqual(event, .otherKeyDown)
    }

    func test_mapEvent_combo_triggerKeyUp_mapsToKeyUp() {
        // keyUp of the trigger key (modifiers irrelevant on release) → keyUp.
        let event = SpaceHoldMonitor.mapEvent(
            type: .keyUp,
            keyCode: optD.keyCode,
            isRepeat: false,
            flags: [],
            triggerKeyCode: optD.keyCode,
            requiredModifiers: optD.mods
        )
        XCTAssertEqual(event, .spaceKeyUp,
                       "release of the trigger key ends the gesture for a combo too")
    }

    // MARK: - tapDecision: combo policy i (swallow from first keyDown)

    func test_tapDecision_combo_swallowsTriggerKeyDown_fromFirstEvent() {
        // Policy (i): for a modified combo, the very first trigger keyDown is
        // swallowed (∂ never prints). The FSM emits `[.passThrough, .beginPending]`
        // in idle on the fresh keyDown, but the combo decision overrides the
        // passThrough so the character is consumed.
        let decision = SpaceHoldMonitor.tapDecision(
            for: .spaceKeyDown(isRepeat: false),
            beforeState: .idle,
            actions: [.passThrough, .beginPending],
            triggerIsModifiedCombo: true
        )
        XCTAssertEqual(decision, .swallow,
                       "combo trigger keyDown is swallowed from the first event (policy i)")
    }

    func test_tapDecision_combo_swallowsLeakedRepeat() {
        // An auto-repeat trigger keyDown while pending also swallows under combo
        // policy (no leaked characters at all).
        let decision = SpaceHoldMonitor.tapDecision(
            for: .spaceKeyDown(isRepeat: true),
            beforeState: .pending(leaked: 0),
            actions: [.passThrough, .incrementLeak],
            triggerIsModifiedCombo: true
        )
        XCTAssertEqual(decision, .swallow,
                       "combo auto-repeat trigger keyDown is also swallowed")
    }

    func test_tapDecision_combo_armedRelease_isSwallowed() {
        // Release while armed is swallowed for a combo exactly as for Space —
        // the armed-state ownership rule is trigger-independent.
        let decision = SpaceHoldMonitor.tapDecision(
            for: .spaceKeyUp,
            beforeState: .armed,
            actions: [.stopAndTranscribe],
            triggerIsModifiedCombo: true
        )
        XCTAssertEqual(decision, .swallow)
    }

    func test_tapDecision_combo_nonTriggerKeyInIdle_passesThrough() {
        // `.otherKeyDown` in idle carries an explicit `.passThrough`; even under
        // combo policy a non-trigger key must reach the app (we only swallow the
        // trigger key itself).
        let decision = SpaceHoldMonitor.tapDecision(
            for: .otherKeyDown,
            beforeState: .idle,
            actions: [],
            triggerIsModifiedCombo: true
        )
        XCTAssertEqual(decision, .passThrough,
                       "a non-trigger key is never swallowed by the combo policy")
    }

    // MARK: - End-to-end combo gesture through handleTapEvent

    func test_combo_hold_editable_arms_and_swallows_from_first_keyDown() {
        var hotkeyCalls = 0
        let post = PostEventRecorder()
        let monitor = makeComboMonitor(editable: true, post: post, onHotkey: { hotkeyCalls += 1 })

        // ⌥D keyDown is swallowed from the first event (policy i): ∂ never prints.
        XCTAssertEqual(
            monitor.handleTapEvent(type: .keyDown, keyCode: optD.keyCode, isRepeat: false, flags: optD.mods),
            .swallow,
            "first ⌥D keyDown is swallowed (combo policy i)"
        )
        // An auto-repeat ⌥D while held is also swallowed (no leaked characters).
        XCTAssertEqual(
            monitor.handleTapEvent(type: .keyDown, keyCode: optD.keyCode, isRepeat: true, flags: optD.mods),
            .swallow
        )

        // Threshold elapses → AX check (editable) → arm.
        monitor.fireThreshold()
        XCTAssertEqual(hotkeyCalls, 1, "combo hold in an editable field arms exactly once")

        // CRITICAL: because the trigger keyDowns were swallowed (never printed),
        // arming must synthesize ZERO Backspaces — the FSM's leaked count (which
        // counts every keyDown) must NOT erase real characters for a combo.
        XCTAssertEqual(post.backspacePairs, 0,
                       "combo arm must not Backspace — nothing leaked under policy i")

        // Release stops + transcribes, and is swallowed.
        XCTAssertEqual(
            monitor.handleTapEvent(type: .keyUp, keyCode: optD.keyCode, isRepeat: false, flags: []),
            .swallow
        )
    }

    func test_combo_bareTriggerKey_passesThrough_andNeverArms() {
        var hotkeyCalls = 0
        let monitor = makeComboMonitor(editable: true, onHotkey: { hotkeyCalls += 1 })

        // Bare D (no ⌥): not the trigger → ordinary key → passes through.
        XCTAssertEqual(
            monitor.handleTapEvent(type: .keyDown, keyCode: optD.keyCode, isRepeat: false, flags: []),
            .passThrough,
            "bare D is ordinary typing for an ⌥D binding and must reach the app"
        )

        // Even if a threshold somehow fires, nothing is armed (we are idle).
        monitor.fireThreshold()
        XCTAssertEqual(hotkeyCalls, 0, "bare D must never arm an ⌥D binding")
    }

    func test_combo_extraModifier_chord_passesThrough_andNeverArms() {
        var hotkeyCalls = 0
        let monitor = makeComboMonitor(editable: true, onHotkey: { hotkeyCalls += 1 })

        // ⌘⌥D: extra Command modifier → not the bound trigger → passes through.
        XCTAssertEqual(
            monitor.handleTapEvent(
                type: .keyDown, keyCode: optD.keyCode, isRepeat: false,
                flags: [.maskAlternate, .maskCommand]
            ),
            .passThrough,
            "⌘⌥D is a different chord and must not arm the ⌥D binding"
        )
        monitor.fireThreshold()
        XCTAssertEqual(hotkeyCalls, 0)
    }

    // MARK: - Regression: Space path (default init) is bit-for-bit unchanged

    /// The default `mapEvent` (no trigger args = Space, no modifiers) must
    /// reproduce the exact mapping the original hardcoded implementation gave.
    func test_default_mapEvent_matches_legacy_space_mapping() {
        // Space keyDown → spaceKeyDown (modifiers must be ignored for Space).
        XCTAssertEqual(
            SpaceHoldMonitor.mapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: false, flags: []),
            .spaceKeyDown(isRepeat: false)
        )
        // Space keyDown even WITH an incidental modifier still arms (Space binding
        // has requiredModifiers == [] → gate is satisfied by the empty subset,
        // and exact-equality must not be applied to the default Space trigger).
        XCTAssertEqual(
            SpaceHoldMonitor.mapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Space), isRepeat: true, flags: []),
            .spaceKeyDown(isRepeat: true)
        )
        // Escape keyDown → escapeKeyDown.
        XCTAssertEqual(
            SpaceHoldMonitor.mapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_Escape), isRepeat: false, flags: []),
            .escapeKeyDown
        )
        // Other keyDown → otherKeyDown.
        XCTAssertEqual(
            SpaceHoldMonitor.mapEvent(type: .keyDown, keyCode: CGKeyCode(kVK_ANSI_A), isRepeat: false, flags: []),
            .otherKeyDown
        )
        // Space keyUp → spaceKeyUp; non-space keyUp → nil.
        XCTAssertEqual(
            SpaceHoldMonitor.mapEvent(type: .keyUp, keyCode: CGKeyCode(kVK_Space), isRepeat: false, flags: []),
            .spaceKeyUp
        )
        XCTAssertNil(
            SpaceHoldMonitor.mapEvent(type: .keyUp, keyCode: CGKeyCode(kVK_ANSI_A), isRepeat: false, flags: [])
        )
    }

    /// The default `tapDecision` (Space trigger, `triggerIsModifiedCombo == false`)
    /// must reproduce the legacy verdicts: Space keyDown in idle passes through
    /// (counted as leaked, deleted later), and the armed/awaiting rules are
    /// unchanged.
    func test_default_tapDecision_matches_legacy_space_verdicts() {
        // Fresh Space keyDown in idle → passThrough (the first space prints and
        // is later deleted; NOT swallowed for the Space trigger).
        XCTAssertEqual(
            SpaceHoldMonitor.tapDecision(
                for: .spaceKeyDown(isRepeat: false),
                beforeState: .idle,
                actions: [.passThrough, .beginPending]
            ),
            .passThrough
        )
        // Space auto-repeat while awaitingDecision → swallow (stop extra leaks).
        XCTAssertEqual(
            SpaceHoldMonitor.tapDecision(
                for: .spaceKeyDown(isRepeat: true),
                beforeState: .awaitingDecision(leaked: 1),
                actions: []
            ),
            .swallow
        )
        // Release while awaitingDecision → passThrough (ordinary key).
        XCTAssertEqual(
            SpaceHoldMonitor.tapDecision(
                for: .spaceKeyUp,
                beforeState: .awaitingDecision(leaked: 1),
                actions: [.cancelPending]
            ),
            .passThrough
        )
        // Anything while armed with no passThrough → swallow.
        XCTAssertEqual(
            SpaceHoldMonitor.tapDecision(
                for: .spaceKeyUp,
                beforeState: .armed,
                actions: [.stopAndTranscribe]
            ),
            .swallow
        )
        // Explicit passThrough always forwards.
        XCTAssertEqual(
            SpaceHoldMonitor.tapDecision(
                for: .otherKeyDown,
                beforeState: .armed,
                actions: [.passThrough]
            ),
            .passThrough
        )
    }
}

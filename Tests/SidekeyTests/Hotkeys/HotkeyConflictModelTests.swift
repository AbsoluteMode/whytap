import Carbon.HIToolbox
import AppKit
import XCTest
@testable import Sidekey

/// Stage 1 of configurable hotkeys (ROO-234): `HotkeyConfiguration.conflicts`
/// must reason about the *physical key*, not the `(gesture, key)` pair.
///
/// - For a `.modifier` key (Right ⌘ / Right ⌥) a tap/hold split is a valid,
///   intentional pairing: tap = Agent text, hold = Agent voice. Two bindings on
///   the same modifier conflict only when they share both gesture *and* key.
/// - For a `.combo` (a real key code) or `.holdSpace` (a press-and-hold on
///   Space), one physical key maps to exactly one action. Any second use of the
///   same physical key conflicts regardless of gesture — a hold-Space Drop plus
///   a tap-Space anything is indistinguishable to the user and fires falsely.
@MainActor
final class HotkeyConflictModelTests: XCTestCase {
    // MARK: Modifier (tap/hold split is allowed)

    func test_modifier_tap_hold_split_is_not_conflict() {
        // tap R⌘ and hold R⌘ are the canonical Agent text/voice pairing.
        var configuration = HotkeyConfiguration.defaults
        configuration.agentTextShortcut = .modifier(.rightCommand)
        configuration.agentVoiceShortcut = .modifier(.rightCommand)
        configuration.agentVoiceGesture = .hold

        XCTAssertTrue(configuration.conflicts.isEmpty)
    }

    func test_agent_text_and_voice_share_rcmd_without_conflict() {
        // The real production default: Agent text = (.modifier(.rightCommand), tap),
        // Agent voice = (.modifier(.rightCommand), hold). This split MUST survive
        // the new physical-key model — the rule is "physical key = one action"
        // for ordinary keys, not "simplify away the modifier tap/hold split".
        let configuration = HotkeyConfiguration.defaults

        XCTAssertEqual(configuration.agentTextShortcut, .modifier(.rightCommand))
        XCTAssertEqual(configuration.agentVoiceShortcut, .modifier(.rightCommand))
        XCTAssertEqual(configuration.agentVoiceGesture, .hold)
        XCTAssertTrue(configuration.conflicts.isEmpty)
    }

    func test_modifier_same_gesture_same_key_is_conflict() throws {
        // Two tap bindings on the same modifier DO collide (same gesture + key).
        var configuration = HotkeyConfiguration.defaults
        configuration.agentTextShortcut = .modifier(.rightCommand)
        configuration.agentVoiceShortcut = .modifier(.rightCommand)
        configuration.agentVoiceGesture = .tap

        let conflict = try XCTUnwrap(configuration.conflicts.first)
        XCTAssertEqual(conflict.actionTitles, ["Agent text", "Agent voice"])
        XCTAssertTrue(conflict.message.contains("already used"))
    }

    // MARK: Combo (one physical key = one action, gesture ignored)

    func test_combo_same_key_any_gesture_is_conflict() throws {
        // ⌥D assigned to a tap action (Agent text) and a hold action (Agent
        // voice) is a conflict: a real key combo is one physical key, and
        // tap/hold on an ordinary key cannot be reliably told apart.
        var configuration = HotkeyConfiguration.defaults
        configuration.agentTextShortcut = .combo(.optionD)
        configuration.agentVoiceShortcut = .combo(.optionD)
        configuration.agentVoiceGesture = .hold

        let conflict = try XCTUnwrap(configuration.conflicts.first)
        XCTAssertEqual(conflict.actionTitles, ["Agent text", "Agent voice"])
        XCTAssertTrue(conflict.message.contains("already used"))
    }

    func test_combo_same_key_same_gesture_is_conflict() throws {
        // Sanity: two tap combos on the same physical key still conflict (this
        // worked before and must keep working under the physical-key model).
        var configuration = HotkeyConfiguration.defaults
        configuration.agentTextShortcut = .combo(.optionQ)
        configuration.agentCloseShortcut = .combo(.optionQ)

        let conflict = try XCTUnwrap(configuration.conflicts.first)
        XCTAssertEqual(conflict.actionTitles, ["Agent text", "Agent close"])
    }

    // MARK: Hold-Space (bare Space, gesture ignored)

    func test_holdspace_conflicts_with_other_space_binding() throws {
        // The reachable hold-Space regression: Drop defaults to `.holdSpace`,
        // and a SECOND action also bound to `.holdSpace` must conflict. The
        // bare press-and-hold on Space is one physical trigger — two actions on
        // it is the ROO-234 false-firing scenario. (A bare-Space *combo*,
        // keyCode=Space + no modifier, is NOT reachable: `recorded(from:)`
        // rejects modifier-less combos, and `.holdSpace` is the only way bare
        // Space enters the model. So the only constructible Space collision is
        // holdSpace + holdSpace — see also the design note in this stage's report.)
        var configuration = HotkeyConfiguration.defaults
        configuration.agentCloseShortcut = .holdSpace

        let conflict = try XCTUnwrap(configuration.conflicts.first)
        XCTAssertTrue(conflict.actionTitles.contains("Drop voice"))
        XCTAssertTrue(conflict.actionTitles.contains("Agent close"))
    }

    func test_holdspace_does_not_conflict_with_option_space_combo() {
        // `.holdSpace` is a dedicated bare-Space hold trigger, deliberately
        // distinct from any `.combo` (see the doc comment on
        // `HotkeyBinding.Key.holdSpace`). `⌥+Space` is a different physical
        // trigger (Space + Option modifier). They must NOT conflict — distinct
        // triggers, per the Stage 1 baseline interpretation.
        var configuration = HotkeyConfiguration.defaults
        configuration.agentCloseShortcut = .combo(.optionSpace)

        XCTAssertTrue(configuration.conflicts.isEmpty)
    }

    // MARK: Regression-lock: ≤ 2 keys (1 modifier + 1 key)

    func test_recorder_rejects_more_than_two_keys() throws {
        // REGRESSION-LOCK: the recorder already captures exactly one modifier +
        // one key — a recorded combo never carries a second non-modifier key.
        // This pins the "≤ 2 keys" invariant; it does NOT add a new guard for a
        // bug that does not exist. Recording two keys in a row replaces the key
        // slot (the second key wins) rather than accumulating a third token.
        var recorder = HotkeyComboRecorder()
        let modifierEvent = try XCTUnwrap(makeModifierEvent(modifierFlags: [.option]))
        let firstKeyEvent = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_D),
            charactersIgnoringModifiers: "d",
            modifierFlags: []
        ))
        let secondKeyEvent = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_Q),
            charactersIgnoringModifiers: "q",
            modifierFlags: []
        ))

        XCTAssertNil(recorder.record(modifierEvent))
        XCTAssertEqual(recorder.record(firstKeyEvent), .optionD)

        let replacement = try XCTUnwrap(recorder.record(secondKeyEvent))

        // The combo holds exactly one modifier glyph + one key glyph — no third
        // key token accumulated.
        XCTAssertEqual(replacement, .optionQ)
        XCTAssertEqual(recorder.contents, [.text(HotkeyGlyph.option), .text("Q")])
        XCTAssertEqual(recorder.contents.count, 2)
    }

    func test_recorded_combo_requires_a_modifier() throws {
        // The other half of "≤ 2 keys": a bare key with no modifier is rejected
        // by the recorder, so a recorded combo is always 1 modifier + 1 key.
        let bareKeyEvent = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_A),
            charactersIgnoringModifiers: "a",
            modifierFlags: []
        ))

        XCTAssertNil(HotkeyTapCombo.recorded(from: bareKeyEvent))
    }

    // MARK: Defaults

    func test_default_configuration_has_no_conflicts() {
        // The shipped defaults (R⌘ tap/hold split + hold-Space Drop + distinct
        // combos) must be conflict-free under the new physical-key model.
        XCTAssertTrue(HotkeyConfiguration.defaults.conflicts.isEmpty)
    }

    // MARK: Test event factories (mirror HotkeyPreferencesTests)

    private func makeKeyEvent(
        keyCode: UInt16,
        charactersIgnoringModifiers: String,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: charactersIgnoringModifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func makeModifierEvent(modifierFlags: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .flagsChanged,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(kVK_Option)
        )
    }
}

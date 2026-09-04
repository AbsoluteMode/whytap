import Carbon.HIToolbox
import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class HotkeyPreferencesTests: XCTestCase {
    func testDefaultsMatchCurrentProductionBindings() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())

        XCTAssertEqual(preferences.agentTextShortcut, .modifier(.rightCommand))
        XCTAssertEqual(preferences.agentVoiceShortcut, .modifier(.rightCommand))
        XCTAssertEqual(preferences.agentTextKey, .rightCommand)
        XCTAssertEqual(preferences.agentVoiceKey, .rightCommand)
        XCTAssertEqual(preferences.agentVoiceGesture, .hold)
        // Drop is now the Space-hold gesture (Stage 4 cutover): a press-and-hold
        // on Space, not a Carbon combo. `dropVoiceShortcut` is `.holdSpace`,
        // `dropVoiceGesture` is `.hold` (release stops + transcribes), and the
        // optional combo accessor reports `nil` because there is no real combo.
        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        XCTAssertNil(preferences.configuration.dropVoiceTapComboIfPresent)
        XCTAssertEqual(preferences.agentCloseCombo, .optionQ)
        XCTAssertEqual(preferences.usefulLinksInsertCombo, .leftArrow)
        XCTAssertEqual(preferences.usefulLinksOpenCombo, .rightArrow)
        XCTAssertEqual(preferences.usefulLinksNextCombo, .downArrow)
        XCTAssertEqual(preferences.usefulLinksPreviousCombo, .upArrow)
        XCTAssertEqual(preferences.meetingRecordShortcut, .combo(.optionM))
        XCTAssertEqual(HotkeyDisplay.agentTextHint(for: preferences.configuration), "tap r cmd")
        XCTAssertEqual(HotkeyDisplay.agentVoiceHint(for: preferences.configuration), "hold r cmd")
        XCTAssertEqual(HotkeyDisplay.dropVoiceHint(for: preferences.configuration), "hold Space")
        XCTAssertEqual(HotkeyDisplay.agentCloseHint(for: preferences.configuration), "tap opt q")
        XCTAssertEqual(HotkeyDisplay.usefulLinksInsertHint(for: preferences.configuration), "tap left")
        XCTAssertEqual(HotkeyDisplay.usefulLinksOpenHint(for: preferences.configuration), "tap right")
        XCTAssertEqual(HotkeyDisplay.usefulLinksNextHint(for: preferences.configuration), "tap down")
        XCTAssertEqual(HotkeyDisplay.usefulLinksPreviousHint(for: preferences.configuration), "tap up")
    }

    func testPersistsChangedBindingsImmediately() {
        let defaults = makeDefaults()
        var preferences: HotkeyPreferences? = HotkeyPreferences(defaults: defaults)

        preferences?.agentTextShortcut = .combo(.optionD)
        preferences?.agentVoiceShortcut = .modifier(.rightOption)
        preferences?.agentVoiceGesture = .tap
        // Drop defaults to the Space-hold gesture; assign it explicitly here and
        // prove it round-trips through UserDefaults. (Combo-Drop persistence is
        // covered by `DropConfigurableTests.test_reinit_preserves_user_combo_drop`.)
        preferences?.dropVoiceShortcut = .holdSpace
        preferences?.dropVoiceGesture = .hold
        preferences?.agentCloseCombo = .optionD
        preferences?.usefulLinksInsertCombo = .optionSpace
        preferences?.usefulLinksOpenCombo = .optionQ
        preferences?.usefulLinksNextCombo = .optionSpace
        preferences?.usefulLinksPreviousCombo = .optionQ
        preferences = nil

        let reloaded = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.agentTextShortcut, .combo(.optionD))
        XCTAssertEqual(reloaded.agentVoiceShortcut, .modifier(.rightOption))
        XCTAssertEqual(reloaded.agentVoiceGesture, .tap)
        XCTAssertEqual(reloaded.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(reloaded.dropVoiceGesture, .hold)
        XCTAssertEqual(reloaded.agentCloseCombo, .optionD)
        XCTAssertEqual(reloaded.usefulLinksInsertCombo, .optionSpace)
        XCTAssertEqual(reloaded.usefulLinksOpenCombo, .optionQ)
        XCTAssertEqual(reloaded.usefulLinksNextCombo, .optionSpace)
        XCTAssertEqual(reloaded.usefulLinksPreviousCombo, .optionQ)
        XCTAssertEqual(HotkeyDisplay.agentTextHint(for: reloaded.configuration), "tap opt d")
        // agentVoiceGesture=.tap → voiceTitle="Toggle" → lowercased "toggle"
        XCTAssertEqual(HotkeyDisplay.agentVoiceHint(for: reloaded.configuration), "toggle r opt")
        XCTAssertEqual(HotkeyDisplay.dropVoiceHint(for: reloaded.configuration), "hold Space")
        XCTAssertEqual(HotkeyDisplay.agentCloseHint(for: reloaded.configuration), "tap opt d")
        XCTAssertEqual(HotkeyDisplay.usefulLinksInsertHint(for: reloaded.configuration), "tap opt space")
        XCTAssertEqual(HotkeyDisplay.usefulLinksOpenHint(for: reloaded.configuration), "tap opt q")
        XCTAssertEqual(HotkeyDisplay.usefulLinksNextHint(for: reloaded.configuration), "tap opt space")
        XCTAssertEqual(HotkeyDisplay.usefulLinksPreviousHint(for: reloaded.configuration), "tap opt q")
    }

    func test_combo_flags_map_carbon_to_cgevent() {
        // The combo-swallow tap (`SpaceHoldMonitor`) gates the trigger keyDown on
        // `CGEventFlags`, but `HotkeyTapCombo.modifiers` is a Carbon mask. The
        // `cgEventFlags` bridge converts each Carbon bit to its CoreGraphics peer
        // so a rebound hold-combo Drop (e.g. ⌥D) can be routed through the tap.
        XCTAssertEqual(HotkeyTapCombo.optionD.cgEventFlags, [.maskAlternate])
        XCTAssertEqual(
            HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(cmdKey) | UInt32(optionKey), keyTitle: "D").cgEventFlags,
            [.maskCommand, .maskAlternate]
        )
        XCTAssertEqual(
            HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey) | UInt32(optionKey), keyTitle: "D").cgEventFlags,
            [.maskControl, .maskAlternate]
        )
        XCTAssertEqual(
            HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(shiftKey) | UInt32(optionKey), keyTitle: "D").cgEventFlags,
            [.maskShift, .maskAlternate]
        )
        // A modifier-less combo maps to an empty flag set (no incidental bits).
        XCTAssertEqual(HotkeyTapCombo.leftArrow.cgEventFlags, [])
    }

    func testDropTapCombosMapToCarbonRegistrations() {
        XCTAssertEqual(HotkeyTapCombo.optionSlash.keyCode, CarbonHotkeyMonitor.slashKeyCode)
        XCTAssertEqual(HotkeyTapCombo.optionPeriod.keyCode, UInt32(kVK_ANSI_Period))
        XCTAssertEqual(HotkeyTapCombo.optionSpace.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(HotkeyTapCombo.optionD.keyCode, UInt32(kVK_ANSI_D))
        XCTAssertEqual(HotkeyTapCombo.optionQ.keyCode, CarbonHotkeyMonitor.qKeyCode)
        XCTAssertEqual(HotkeyTapCombo.optionLeftArrow.keyCode, CarbonHotkeyMonitor.leftArrowKeyCode)
        XCTAssertEqual(HotkeyTapCombo.optionRightArrow.keyCode, CarbonHotkeyMonitor.rightArrowKeyCode)
        XCTAssertEqual(HotkeyTapCombo.optionUpArrow.keyCode, CarbonHotkeyMonitor.upArrowKeyCode)
        XCTAssertEqual(HotkeyTapCombo.optionDownArrow.keyCode, CarbonHotkeyMonitor.downArrowKeyCode)
        XCTAssertEqual(HotkeyTapCombo.optionQ.modifiers, CarbonHotkeyMonitor.optionModifier)
        // Bare-arrow Useful Links combos (Insert ←, Open →, Next ↓, Prev ↑)
        // carry NO modifier.
        XCTAssertEqual(HotkeyTapCombo.leftArrow.keyCode, CarbonHotkeyMonitor.leftArrowKeyCode)
        XCTAssertEqual(HotkeyTapCombo.rightArrow.keyCode, CarbonHotkeyMonitor.rightArrowKeyCode)
        XCTAssertEqual(HotkeyTapCombo.upArrow.keyCode, CarbonHotkeyMonitor.upArrowKeyCode)
        XCTAssertEqual(HotkeyTapCombo.downArrow.keyCode, CarbonHotkeyMonitor.downArrowKeyCode)
        XCTAssertEqual(HotkeyTapCombo.leftArrow.modifiers, 0)
        XCTAssertEqual(HotkeyTapCombo.rightArrow.modifiers, 0)
        XCTAssertEqual(HotkeyTapCombo.upArrow.modifiers, 0)
        XCTAssertEqual(HotkeyTapCombo.downArrow.modifiers, 0)
    }

    func testHotkeyGestureVoiceTitle() {
        // `.tap` → "Toggle" for voice rows (tap-start/tap-stop semantics).
        // `.hold` → "Hold" (unchanged — one source of truth via extension).
        XCTAssertEqual(HotkeyGesture.tap.voiceTitle, "Toggle")
        XCTAssertEqual(HotkeyGesture.hold.voiceTitle, "Hold")
        // Sanity: voiceTitle for .hold matches title (no rename).
        XCTAssertEqual(HotkeyGesture.hold.voiceTitle, HotkeyGesture.hold.title)
    }

    func testPersistsCustomRecordedComboOutsidePresetList() {
        let defaults = makeDefaults()
        let custom = HotkeyTapCombo(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(cmdKey) | UInt32(shiftKey),
            keyTitle: "A"
        )
        XCTAssertEqual(HotkeyTapCombo(rawValue: custom.rawValue), custom)

        var preferences: HotkeyPreferences? = HotkeyPreferences(defaults: defaults)
        preferences?.agentCloseCombo = custom
        preferences = nil

        let reloaded = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.agentCloseCombo, custom)
        XCTAssertEqual(reloaded.agentCloseCombo.contents, [
            .text(HotkeyGlyph.shift),
            .text(HotkeyGlyph.command),
            .text("A")
        ])
    }

    func testRecordsUserProvidedKeyComboFromKeyboardEvent() throws {
        let event = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_A),
            charactersIgnoringModifiers: "a",
            modifierFlags: [.command, .shift]
        ))

        let combo = try XCTUnwrap(HotkeyTapCombo.recorded(from: event))

        XCTAssertEqual(combo, HotkeyTapCombo(
            keyCode: UInt32(kVK_ANSI_A),
            modifiers: UInt32(cmdKey) | UInt32(shiftKey),
            keyTitle: "A"
        ))
        XCTAssertEqual(combo.contents, [
            .text(HotkeyGlyph.shift),
            .text(HotkeyGlyph.command),
            .text("A")
        ])
    }

    func testRejectsBareRecordedKeyCombo() throws {
        let event = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_A),
            charactersIgnoringModifiers: "a",
            modifierFlags: []
        ))

        XCTAssertNil(HotkeyTapCombo.recorded(from: event))
    }

    func testResetRestoresDefaults() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        preferences.agentTextShortcut = .combo(.optionD)
        preferences.agentVoiceShortcut = .modifier(.rightOption)
        preferences.agentVoiceGesture = .tap
        preferences.dropVoiceGesture = .hold
        preferences.dropVoiceTapCombo = .optionD
        preferences.agentCloseCombo = .optionSpace
        preferences.usefulLinksInsertCombo = .optionQ
        preferences.usefulLinksOpenCombo = .optionD
        preferences.usefulLinksNextCombo = .optionQ
        preferences.usefulLinksPreviousCombo = .optionPeriod

        preferences.resetToDefaults()

        XCTAssertEqual(preferences.configuration, .defaults)
    }

    func testAgentTapAndHoldCanShareTheSamePhysicalKeyWithoutConflict() {
        let configuration = HotkeyConfiguration.defaults

        XCTAssertTrue(configuration.conflicts.isEmpty)
    }

    func testAgentTextAndVoiceTapOnSameKeyConflictBeforeSaving() {
        var configuration = HotkeyConfiguration.defaults
        configuration.agentTextShortcut = .modifier(.rightCommand)
        configuration.agentVoiceShortcut = .modifier(.rightCommand)
        configuration.agentVoiceGesture = .tap

        let conflict = try! XCTUnwrap(configuration.conflicts.first)
        XCTAssertEqual(conflict.actionTitles, ["Agent text", "Agent voice"])
        XCTAssertTrue(conflict.message.contains("already used"))
    }

    func testAgentTextTapAndVoiceHoldOnSameComboConflict() {
        // ROO-234 (Stage 1): the conflict model now reasons about the *physical
        // key*. tap/hold on the same ordinary key combo (here ⌥D) is no longer
        // an allowed split — unlike a modifier (R⌘), tap and hold on a regular
        // key cannot be reliably distinguished, so the second use of ⌥D is a
        // conflict. The tap/hold split survives only for `.modifier` bindings
        // (see `testAgentTapAndHoldCanShareTheSamePhysicalKeyWithoutConflict`).
        var configuration = HotkeyConfiguration.defaults
        configuration.agentTextShortcut = .combo(.optionD)
        configuration.agentVoiceShortcut = .combo(.optionD)
        configuration.agentVoiceGesture = .hold

        let conflict = try! XCTUnwrap(configuration.conflicts.first)
        XCTAssertEqual(conflict.actionTitles, ["Agent text", "Agent voice"])
    }

    func testAgentComboConflictsWithOtherTapComboByPhysicalKey() {
        var configuration = HotkeyConfiguration.defaults
        configuration.agentTextShortcut = .combo(.optionQ)
        configuration.agentCloseShortcut = .combo(.optionQ)

        let conflict = try! XCTUnwrap(configuration.conflicts.first)
        XCTAssertEqual(conflict.actionTitles, ["Agent text", "Agent close"])
    }

    func testDetectsDuplicateTapCombosBeforeSaving() {
        var configuration = HotkeyConfiguration.defaults
        // Drop now defaults to the `.hold` Space gesture; assigning a tap combo
        // to it requires also flipping the gesture back to `.tap`, otherwise a
        // hold-Drop and a tap-AgentClose on the same physical key would NOT
        // conflict (tap/hold on one key is an allowed pairing — see
        // `testAgentTapAndHoldCanShareTheSamePhysicalKeyWithoutConflict`). The
        // intent here is "two TAP combos on the same key conflict".
        configuration.dropVoiceGesture = .tap
        configuration.dropVoiceTapCombo = .optionQ
        configuration.agentCloseCombo = .optionQ

        let conflict = try! XCTUnwrap(configuration.conflicts.first)
        XCTAssertEqual(conflict.actionTitles, ["Drop voice", "Agent close"])
        XCTAssertTrue(conflict.message.contains("already used"))
    }

    func testDuplicatePhysicalKeysConflictEvenWhenDisplayTitleDiffersByLayout() {
        var configuration = HotkeyConfiguration.defaults
        configuration.agentCloseShortcut = .combo(HotkeyTapCombo(
            keyCode: UInt32(kVK_ANSI_Y),
            modifiers: UInt32(optionKey),
            keyTitle: "Y"
        ))
        configuration.usefulLinksOpenShortcut = .combo(HotkeyTapCombo(
            keyCode: UInt32(kVK_ANSI_Y),
            modifiers: UInt32(optionKey),
            keyTitle: "\u{041D}"
        ))

        let conflict = try! XCTUnwrap(configuration.conflicts.first)
        XCTAssertEqual(conflict.actionTitles, ["Agent close", "Useful links open"])
        XCTAssertEqual(configuration.agentCloseShortcut, configuration.usefulLinksOpenShortcut)
    }

    func testApplyRejectsConflictingBindingsAndKeepsExistingPreferences() throws {
        let preferences = HotkeyPreferences(defaults: makeDefaults())
        var configuration = preferences.configuration
        // Make Drop a tap combo so it collides with the AgentClose tap combo
        // (see `testDetectsDuplicateTapCombosBeforeSaving` for why the gesture
        // flip is required now that Drop defaults to `.hold`).
        configuration.dropVoiceGesture = .tap
        configuration.dropVoiceTapCombo = .optionQ
        configuration.agentCloseCombo = .optionQ

        XCTAssertThrowsError(try preferences.apply(configuration))
        XCTAssertEqual(preferences.configuration, .defaults)
    }

    func testHotkeyRecorderCapturesTwoButtonsIntoComboWithoutSavingPreferences() throws {
        let defaults = makeDefaults()
        let preferences = HotkeyPreferences(defaults: defaults)
        var recorder = HotkeyComboRecorder()
        let modifierEvent = try XCTUnwrap(makeModifierEvent(modifierFlags: [.option]))
        let keyEvent = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_D),
            charactersIgnoringModifiers: "d",
            modifierFlags: []
        ))

        XCTAssertNil(recorder.record(modifierEvent))
        XCTAssertEqual(recorder.contents, [.text(HotkeyGlyph.option)])

        let combo = try XCTUnwrap(recorder.record(keyEvent))

        XCTAssertEqual(combo, .optionD)
        XCTAssertEqual(recorder.contents, [.text(HotkeyGlyph.option), .text("D")])
        XCTAssertEqual(preferences.agentCloseCombo, .optionQ)
    }

    func testHotkeyRecorderKeepsListeningAndReplacesSecondButton() throws {
        var recorder = HotkeyComboRecorder()
        let modifierEvent = try XCTUnwrap(makeModifierEvent(modifierFlags: [.option]))
        let firstKeyEvent = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_D),
            charactersIgnoringModifiers: "d",
            modifierFlags: []
        ))
        let replacementKeyEvent = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_Q),
            charactersIgnoringModifiers: "q",
            modifierFlags: []
        ))

        XCTAssertNil(recorder.record(modifierEvent))
        XCTAssertEqual(recorder.record(firstKeyEvent), .optionD)

        let replacementCombo = try XCTUnwrap(recorder.record(replacementKeyEvent))

        XCTAssertEqual(replacementCombo, .optionQ)
        XCTAssertEqual(recorder.contents, [.text(HotkeyGlyph.option), .text("Q")])
    }

    func testHotkeyRecorderCanStartFromExistingComboAndReplaceEitherSlot() throws {
        var recorder = HotkeyComboRecorder(combo: .optionQ)
        let keyEvent = try XCTUnwrap(makeKeyEvent(
            keyCode: UInt16(kVK_ANSI_D),
            charactersIgnoringModifiers: "d",
            modifierFlags: []
        ))
        let modifierEvent = try XCTUnwrap(makeModifierEvent(modifierFlags: [.command]))

        XCTAssertEqual(recorder.contents, [.text(HotkeyGlyph.option), .text("Q")])
        XCTAssertEqual(recorder.record(keyEvent), .optionD)

        let commandD = try XCTUnwrap(recorder.record(modifierEvent))

        XCTAssertEqual(commandD, HotkeyTapCombo(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey),
            keyTitle: "D"
        ))
        XCTAssertEqual(recorder.contents, [.text(HotkeyGlyph.command), .text("D")])
    }

    func testStaleNonDropHoldSpaceFallsBackToSlotDefaultAtLoad() throws {
        // `.holdSpace` is Drop-only: the SpaceHold tap asserts a release
        // handler that non-Drop registrations legitimately don't pass, so a
        // stale persisted `.holdSpace` on a non-Drop slot (possible from
        // builds where the recorder emitted it before the Settings gate
        // existed) would crash a debug build at launch. Load treats it like a
        // decode failure: the slot falls back through its existing default
        // chain. One slot per load-path family: modifier-legacy (agent
        // voice), combo-legacy (agent close, links), loadShortcut helper
        // (hover). Seeding goes through a FIRST instance's didSet sinks —
        // the same write path the old builds used — so the test cannot pass
        // vacuously if a defaults-key string ever drifts.
        let defaults = makeDefaults()
        let oldBuild = HotkeyPreferences(defaults: defaults)
        oldBuild.agentVoiceShortcut = .holdSpace
        oldBuild.agentCloseShortcut = .holdSpace
        oldBuild.usefulLinksNextShortcut = .holdSpace
        oldBuild.hoverSlot2Shortcut = .holdSpace
        // Drop legitimately persists `.holdSpace`; pair it with the stale
        // `.tap` gesture an older build could have written.
        oldBuild.dropVoiceShortcut = .holdSpace
        oldBuild.dropVoiceGesture = .tap

        let preferences = HotkeyPreferences(defaults: defaults)

        XCTAssertEqual(
            preferences.agentVoiceShortcut,
            HotkeyConfiguration.defaults.agentVoiceShortcut,
            "stale holdSpace on agent voice must fall back to the default"
        )
        XCTAssertEqual(
            preferences.agentCloseShortcut,
            HotkeyConfiguration.defaults.agentCloseShortcut,
            "stale holdSpace on agent close must fall back to the default"
        )
        XCTAssertEqual(
            preferences.usefulLinksNextShortcut,
            HotkeyConfiguration.defaults.usefulLinksNextShortcut,
            "stale holdSpace on links next must fall back to the default"
        )
        XCTAssertEqual(
            preferences.hoverSlot2Shortcut,
            HotkeyConfiguration.defaults.hoverSlot2Shortcut,
            "stale holdSpace on hover slot 2 must fall back to the default"
        )
        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace, "Drop keeps holdSpace")

        // Heal on Save: `apply` normalizes the Drop gesture (Space hold-only),
        // so the stale `.tap` converges to `.hold` and persists.
        try preferences.apply(preferences.configuration)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold,
                       "Save must heal the stale holdSpace+tap pair")
        let reloaded = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.dropVoiceGesture, .hold,
                       "the healed gesture must be the persisted one")
    }

    func testMeetingRecordShortcutPersistsAndJoinsConflictModel() {
        // Fresh domain (and any pre-feature build's domain): the key is
        // absent, so the loader falls back to the ⌥M default.
        let defaults = makeDefaults()
        var preferences: HotkeyPreferences? = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(preferences?.meetingRecordShortcut, .combo(.optionM))

        // A rebind persists immediately and survives a reload.
        preferences?.meetingRecordShortcut = .combo(.optionD)
        preferences = nil
        let reloaded = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.meetingRecordShortcut, .combo(.optionD))

        // Participates in the physical-key conflict model: colliding with
        // Agent close (⌥Q) must be reported so Save is blocked.
        var configuration = HotkeyConfiguration.defaults
        configuration.meetingRecordShortcut = configuration.agentCloseShortcut
        XCTAssertTrue(
            configuration.conflicts.contains { $0.actionTitles.contains("Meeting record") },
            "meeting record must join the conflict model"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SidekeyTests.HotkeyPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

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

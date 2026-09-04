import Carbon.HIToolbox
import AppKit
import XCTest
@testable import Sidekey

/// Stage 2 (ROO-234) + B2: Drop is a reassignable hotkey with a free gesture.
///
/// The user may rebind Drop to a combo, or restore the "Hold Space (default)"
/// preset. `setDropShortcut` preserves the user's chosen gesture for combos;
/// `.holdSpace` forces `.hold` (Space is hold-only — a tap is
/// indistinguishable from typing a space). `normalizedDropGesture` applies the
/// same rule at read time, healing stale persisted state (`.holdSpace` +
/// `.tap` written by an older build). The one-time
/// `migrateDropComboToHoldSpaceIfNeeded` cutover is gone, so a stored combo
/// Drop now survives a reload instead of being clobbered back to Space.
@MainActor
final class DropConfigurableTests: XCTestCase {

    // MARK: - Drop can be assigned a combo (round-trip through UserDefaults)

    func test_drop_can_be_assigned_combo() {
        let defaults = makeDefaults()
        var configuration = HotkeyConfiguration.defaults
        configuration.setDropShortcut(.combo(.optionD))

        let preferences = HotkeyPreferences(defaults: defaults)
        try? preferences.apply(configuration)

        XCTAssertEqual(preferences.dropVoiceShortcut, .combo(.optionD))

        // Round-trips through UserDefaults: a fresh load sees the same combo.
        let reloaded = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.dropVoiceShortcut, .combo(.optionD))
    }

    // MARK: - Preset restores Hold Space + hold gesture

    func test_drop_holdspace_preset_sets_holdspace_and_hold() {
        var configuration = HotkeyConfiguration.defaults
        // Start from a combo Drop with the wrong gesture, then apply the preset.
        configuration.dropVoiceGesture = .tap
        configuration.dropVoiceShortcut = .combo(.optionD)

        configuration.resetDropToHoldSpace()

        XCTAssertEqual(configuration.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(configuration.dropVoiceGesture, .hold)
    }

    // MARK: - B2: setDropShortcut combo preserves gesture, holdSpace forces hold;
    //         normalizedDropGesture heals stale persisted state

    func test_combo_drop_preserves_hold_gesture() {
        var configuration = HotkeyConfiguration.defaults
        // `.hold` stays `.hold` — setDropShortcut never changes gesture for combos.
        configuration.dropVoiceGesture = .hold

        configuration.setDropShortcut(.combo(.optionD))

        XCTAssertEqual(configuration.dropVoiceShortcut, .combo(.optionD))
        XCTAssertEqual(configuration.dropVoiceGesture, .hold)
    }

    func test_combo_drop_preserves_tap_gesture() {
        var configuration = HotkeyConfiguration.defaults
        // `.tap` is also preserved — the model layer allows it (B3 unlocks the UI).
        configuration.dropVoiceGesture = .tap

        configuration.setDropShortcut(.combo(.optionD))

        XCTAssertEqual(configuration.dropVoiceShortcut, .combo(.optionD))
        XCTAssertEqual(configuration.dropVoiceGesture, .tap, "запись combo не должна сбрасывать выбранный жест")
    }

    func testSetDropShortcutHoldSpaceForcesHold() {
        var config = HotkeyConfiguration.defaults
        config.dropVoiceGesture = .tap
        config.setDropShortcut(.holdSpace)
        XCTAssertEqual(config.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(config.dropVoiceGesture, .hold, "Space hold-only")
    }

    func testNormalizedDropGestureFixesHoldSpaceTap() {
        var config = HotkeyConfiguration.defaults
        config.dropVoiceShortcut = .holdSpace
        config.dropVoiceGesture = .tap
        XCTAssertEqual(config.normalizedDropGesture, .hold)

        config.dropVoiceShortcut = .combo(.optionSlash)
        config.dropVoiceGesture = .tap
        XCTAssertEqual(config.normalizedDropGesture, .tap)

        // `.modifier` shares the non-holdSpace branch: gesture passes through.
        XCTAssertEqual(
            HotkeyConfiguration.normalizedDropGesture(shortcut: .modifier(.rightCommand), gesture: .tap),
            .tap
        )
    }

    // MARK: - Routing: hold-combo Drop → SpaceHold tap, holdSpace → SpaceHold,
    //         non-Drop combo → Carbon (combo-swallow Stage 2-4)

    /// A hold-combo Drop (e.g. ⌥D) now routes through the **generalized**
    /// `SpaceHoldMonitor` CGEventTap — the same swallow mechanism as hold-Space —
    /// so the bound character (∂) never prints. Stage 2's earlier
    /// "combo → Carbon" expectation is intentionally superseded here: only the
    /// Drop-hold registration sets `dropHoldSwallow`, and that flag flips the
    /// route to the tap. (Carbon hold-combos printed the character and had no
    /// Escape-cancel; the tap path fixes both.)
    func test_drop_hold_combo_routes_to_spacehold_tap() {
        let monitor = HotkeyShortcutMonitor(
            shortcut: .combo(.optionD),
            hotKeyIDValue: 1,
            onHotkey: {},
            onHotkeyReleased: {},
            onCancel: {},
            dropHoldSwallow: true
        )

        XCTAssertTrue(monitor.routedMonitorIsSpaceHold)
        XCTAssertFalse(monitor.routedMonitorIsCarbon)
    }

    func test_drop_holdspace_routes_to_spacehold() {
        let monitor = HotkeyShortcutMonitor(
            shortcut: .holdSpace,
            hotKeyIDValue: 1,
            onHotkey: {},
            onHotkeyReleased: {},
            onCancel: {}
        )

        XCTAssertTrue(monitor.routedMonitorIsSpaceHold)
        XCTAssertFalse(monitor.routedMonitorIsCarbon)
    }

    /// Every non-Drop combo (agent close ⌥Q, hover ⌥1..5, history ⌥V, help ⌥H,
    /// agent text/voice combos) is registered WITHOUT `dropHoldSwallow`, so it
    /// keeps the Carbon `RegisterEventHotKey` route — no Input Monitoring, no
    /// keystroke swallow. The default `dropHoldSwallow == false` guarantees this.
    func test_non_drop_combo_routes_to_carbon() {
        let monitor = HotkeyShortcutMonitor(
            shortcut: .combo(.optionQ),
            hotKeyIDValue: 1,
            onHotkey: {}
        )

        XCTAssertTrue(monitor.routedMonitorIsCarbon)
        XCTAssertFalse(monitor.routedMonitorIsSpaceHold)
    }

    // MARK: - isDropHoldTap truth table (Input Monitoring gate)

    /// `isDropHoldTap` is the single predicate that decides whether a Drop
    /// binding runs on the CGEventTap (and therefore needs Input Monitoring +
    /// the swallow route): hold-Space and hold-combo do; tap-combo and modifier
    /// Drop do not.
    ///
    /// Full routing matrix:
    /// | shortcut             | gesture | isDropHoldTap | routed monitor |
    /// |----------------------|---------|---------------|----------------|
    /// | .holdSpace           | .hold   | true          | SpaceHold      |
    /// | .combo (modifier)    | .hold   | true          | SpaceHold      |
    /// | .combo (modifier)    | .tap    | false         | Carbon         |
    /// | .combo (bare, mod=0) | .hold   | true          | SpaceHold      |
    /// | .combo (bare, mod=0) | .tap    | false         | Carbon         |
    /// | .modifier            | any     | false         | ModifierOnly   |
    func test_isDropHoldTap_truth_table() {
        // hold-Space → tap path.
        XCTAssertTrue(HotkeyShortcutMonitor.isDropHoldTap(shortcut: .holdSpace, gesture: .hold))
        // hold-combo → tap path (the new Stage 2-4 behaviour).
        XCTAssertTrue(HotkeyShortcutMonitor.isDropHoldTap(shortcut: .combo(.optionD), gesture: .hold))
        // tap-combo → Carbon (tap-Drop is deferred, but the gate must say false).
        XCTAssertFalse(HotkeyShortcutMonitor.isDropHoldTap(shortcut: .combo(.optionD), gesture: .tap))
        // bare-key hold (modifiers == 0) → tap path; same .combo branch, gesture decides.
        XCTAssertTrue(HotkeyShortcutMonitor.isDropHoldTap(
            shortcut: .combo(HotkeyTapCombo(keyCode: UInt32(kVK_Tab), modifiers: 0, keyTitle: "Tab")),
            gesture: .hold
        ))
        // bare-key tap → Carbon (grabbed globally; warned in Settings).
        XCTAssertFalse(HotkeyShortcutMonitor.isDropHoldTap(
            shortcut: .combo(HotkeyTapCombo(keyCode: UInt32(kVK_Tab), modifiers: 0, keyTitle: "Tab")),
            gesture: .tap
        ))
        // modifier Drop → Carbon/modifier monitor, never the tap.
        XCTAssertFalse(HotkeyShortcutMonitor.isDropHoldTap(shortcut: .modifier(.rightCommand), gesture: .hold))
        XCTAssertFalse(HotkeyShortcutMonitor.isDropHoldTap(shortcut: .modifier(.rightCommand), gesture: .tap))
    }

    // MARK: - Bare-key routing: modifiers == 0 combo routes the same as modifier combo

    /// A bare-key hold Drop (e.g. Tab, no modifiers) routes through
    /// `SpaceHoldMonitor` — identical to a modifier-combo hold Drop. The predicate
    /// `isDropHoldTap` is indifferent to the modifier mask; the `.combo` branch
    /// returns `gesture == .hold` unconditionally.
    func test_bare_key_hold_routes_to_spacehold() {
        let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: UInt32(kVK_Tab), modifiers: 0, keyTitle: "Tab"))
        let monitor = HotkeyShortcutMonitor(
            shortcut: bareTab,
            hotKeyIDValue: 1,
            onHotkey: {},
            onHotkeyReleased: {},
            onCancel: {},
            dropHoldSwallow: HotkeyShortcutMonitor.isDropHoldTap(shortcut: bareTab, gesture: .hold)
        )
        XCTAssertTrue(monitor.routedMonitorIsSpaceHold)
        XCTAssertFalse(monitor.routedMonitorIsCarbon)
    }

    /// A bare-key tap Drop routes through Carbon `RegisterEventHotKey` —
    /// the key is globally grabbed (no Input Monitoring needed; warned in Settings).
    func test_bare_key_tap_routes_to_carbon() {
        let bareTab = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: UInt32(kVK_Tab), modifiers: 0, keyTitle: "Tab"))
        XCTAssertFalse(HotkeyShortcutMonitor.isDropHoldTap(shortcut: bareTab, gesture: .tap))
        let monitor = HotkeyShortcutMonitor(
            shortcut: bareTab,
            hotKeyIDValue: 1,
            onHotkey: {}
        )
        XCTAssertTrue(monitor.routedMonitorIsCarbon)
        XCTAssertFalse(monitor.routedMonitorIsSpaceHold)
    }

    // MARK: - Reinit preserves a user combo Drop (migration removed)

    func test_reinit_preserves_user_combo_drop() {
        let defaults = makeDefaults()
        defaults.set(HotkeyShortcut.combo(.optionD).rawValue, forKey: "hotkeys.dropVoiceShortcut")
        defaults.set(HotkeyGesture.hold.rawValue, forKey: "hotkeys.dropVoiceGesture")

        // Reloading must NOT rewrite the stored combo back to `.holdSpace`
        // (the Stage 4 cutover migration was removed in Stage 2).
        let preferences = HotkeyPreferences(defaults: defaults)

        XCTAssertEqual(preferences.dropVoiceShortcut, .combo(.optionD))
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        // The persisted value is untouched, so a second reload is stable too.
        XCTAssertEqual(
            defaults.string(forKey: "hotkeys.dropVoiceShortcut"),
            HotkeyShortcut.combo(.optionD).rawValue
        )
    }

    // MARK: - Fresh install still defaults to Hold Space

    func test_fresh_install_defaults_to_hold_space() {
        let preferences = HotkeyPreferences(defaults: makeDefaults())

        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
    }

    // MARK: - Per-field conflict highlight (Stage 1 review fix)

    /// After Stage 1, `conflicts` groups by `conflictKey` (combo/holdSpace
    /// ignore gesture). The reported conflict carries only the *first* member's
    /// binding, so a per-row "is this row in a conflict?" check that compares
    /// the full `HotkeyBinding` (gesture included) would fail to flag the other
    /// member when the two members differ only by gesture. Both members must be
    /// matchable by `conflictKey` — this is the contract the Settings row
    /// highlight depends on.
    func test_combo_tap_and_hold_conflict_matches_both_rows_by_conflict_key() {
        var configuration = HotkeyConfiguration.defaults
        // Agent text = tap ⌥D; Drop = hold ⌥D. Same physical key, different
        // gesture → a single combo conflict (tap/hold indistinguishable).
        configuration.agentTextShortcut = .combo(.optionD)
        configuration.dropVoiceShortcut = .combo(.optionD)
        configuration.dropVoiceGesture = .hold

        let conflicts = configuration.conflicts
        XCTAssertEqual(conflicts.count, 1)
        let conflict = try! XCTUnwrap(conflicts.first)

        let agentTextBinding = HotkeyBinding(gesture: .tap, key: HotkeyShortcut.combo(.optionD).bindingKey)
        let dropBinding = HotkeyBinding(gesture: .hold, key: HotkeyShortcut.combo(.optionD).bindingKey)

        // The reported binding equals only ONE member's full binding…
        let fullBindingMatches = [agentTextBinding, dropBinding].filter { $0 == conflict.binding }
        XCTAssertEqual(fullBindingMatches.count, 1, "full-binding compare flags only one of the two rows")

        // …but BOTH members share the conflict's `conflictKey`, so a
        // conflictKey-based row check flags both rows (the Stage 2 fix).
        XCTAssertEqual(agentTextBinding.conflictKey, conflict.binding.conflictKey)
        XCTAssertEqual(dropBinding.conflictKey, conflict.binding.conflictKey)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SidekeyTests.DropConfigurable.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

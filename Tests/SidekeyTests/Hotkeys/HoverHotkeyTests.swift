import Carbon.HIToolbox
import AppKit
import XCTest
@testable import Sidekey

/// Stage 3 of configurable hotkeys (ROO-234 + ROO-210): the five Hover slots
/// gain positional keyboard shortcuts (default ⌥1..⌥5). Pressing ⌥N expands the
/// Hover (when policy allows) and runs the action of the tool currently in slot
/// `N` (`HoverLayoutStore.slots[N-1]`) — the SAME action a click on that tile
/// would fire (D1). Programmatic expansion respects `IslandHoverPolicy`
/// (`allowsExpansion`) so ⌥N never forces the drawer open during a meeting /
/// agent flow (D4).
@MainActor
final class HoverHotkeyTests: XCTestCase {

    // MARK: - Defaults are ⌥1..⌥5

    func test_hover_shortcut_defaults_are_option_digits() {
        let config = HotkeyConfiguration.defaults
        XCTAssertEqual(config.hoverSlot1Shortcut, .combo(.optionOne))
        XCTAssertEqual(config.hoverSlot2Shortcut, .combo(.optionTwo))
        XCTAssertEqual(config.hoverSlot3Shortcut, .combo(.optionThree))
        XCTAssertEqual(config.hoverSlot4Shortcut, .combo(.optionFour))
        XCTAssertEqual(config.hoverSlot5Shortcut, .combo(.optionFive))
    }

    func test_option_digit_presets_carry_option_modifier_and_digit_titles() {
        let presets: [(HotkeyTapCombo, UInt32, String)] = [
            (.optionOne, UInt32(kVK_ANSI_1), "1"),
            (.optionTwo, UInt32(kVK_ANSI_2), "2"),
            (.optionThree, UInt32(kVK_ANSI_3), "3"),
            (.optionFour, UInt32(kVK_ANSI_4), "4"),
            (.optionFive, UInt32(kVK_ANSI_5), "5")
        ]
        for (combo, expectedKeyCode, expectedTitle) in presets {
            XCTAssertEqual(combo.keyCode, expectedKeyCode)
            XCTAssertEqual(combo.modifiers, UInt32(optionKey))
            XCTAssertEqual(combo.keyTitle, expectedTitle)
        }
    }

    // MARK: - Round-trip (rawValue + Codable) stays on the legacy preset form

    func test_option_digit_presets_round_trip() throws {
        let presets: [HotkeyTapCombo] = [.optionOne, .optionTwo, .optionThree, .optionFour, .optionFive]
        for preset in presets {
            // rawValue must round-trip through the legacy-preset path (a short
            // token), NOT collapse into JSON — otherwise a stored ⌥1 reloads as
            // an anonymous JSON combo and breaks preset identity.
            let raw = preset.rawValue
            XCTAssertFalse(raw.contains("{"), "preset rawValue must be a legacy token, got JSON: \(raw)")
            let restored = try XCTUnwrap(HotkeyTapCombo(rawValue: raw))
            XCTAssertEqual(restored, preset)

            // Codable round-trip via HotkeyShortcut (the form persisted in prefs).
            let shortcut = HotkeyShortcut.combo(preset)
            let data = try JSONEncoder().encode(shortcut)
            let decoded = try JSONDecoder().decode(HotkeyShortcut.self, from: data)
            XCTAssertEqual(decoded, shortcut)
        }
    }

    func test_option_digit_preset_round_trips_through_shortcut_raw_value() throws {
        for preset in [HotkeyTapCombo.optionOne, .optionFive] {
            let shortcut = HotkeyShortcut.combo(preset)
            let restored = try XCTUnwrap(HotkeyShortcut(rawValue: shortcut.rawValue))
            XCTAssertEqual(restored, shortcut)
        }
    }

    // MARK: - Hover bindings participate in the conflict graph

    func test_hover_shortcuts_in_assignments() {
        let assignments = HotkeyConfiguration.defaults.assignments
        let hoverTitles = (1...5).map { "Hover slot \($0)" }
        for title in hoverTitles {
            XCTAssertTrue(
                assignments.contains { $0.actionTitle == title },
                "assignments missing \(title)"
            )
        }
        // Each hover binding is a `.tap` on its ⌥-digit combo.
        let slot1 = assignments.first { $0.actionTitle == "Hover slot 1" }
        XCTAssertEqual(slot1?.binding.gesture, .tap)
        XCTAssertEqual(slot1?.binding.key, .combo(.optionOne))
    }

    func test_default_configuration_has_no_conflicts_with_hover_slots() {
        // ⌥1..⌥5 are distinct physical keys and distinct from every other
        // default binding, so the full default config is still conflict-free.
        XCTAssertTrue(HotkeyConfiguration.defaults.conflicts.isEmpty)
    }

    func test_two_slots_on_same_hover_shortcut_conflict() throws {
        var config = HotkeyConfiguration.defaults
        // Put ⌥1 on two hover slots → one combo conflict.
        config.hoverSlot2Shortcut = .combo(.optionOne)
        let conflict = try XCTUnwrap(config.conflicts.first { $0.actionTitles.contains("Hover slot 1") })
        XCTAssertTrue(conflict.actionTitles.contains("Hover slot 1"))
        XCTAssertTrue(conflict.actionTitles.contains("Hover slot 2"))
    }

    func test_hover_shortcut_conflicts_with_agent_close() throws {
        var config = HotkeyConfiguration.defaults
        // agentClose default is ⌥Q; move a hover slot onto ⌥Q → conflict.
        config.hoverSlot1Shortcut = .combo(.optionQ)
        let conflict = try XCTUnwrap(config.conflicts.first { $0.actionTitles.contains("Agent close") })
        XCTAssertTrue(conflict.actionTitles.contains("Hover slot 1"))
        XCTAssertTrue(conflict.actionTitles.contains("Agent close"))
    }

    // MARK: - Prefs round-trip through UserDefaults

    func test_hover_prefs_round_trip_userdefaults() {
        let defaults = makeDefaults()
        var config = HotkeyConfiguration.defaults
        config.hoverSlot1Shortcut = .combo(.optionD)
        config.hoverSlot3Shortcut = .combo(.optionPeriod)

        let prefs = HotkeyPreferences(defaults: defaults)
        try? prefs.apply(config)

        XCTAssertEqual(prefs.hoverSlot1Shortcut, .combo(.optionD))
        XCTAssertEqual(prefs.hoverSlot3Shortcut, .combo(.optionPeriod))

        // Fresh load sees the same values.
        let reloaded = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.hoverSlot1Shortcut, .combo(.optionD))
        XCTAssertEqual(reloaded.hoverSlot3Shortcut, .combo(.optionPeriod))
        XCTAssertEqual(reloaded.hoverSlot2Shortcut, .combo(.optionTwo))
    }

    func test_fresh_install_hover_defaults_are_option_digits() {
        let prefs = HotkeyPreferences(defaults: makeDefaults())
        XCTAssertEqual(prefs.hoverSlot1Shortcut, .combo(.optionOne))
        XCTAssertEqual(prefs.hoverSlot5Shortcut, .combo(.optionFive))
    }

    func test_reset_to_defaults_restores_hover_shortcuts() {
        let prefs = HotkeyPreferences(defaults: makeDefaults())
        prefs.hoverSlot1Shortcut = .combo(.optionD)
        prefs.resetToDefaults()
        XCTAssertEqual(prefs.hoverSlot1Shortcut, .combo(.optionOne))
    }

    func test_configuration_computed_reflects_hover_shortcuts() {
        let prefs = HotkeyPreferences(defaults: makeDefaults())
        prefs.hoverSlot2Shortcut = .combo(.optionD)
        XCTAssertEqual(prefs.configuration.hoverSlot2Shortcut, .combo(.optionD))
    }

    // MARK: - Router: slot effect maps to the same action a click fires (D1)

    func test_router_maps_action_tools_to_island_actions() {
        // .action / .navigate tools route to an IslandActions closure.
        XCTAssertEqual(HoverSlotRouter.effect(for: .dropMode), .toggleDropMode)
        XCTAssertEqual(HoverSlotRouter.effect(for: .settings), .openSettings)
        XCTAssertEqual(HoverSlotRouter.effect(for: .hotkeys), .openHotkeys)
        XCTAssertEqual(HoverSlotRouter.effect(for: .notes), .openNotes)
        XCTAssertEqual(HoverSlotRouter.effect(for: .meetingRecord), .toggleMeetingRecord)
        XCTAssertEqual(HoverSlotRouter.effect(for: .quit), .quit)
        // The record toggle fires instantly — no drawer expansion required.
        XCTAssertFalse(HoverSlotEffect.toggleMeetingRecord.requiresExpansion)
    }

    func test_router_maps_inline_panel_tools_to_panels() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .vocab), .openPanel(.vocabularyEditor))
        XCTAssertEqual(HoverSlotRouter.effect(for: .caseVault), .openPanel(.caseVault))
        XCTAssertEqual(HoverSlotRouter.effect(for: .filler), .openPanel(.fillerEditor))
        XCTAssertEqual(HoverSlotRouter.effect(for: .inputLang), .openPanel(.inputLanguagePicker))
        XCTAssertEqual(HoverSlotRouter.effect(for: .outputLang), .openPanel(.outputLanguagePicker))
    }

    /// #313 turned the Clipboard tile into the History inline hover panel
    /// (`HoverTool.clipboard` is now `.inlinePanel`, title "History"). The ⌥N
    /// hotkey for that slot must therefore open the History panel in-place
    /// (D1: same as the tile click, which sets `panelMode = .history`), NOT
    /// fire the old bottom-strip `openClipboard` action.
    func test_router_maps_clipboard_slot_to_history_panel() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .clipboard), .openPanel(.history))
    }

    func test_inline_panel_effects_require_expansion_action_effects_do_not() {
        // .action/.navigate effects can run without the drawer open (they open
        // windows / toggle state); .openPanel effects only make sense expanded.
        XCTAssertFalse(HoverSlotEffect.toggleDropMode.requiresExpansion)
        XCTAssertFalse(HoverSlotEffect.openSettings.requiresExpansion)
        XCTAssertTrue(HoverSlotEffect.openPanel(.caseVault).requiresExpansion)
        XCTAssertTrue(HoverSlotEffect.openPanel(.vocabularyEditor).requiresExpansion)
    }

    /// History is an inline panel rendered inside the drawer, so its ⌥N hotkey
    /// must request programmatic expansion (D3b) — exactly like vocab.
    func test_clipboard_history_slot_requires_expansion() {
        XCTAssertTrue(HoverSlotRouter.effect(for: .clipboard).requiresExpansion)
        XCTAssertTrue(HoverSlotEffect.openPanel(.history).requiresExpansion)
    }

    // MARK: - Activating a slot invokes the slot's IslandActions closure

    func test_activate_hover_slot_invokes_slot_action() {
        var didToggleDropMode = false
        var didOpenClipboard = false
        var didOpenSettings = false
        let actions = spyActions(
            toggleDropMode: { didToggleDropMode = true },
            openClipboard: { didOpenClipboard = true },
            openSettings: { didOpenSettings = true }
        )

        // Slot 1 (default layout) = .dropMode → handled by
        // `AppDelegate.onHoverSlotActivated` directly (the returned mode feeds
        // `AppState.publishDropModeHotkeyToggle`), so `invoke` must be a no-op
        // — see test_toggle_drop_mode_effect_is_noop_in_invoke.
        HoverSlotRouter.effect(for: .dropMode).invoke(on: actions)
        XCTAssertFalse(didToggleDropMode)
        XCTAssertFalse(didOpenClipboard)
        XCTAssertFalse(didOpenSettings)

        // Slot 3 (default layout) = .clipboard → .openPanel(.history) after
        // #313. Inline-panel effects are driven by the view (panel mode), so
        // invoking on `actions` is a no-op — the old bottom-strip openClipboard
        // closure must NOT fire from a hover slot anymore.
        HoverSlotRouter.effect(for: .clipboard).invoke(on: actions)
        XCTAssertFalse(didOpenClipboard)

        // Slot 5 (locked) = .settings → openSettings.
        HoverSlotRouter.effect(for: .settings).invoke(on: actions)
        XCTAssertTrue(didOpenSettings)
    }

    func test_navigate_tools_invoke_their_closures() {
        var didOpenHotkeys = false
        var didOpenNotes = false
        var didQuit = false
        let actions = spyActions(
            openHotkeys: { didOpenHotkeys = true },
            openNotes: { didOpenNotes = true },
            quit: { didQuit = true }
        )
        HoverSlotRouter.effect(for: .hotkeys).invoke(on: actions)
        HoverSlotRouter.effect(for: .notes).invoke(on: actions)
        HoverSlotRouter.effect(for: .quit).invoke(on: actions)
        XCTAssertTrue(didOpenHotkeys)
        XCTAssertTrue(didOpenNotes)
        XCTAssertTrue(didQuit)
    }

    /// D1 contract lock: the ⌥N hotkey effect for each action/navigate tool must
    /// fire the EXACT `IslandActions` closure that `IslandView.tileView` wires to
    /// that tile's click. The click handlers are:
    ///   .settings  → onOpenSettings     (openSettings)
    ///   .hotkeys   → onOpenHotkeys       (openHotkeys)
    ///   .notes     → onOpenNotes         (openMeetings)
    ///   .quit      → onQuit              (quitApplication)
    /// `.clipboard` is intentionally absent — #313 made it the `.history` inline
    /// panel (driven by panel-mode state, not an `IslandActions` closure), so it
    /// is covered by `test_router_maps_clipboard_slot_to_history_panel` instead.
    /// `.dropMode` is intentionally absent too — both activation paths call
    /// `actions.toggleDropMode()` themselves to consume the returned mode (tile
    /// click in `IslandView`, hotkey in `AppDelegate.onHoverSlotActivated` +
    /// `AppState.publishDropModeHotkeyToggle`), so `invoke` is a no-op for it;
    /// covered by `test_toggle_drop_mode_effect_is_noop_in_invoke`.
    /// If either side drifts, this fails.
    func test_hover_slot_routes_same_action_as_click() {
        let pairs: [(HoverTool, KeyPath<ClickSpy, Bool>)] = [
            (.settings, \.openedSettings),
            (.hotkeys, \.openedHotkeys),
            (.notes, \.openedNotes),
            (.quit, \.quit)
        ]
        for (tool, flagKey) in pairs {
            var spy = ClickSpy()
            let actions = spy.makeActions()
            HoverSlotRouter.effect(for: tool).invoke(on: actions)
            XCTAssertTrue(spy.fired(flagKey), "router effect for \(tool) did not fire the click's closure")
            // Exactly one closure fired — no cross-wiring.
            XCTAssertEqual(spy.firedCount, 1, "router effect for \(tool) fired more than one closure")
        }
    }

    func test_inline_panel_effect_does_not_invoke_any_action_closure() {
        var anyClosureFired = false
        let actions = spyActions(
            toggleDropMode: { anyClosureFired = true },
            openClipboard: { anyClosureFired = true },
            openSettings: { anyClosureFired = true },
            openHotkeys: { anyClosureFired = true },
            openNotes: { anyClosureFired = true },
            quit: { anyClosureFired = true }
        )
        // An inline-panel effect is handled by the view (panel mode), not by an
        // IslandActions closure → invoking on actions must be a no-op.
        HoverSlotEffect.openPanel(.vocabularyEditor).invoke(on: actions)
        XCTAssertFalse(anyClosureFired)
    }

    /// `.toggleDropMode` is handled by `AppDelegate.onHoverSlotActivated`
    /// directly — the returned mode must be published via
    /// `AppState.publishDropModeHotkeyToggle` so `IslandView` can sync its tile
    /// and show the transient ON Smart/Fast right-band status. Routing it
    /// through `invoke` would silently drop that feedback (`invoke` discards
    /// the return value), so `invoke` must be a no-op for it. If this fails,
    /// someone re-wired `.toggleDropMode` through `invoke` — the ⌥N hotkey
    /// would toggle the mode with zero UI feedback again.
    func test_toggle_drop_mode_effect_is_noop_in_invoke() {
        var anyClosureFired = false
        let actions = spyActions(
            toggleDropMode: { anyClosureFired = true },
            openClipboard: { anyClosureFired = true },
            openSettings: { anyClosureFired = true },
            openHotkeys: { anyClosureFired = true },
            openNotes: { anyClosureFired = true },
            quit: { anyClosureFired = true }
        )
        HoverSlotEffect.toggleDropMode.invoke(on: actions)
        XCTAssertFalse(anyClosureFired)
    }

    // MARK: - Positional binding follows layout reorder (D1)

    func test_hover_slot_action_follows_layout_reorder() {
        let store = makeLayoutStore()
        // The active product profile defines the initial tool at position 1.
        XCTAssertEqual(
            HoverSlotRouter.effect(for: store.slots[0]),
            HoverSlotRouter.effect(for: HoverLayoutStore.defaultSlots[0])
        )

        // Swap in a tool NOT already present in the default layout
        // (`.vocab`); `setSlot` rejects duplicates, so a tool already on
        // screen wouldn't move. Position 1 now holds `.vocab`.
        store.setSlot(0, to: .vocab)
        XCTAssertEqual(store.slots[0], .vocab)

        // Activating position 1 now resolves to `.vocab`'s effect, not
        // `.dropMode`'s — the shortcut is bound to the POSITION, not the tool.
        let toolAtPosition1 = store.slots[0]
        XCTAssertEqual(HoverSlotRouter.effect(for: toolAtPosition1), .openPanel(.vocabularyEditor))
    }

    // MARK: - Programmatic expansion respects hover policy (D4)

    func test_programmatic_expansion_respects_hover_policy() {
        // Mirror IslandView.isHoverExpanded composition:
        //   (isHovering || programmaticHoverExpansion) && allowsExpansion
        func isHoverExpanded(programmatic: Bool, isHovering: Bool, allows: Bool) -> Bool {
            (isHovering || programmatic) && allows
        }

        // Policy allows → ⌥N (programmatic, no mouse) expands.
        XCTAssertTrue(
            isHoverExpanded(
                programmatic: true,
                isHovering: false,
                allows: IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: false)
            )
        )
        // Meeting suggestion blocks → ⌥N must NOT force expansion.
        XCTAssertFalse(
            isHoverExpanded(
                programmatic: true,
                isHovering: false,
                allows: IslandHoverPolicy.allowsExpansion(meetingSuggestionActive: true)
            )
        )
        // Agent flow blocks → ⌥N must NOT force expansion.
        XCTAssertFalse(
            isHoverExpanded(
                programmatic: true,
                isHovering: false,
                allows: IslandHoverPolicy.allowsExpansion(
                    meetingSuggestionActive: false,
                    agentFlowActive: true
                )
            )
        )
    }

    func test_appstate_programmatic_expansion_defaults_off() {
        XCTAssertFalse(AppState.shared.programmaticHoverExpansion)
    }

    // MARK: - Carbon hotKeyIDs are a distinct contiguous block

    func test_hover_hotkey_ids_are_distinct_and_after_agent_voice() {
        let ids = [
            CarbonHotkeyMonitor.hoverSlot1HotKeyID,
            CarbonHotkeyMonitor.hoverSlot2HotKeyID,
            CarbonHotkeyMonitor.hoverSlot3HotKeyID,
            CarbonHotkeyMonitor.hoverSlot4HotKeyID,
            CarbonHotkeyMonitor.hoverSlot5HotKeyID
        ]
        // 13..17 — after agentVoiceHotKeyID (12), no collisions.
        XCTAssertEqual(ids, [13, 14, 15, 16, 17])
        XCTAssertEqual(Set(ids).count, 5)
        XCTAssertGreaterThan(ids.min()!, CarbonHotkeyMonitor.agentVoiceHotKeyID)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suiteName = "SidekeyTests.HoverHotkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeLayoutStore() -> HoverLayoutStore {
        let suiteName = "SidekeyTests.HoverHotkey.layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HoverLayoutStore(defaults: defaults)
    }

    /// Records which `IslandActions` closure fired, so the click-parity test can
    /// assert exactly one fired per tool. Backed by a class box because the
    /// closures escape into `IslandActions`.
    private struct ClickSpy {
        private final class Box {
            var toggledDropMode = false
            var openedSettings = false
            var openedHotkeys = false
            var openedNotes = false
            var quit = false
        }
        private let box = Box()

        var toggledDropMode: Bool { box.toggledDropMode }
        var openedSettings: Bool { box.openedSettings }
        var openedHotkeys: Bool { box.openedHotkeys }
        var openedNotes: Bool { box.openedNotes }
        var quit: Bool { box.quit }

        var firedCount: Int {
            [box.toggledDropMode, box.openedSettings,
             box.openedHotkeys, box.openedNotes, box.quit].filter { $0 }.count
        }

        func fired(_ keyPath: KeyPath<ClickSpy, Bool>) -> Bool {
            self[keyPath: keyPath]
        }

        @MainActor
        func makeActions() -> IslandActions {
            var actions = IslandActions.noOp
            actions.toggleDropMode = { [box] in box.toggledDropMode = true; return .fast }
            actions.openSettings = { [box] in box.openedSettings = true }
            actions.openHotkeys = { [box] in box.openedHotkeys = true }
            actions.openMeetings = { [box] in box.openedNotes = true }
            actions.quitApplication = { [box] in box.quit = true }
            return actions
        }
    }

    /// Builds an `IslandActions` whose closures default to no-ops; only the
    /// passed-in spies fire. Keeps the test focused on routing, not on the
    /// dozens of unrelated closures.
    private func spyActions(
        toggleDropMode: @escaping () -> Void = {},
        openClipboard: @escaping () -> Void = {},
        openSettings: @escaping () -> Void = {},
        openHotkeys: @escaping () -> Void = {},
        openNotes: @escaping () -> Void = {},
        quit: @escaping () -> Void = {}
    ) -> IslandActions {
        var actions = IslandActions.noOp
        actions.toggleDropMode = { toggleDropMode(); return .fast }
        actions.openClipboard = openClipboard
        actions.openSettings = openSettings
        actions.openHotkeys = openHotkeys
        actions.openMeetings = openNotes
        actions.quitApplication = quit
        return actions
    }
}

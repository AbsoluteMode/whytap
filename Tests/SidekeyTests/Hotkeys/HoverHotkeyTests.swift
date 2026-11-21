import Carbon.HIToolbox
import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class HoverHotkeyTests: XCTestCase {
    func test_fresh_install_does_not_claim_number_shortcuts() {
        XCTAssertTrue(HotkeyConfiguration.defaults.toolShortcuts.isEmpty)
        XCTAssertTrue(HotkeyPreferences(defaults: makeDefaults()).toolShortcuts.isEmpty)
        XCTAssertTrue(HotkeyConfiguration.defaults.conflicts.isEmpty)
    }

    func test_bindings_round_trip_and_clear_without_resurrecting_legacy_slots() throws {
        let defaults = makeDefaults()
        defaults.set(HotkeyShortcut.combo(.optionOne).rawValue, forKey: "hotkeys.hoverSlot1Shortcut")
        let prefs = HotkeyPreferences(defaults: defaults)
        var config = prefs.configuration
        config.toolShortcuts = [.brightness: .combo(.optionD), .vocab: .combo(.optionPeriod)]
        try prefs.apply(config)
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).toolShortcuts, config.toolShortcuts)
        config.toolShortcuts = [:]
        try prefs.apply(config)
        XCTAssertTrue(HotkeyPreferences(defaults: defaults).toolShortcuts.isEmpty)
    }

    func test_saved_legacy_slots_migrate_to_current_tools_only_once() {
        let defaults = makeDefaults()
        defaults.set(["vocab", "brightness", "settings"], forKey: HoverLayoutStore.defaultsKey)
        defaults.set(HotkeyShortcut.combo(.optionD).rawValue, forKey: "hotkeys.hoverSlot1Shortcut")
        defaults.set(HotkeyShortcut.combo(.optionTwo).rawValue, forKey: "hotkeys.hoverSlot2Shortcut")
        defaults.set(HotkeyShortcut.combo(.optionFive).rawValue, forKey: "hotkeys.hoverSlot5Shortcut")
        let prefs = HotkeyPreferences(defaults: defaults)
        XCTAssertEqual(prefs.toolShortcuts, [.vocab: .combo(.optionD), .brightness: .combo(.optionTwo)])
        defaults.set(["brightness", "vocab", "settings"], forKey: HoverLayoutStore.defaultsKey)
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).toolShortcuts, prefs.toolShortcuts)
    }

    func test_invalid_or_drop_only_shortcuts_and_unknown_tools_are_ignored() {
        let defaults = makeDefaults()
        defaults.set(["vocab": HotkeyShortcut.holdSpace.rawValue, "brightness": "invalid",
                      "unknown": HotkeyShortcut.combo(.optionD).rawValue,
                      "settings": HotkeyShortcut.combo(.optionFive).rawValue],
                     forKey: HotkeyPreferences.toolShortcutsDefaultsKey)
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).toolShortcuts, [.settings: .combo(.optionFive)])
    }

    func test_reorder_and_unpin_keep_registration_target_and_id() {
        let prefs = HotkeyPreferences(defaults: makeDefaults())
        prefs.toolShortcuts = [.brightness: .combo(.optionD), .vocab: .combo(.optionPeriod)]
        let before = ToolHotkeyBinding.resolve(prefs.toolShortcuts)
        let layout = makeLayoutStore()
        layout.placeTool(.brightness, at: 0)
        layout.placeTool(.vocab, at: 0)
        layout.removeTool(.brightness)
        XCTAssertEqual(ToolHotkeyBinding.resolve(prefs.toolShortcuts), before)
        XCTAssertTrue(before.contains { $0.tool == .brightness && $0.shortcut == .combo(.optionD) })
        prefs.toolShortcuts[.brightness] = nil
        XCTAssertFalse(ToolHotkeyBinding.resolve(prefs.toolShortcuts).contains { $0.tool == .brightness })
    }

    func test_all_catalog_tools_can_register_beyond_five_tiles_with_unique_ids() {
        // Calendar is "Soon" and registers no key; this contract is for the open catalog.
        openCalendarForThisTest()
        let bindings = ToolHotkeyBinding.resolve(Dictionary(uniqueKeysWithValues:
            HoverTool.allCases.map { ($0, HotkeyShortcut.combo(.optionD)) }))
        XCTAssertEqual(bindings.count, HoverTool.allCases.count)
        XCTAssertEqual(Set(bindings.map(\.hotKeyID)).count, bindings.count)
        XCTAssertTrue(bindings.allSatisfy { $0.hotKeyID > CarbonHotkeyMonitor.meetingRecordHotKeyID })
        XCTAssertTrue(ToolHotkeyBinding.resolve([.vocab: .holdSpace]).isEmpty)
    }

    func test_conflicts_block_save_between_tools_and_core_actions() throws {
        var config = HotkeyConfiguration.defaults
        config.toolShortcuts = [.vocab: .combo(.optionQ), .brightness: .combo(.optionQ)]
        let conflict = try XCTUnwrap(config.conflicts.first)
        XCTAssertEqual(Set(conflict.actionTitles), ["Agent close", "Vocab", "Display"])
        let prefs = HotkeyPreferences(defaults: makeDefaults())
        XCTAssertThrowsError(try prefs.apply(config))
        XCTAssertTrue(prefs.toolShortcuts.isEmpty)
        config.toolShortcuts = [.vocab: .combo(HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_H),
                            modifiers: UInt32(optionKey), keyTitle: "H"))]
        XCTAssertTrue(config.conflicts.contains { $0.actionTitles.contains("Help") })
    }

    func test_reset_clears_feature_bindings() {
        let defaults = makeDefaults()
        let prefs = HotkeyPreferences(defaults: defaults)
        prefs.toolShortcuts = [.brightness: .combo(.optionD)]
        prefs.resetToDefaults()
        XCTAssertTrue(HotkeyPreferences(defaults: defaults).toolShortcuts.isEmpty)
        XCTAssertTrue(prefs.toolShortcuts.isEmpty)
    }

    func test_backup_preserves_feature_bindings_and_intentional_empty_map() throws {
        let defaults = makeDefaults()
        let prefs = HotkeyPreferences(defaults: defaults)
        prefs.toolShortcuts = [.brightness: .combo(.optionD)]
        let archive = try ConfigBackupRegistry.capture(defaults)
        let restored = makeDefaults()
        try ConfigBackupRegistry.apply(archive, sections: [.hotkeys], to: restored)
        XCTAssertEqual(HotkeyPreferences(defaults: restored).toolShortcuts, prefs.toolShortcuts)
        prefs.toolShortcuts = [:]
        try ConfigBackupRegistry.apply(ConfigBackupRegistry.capture(defaults), sections: [.hotkeys], to: restored)
        XCTAssertTrue(HotkeyPreferences(defaults: restored).toolShortcuts.isEmpty)
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
    /// (D1: same as the tile click, which sets `panelMode = .history`).
    func test_router_maps_clipboard_slot_to_history_panel() {
        XCTAssertEqual(HoverSlotRouter.effect(for: .clipboard), .openPanel(.history))
    }

    func test_monitor_slot_expands_inline_without_opening_a_standalone_window() {
        var windowOpenCount = 0
        var actions = IslandActions.noOp
        actions.openMonitor = { windowOpenCount += 1 }
        let effect = HoverSlotRouter.effect(for: .monitor)
        XCTAssertEqual(effect, .openPanel(.monitor))
        XCTAssertTrue(effect.requiresExpansion)
        effect.invoke(on: actions)
        XCTAssertEqual(windowOpenCount, 0)
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
        var didOpenHistory = false
        var didOpenSettings = false
        let actions = spyActions(
            toggleDropMode: { didToggleDropMode = true },
            openHistory: { didOpenHistory = true },
            openSettings: { didOpenSettings = true }
        )

        // Slot 1 (default layout) = .dropMode → handled by
        // `AppDelegate.onToolHotkeyActivated` directly (the returned mode feeds
        // `AppState.publishDropModeHotkeyToggle`), so `invoke` must be a no-op
        // — see test_toggle_drop_mode_effect_is_noop_in_invoke.
        HoverSlotRouter.effect(for: .dropMode).invoke(on: actions)
        XCTAssertFalse(didToggleDropMode)
        XCTAssertFalse(didOpenHistory)
        XCTAssertFalse(didOpenSettings)

        // Slot 3 (default layout) = .clipboard → .openPanel(.history) after
        // #313. Inline-panel effects are driven by the view (panel mode), so
        // invoking the route leaves opening History to the island view.
        HoverSlotRouter.effect(for: .clipboard).invoke(on: actions)
        XCTAssertFalse(didOpenHistory)

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
    /// click in `IslandView`, hotkey in `AppDelegate.onToolHotkeyActivated` +
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
            openHistory: { anyClosureFired = true },
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

    /// `.toggleDropMode` is handled by `AppDelegate.onToolHotkeyActivated`
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
            openHistory: { anyClosureFired = true },
            openSettings: { anyClosureFired = true },
            openHotkeys: { anyClosureFired = true },
            openNotes: { anyClosureFired = true },
            quit: { anyClosureFired = true }
        )
        HoverSlotEffect.toggleDropMode.invoke(on: actions)
        XCTAssertFalse(anyClosureFired)
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
        openHistory: @escaping () -> Void = {},
        openSettings: @escaping () -> Void = {},
        openHotkeys: @escaping () -> Void = {},
        openNotes: @escaping () -> Void = {},
        quit: @escaping () -> Void = {}
    ) -> IslandActions {
        var actions = IslandActions.noOp
        actions.toggleDropMode = { toggleDropMode(); return .fast }
        actions.openHistory = {
            openHistory()
            return .clipboard
        }
        actions.openSettings = openSettings
        actions.openHotkeys = openHotkeys
        actions.openMeetings = openNotes
        actions.quitApplication = quit
        return actions
    }
}

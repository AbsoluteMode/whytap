import Carbon.HIToolbox
import XCTest
@testable import Sidekey

/// Stage 4 of configurable hotkeys (ROO-234 + ROO-210): the five positional
/// Hover-slot shortcuts become *visible* and *editable*.
///   - a keycap-pair hint (`.keycaps` / `.tiny`) sits above each Hover tile,
///     sourced positionally from the live `HotkeyConfiguration`,
///   - the Help window lists all five,
///   - and the ⌥N gating fix from the Stage 3 review only forces Hover
///     expansion for inline-panel slots (`requiresExpansion`).
///
/// The SwiftUI rendering itself is deferred to the user handoff; these tests
/// pin the *data* the views consume (hint contents per position, Help rows,
/// the expansion-gating composition).
@MainActor
final class HoverHintsTests: XCTestCase {

    // MARK: - Keycap hint contents are sourced positionally from config

    func test_hover_hint_contents_match_config_defaults() {
        // The hint above the tile at position N must render the caps of
        // `configuration.hoverSlotShortcuts[N-1]`. For the default config that
        // is ⌥1..⌥5 (each: [⌥, digit]).
        let config = HotkeyConfiguration.defaults
        let expectedDigits = ["1", "2", "3", "4", "5"]
        for (offset, shortcut) in config.hoverSlotShortcuts.enumerated() {
            XCTAssertEqual(
                shortcut.contents,
                [.text(HotkeyGlyph.option), .text(expectedDigits[offset])],
                "slot \(offset + 1) hint should be ⌥\(expectedDigits[offset])"
            )
        }
    }

    func test_hover_hint_contents_track_changed_config() {
        // Rebinding a slot must change the caps the hint renders — the hint is
        // a pure projection of the live config, so a Save propagates.
        var config = HotkeyConfiguration.defaults
        config.hoverSlot3Shortcut = .combo(.optionD)
        XCTAssertEqual(
            config.hoverSlotShortcuts[2].contents,
            HotkeyShortcut.combo(.optionD).contents
        )
        // The other slots are untouched.
        XCTAssertEqual(
            config.hoverSlotShortcuts[0].contents,
            [.text(HotkeyGlyph.option), .text("1")]
        )
    }

    func test_hover_slot_shortcuts_expose_exactly_five_positions() {
        // The positional family the hint row iterates is always 5 entries, in
        // slot order, so a `HoverLayoutStore` (also 5 slots) maps 1:1.
        XCTAssertEqual(HotkeyConfiguration.defaults.hoverSlotShortcuts.count, 5)
        XCTAssertEqual(HoverLayoutStore.slotCount, 5)
    }

    // MARK: - Help window lists the five hover hotkeys

    func test_help_rows_include_five_hover_hotkeys() {
        let rows = HelpWindowContent.hotkeyRows(for: .defaults)
        for slot in 1...5 {
            XCTAssertTrue(
                rows.contains { $0.title == "Hover slot \(slot)" },
                "Help rows missing 'Hover slot \(slot)'"
            )
        }
    }

    func test_help_rows_hover_contents_match_config() throws {
        // Each hover Help row sources its caps from the matching
        // `configuration.hoverSlotNShortcut`, not a hardcoded glyph — so a
        // rebound shortcut shows through in Help.
        var config = HotkeyConfiguration.defaults
        config.hoverSlot2Shortcut = .combo(.optionD)
        let rows = HelpWindowContent.hotkeyRows(for: config)

        let slot1 = try XCTUnwrap(rows.first { $0.title == "Hover slot 1" })
        XCTAssertEqual(slot1.contents, [.text(HotkeyGlyph.option), .text("1")])

        let slot2 = try XCTUnwrap(rows.first { $0.title == "Hover slot 2" })
        XCTAssertEqual(slot2.contents, HotkeyShortcut.combo(.optionD).contents)
    }

    func test_help_rows_hover_titles_describe_live_layout_tool() throws {
        // D1: the hotkey is positional, so the Help detail names the tool that
        // currently occupies that position in the active product's DEFAULT
        // layout. B2B intentionally has a different safe set from B2C.
        let rows = HelpWindowContent.hotkeyRows(for: .defaults)
        let slot1 = try XCTUnwrap(rows.first { $0.title == "Hover slot 1" })
        let firstDefaultTool = try XCTUnwrap(HoverLayoutStore.defaultSlots.first)
        XCTAssertTrue(
            slot1.detail.contains(HoverToolRegistry.info(for: firstDefaultTool).title),
            "slot 1 detail should name the active product's default tool, got: \(slot1.detail)"
        )
        let slot5 = try XCTUnwrap(rows.first { $0.title == "Hover slot 5" })
        XCTAssertTrue(
            slot5.detail.contains(HoverToolRegistry.info(for: .settings).title),
            "slot 5 detail should name the Settings tool, got: \(slot5.detail)"
        )
    }

    // MARK: - Stage 3 review fix: expansion gating on requiresExpansion (D4)

    func test_action_slot_effect_does_not_request_expansion() {
        // ⌥N on an `.action`/`.navigate` tile must NOT request programmatic
        // expansion (those tiles open their own surfaces instantly). The Stage
        // 3 bug forced expansion for every slot, leaving an empty drawer open
        // ~4s on action tiles. (`.clipboard` is intentionally absent — #313
        // turned it into the History inline panel; see the inline-panel test.)
        for tool in [HoverTool.dropMode, .settings, .hotkeys, .notes, .quit] {
            XCTAssertFalse(
                HoverSlotRouter.effect(for: tool).requiresExpansion,
                "\(tool) is an action/navigate tile — must not require expansion"
            )
        }
    }

    func test_inline_panel_slot_effect_requests_expansion() {
        // ⌥N on an `.inlinePanel` tile DOES request expansion — the sub-panel
        // renders inside the drawer. `.clipboard` joined this set in #313 (it is
        // now the History inline hover panel).
        for tool in [HoverTool.clipboard, .vocab, .caseVault, .filler, .inputLang, .outputLang] {
            XCTAssertTrue(
                HoverSlotRouter.effect(for: tool).requiresExpansion,
                "\(tool) is an inline-panel tile — must require expansion"
            )
        }
    }

    func test_expansion_request_only_set_for_inline_panel_slots() {
        // Mirror the gated `onHoverSlotActivated` contract on the live
        // `AppState`: requesting expansion is conditioned on
        // `effect.requiresExpansion`. We exercise the exact gate the AppDelegate
        // uses so the action path leaves expansion OFF and the inline path
        // turns it ON.
        func simulateActivation(of tool: HoverTool) -> Bool {
            AppState.shared.programmaticHoverExpansion = false
            let effect = HoverSlotRouter.effect(for: tool)
            if effect.requiresExpansion {
                AppState.shared.programmaticHoverExpansion = true
            }
            return AppState.shared.programmaticHoverExpansion
        }

        // Action tile (slot 1 default = .dropMode) → expansion stays OFF.
        XCTAssertFalse(simulateActivation(of: .dropMode))
        // Inline-panel tile (.vocab) → expansion turns ON.
        XCTAssertTrue(simulateActivation(of: .vocab))

        // Reset shared state so other tests aren't polluted.
        AppState.shared.programmaticHoverExpansion = false
    }

    // MARK: - D2: slot 5 key editable, tool fixed to Settings

    func test_slot5_key_is_editable_in_config() {
        // The 5th hover shortcut is a normal editable field (assigning a new
        // combo sticks), independent of the tool lock.
        var config = HotkeyConfiguration.defaults
        config.hoverSlot5Shortcut = .combo(.optionD)
        XCTAssertEqual(config.hoverSlotShortcuts[4], .combo(.optionD))
    }

    func test_slot5_tool_is_locked_to_settings() {
        // D2: position 5 is always `.settings` — `setSlot` refuses to change
        // the lock slot, even when the Toolbox tries. So ⌥5 (whatever its key)
        // always resolves to the Settings effect.
        let store = makeLayoutStore()
        XCTAssertEqual(HoverLayoutStore.lockSlotIndex, 4)
        XCTAssertEqual(store.slots[HoverLayoutStore.lockSlotIndex], .settings)

        store.setSlot(HoverLayoutStore.lockSlotIndex, to: .clipboard)
        XCTAssertEqual(
            store.slots[HoverLayoutStore.lockSlotIndex], .settings,
            "lock slot must stay .settings"
        )
        XCTAssertEqual(
            HoverSlotRouter.effect(for: store.slots[HoverLayoutStore.lockSlotIndex]),
            .openSettings
        )
    }

    // MARK: - Conflict model surfaces for hover rows (Stage 1 reuse)

    func test_hover_slot_conflict_flagged_by_conflict_key() throws {
        // Putting ⌥1 on two hover slots produces a single combo conflict whose
        // members share a `conflictKey` — the exact thing the Settings row
        // highlight matches on.
        var config = HotkeyConfiguration.defaults
        config.hoverSlot2Shortcut = .combo(.optionOne)

        let conflictKey = HotkeyBinding(
            gesture: .tap, key: config.hoverSlot1Shortcut.bindingKey
        ).conflictKey
        XCTAssertTrue(
            config.conflicts.contains { $0.binding.conflictKey == conflictKey },
            "⌥1 collision between slot 1 and slot 2 must be a conflict"
        )
    }

    func test_hover_slot_conflict_with_agent_close_flagged() {
        // ⌥Q collision between a hover slot and Agent close (default ⌥Q) is a
        // conflict — proves the hover bindings are in the same graph as the
        // other actions.
        var config = HotkeyConfiguration.defaults
        config.hoverSlot1Shortcut = .combo(.optionQ)
        let conflictKey = HotkeyBinding(
            gesture: .tap, key: config.agentCloseShortcut.bindingKey
        ).conflictKey
        XCTAssertTrue(
            config.conflicts.contains { $0.binding.conflictKey == conflictKey }
        )
    }

    // MARK: - Helpers

    private func makeLayoutStore() -> HoverLayoutStore {
        let suiteName = "SidekeyTests.HoverHints.layout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return HoverLayoutStore(defaults: defaults)
    }
}

// Tests/SidekeyTests/Settings/HoverLayoutStoreTests.swift
import XCTest
@testable import Sidekey

@MainActor
final class HoverLayoutStoreTests: XCTestCase {

    private func makeStore() -> HoverLayoutStore {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return HoverLayoutStore(defaults: defaults)
    }

    // MARK: - Defaults

    func test_default_layout_includes_monitor() {
        let store = makeStore()
        XCTAssertEqual(store.slots.count, 6)
    }

    func test_default_layout_matches_spec() {
        let store = makeStore()
        XCTAssertEqual(store.slots, [.inputLang, .notes, .meetingRecord, .hotkeys, .monitor, .settings])
    }

    func test_last_slot_is_always_settings() {
        let store = makeStore()
        XCTAssertEqual(store.slots.last, .settings)
    }

    // MARK: - setSlot

    func test_setSlot_replaces_free_slot() {
        let store = makeStore()
        // `.vocab` is not in the default layout, so it is a valid free tool to
        // swap in (`setSlot` rejects tools already on screen as duplicates).
        store.setSlot(0, to: .vocab)
        XCTAssertEqual(store.slots[0], .vocab)
    }

    func test_setSlot_rejects_locked_index() {
        let store = makeStore()
        let original = store.slots
        store.setSlot(store.lockSlotIndex, to: .filler)
        XCTAssertEqual(store.slots, original)
    }

    func test_setSlot_rejects_duplicate_tool() {
        let store = makeStore()
        // .notes is already at index 1
        store.setSlot(0, to: .notes)
        XCTAssertNotEqual(store.slots[0], .notes)
    }

    func test_setSlot_out_of_bounds_is_noop() {
        let store = makeStore()
        let original = store.slots
        store.setSlot(store.slots.count, to: .filler)
        XCTAssertEqual(store.slots, original)
    }

    // MARK: - Persistence

    func test_slots_round_trip_through_userdefaults() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        let store1 = HoverLayoutStore(defaults: defaults)
        store1.setSlot(0, to: .vocab)

        let store2 = HoverLayoutStore(defaults: defaults)
        XCTAssertEqual(store2.slots[0], .vocab)
    }

    // MARK: - Normalization

    func test_normalization_drops_unknown_ids() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Simulate a stored layout that has a stale/renamed tool ID
        defaults.set(["dropMode", "UNKNOWN_ID", "clipboard", "vocab", "settings"],
                     forKey: HoverLayoutStore.defaultsKey)

        let store = HoverLayoutStore(defaults: defaults)
        XCTAssertFalse(store.slots.contains { $0.rawValue == "UNKNOWN_ID" })
        XCTAssertEqual(store.slots, [.dropMode, .clipboard, .vocab, .settings])
    }

    func test_normalization_forces_settings_into_lock_slot() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Stored layout without .settings in slot 4
        defaults.set(["dropMode", "notifs", "clipboard", "vocab", "filler"],
                     forKey: HoverLayoutStore.defaultsKey)

        let store = HoverLayoutStore(defaults: defaults)
        XCTAssertEqual(store.slots.last, .settings)
    }

    func test_normalization_removes_duplicates() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(["dropMode", "dropMode", "clipboard", "vocab", "settings"],
                     forKey: HoverLayoutStore.defaultsKey)

        let store = HoverLayoutStore(defaults: defaults)
        let dropModeCount = store.slots.filter { $0 == .dropMode }.count
        XCTAssertEqual(dropModeCount, 1)
    }

    func test_empty_stored_value_keeps_only_settings() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set([String](), forKey: HoverLayoutStore.defaultsKey)

        let store = HoverLayoutStore(defaults: defaults)
        XCTAssertEqual(store.slots, [.settings])
    }

    func test_adds_more_than_five_tools_and_persists_full_order() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = HoverLayoutStore(defaults: defaults)
        for tool in HoverTool.allCases where tool != .settings {
            store.placeTool(tool, at: store.lockSlotIndex)
        }
        XCTAssertEqual(Set(store.slots), Set(HoverTool.allCases))
        XCTAssertEqual(store.slots.last, .settings)
        XCTAssertEqual(HoverLayoutStore(defaults: defaults).slots, store.slots)
    }

    func test_removing_tools_does_not_pad_and_survives_reload() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let store = HoverLayoutStore(defaults: defaults)
        for tool in store.slots { store.removeTool(tool) }
        XCTAssertEqual(store.slots, [.settings])
        XCTAssertEqual(HoverLayoutStore(defaults: defaults).slots, [.settings])
        XCTAssertTrue(store.placeTool(.clipboard, at: store.lockSlotIndex))
        XCTAssertEqual(store.slots, [.clipboard, .settings])
    }

    func test_dragging_existing_tool_moves_without_duplicate_or_displacement() {
        let store = makeStore()
        XCTAssertTrue(store.placeTool(.meetingRecord, at: 0))
        XCTAssertEqual(store.slots, [.meetingRecord, .inputLang, .notes, .hotkeys, .monitor, .settings])
        XCTAssertTrue(store.placeTool(.meetingRecord, at: store.lockSlotIndex))
        XCTAssertEqual(store.slots, [.inputLang, .notes, .hotkeys, .monitor, .meetingRecord, .settings])
        XCTAssertTrue(store.placeTool(.vocab, at: 1))
        XCTAssertEqual(store.slots, [.inputLang, .vocab, .notes, .hotkeys, .monitor, .meetingRecord, .settings])
    }

    func test_dragging_to_the_next_position_changes_order() {
        let store = makeStore()
        XCTAssertTrue(store.placeTool(.inputLang, at: 1))
        XCTAssertEqual(store.slots, [.notes, .inputLang, .meetingRecord, .hotkeys, .monitor, .settings])
    }

    func test_pinned_settings_cannot_be_moved_removed_or_duplicated() {
        let store = makeStore()
        let original = store.slots
        XCTAssertFalse(store.placeTool(.settings, at: 0))
        XCTAssertFalse(store.placeTool(.vocab, at: -1))
        XCTAssertFalse(store.placeTool(.vocab, at: store.slots.count))
        store.removeTool(.settings)
        store.setSlot(0, to: .settings)
        XCTAssertEqual(store.slots, original)
    }

    func test_replace_keeps_exact_selection_without_padding_or_truncation() {
        let store = makeStore()
        store.replaceEditableSlots(with: [.vocab, .vocab])
        XCTAssertEqual(store.slots, [.vocab, .settings])
        let allTools = HoverTool.allCases.filter { $0 != .settings }
        store.replaceEditableSlots(with: allTools)
        XCTAssertEqual(store.slots, allTools + [.settings])
        store.replaceEditableSlots(with: [])
        XCTAssertEqual(store.slots, [.settings])
    }
    // MARK: - Pin / unpin (island drawer)

    func test_unpin_removes_tool_and_persists_and_neighbours_close_the_gap() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = HoverLayoutStore(defaults: defaults)
        XCTAssertTrue(store.unpin(.meetingRecord))
        XCTAssertEqual(store.slots, [.inputLang, .notes, .hotkeys, .monitor, .settings])
        XCTAssertEqual(HoverLayoutStore(defaults: defaults).slots, store.slots, "Survives a restart")
        XCTAssertFalse(store.unpin(.meetingRecord), "Removing a tool that is not there changes nothing")
    }

    func test_settings_cannot_be_unpinned() {
        let store = makeStore()
        XCTAssertFalse(HoverLayoutStore.canUnpin(.settings))
        XCTAssertFalse(store.unpin(.settings))
        XCTAssertEqual(store.slots.last, .settings)
    }

    func test_pin_appends_before_settings_and_keeps_other_places() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = HoverLayoutStore(defaults: defaults)
        let before = store.slots
        XCTAssertTrue(store.pin(.vocab))
        XCTAssertEqual(store.slots, Array(before.dropLast()) + [.vocab, .settings])
        XCTAssertEqual(HoverLayoutStore(defaults: defaults).slots, store.slots)
        XCTAssertFalse(store.pin(.vocab), "A tool already in the island is not added twice")
        XCTAssertFalse(store.pin(.settings))
    }

    func test_unpinned_tools_are_the_catalog_minus_the_island_in_catalog_order() {
        let store = makeStore()
        XCTAssertEqual(store.unpinnedTools, HoverTool.allCases.filter { !store.slots.contains($0) })
        XCTAssertFalse(store.unpinnedTools.contains(.settings))
        store.unpin(.notes)
        XCTAssertTrue(store.unpinnedTools.contains(.notes))
        store.pin(.notes)
        XCTAssertFalse(store.unpinnedTools.contains(.notes))
    }

    func test_pinning_everything_leaves_nothing_to_add_and_unpinning_everything_leaves_settings() {
        let store = makeStore()
        for tool in store.unpinnedTools { store.pin(tool) }
        XCTAssertTrue(store.unpinnedTools.isEmpty)
        XCTAssertEqual(store.slots.count, HoverTool.allCases.count)
        XCTAssertEqual(store.slots.last, .settings)
        for tool in store.slots { store.unpin(tool) }
        XCTAssertEqual(store.slots, [.settings])
    }
}

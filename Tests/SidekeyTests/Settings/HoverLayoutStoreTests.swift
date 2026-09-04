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

    func test_default_slots_are_five_items() {
        let store = makeStore()
        XCTAssertEqual(store.slots.count, 5)
    }

    func test_default_layout_matches_spec() {
        let store = makeStore()
        XCTAssertEqual(store.slots, [.inputLang, .notes, .meetingRecord, .hotkeys, .settings])
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
        store.setSlot(4, to: .filler)   // index 4 is locked (.settings)
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
        store.setSlot(5, to: .filler)
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
        XCTAssertEqual(store.slots.count, 5)
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

    func test_empty_stored_value_falls_back_to_defaults() {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set([String](), forKey: HoverLayoutStore.defaultsKey)

        let store = HoverLayoutStore(defaults: defaults)
        XCTAssertEqual(store.slots, [.inputLang, .notes, .meetingRecord, .hotkeys, .settings])
    }
}

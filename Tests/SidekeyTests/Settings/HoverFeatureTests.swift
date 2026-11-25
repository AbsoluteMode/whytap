import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Sidekey

/// Settings -> Features -> Hover, as a person uses it: open the list in the
/// island's order, switch off a tool they don't need and back on, move one
/// without a mouse, and keep its shortcut. Every change lands in the one
/// layout the island observes, and survives a restart. Dragging tools happens
/// in the island itself (`IslandHoverReorderTests`).
@MainActor
final class HoverFeatureTests: XCTestCase {
    private func fixture(_ state: FeaturesFixture.State = .usual) async throws -> FeaturesFixture {
        let fixture = try await FeaturesFixture(state)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        return fixture
    }

    /// What the island will show after a restart: a new store on the same defaults.
    private func restored(_ fixture: FeaturesFixture) -> [HoverTool] {
        HoverLayoutStore(defaults: fixture.defaults).slots
    }

    // MARK: - Opening

    func testHoverRowOpensItsOwnScreenAndIsReadyOnAFreshMac() async throws {
        let fixture = try await fixture(.freshInstall)
        let selection = SettingsWindowSelection(selectedTab: .toolbox)
        selection.open(.hover)
        XCTAssertEqual(selection.selectedTab, .features)
        XCTAssertEqual(selection.shownFeature, .hover)
        XCTAssertEqual(FeatureCatalog.status(for: .hover, snapshot: fixture.snapshot), .ready(note: nil),
                       "Hover needs no key, model or permission")
    }

    func testListShowsTheIslandOrderThenEveryOtherTool() async throws {
        let fixture = try await fixture()
        let layout = HoverToolLayout(slots: fixture.hoverStore.slots)
        XCTAssertEqual(layout.inIsland, [.inputLang, .notes, .meetingRecord, .hotkeys, .monitor])
        XCTAssertFalse(layout.offIsland.contains(.settings), "Settings is drawn pinned, not as a tool to switch")
        XCTAssertEqual(Set(layout.inIsland + layout.offIsland), Set(HoverTool.allCases).subtracting([.settings]),
                       "Every tool is on the screen exactly once")
        XCTAssertEqual(layout.offIsland, HoverTool.allCases.filter { !fixture.hoverStore.slots.contains($0) },
                       "Tools that are off keep the catalog order")
    }

    // MARK: - Toggle

    func testSwitchingAToolOffTakesItOutOfTheIslandAndOnPutsItBackBeforeSettings() async throws {
        let fixture = try await fixture()
        let store = fixture.hoverStore
        var layout = HoverToolLayout(slots: store.slots)
        layout.set(.notes, on: false, in: store)
        XCTAssertFalse(store.slots.contains(.notes))
        XCTAssertEqual(restored(fixture), store.slots, "The island reads the same layout after a restart")

        layout = HoverToolLayout(slots: store.slots)
        XCTAssertTrue(layout.offIsland.contains(.notes))
        layout.set(.notes, on: true, in: store)
        XCTAssertEqual(store.slots.suffix(2), [.notes, .settings], "A tool switched on joins the end, Settings stays last")
        XCTAssertEqual(restored(fixture), store.slots)
    }

    func testEveryToolCanBeSwitchedOffAndSettingsStaysAlone() async throws {
        let fixture = try await fixture()
        let store = fixture.hoverStore
        for tool in HoverToolLayout(slots: store.slots).inIsland {
            HoverToolLayout(slots: store.slots).set(tool, on: false, in: store)
        }
        XCTAssertEqual(store.slots, [.settings])
        XCTAssertTrue(HoverToolLayout(slots: store.slots).inIsland.isEmpty)
        XCTAssertEqual(restored(fixture), [.settings])
    }

    func testAToolKeepsItsShortcutWhenItIsSwitchedOff() async throws {
        let fixture = try await fixture()
        let shortcut = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: 0x2D, modifiers: CarbonHotkeyMonitor.optionModifier,
                                                           keyTitle: "N"))
        XCTAssertEqual(fixture.hotkeys.assignToolShortcut(shortcut, to: .notes), .saved)
        HoverToolLayout(slots: fixture.hoverStore.slots).set(.notes, on: false, in: fixture.hoverStore)
        XCTAssertEqual(fixture.hotkeys.toolShortcuts[.notes], shortcut,
                       "Search and the shortcut still reach a tool that is not in the island")
    }

    // MARK: - Keyboard and VoiceOver

    func testMoveUpDownAndToTopWithoutAMouse() async throws {
        let fixture = try await fixture()
        let store = fixture.hoverStore
        var layout = HoverToolLayout(slots: store.slots)
        XCTAssertFalse(layout.canMoveUp(.inputLang))
        XCTAssertFalse(layout.canMoveDown(.monitor))
        XCTAssertFalse(layout.canMoveUp(.vocab), "A tool that is off has no place to move")

        layout.move(.monitor, by: -1, in: store)
        XCTAssertEqual(store.slots, [.inputLang, .notes, .meetingRecord, .monitor, .hotkeys, .settings])
        layout = HoverToolLayout(slots: store.slots)
        layout.move(.notes, by: 1, in: store)
        XCTAssertEqual(store.slots, [.inputLang, .meetingRecord, .notes, .monitor, .hotkeys, .settings])
        layout.move(.hotkeys, by: .min, in: store)
        XCTAssertEqual(store.slots.first, .hotkeys)

        let before = store.slots
        layout = HoverToolLayout(slots: store.slots)
        layout.move(.monitor, by: 5, in: store)
        layout.move(.hotkeys, by: -1, in: store)
        XCTAssertEqual(store.slots, before, "Past either end nothing moves, and Settings stays last")
    }

    // MARK: - Looks

    func testScreenRendersInBothAppearancesWithoutGrowing() async throws {
        let fixture = try await fixture()
        let selection = SettingsWindowSelection()
        selection.open(.hover)
        for dark in [false, true] {
            for width in [960.0, 1280.0] {
                try FeaturesFixture.render(
                    fixture.shell(selection: selection), size: NSSize(width: width, height: 720), dark: dark,
                    to: FeaturesFixture.renderDirectory?.appendingPathComponent(
                        "hover-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
        // Every tool in the island, nothing left in More tools.
        fixture.hoverStore.replaceEditableSlots(with: HoverTool.allCases)
        try FeaturesFixture.render(
            HoverFeatureView(selection: selection, environment: fixture.environment)
                .background(MacSettingsTheme.bgContent),
            size: NSSize(width: 760, height: 1400), dark: false,
            to: FeaturesFixture.renderDirectory?.appendingPathComponent("hover-all-on-light.png"))
    }
}

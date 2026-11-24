import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Sidekey

/// Settings -> Features -> Hover, as a person uses it: open the list, hold a
/// tool and drag it to another place, switch off a tool they don't need and
/// back on, and keep its shortcut. Every change lands in the one layout the
/// island observes, and survives a restart.
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

    func testOnlyAnInternalToolProviderOffersTheReorderType() {
        let type = HoverToolDropDelegate.contentType.identifier
        XCTAssertTrue(HoverToolDropDelegate.provider(for: .monitor).hasItemConformingToTypeIdentifier(type))
        XCTAssertFalse(NSItemProvider(object: "external text" as NSString).hasItemConformingToTypeIdentifier(type))
        XCTAssertFalse(HoverToolDropDelegate.contentType.conforms(to: .text))
    }

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

    // MARK: - Drag

    func testHoldingAToolAndDraggingItUpMovesItLiveAndTheDropKeepsIt() async throws {
        let fixture = try await fixture()
        let drag = HoverToolDragModel(store: fixture.hoverStore)
        drag.begin(.monitor)
        drag.enter(.tool(.notes))
        XCTAssertEqual(fixture.hoverStore.slots, [.inputLang, .monitor, .notes, .meetingRecord, .hotkeys, .settings],
                       "The tool takes the row's place while it is still held")
        drag.enter(.tool(.inputLang))
        XCTAssertEqual(fixture.hoverStore.slots.first, .monitor)
        XCTAssertTrue(drag.drop(on: .tool(.inputLang)))
        XCTAssertNil(drag.dragging)
        XCTAssertEqual(fixture.hoverStore.slots, [.monitor, .inputLang, .notes, .meetingRecord, .hotkeys, .settings])
        XCTAssertEqual(restored(fixture), fixture.hoverStore.slots)
    }

    func testDraggingDownTakesThePlaceOfTheRowItIsOver() async throws {
        let fixture = try await fixture()
        let drag = HoverToolDragModel(store: fixture.hoverStore)
        drag.begin(.inputLang)
        drag.enter(.tool(.meetingRecord))
        XCTAssertTrue(drag.drop(on: .tool(.meetingRecord)))
        XCTAssertEqual(fixture.hoverStore.slots, [.notes, .meetingRecord, .inputLang, .hotkeys, .monitor, .settings])
    }

    /// After a live move the row the tool passed slides under the pointer.
    /// Entering it again must not swap the two back and forth.
    func testARowSlidingUnderThePointerDoesNotFlipTheToolBack() async throws {
        let fixture = try await fixture()
        let drag = HoverToolDragModel(store: fixture.hoverStore)
        drag.begin(.notes)
        drag.enter(.tool(.inputLang))
        let moved = fixture.hoverStore.slots
        XCTAssertEqual(moved.first, .notes)
        drag.enter(.tool(.inputLang))
        drag.enter(.tool(.notes))
        XCTAssertEqual(fixture.hoverStore.slots, moved)
        XCTAssertTrue(drag.drop(on: .tool(.inputLang)))
        XCTAssertEqual(fixture.hoverStore.slots, moved, "The drop keeps what the person saw")
    }

    func testDraggingAToolThatIsOffIntoTheIslandPutsItWhereItIsDropped() async throws {
        let fixture = try await fixture()
        let drag = HoverToolDragModel(store: fixture.hoverStore)
        drag.begin(.vocab)
        drag.enter(.tool(.inputLang))
        XCTAssertFalse(fixture.hoverStore.slots.contains(.vocab), "Passing over rows does not switch it on yet")
        XCTAssertTrue(drag.drop(on: .tool(.notes)))
        XCTAssertEqual(fixture.hoverStore.slots, [.inputLang, .vocab, .notes, .meetingRecord, .hotkeys, .monitor, .settings])
    }

    func testDroppingOnSettingsPutsTheToolLastBeforeSettings() async throws {
        let fixture = try await fixture()
        let drag = HoverToolDragModel(store: fixture.hoverStore)
        drag.begin(.caseVault)
        XCTAssertTrue(drag.drop(on: .end))
        XCTAssertEqual(fixture.hoverStore.slots.suffix(2), [.caseVault, .settings])

        drag.begin(.inputLang)
        drag.enter(.end)
        XCTAssertTrue(drag.drop(on: .end))
        XCTAssertEqual(fixture.hoverStore.slots.suffix(2), [.inputLang, .settings])
    }

    func testDroppingAToolOnMoreToolsTakesItOutOfTheIsland() async throws {
        let fixture = try await fixture()
        let drag = HoverToolDragModel(store: fixture.hoverStore)
        drag.begin(.hotkeys)
        XCTAssertTrue(drag.drop(on: .off))
        XCTAssertFalse(fixture.hoverStore.slots.contains(.hotkeys))

        drag.begin(.vocab)
        XCTAssertFalse(drag.drop(on: .off), "A tool that is already off has nowhere to go")
    }

    func testSettingsCannotBeDraggedAndADropWithoutADragDoesNothing() async throws {
        let fixture = try await fixture()
        let before = fixture.hoverStore.slots
        let drag = HoverToolDragModel(store: fixture.hoverStore)
        drag.begin(.settings)
        XCTAssertNil(drag.dragging)
        drag.enter(.tool(.inputLang))
        XCTAssertFalse(drag.drop(on: .tool(.inputLang)))
        XCTAssertFalse(drag.drop(on: .off))
        XCTAssertEqual(fixture.hoverStore.slots, before)
    }

    func testLeavingTheScreenMidDragForgetsTheDrag() async throws {
        let fixture = try await fixture()
        let drag = HoverToolDragModel(store: fixture.hoverStore)
        drag.begin(.notes)
        drag.end()
        let before = fixture.hoverStore.slots
        drag.enter(.tool(.inputLang))
        XCTAssertFalse(drag.drop(on: .off))
        XCTAssertEqual(fixture.hoverStore.slots, before)
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

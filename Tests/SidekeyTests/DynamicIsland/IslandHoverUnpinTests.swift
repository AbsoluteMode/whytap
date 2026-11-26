import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Removing a tool from the island's drawer and adding one back from More, as
/// a person does it: right-click a tile -> Remove from Hover; open More at the
/// bottom -> click a tool -> it joins the grid before Settings. The drawer must
/// not close because its tools changed (REV 1): it stays until a click outside,
/// or until the pointer comes back and leaves again. Clicks go through the
/// same window-level dispatch as in the app, in an offscreen window.
@MainActor
final class IslandHoverUnpinTests: XCTestCase {
    private let cell = 60.0
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: HoverLayoutStore!
    private var bridge: IslandHoverHitBridge!
    private var window: NSWindow!
    private var host: NSView!
    private var toggled = 0

    override func setUp() async throws {
        suiteName = "IslandHoverUnpinTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: [.inputLang, .notes, .monitor])
        bridge = IslandHoverHitBridge()
        bridge.layoutStore = store
        bridge.setEnabled(true)
        bridge.setSurface(.tile)
        bridge.setContext("grid")
        toggled = 0
        // Row 0 (top): the grid's tiles. Row 1: the footer chevron.
        // Row 2: More rows for two tools that are not in the island.
        let width = cell, bridge = bridge!
        let tiles: [HoverTool] = [.inputLang, .notes, .monitor, .settings]
        let more: [HoverTool] = [.vocab, .filler]
        let view = VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tiles, id: \.self) { tool in
                    Color.clear.frame(width: width, height: 40)
                        .islandHoverHitTarget(bridge: bridge, id: .init(surface: .tile, tool: tool), context: "grid",
                                              action: {})
                }
            }
            .islandHoverHitRegion(bridge: bridge, surface: .tile)
            HStack(spacing: 0) {
                Color.clear.frame(width: width, height: 40)
                    .islandHoverHitTarget(bridge: bridge, id: .moreToolsToggle, context: "grid",
                                          action: { [unowned self] in toggled += 1 })
                Spacer(minLength: 0)
            }
            .frame(width: width * 4)
            .islandHoverHitRegion(bridge: bridge, surface: .moreToggle)
            HStack(spacing: 0) {
                ForEach(more, id: \.self) { tool in
                    Color.clear.frame(width: width, height: 40)
                        .islandHoverHitTarget(bridge: bridge, id: .init(surface: .moreTools, tool: tool), context: "grid",
                                              action: { bridge.pin(tool) })
                }
                Spacer(minLength: 0)
            }
            .frame(width: width * 4)
            .islandHoverHitRegion(bridge: bridge, surface: .moreTools)
        }
        let hosting = NSHostingView(rootView: view)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: cell * 4, height: 120),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: cell * 4, height: 120)
        for _ in 0..<3 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        host = hosting
    }

    override func tearDown() async throws {
        window.close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Centre of column `column` in row `row` (0 = top), window coordinates.
    private func point(row: Int, column: Int) -> CGPoint {
        host.convert(NSPoint(x: cell * (Double(column) + 0.5), y: 20 + 40 * Double(row)), to: nil)
    }

    private func click(_ point: CGPoint) {
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true), "The click lands on a control")
        bridge.mouseUp(at: point, in: window, allowed: true)
    }

    // MARK: - Close decision (REV 1)

    /// The drawer's decision after a change, from the island's own gate.
    private func drawerStaysOpen(_ hold: IslandHoverEditHold, pointerInside: Bool) -> Bool {
        IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: pointerInside, wasExpanded: true,
                                    glance: false, interactionHeld: hold.holdsDrawer)
    }

    func testAfterAnEditLeavingWithoutComingBackDoesNotCloseTheDrawer() {
        var hold = IslandHoverEditHold()
        hold.edited()
        // The tile vanished and the drawer shrank: the pointer is now outside.
        hold.pointer(inside: false)
        XCTAssertTrue(drawerStaysOpen(hold, pointerInside: false))
        hold.pointer(inside: false)
        XCTAssertTrue(drawerStaysOpen(hold, pointerInside: false), "Repeated leave signals never release it")
    }

    func testAfterAnEditAClickOutsideClosesTheDrawer() {
        var hold = IslandHoverEditHold()
        hold.edited()
        hold.pointer(inside: false)
        hold.release()
        XCTAssertFalse(drawerStaysOpen(hold, pointerInside: false))
    }

    func testAfterAnEditComingBackAndLeavingClosesTheDrawer() {
        var hold = IslandHoverEditHold()
        hold.edited()
        hold.pointer(inside: true)
        XCTAssertEqual(hold.phase, .reentered)
        XCTAssertTrue(drawerStaysOpen(hold, pointerInside: true))
        hold.pointer(inside: false)
        XCTAssertEqual(hold.phase, .free)
        XCTAssertFalse(drawerStaysOpen(hold, pointerInside: false), "The normal hover exit applies again")
    }

    func testWithoutAnEditTheNormalHoverExitApplies() {
        var hold = IslandHoverEditHold()
        hold.pointer(inside: true)
        hold.pointer(inside: false)
        XCTAssertFalse(drawerStaysOpen(hold, pointerInside: false))
    }

    func testASecondEditAfterComingBackHoldsAgain() {
        var hold = IslandHoverEditHold()
        hold.edited()
        hold.pointer(inside: true)
        hold.edited()
        hold.pointer(inside: false)
        XCTAssertTrue(drawerStaysOpen(hold, pointerInside: false))
    }

    // MARK: - Remove from Hover

    func testRightClickOnATileOffersRemoveAndSettingsStays() {
        let notes = bridge.contextMenuTarget(at: point(row: 0, column: 1), in: window, allowed: true)
        XCTAssertEqual(notes, IslandHoverHitTargetID(surface: .tile, tool: .notes))
        XCTAssertEqual(notes.map { IslandHoverToolMenu.items(for: $0, slots: store.slots) }, [.remove(.notes)])

        let settings = bridge.contextMenuTarget(at: point(row: 0, column: 3), in: window, allowed: true)
        let items = settings.map { IslandHoverToolMenu.items(for: $0, slots: store.slots) } ?? []
        XCTAssertEqual(items, [.settingsStays])
        XCTAssertFalse(items[0].isEnabled, "Settings is the way back to every tool")

        XCTAssertNil(bridge.contextMenuTarget(at: point(row: 1, column: 0), in: window, allowed: true),
                     "The chevron has no tool menu")
        XCTAssertNil(bridge.contextMenuTarget(at: point(row: 0, column: 1), in: window, allowed: false),
                     "No menu while hover clicks are not allowed")
    }

    func testRemoveFromHoverTakesTheToolOutHoldsTheDrawerAndKeepsTheOthers() {
        let menu = IslandHoverToolMenu.menu(for: [.remove(.notes)], bridge: bridge)
        bridge.toolMenuWillOpen()
        XCTAssertTrue(bridge.holdsDrawer, "The open menu holds the drawer")
        menu.performActionForItem(at: 0)
        bridge.toolMenuDidClose()
        XCTAssertEqual(store.slots, [.inputLang, .monitor, .settings])
        XCTAssertEqual(HoverLayoutStore(defaults: defaults).slots, store.slots, "Saved like Settings -> Hover")
        XCTAssertTrue(bridge.holdsDrawer, "The pointer may now be outside the smaller drawer")
        XCTAssertTrue(store.unpinnedTools.contains(.notes), "It is in More now")

        bridge.notePointer(inside: false)
        XCTAssertTrue(bridge.holdsDrawer)
        bridge.noteOutsideClick()
        XCTAssertFalse(bridge.holdsDrawer)
    }

    func testAMenuClosedWithoutChoosingStillHoldsUntilThePointerReturns() {
        bridge.toolMenuWillOpen()
        bridge.noteOutsideClick()
        XCTAssertTrue(bridge.holdsDrawer, "A click inside the menu is not a click outside the drawer")
        bridge.toolMenuDidClose()
        XCTAssertEqual(store.slots, [.inputLang, .notes, .monitor, .settings])
        bridge.notePointer(inside: true)
        XCTAssertTrue(bridge.holdsDrawer)
        bridge.notePointer(inside: false)
        XCTAssertFalse(bridge.holdsDrawer)
    }

    func testClosingTheDrawerEndsTheHold() {
        XCTAssertTrue(bridge.unpin(.notes))
        XCTAssertTrue(bridge.holdsDrawer)
        bridge.setEnabled(false)
        XCTAssertFalse(bridge.holdsDrawer, "Nothing stays held for the next hover")
    }

    func testSettingsAndAMissingToolCannotBeRemoved() {
        XCTAssertFalse(bridge.unpin(.settings))
        XCTAssertFalse(bridge.unpin(.vocab))
        XCTAssertFalse(bridge.holdsDrawer, "Nothing changed, nothing to hold")
        XCTAssertEqual(store.slots, [.inputLang, .notes, .monitor, .settings])
    }

    func testRemovingTheLiftedToolsOrderIsRefusedDuringADrag() {
        XCTAssertTrue(bridge.mouseDown(at: point(row: 0, column: 0), in: window, allowed: true))
        bridge.mouseDragged(at: point(row: 0, column: 1), in: window, allowed: true)
        XCTAssertTrue(bridge.isReordering)
        XCTAssertNil(bridge.contextMenuTarget(at: point(row: 0, column: 2), in: window, allowed: true))
        XCTAssertFalse(bridge.unpin(.monitor))
        bridge.mouseUp(at: point(row: 0, column: 1), in: window, allowed: true)
    }

    // MARK: - More

    func testTheChevronAndMoreRowsTakeClicksTogetherWithTheGrid() {
        click(point(row: 1, column: 0))
        XCTAssertEqual(toggled, 1)
        bridge.setSurface(.result)
        XCTAssertFalse(bridge.mouseDown(at: point(row: 1, column: 0), in: window, allowed: true),
                       "While search results show, the grid's companions are not clickable")
        XCTAssertTrue(IslandHoverHitBridge.isCompanion(.moreTools, of: .tile))
        XCTAssertFalse(IslandHoverHitBridge.isCompanion(.moreTools, of: .navigation))
    }

    func testClickingAMoreRowAddsItBeforeSettingsAndHoldsTheDrawer() {
        click(point(row: 2, column: 0))
        XCTAssertEqual(store.slots, [.inputLang, .notes, .monitor, .vocab, .settings])
        XCTAssertFalse(store.unpinnedTools.contains(.vocab), "It leaves More at once")
        XCTAssertEqual(HoverLayoutStore(defaults: defaults).slots, store.slots)
        XCTAssertTrue(bridge.holdsDrawer, "The grid and the section changed size under the pointer")
    }

    func testRightClickOnAMoreRowOffersAdd() {
        let target = bridge.contextMenuTarget(at: point(row: 2, column: 1), in: window, allowed: true)
        XCTAssertEqual(target.map { IslandHoverToolMenu.items(for: $0, slots: store.slots) }, [.add(.filler)])
        XCTAssertTrue(IslandHoverToolMenu.perform(.add(.filler), bridge: bridge))
        XCTAssertEqual(store.slots.suffix(2), [.filler, .settings])
    }

    func testTheSectionGrowsTheHoverBandAndStopsAtThreeVisibleRows() {
        let collapsed = IslandDropModeControl.controlsHoverPanelHeight(toolCount: 6)
        XCTAssertEqual(IslandDropModeControl.controlsHoverPanelHeight(toolCount: 6, moreTools: nil), collapsed)
        XCTAssertEqual(IslandDropModeControl.controlsHoverPanelHeight(toolCount: 6, moreTools: 3) - collapsed,
                       1 + 30 + 16, accuracy: 0.001, "One row of three")
        XCTAssertEqual(IslandHoverMoreToolsLayout.listHeight(toolCount: 9), 3 * 30 + 2 * 6 + 16, accuracy: 0.001)
        XCTAssertEqual(IslandHoverMoreToolsLayout.listHeight(toolCount: 14),
                       IslandHoverMoreToolsLayout.listHeight(toolCount: 9), accuracy: 0.001)
        XCTAssertTrue(IslandHoverMoreToolsLayout.requiresScrolling(toolCount: 10))
        XCTAssertFalse(IslandHoverMoreToolsLayout.requiresScrolling(toolCount: 9))
        XCTAssertEqual(IslandHoverMoreToolsLayout.listHeight(toolCount: 0), IslandHoverMoreToolsLayout.emptyHeight,
                       "After the last tool was added the section says every tool is in Hover")
        XCTAssertEqual(IslandView.hoverPanelHeight(for: .controls, musicActive: false, toolCount: 6, moreTools: 3),
                       IslandDropModeControl.controlsHoverPanelHeight(toolCount: 6, moreTools: 3), accuracy: 0.001)
        XCTAssertEqual(IslandView.hoverPanelHeight(for: .monitor, musicActive: false, toolCount: 6, moreTools: 3),
                       collapsed, accuracy: 0.001, "Other panels never include the section")
    }

    // MARK: - Shortcuts and search

    func testARemovedToolKeepsItsShortcutAndSearchStillFindsIt() async throws {
        let fixture = try await FeaturesFixture(.usual)
        addTeardownBlock { await MainActor.run { fixture.cleanUp() } }
        let shortcut = HotkeyShortcut.combo(HotkeyTapCombo(keyCode: 0x2D, modifiers: CarbonHotkeyMonitor.optionModifier,
                                                           keyTitle: "N"))
        XCTAssertEqual(fixture.hotkeys.assignToolShortcut(shortcut, to: .notes), .saved)
        let bridge = IslandHoverHitBridge()
        bridge.layoutStore = fixture.hoverStore
        let others = fixture.hoverStore.slots.filter { $0 != .notes }
        XCTAssertTrue(bridge.unpin(.notes))
        XCTAssertEqual(fixture.hoverStore.slots, others, "The others keep their order; no position shifts a binding")
        XCTAssertEqual(fixture.hotkeys.toolShortcuts[.notes], shortcut, "Shortcuts belong to tools, not places")
        XCTAssertEqual(HoverSlotRouter.effect(for: .notes), .openNotes)
        XCTAssertTrue(IslandHoverToolSearch.results(for: "notes").contains(.notes))
        XCTAssertTrue(HoverToolLayout(slots: fixture.hoverStore.slots).offIsland.contains(.notes),
                      "Settings -> Features -> Hover shows it as off")
    }
}

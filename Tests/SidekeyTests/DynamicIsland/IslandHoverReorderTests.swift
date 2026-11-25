import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Reordering the island's tools in the hover drawer, as a person does it:
/// a click still opens a tool; holding a tile lifts it, moving the pointer
/// over another tile puts it there at once, letting go keeps the order the
/// island shows (and Settings -> Features -> Hover shows the same order);
/// Letting go far outside the tools puts everything back. Events go through the same window-level
/// dispatch as in the app, against an offscreen window that is never shown.
@MainActor
final class IslandHoverReorderTests: XCTestCase {
    private let tools: [HoverTool] = [.inputLang, .notes, .monitor, .settings]
    private let cell = 60.0
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: HoverLayoutStore!
    private var bridge: IslandHoverHitBridge!
    private var window: NSWindow!
    private var host: NSView!
    private var activated: [HoverTool] = []

    override func setUp() async throws {
        suiteName = "IslandHoverReorderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: tools)
        bridge = IslandHoverHitBridge()
        bridge.layoutStore = store
        bridge.setEnabled(true)
        bridge.setSurface(.tile)
        bridge.setContext("grid")
        activated = []
        // One row of tiles, in the order the island had when it was drawn.
        let width = cell, bridge = bridge!
        let row = HStack(spacing: 0) {
            ForEach(tools, id: \.self) { tool in
                Color.clear.frame(width: width, height: 44)
                    .islandHoverHitTarget(bridge: bridge, id: .init(surface: .tile, tool: tool), context: "grid",
                                          action: { [unowned self] in activated.append(tool) })
            }
        }
        .islandHoverHitRegion(bridge: bridge, surface: .tile)
        let hosting = NSHostingView(rootView: row)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: cell * 4, height: 44),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: cell * 4, height: 44)
        for _ in 0..<3 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        host = hosting
    }

    override func tearDown() async throws {
        window.close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The centre of the tile that was drawn in `slot` (window coordinates).
    private func point(_ slot: Int) -> CGPoint {
        host.convert(NSPoint(x: cell * (Double(slot) + 0.5), y: 22), to: nil)
    }

    private func down(_ slot: Int) -> Bool { bridge.mouseDown(at: point(slot), in: window, allowed: true) }
    private func drag(to point: CGPoint) { bridge.mouseDragged(at: point, in: window, allowed: true) }
    private func up(at point: CGPoint) { bridge.mouseUp(at: point, in: window, allowed: true) }
    private func restored() -> [HoverTool] { HoverLayoutStore(defaults: defaults).slots }

    // MARK: - A click stays a click

    func testAShortClickOpensTheToolAndMovesNothing() {
        XCTAssertTrue(down(1))
        up(at: point(1))
        XCTAssertEqual(activated, [.notes])
        XCTAssertFalse(bridge.isReordering)
        XCTAssertEqual(store.slots, tools)
    }

    func testAPressReleasedBeforeTheHoldDelayNeverLifts() async throws {
        bridge.reorderHoldDelay = .milliseconds(40)
        XCTAssertTrue(down(0))
        up(at: point(0))
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(bridge.isReordering, "The hold timer ends with the press")
        XCTAssertEqual(activated, [.inputLang])
    }

    func testMovingOffTheTileBeforeTheHoldCancelsTheClickAndTheLift() {
        XCTAssertTrue(down(0))
        drag(to: point(2))
        XCTAssertFalse(bridge.liftPressedTool())
        up(at: point(2))
        XCTAssertEqual(activated, [])
        XCTAssertEqual(store.slots, tools)
    }

    // MARK: - Hold, drag, let go

    func testHoldingATileLiftsItAfterTheDelay() async throws {
        bridge.reorderHoldDelay = .milliseconds(40)
        XCTAssertTrue(down(0))
        XCTAssertEqual(bridge.pressedID?.tool, .inputLang)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(bridge.reorderingTool, .inputLang)
        XCTAssertNil(bridge.pressedID, "A lifted tile is no longer a pressed button")
        XCTAssertTrue(bridge.consumesPointerSequence, "The window keeps the drag and the mouse-up")
        up(at: point(0))
        XCTAssertEqual(activated, [], "Letting go of a lifted tool never opens it")
    }

    func testDraggingALiftedToolMovesItLiveAndLettingGoKeepsTheOrder() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(1))
        XCTAssertEqual(store.slots, [.notes, .inputLang, .monitor, .settings], "It takes the place at once")
        drag(to: point(2))
        XCTAssertEqual(store.slots, [.notes, .monitor, .inputLang, .settings])
        // The pointer stays over the same cell while tiles settle: no flip back.
        drag(to: point(2))
        drag(to: CGPoint(x: point(2).x + 10, y: point(2).y))
        XCTAssertEqual(store.slots, [.notes, .monitor, .inputLang, .settings])
        up(at: point(2))
        XCTAssertFalse(bridge.isReordering)
        XCTAssertFalse(bridge.consumesPointerSequence)
        XCTAssertEqual(activated, [])
        XCTAssertEqual(restored(), store.slots, "The island and Settings read the same saved order after a restart")
        XCTAssertEqual(HoverToolLayout(slots: store.slots).inIsland, [.notes, .monitor, .inputLang],
                       "Settings -> Features -> Hover lists the new order")
    }

    func testDraggingBackwardsAndOntoSettingsPutsTheToolLastBeforeSettings() {
        XCTAssertTrue(down(2))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(0))
        XCTAssertEqual(store.slots, [.monitor, .inputLang, .notes, .settings])
        drag(to: point(3))
        XCTAssertEqual(store.slots, [.inputLang, .notes, .monitor, .settings], "Settings stays last")
        up(at: point(3))
        XCTAssertEqual(store.slots.last, .settings)
        XCTAssertEqual(activated, [], "Dropping on Settings does not open Settings")
    }

    func testPassingOutsideTheGridKeepsTheLastPlaceAndAReleaseNearTheEdgeKeepsIt() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(1))
        drag(to: CGPoint(x: point(1).x, y: point(1).y + 200))
        XCTAssertEqual(store.slots, [.notes, .inputLang, .monitor, .settings], "Outside the grid nothing moves")
        drag(to: point(1))
        // Just past the tiles' edge, as a hand overshoots: still a drop.
        let nearEdge = CGPoint(x: point(1).x, y: point(1).y + 22 + IslandHoverReorder.releaseMargin / 2)
        up(at: nearEdge)
        XCTAssertFalse(bridge.isReordering)
        XCTAssertEqual(restored(), [.notes, .inputLang, .monitor, .settings])
    }

    // MARK: - Ways out

    /// The island is not key while the tools are shown, so a key cannot reach
    /// it without taking focus from the person's app. Letting go well outside
    /// the tools is the cancel, through the same window events as a drop.
    func testReleasingFarOutsideTheToolsPutsEveryToolBack() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(2))
        XCTAssertEqual(store.slots, [.notes, .monitor, .inputLang, .settings])
        up(at: CGPoint(x: point(2).x, y: point(2).y + 200))
        XCTAssertEqual(store.slots, tools)
        XCTAssertEqual(restored(), tools)
        XCTAssertFalse(bridge.isReordering)
        XCTAssertFalse(bridge.consumesPointerSequence)
        XCTAssertEqual(activated, [])
    }

    /// Escape reaches the island only when it already has keyboard focus
    /// (IslandPanel.sendEvent); the cancel it calls restores the order.
    func testCancelPutsEveryToolBack() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(2))
        bridge.cancelReorder()
        XCTAssertEqual(store.slots, tools)
        XCTAssertEqual(restored(), tools)
        XCTAssertFalse(bridge.isReordering)
        XCTAssertFalse(bridge.consumesPointerSequence)
    }

    // MARK: - The layout changes from elsewhere mid-drag (Settings Sync)

    /// Another Mac's layout arriving through Settings Sync: written to the
    /// defaults, then the store reloads, as the sync route does.
    private func syncArrives(_ slots: [HoverTool]) {
        defaults.set(slots.map(\.rawValue), forKey: HoverLayoutStore.defaultsKey)
        store.reloadFromDefaults()
    }

    func testSyncRemovingTheLiftedToolEndsTheDragAndNeverBringsItBack() {
        XCTAssertTrue(down(1))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(0))
        syncArrives([.inputLang, .monitor, .settings])
        XCTAssertFalse(bridge.isReordering, "The lift no longer describes the island")
        drag(to: point(2))
        up(at: point(2))
        XCTAssertEqual(store.slots, [.inputLang, .monitor, .settings])
        XCTAssertEqual(restored(), [.inputLang, .monitor, .settings], "A removed tool is not switched back on")
        XCTAssertEqual(activated, [], "The ended press still opens nothing")
    }

    func testSyncAddingOrRemovingAnotherToolIsKeptWhenTheDragIsCancelled() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(1))
        syncArrives([.vocab, .notes, .inputLang, .settings])
        XCTAssertFalse(bridge.isReordering)
        up(at: CGPoint(x: point(1).x, y: point(1).y + 200))
        bridge.cancelReorder()
        XCTAssertEqual(store.slots, [.vocab, .notes, .inputLang, .settings])
        XCTAssertEqual(restored(), [.vocab, .notes, .inputLang, .settings],
                       "Vocab stays on and Monitor stays off, as the sync left them")
    }

    func testAStaleLiftNeverRestoresAnOldMembership() {
        let reorder = IslandHoverReorder(tool: .notes, original: tools, cells: [:])
        XCTAssertEqual(reorder.restoredOrder(current: [.notes, .inputLang, .monitor, .settings]), tools)
        XCTAssertNil(reorder.restoredOrder(current: [.inputLang, .monitor, .settings]))
        XCTAssertNil(reorder.restoredOrder(current: tools + [.vocab]))
        XCTAssertFalse(reorder.cancelsRelease(at: .zero), "Without measured cells a release is never a cancel")
    }

    func testTheDrawerClosingOrTheIslandHidingEndsTheDragWithTheOrderSoFar() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(1))
        bridge.setEnabled(false)
        XCTAssertFalse(bridge.isReordering)
        XCTAssertEqual(store.slots, [.notes, .inputLang, .monitor, .settings])

        bridge.setEnabled(true)
        XCTAssertTrue(down(2))
        XCTAssertTrue(bridge.liftPressedTool())
        bridge.discardSequence()
        XCTAssertFalse(bridge.isReordering)
        drag(to: point(0))
        XCTAssertEqual(store.slots, [.notes, .inputLang, .monitor, .settings], "A forgotten drag moves nothing")
    }

    func testTheNextPressAfterAReorderIsAClickAgain() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(1))
        up(at: point(1))
        // The tile drawn in slot 2 still reports Monitor in this static grid.
        XCTAssertTrue(down(2))
        up(at: point(2))
        XCTAssertEqual(activated, [.monitor])
    }

    // MARK: - What cannot move

    func testSettingsCannotBeLiftedAndStillOpensOnClick() {
        XCTAssertTrue(down(3))
        XCTAssertFalse(bridge.liftPressedTool())
        up(at: point(3))
        XCTAssertEqual(activated, [.settings])
        XCTAssertEqual(store.slots, tools)
    }

    func testOnlyToolsInTheIslandThatWorkCanBeLifted() {
        XCTAssertFalse(IslandHoverReorder.canLift(nil, slots: tools))
        XCTAssertFalse(IslandHoverReorder.canLift(.settings, slots: tools))
        XCTAssertFalse(IslandHoverReorder.canLift(.vocab, slots: tools), "Not in the island")
        XCTAssertTrue(IslandHoverReorder.canLift(.notes, slots: tools))
        for tool in HoverTool.allCases where tool.isComingSoon {
            XCTAssertFalse(IslandHoverReorder.canLift(tool, slots: tools + [tool]))
        }
    }

    func testTheCellUnderThePointerIsTheTarget() {
        let reorder = IslandHoverReorder(tool: .notes, original: tools, cells: [
            0: CGRect(x: 0, y: 0, width: 60, height: 44),
            1: CGRect(x: 60, y: 0, width: 60, height: 44),
            3: CGRect(x: 0, y: 50, width: 60, height: 44),
        ])
        XCTAssertEqual(reorder.slot(at: CGPoint(x: 10, y: 10)), 0)
        XCTAssertEqual(reorder.slot(at: CGPoint(x: 70, y: 10)), 1)
        XCTAssertEqual(reorder.slot(at: CGPoint(x: 10, y: 60)), 3)
        XCTAssertNil(reorder.slot(at: CGPoint(x: 200, y: 10)), "Outside the grid nothing moves")
    }

    func testALiftedToolHoldsTheDrawerOpenWithoutThePointer() {
        XCTAssertTrue(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false, wasExpanded: true,
                                                  glance: false, interactionHeld: true),
                      "The drawer stays while a tool is lifted, even outside the island")
        XCTAssertFalse(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false, wasExpanded: true,
                                                   glance: false, interactionHeld: false))
    }
}

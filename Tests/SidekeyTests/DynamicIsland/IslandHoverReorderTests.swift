import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Sidekey

/// Reordering the island's tools in the hover drawer, as a person does it:
/// a click still opens a tool; pressing a tile and moving it a few points
/// lifts it at once, moving the pointer over another tile puts it there, letting go keeps the order the
/// island shows (and Settings -> Features -> Hover shows the same order);
/// letting go outside the hover throws the tool out of it, and Escape puts
/// everything back. Events go through
/// the same window-level dispatch as in the app, against an offscreen window that is never shown.
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
        bridge.dragEffects = .silent
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

    func testASmallJitterIsStillAClick() {
        XCTAssertTrue(down(1))
        drag(to: CGPoint(x: point(1).x + 2, y: point(1).y + 1))
        XCTAssertFalse(bridge.isReordering, "Under the drag threshold the press stays a click")
        up(at: CGPoint(x: point(1).x + 2, y: point(1).y + 1))
        XCTAssertEqual(activated, [.notes])
        XCTAssertEqual(store.slots, tools)
    }

    /// REV 3: no waiting. Pressing and moving is the intent to drag.
    func testMovingPastTheThresholdLiftsAtOnceWithoutWaiting() {
        XCTAssertTrue(down(0))
        XCTAssertEqual(bridge.pressedID?.tool, .inputLang)
        let nudged = CGPoint(x: point(0).x + IslandHoverHitBridge.dragThreshold, y: point(0).y)
        drag(to: nudged)
        XCTAssertEqual(bridge.reorderingTool, .inputLang, "Lifted on the first move past the threshold")
        XCTAssertNil(bridge.pressedID, "A lifted tile is no longer a pressed button")
        XCTAssertTrue(bridge.consumesPointerSequence, "The window keeps the drag and the mouse-up")
        XCTAssertEqual(bridge.motion.translation, CGSize(width: IslandHoverHitBridge.dragThreshold, height: 0),
                       "The tile keeps its offset from the pointer where the button went down")
        up(at: nudged)
        XCTAssertEqual(activated, [], "Letting go of a dragged tool never opens it")
        XCTAssertEqual(store.slots, tools, "Dropped back in its own cell")
    }

    func testAFastFlickStraightOntoAnotherTileLiftsAndMovesIt() {
        XCTAssertTrue(down(0))
        drag(to: point(2))
        XCTAssertEqual(bridge.reorderingTool, .inputLang, "Leaving the tile in one move still drags it")
        XCTAssertEqual(store.slots, [.notes, .monitor, .inputLang, .settings])
        up(at: point(2))
        XCTAssertEqual(activated, [])
        XCTAssertEqual(restored(), [.notes, .monitor, .inputLang, .settings])
    }

    func testHoldingStillNeverLiftsAndReleasingOpensTheTool() {
        XCTAssertTrue(down(0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        XCTAssertFalse(bridge.isReordering, "There is no timer: only movement starts a drag")
        up(at: point(0))
        XCTAssertEqual(activated, [.inputLang])
    }

    func testSettingsDoesNotDragAndAPressThatLeavesItOpensNothing() {
        XCTAssertTrue(down(3))
        drag(to: CGPoint(x: point(3).x + 10, y: point(3).y))
        XCTAssertFalse(bridge.isReordering)
        drag(to: point(1))
        up(at: point(1))
        XCTAssertEqual(activated, [], "Leaving the pressed tile cancels its click, as before")
        XCTAssertEqual(store.slots, tools)
    }

    // MARK: - Drag, let go

    func testDraggingALiftedToolMovesItLiveAndLettingGoKeepsTheOrder() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(1))
        XCTAssertEqual(store.slots, [.notes, .inputLang, .monitor, .settings], "It takes the place at once")
        XCTAssertEqual(restored(), tools, "Nothing is written while the tool is still held")
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

    /// REV 4: throwing a tool out of the hover removes it. Outside, the tile
    /// says so before the release; dropping it back inside keeps it.
    func testThrowingAToolOutOfTheHoverRemovesItAndKeepsTheOrderReached() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: point(2))
        XCTAssertEqual(store.slots, [.notes, .monitor, .inputLang, .settings])
        let outside = CGPoint(x: point(2).x, y: point(2).y + 200)
        drag(to: outside)
        XCTAssertTrue(bridge.motion.outside, "The tile shows it will be removed")
        XCTAssertEqual(store.slots, [.notes, .monitor, .inputLang, .settings], "Outside, nothing moves")
        up(at: outside)
        XCTAssertEqual(store.slots, [.notes, .monitor, .settings])
        XCTAssertEqual(restored(), [.notes, .monitor, .settings], "Saved like Settings -> Hover")
        XCTAssertFalse(bridge.isReordering)
        XCTAssertFalse(bridge.consumesPointerSequence)
        XCTAssertFalse(bridge.motion.outside)
        XCTAssertEqual(bridge.reorderPhase.state, .removed, "The picture puffs away where it was let go")
        XCTAssertEqual(bridge.editHold.phase, .away, "The drawer stays until a click outside or a return")
        XCTAssertTrue(bridge.holdsDrawer)
        XCTAssertEqual(activated, [])
    }

    func testComingBackInsideBeforeLettingGoKeepsTheTool() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: CGPoint(x: point(1).x, y: point(1).y + 200))
        XCTAssertTrue(bridge.motion.outside)
        drag(to: point(1))
        XCTAssertFalse(bridge.motion.outside, "Back inside, the remove hint goes")
        up(at: point(1))
        XCTAssertEqual(store.slots, [.notes, .inputLang, .monitor, .settings])
        XCTAssertEqual(bridge.editHold.phase, .free, "A reorder is not an edit that holds the drawer")
    }

    // MARK: - REV 5: the whole tile leaves the hover

    /// A 60 x 44 tile pressed at its centre (30, 22), in a drawer from
    /// (0, 0) to (300, 200). Drawn lifted it is 66 x 48.4, so the pointer
    /// must be 33 / 24.2 past an edge for the picture to have left entirely.
    private func wholeTileReorder(panel: CGRect? = CGRect(x: 0, y: 0, width: 300, height: 200)) -> IslandHoverReorder {
        IslandHoverReorder(tool: .notes, original: tools, cells: [0: CGRect(x: 0, y: 0, width: 60, height: 44)],
                           panel: panel, tile: CGRect(x: 0, y: 0, width: 60, height: 44), lift: CGPoint(x: 30, y: 22))
    }

    func testThePictureFollowsThePointerAtItsLiftedSize() throws {
        let frame = try XCTUnwrap(wholeTileReorder().tileFrame(at: CGPoint(x: 130, y: 72)))
        XCTAssertEqual(frame.midX, 130, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 72, accuracy: 0.001)
        XCTAssertEqual(frame.width, 60 * IslandHoverReorderMotionCurve.liftedScale, accuracy: 0.001)
        XCTAssertEqual(frame.height, 44 * IslandHoverReorderMotionCurve.liftedScale, accuracy: 0.001)
    }

    func testAPartlyOutsideTileIsNeverRemovedOnAnySide() {
        let reorder = wholeTileReorder()
        let halfWidth = 33.0, halfHeight = 24.2
        // The pointer itself is already outside the drawer on every side here.
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 150, y: -halfHeight + 1)), "Below")
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 150, y: 200 + halfHeight - 1)), "Above, toward the notch")
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: -halfWidth + 1, y: 100)), "Beside, left")
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 300 + halfWidth - 1, y: 100)), "Beside, right")
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 300 + halfWidth - 1, y: 200 + halfHeight - 1)), "A corner")
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 150, y: 190)), "Over the search band")
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 280, y: 10)), "Over the footer or More")
    }

    func testAFullyOutsideTileIsRemovedOnEverySideWithNoExtraDistance() {
        let reorder = wholeTileReorder()
        let halfWidth = 33.0, halfHeight = 24.2
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: 150, y: -halfHeight - 0.5)), "Below")
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: 150, y: 200 + halfHeight + 0.5)), "Above, toward the notch")
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: -halfWidth - 0.5, y: 100)), "Beside, left")
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: 300 + halfWidth + 0.5, y: 100)), "Beside, right")
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: 300 + halfWidth, y: 100)), "Touching the edge is outside")
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: -halfWidth - 1, y: 200 + halfHeight + 1)), "Diagonally off a corner")
    }

    func testWhereTheTileWasGrabbedDecidesHowFarThePointerGoes() {
        // Pressed near the tile's top edge: the picture hangs below the pointer.
        let reorder = IslandHoverReorder(tool: .notes, original: tools,
                                         cells: [0: CGRect(x: 0, y: 0, width: 60, height: 44)],
                                         panel: CGRect(x: 0, y: 0, width: 300, height: 200),
                                         tile: CGRect(x: 0, y: 0, width: 60, height: 44), lift: CGPoint(x: 30, y: 40))
        // Above the drawer by more than half a tile, the bottom still overlaps.
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 150, y: 230)))
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: 150, y: 245)))
    }

    /// Grabbed near its top edge, a top-row tile hangs below the pointer;
    /// the screen's top (32 pt above the drawer, a 24 pt menu bar) stops the
    /// pointer before the picture can leave. Above the drawer the picture
    /// rises a little faster, so at the screen's top it has just left.
    func testUpwardRemovalIsReachableWhereverTheTileWasGrabbed() throws {
        var reorder = IslandHoverReorder(tool: .notes, original: tools,
                                         cells: [0: CGRect(x: 0, y: 150, width: 60, height: 50)],
                                         panel: CGRect(x: 0, y: 0, width: 300, height: 200),
                                         tile: CGRect(x: 0, y: 150, width: 60, height: 50), lift: CGPoint(x: 30, y: 198))
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 30, y: 232)),
                       "Without the screen's top known, the pointer at 232 leaves the picture over the drawer")
        reorder.ceiling = 232
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: 30, y: 232)), "Pointer at the screen's top: removed")
        // Never while any part of the drawn picture is still over the drawer.
        var y: CGFloat = 150
        while y <= 232 {
            let point = CGPoint(x: 30, y: y)
            let drawn = try XCTUnwrap(reorder.tileFrame(at: reorder.pictureAnchor(for: point)))
            let overlap = drawn.intersection(CGRect(x: 0, y: 0, width: 300, height: 200))
            let visiblyOver = !overlap.isNull && overlap.width > 0 && overlap.height > 0
            if reorder.removesRelease(at: point) {
                XCTAssertFalse(visiblyOver, "removal at y=\(y) while the drawn picture overlaps the drawer")
            }
            y += 0.5
        }
        XCTAssertEqual(reorder.pictureAnchor(for: CGPoint(x: 30, y: 180)), CGPoint(x: 30, y: 180),
                       "Inside the drawer the picture follows the pointer exactly")
    }

    /// Grabbed at its middle the picture leaves the drawer before the screen's
    /// top: it follows the pointer exactly, with no extra speed.
    func testAMiddleGrabNeedsNoHelpUpward() {
        let reorder = IslandHoverReorder(tool: .notes, original: tools,
                                         cells: [0: CGRect(x: 0, y: 150, width: 60, height: 50)],
                                         panel: CGRect(x: 0, y: 0, width: 300, height: 200),
                                         tile: CGRect(x: 0, y: 150, width: 60, height: 50), lift: CGPoint(x: 30, y: 175),
                                         ceiling: 240)
        XCTAssertEqual(reorder.pictureAnchor(for: CGPoint(x: 30, y: 220)), CGPoint(x: 30, y: 220))
    }

    /// Outside, the tile is drawn at 0.9x; it comes back only when that
    /// smaller picture touches the drawer, not where the 1.1x one would.
    func testTheRemoveCueStaysUntilTheSmallerOutsidePictureTouchesTheDrawer() {
        let reorder = wholeTileReorder()
        let lifted = 44 * IslandHoverReorderMotionCurve.liftedScale / 2
        let outside = 44 * IslandHoverReorderMotionCurve.outsideScale / 2
        let between = CGPoint(x: 150, y: -(lifted + outside) / 2)   // 1.1x overlaps, 0.9x does not
        XCTAssertFalse(reorder.removesRelease(at: between, outside: false), "Not yet out at the lifted size")
        XCTAssertTrue(reorder.removesRelease(at: between, outside: true), "Already out: the drawn 0.9x tile is clear")
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 150, y: -outside + 1), outside: true),
                       "The visible tile touching the drawer brings it back")
    }

    func testWithoutTheDrawersFrameTheGridAndItsMarginAreTheHover() {
        let reorder = wholeTileReorder(panel: nil)
        let edge = 44 + IslandHoverReorder.releaseMargin
        XCTAssertFalse(reorder.removesRelease(at: CGPoint(x: 30, y: edge + 24.2 - 1)))
        XCTAssertTrue(reorder.removesRelease(at: CGPoint(x: 30, y: edge + 24.2 + 0.5)))
        let pointOnly = IslandHoverReorder(tool: .notes, original: tools,
                                           cells: [0: CGRect(x: 0, y: 0, width: 60, height: 44)])
        XCTAssertFalse(pointOnly.removesRelease(at: CGPoint(x: 30, y: edge - 1)), "No tile known: the pointer decides")
        XCTAssertTrue(pointOnly.removesRelease(at: CGPoint(x: 30, y: edge + 1)))
    }

    /// The fixture has no drawer region: the hover is the row (y 0...44)
    /// plus the margin, and the lifted tile is 66 x 48.4 around the pointer.
    func testThePointerOutsideWithTheTileStillOverlappingKeepsTheTool() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        let top = point(0).y + 22 + IslandHoverReorder.releaseMargin
        let partlyOut = CGPoint(x: point(0).x, y: top + 10)
        drag(to: partlyOut)
        XCTAssertFalse(bridge.motion.outside, "Part of the tile is still over the hover: no remove cue")
        up(at: partlyOut)
        XCTAssertEqual(store.slots, tools, "Released partly outside: kept where it was")
        XCTAssertNotEqual(bridge.reorderPhase.state, .removed)
    }

    func testTheCueAppearsTheMomentTheWholeTileIsOutAndGoesWhenAnyPartReturns() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        let top = point(0).y + 22 + IslandHoverReorder.releaseMargin
        let halfHeight = 22 * IslandHoverReorderMotionCurve.liftedScale
        drag(to: CGPoint(x: point(0).x, y: top + halfHeight + 1))
        XCTAssertTrue(bridge.motion.outside, "Fully out: the cue says letting go removes it")
        // Outside it is drawn at 0.9x: the lifted size touching again is not
        // what the user sees, so the cue stays until the drawn tile touches.
        drag(to: CGPoint(x: point(0).x, y: top + halfHeight - 1))
        XCTAssertTrue(bridge.motion.outside, "The visible 0.9x tile is still clear of the hover")
        let outsideHalf = 22 * IslandHoverReorderMotionCurve.outsideScale
        drag(to: CGPoint(x: point(0).x, y: top + outsideHalf - 1))
        XCTAssertFalse(bridge.motion.outside, "A sliver of the visible tile back over the hover: no longer a removal")
        up(at: CGPoint(x: point(0).x, y: top + outsideHalf - 1))
        XCTAssertEqual(store.slots, tools)

        XCTAssertTrue(down(1))
        XCTAssertTrue(bridge.liftPressedTool())
        let beside = CGPoint(x: point(3).x + 30 + IslandHoverReorder.releaseMargin + 33 + 1, y: point(1).y)
        drag(to: beside)
        XCTAssertTrue(bridge.motion.outside, "Beside the hover counts too")
        up(at: beside)
        XCTAssertEqual(store.slots, [.inputLang, .monitor, .settings])
        XCTAssertEqual(bridge.reorderPhase.state, .removed)
    }

    func testEscapeDuringADragPutsEverythingBack() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        drag(to: CGPoint(x: point(2).x, y: point(2).y + 200))
        bridge.cancelReorder()
        up(at: CGPoint(x: point(2).x, y: point(2).y + 200))
        XCTAssertEqual(store.slots, tools, "Escape is the other way out; nothing is removed")
        XCTAssertEqual(restored(), tools)
        XCTAssertFalse(bridge.motion.outside)
    }

    // Builder ticket 695: Escape during a second drag cancels only that
    // drag; the drawer held by the earlier edit stays open.
    func testBuilder695EscapeCancelsADragWithoutDismissingTheEarlierEditHold() {
        bridge.notePointer(inside: true)
        XCTAssertTrue(bridge.unpin(.monitor))
        let before = store.slots
        var dismissals = 0
        let subscribed = bridge.dismissals.sink { dismissals += 1 }
        defer { subscribed.cancel() }
        XCTAssertTrue(down(0))
        drag(to: point(1))
        XCTAssertTrue(bridge.isReordering)
        XCTAssertNotEqual(store.slots, before)
        // The earlier edit observer and the drag observer both see this Escape.
        bridge.dismissAfterEdit()
        bridge.cancelReorder()
        XCTAssertEqual(store.slots, before)
        XCTAssertEqual(dismissals, 0, "Escape cancels the current drag; it must not also close the edited drawer")
        XCTAssertTrue(bridge.editHold.holdsDrawer)
    }

    private func escapeKey(at timestamp: TimeInterval, repeat isARepeat: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                       windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                       charactersIgnoringModifiers: "\u{1b}", isARepeat: isARepeat, keyCode: 53))
    }

    // Builder ticket 698: holding Escape after it cancelled a drag sends
    // auto-repeats with later timestamps. They are still the drag's key and
    // never close the drawer an earlier edit holds; a separate press does.
    func testBuilder698OneHeldEscapeCancelsOnlyDragAcrossAutoRepeat() throws {
        for dragMonitorFirst in [false, true] {
            bridge.notePointer(inside: true)
            if !store.slots.contains(.monitor) { XCTAssertTrue(bridge.pin(.monitor)) }
            XCTAssertTrue(bridge.unpin(.monitor))
            let editedOrder = store.slots
            var dismissals = 0
            let observer = IslandHoverMenuDismissObserver.Coordinator()
            observer.view = window.contentView
            observer.ignores = { [bridge] in bridge!.escapeBelongsToDrag($0) }
            let subscribed = bridge.dismissals.sink { dismissals += 1 }
            defer { subscribed.cancel() }

            XCTAssertTrue(down(0))
            drag(to: point(1))
            XCTAssertTrue(bridge.isReordering)
            let first = try escapeKey(at: 10)
            if dragMonitorFirst { bridge.handleDragKey(first) }
            if observer.shouldDismiss(first) { bridge.dismissAfterEdit() }
            if !dragMonitorFirst { bridge.handleDragKey(first) }
            XCTAssertEqual(store.slots, editedOrder)
            XCTAssertFalse(bridge.isReordering)
            XCTAssertTrue(bridge.editHold.holdsDrawer)

            let repeated = try escapeKey(at: 10.5, repeat: true)
            if observer.shouldDismiss(repeated) { bridge.dismissAfterEdit() }
            XCTAssertEqual(dismissals, 0, "A repeat from the same held Escape is still the drag's key")
            XCTAssertTrue(bridge.editHold.holdsDrawer, "A held key is not a second dismissal")

            bridge.mouseUp(at: point(1), in: window, allowed: true)
            let laterPress = try escapeKey(at: 20)
            if observer.shouldDismiss(laterPress) { bridge.dismissAfterEdit() }
            XCTAssertFalse(bridge.editHold.holdsDrawer, "A separate Escape dismisses normally")
            XCTAssertEqual(dismissals, 1)
        }
    }

    /// A held Escape keeps repeating after the cancel, in either monitor
    /// order and for many repeats; the next real press, and only its own
    /// repeats after the hold ended, are the edit hold's again.
    func testRepeatsOfTheDragsEscapeNeverCloseTheHeldDrawerButANewPressDoes() throws {
        for dragMonitorFirst in [false, true] {
            bridge.notePointer(inside: true)
            if !store.slots.contains(.monitor) { XCTAssertTrue(bridge.pin(.monitor)) }
            XCTAssertTrue(bridge.unpin(.monitor))
            var dismissals = 0
            let subscribed = bridge.dismissals.sink { dismissals += 1 }
            defer { subscribed.cancel() }
            let observer = IslandHoverMenuDismissObserver.Coordinator()
            observer.view = window.contentView
            observer.consumesEscapeElsewhere = false
            observer.ignores = { [bridge] in bridge!.escapeBelongsToDrag($0) }
            func deliver(_ event: NSEvent) {
                if dragMonitorFirst { bridge.handleDragKey(event) }
                if observer.shouldDismiss(event) { bridge.dismissAfterEdit() }
                if !dragMonitorFirst { bridge.handleDragKey(event) }
            }

            XCTAssertTrue(down(0))
            drag(to: point(1))
            deliver(try escapeKey(at: 100))
            XCTAssertFalse(bridge.isReordering)
            // Repeats arrive before and after the pointer is released.
            for step in 1...5 { deliver(try escapeKey(at: 100 + Double(step) * 0.05, repeat: true)) }
            bridge.mouseUp(at: point(1), in: window, allowed: true)
            for step in 6...10 { deliver(try escapeKey(at: 100 + Double(step) * 0.05, repeat: true)) }
            XCTAssertEqual(dismissals, 0)
            XCTAssertTrue(bridge.editHold.holdsDrawer)

            // A separate press closes the drawer; its own repeats change nothing more.
            deliver(try escapeKey(at: 200))
            XCTAssertEqual(dismissals, 1)
            XCTAssertFalse(bridge.editHold.holdsDrawer)
            deliver(try escapeKey(at: 200.05, repeat: true))
            XCTAssertEqual(dismissals, 1)
        }
    }

    /// The real wiring: the edit-dismiss observer and the drag's Escape
    /// monitor see the same key in either order. The drag owns it both ways;
    /// a later Escape with no drag still closes the edited drawer.
    func testADragsEscapeHasOneOwnerWhicheverMonitorSeesItFirst() throws {
        bridge.notePointer(inside: true)
        XCTAssertTrue(bridge.unpin(.monitor))
        let before = store.slots
        var dismissals = 0
        let subscribed = bridge.dismissals.sink { dismissals += 1 }
        defer { subscribed.cancel() }
        let observer = IslandHoverMenuDismissObserver.Coordinator()
        observer.view = window.contentView
        observer.consumesEscapeElsewhere = false
        observer.ignores = { [bridge] in bridge!.escapeBelongsToDrag($0) }
        let deliver: (NSEvent) -> Void = { event in
            if observer.shouldDismiss(event) { self.bridge.dismissAfterEdit() }
        }

        // The observer first, then the drag's monitor.
        XCTAssertTrue(down(0))
        drag(to: point(1))
        XCTAssertTrue(bridge.isReordering)
        let first = try escapeKey(at: 10)
        deliver(first)
        bridge.handleDragKey(first)
        XCTAssertFalse(bridge.isReordering)
        XCTAssertEqual(store.slots, before)

        // The drag's monitor first, then the observer.
        bridge.mouseUp(at: point(1), in: window, allowed: true)
        XCTAssertTrue(down(0))
        drag(to: point(1))
        XCTAssertTrue(bridge.isReordering)
        let second = try escapeKey(at: 20)
        bridge.handleDragKey(second)
        deliver(second)
        XCTAssertFalse(bridge.isReordering)
        XCTAssertEqual(store.slots, before)
        XCTAssertEqual(dismissals, 0, "Neither order closes the drawer the earlier edit holds")
        XCTAssertTrue(bridge.editHold.holdsDrawer)

        // With no drag, Escape is the edit hold's again.
        bridge.mouseUp(at: point(1), in: window, allowed: true)
        deliver(try escapeKey(at: 30))
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(bridge.editHold.holdsDrawer)
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
        XCTAssertFalse(reorder.removesRelease(at: .zero), "Without measured cells a release never removes")
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

    // MARK: - Smooth motion (REV 2)

    func testTheLiftedTileFollowsThePointerInSwiftUIOrientation() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        XCTAssertEqual(bridge.motion.translation, .zero, "It starts exactly over its cell")
        let start = point(0)
        drag(to: CGPoint(x: start.x + 17, y: start.y + 5))
        XCTAssertEqual(bridge.motion.translation, CGSize(width: 17, height: -5),
                       "Window y grows upward; the floating tile's y grows downward")
        drag(to: CGPoint(x: start.x + 95, y: start.y - 3))
        XCTAssertEqual(bridge.motion.translation, CGSize(width: 95, height: 3))
        up(at: CGPoint(x: start.x + 95, y: start.y - 3))
        XCTAssertEqual(bridge.motion.translation, CGSize(width: 95, height: 3),
                       "The landing starts from where the pointer let go")
        XCTAssertTrue(down(2))
        XCTAssertTrue(bridge.liftPressedTool())
        XCTAssertEqual(bridge.motion.translation, .zero, "A new lift starts from its own cell")
    }

    /// The island observes the bridge; a pointer move that stays in one cell
    /// must not redraw it. Only the floating tile observes the travel.
    func testPointerMovesInsideACellRedrawOnlyTheFloatingTile() {
        XCTAssertTrue(down(0))
        XCTAssertTrue(bridge.liftPressedTool())
        var bridgeChanges = 0, motionChanges = 0
        let watchBridge = bridge.objectWillChange.sink { bridgeChanges += 1 }
        let watchMotion = bridge.motion.objectWillChange.sink { motionChanges += 1 }
        let start = point(0)
        for step in 1...10 { drag(to: CGPoint(x: start.x + Double(step), y: start.y)) }
        XCTAssertEqual(bridgeChanges, 0)
        XCTAssertEqual(motionChanges, 10)
        XCTAssertEqual(store.slots, tools)
        watchBridge.cancel(); watchMotion.cancel()
    }

    func testTheFloatingTileFollowsUntilLetGoThenLandsOnItsCell() {
        let origin = CGPoint(x: 45, y: 26)
        XCTAssertEqual(IslandHoverFloatingTile<EmptyView>.position(origin: origin, translation: CGSize(width: 60, height: -4),
                                                                   settle: nil), CGPoint(x: 105, y: 22))
        XCTAssertEqual(IslandHoverFloatingTile<EmptyView>.position(origin: origin, translation: CGSize(width: 60, height: -4),
                                                                   settle: CGPoint(x: 135, y: 26)), CGPoint(x: 135, y: 26))
    }

    func testTheReorderCurvesDoNotBounce() throws {
        let source = try String(contentsOfFile: Self.repoFile("Sources/Sidekey/DynamicIsland/IslandHoverReorderMotion.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains(".animation(nil, value: motion.translation)"),
                      "Following the pointer must never lag behind an animation")
        let island = try String(contentsOfFile: Self.repoFile("Sources/Sidekey/DynamicIsland/IslandView.swift"), encoding: .utf8)
        XCTAssertTrue(island.contains(
            ".opacity(hoverHitBridge.reorderingTool == tool || hoverHitBridge.settlingTool == tool ? 0 : 1)"),
                      "The lifted tool's cell is an empty place while the floating tile is drawn and lands")
        XCTAssertTrue(island.contains("IslandHoverFloatingLayer(stage: hoverHitBridge.stage, motion: hoverHitBridge.motion)"))
        XCTAssertFalse(island.contains(".scaleEffect(hoverHitBridge.reorderingTool == tool"),
                       "The grid tile no longer jumps from cell to cell as the lifted tile")
    }

    /// The floating tile starts over a tile's frame read through the same
    /// structure as the drawer: a lazy grid in a scroll view in the glass
    /// container, measured in the container's space.
    func testTileFramesReachTheGridSpaceThroughScrollAndGlass() {
        final class Box { var frames: [HoverTool: CGRect] = [:] }
        let box = Box(), tools = tools
        let grid = IslandHoverGlassControlsContainer {
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(60), spacing: 0), count: 3), spacing: 0) {
                    ForEach(tools, id: \.self) { tool in
                        Color.clear.frame(width: 60, height: 44)
                            .background(IslandHoverTileFrameReporter(tool: tool, space: "grid"))
                    }
                }
            }
            .frame(width: 180, height: 88)
        }
        .coordinateSpace(name: "grid")
        .onPreferenceChange(IslandHoverTileFramesKey.self) { box.frames = $0 }
        let hosting = NSHostingView(rootView: grid)
        let offscreen = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 88),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        offscreen.isReleasedWhenClosed = false
        offscreen.contentView = hosting
        defer { offscreen.close() }
        for _ in 0..<4 { hosting.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(Set(box.frames.keys), Set(tools))
        XCTAssertEqual(box.frames[.inputLang]?.origin, CGPoint(x: 0, y: 0))
        XCTAssertEqual(box.frames[.notes]?.origin, CGPoint(x: 60, y: 0))
        XCTAssertEqual(box.frames[.settings]?.origin, CGPoint(x: 0, y: 44), "Second row, first cell")
    }

    private static func repoFile(_ path: String) -> String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path).path
    }

    // MARK: - Builder review #562

    func testCrossingTheTileEdgeBeforeTheThresholdStillDrags() {
        let press = CGPoint(x: point(0).x + 29, y: point(0).y)
        XCTAssertTrue(bridge.mouseDown(at: press, in: window, allowed: true))
        drag(to: CGPoint(x: press.x + 2, y: press.y))
        XCTAssertFalse(bridge.isReordering, "Under the threshold")
        drag(to: point(2))
        XCTAssertEqual(bridge.reorderingTool, .inputLang, "The press's drag intent survives a small edge crossing")
        up(at: point(2))
        XCTAssertEqual(restored(), [.notes, .monitor, .inputLang, .settings])
        XCTAssertEqual(activated, [], "The crossing still cancelled the click")
    }

    func testAWindowThatStoppedAllowingHoverNeverLifts() {
        XCTAssertTrue(down(0))
        bridge.mouseDragged(at: point(2), in: window, allowed: false)
        XCTAssertFalse(bridge.isReordering)
        XCTAssertEqual(store.slots, tools)
        bridge.mouseUp(at: point(2), in: window, allowed: false)
        XCTAssertEqual(activated, [])
    }

    func testSyncEqualToTheUnsavedPreviewStillWinsOverACancel() {
        XCTAssertTrue(down(0))
        drag(to: point(1))
        let incoming: [HoverTool] = [.notes, .inputLang, .monitor, .settings]
        XCTAssertEqual(store.slots, incoming)
        XCTAssertEqual(restored(), tools, "The preview is not saved yet")
        syncArrives(incoming)
        XCTAssertFalse(bridge.isReordering, "A sync reload ends the drag even when it equals the preview")
        up(at: CGPoint(x: point(1).x, y: point(1).y + 200))
        XCTAssertEqual(store.slots, incoming)
        XCTAssertEqual(restored(), incoming, "The cancel did not overwrite what sync brought")
    }

    func testACancelledDragLeavesAnUnsetLayoutUnset() {
        defaults.removeObject(forKey: HoverLayoutStore.defaultsKey)
        store.reloadFromDefaults()
        let original = store.slots
        XCTAssertTrue(down(0))
        drag(to: point(1))
        XCTAssertNotEqual(store.slots, original)
        XCTAssertNil(defaults.object(forKey: HoverLayoutStore.defaultsKey))
        bridge.cancelReorder()  // Escape
        up(at: point(1))
        XCTAssertEqual(store.slots, original)
        XCTAssertNil(defaults.object(forKey: HoverLayoutStore.defaultsKey), "A cancel writes nothing")
    }

    func testAThrownOutTileVanishesWhereThePointerLetGo() {
        XCTAssertTrue(down(0))
        drag(to: point(1))
        let released = CGPoint(x: point(1).x + 8, y: point(1).y + 105)
        up(at: released)
        XCTAssertEqual(store.slots, [.notes, .monitor, .settings])
        XCTAssertEqual(bridge.motion.translation, CGSize(width: 68, height: -105))
    }

    func testTheDrawerStaysUntilTheTileHasLanded() async throws {
        XCTAssertTrue(down(0))
        drag(to: point(1))
        bridge.cancelReorder()  // Escape: the tile flies back
        up(at: point(1))
        XCTAssertFalse(bridge.isReordering)
        XCTAssertEqual(bridge.settlingTool, .inputLang)
        XCTAssertTrue(bridge.holdsDrawer, "The fly-back stays visible")
        bridge.didSettle(generation: bridge.reorderGeneration)
        XCTAssertFalse(bridge.holdsDrawer)

        XCTAssertTrue(down(0))
        drag(to: point(1))
        up(at: point(1))
        XCTAssertTrue(bridge.holdsDrawer)
        try await Task.sleep(for: .milliseconds(1_100))
        XCTAssertFalse(bridge.holdsDrawer, "If the island never reports the landing, the hold ends anyway")
    }

    func testAnOlderLandingNeverEndsANewerLiftOfAnotherTile() {
        XCTAssertTrue(down(0))
        drag(to: point(1))
        up(at: point(1))
        let first = bridge.reorderGeneration
        XCTAssertEqual(bridge.settlingTool, .inputLang)
        // The same tile is grabbed again while it is still landing.
        XCTAssertTrue(down(1))
        drag(to: point(0))
        XCTAssertEqual(bridge.reorderingTool, .notes, "The tile drawn in slot 1 of this static grid")
        XCTAssertNil(bridge.settlingTool, "A new lift ends the older landing's hold")
        let second = bridge.reorderGeneration
        XCTAssertNotEqual(first, second)
        bridge.stage.begin(.notes, content: AnyView(EmptyView()), origin: .zero, generation: second)
        bridge.didSettle(generation: first)
        XCTAssertTrue(bridge.isReordering)
        XCTAssertEqual(bridge.stage.tool, .notes, "The newer lift keeps its picture")
        up(at: point(0))
        bridge.didSettle(generation: second)
        XCTAssertFalse(bridge.holdsDrawer)
        XCTAssertNil(bridge.stage.tool)
    }

    func testAReleaseAfterHoverDispatchStoppedKeepsTheLastAllowedOrder() {
        XCTAssertTrue(down(0))
        drag(to: CGPoint(x: point(0).x + 5, y: point(0).y))
        XCTAssertEqual(bridge.reorderingTool, .inputLang)
        bridge.mouseDragged(at: point(2), in: window, allowed: false)
        XCTAssertEqual(store.slots, tools)
        bridge.mouseUp(at: point(2), in: window, allowed: false)
        XCTAssertEqual(store.slots, tools, "An ineligible release cannot move the order")
        XCTAssertEqual(restored(), tools, "An ineligible release cannot save a new order")
        XCTAssertFalse(bridge.isReordering)
    }

    /// The real island, mounted offscreen (never shown): release a tile and
    /// grab the same tile again before SwiftUI redraws. The island must start
    /// a picture for the new lift, and the older landing must not erase it.
    func testGrabbingTheSameTileAgainBeforeARedrawGetsItsOwnPicture() throws {
        let state = AppState()
        state.programmaticHoverExpansion = true
        let liveBridge = IslandHoverHitBridge()
        let prefs = DisplayPreferences(defaults: defaults)
        let hosting = NSHostingView(rootView: IslandView(appState: state, hoverHitBridge: liveBridge,
                                                         displayPreferences: prefs, hoverLayout: store)
            .frame(width: 700, height: 430, alignment: .top))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430),
                             styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        defer { panel.close() }
        func layOut() {
            for _ in 0..<4 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            }
        }
        layOut()
        liveBridge.setEnabled(true)
        var found: CGPoint?
        search: for y in stride(from: 4, to: 426, by: 8) {
            for x in stride(from: 4, to: 696, by: 8) {
                let candidate = CGPoint(x: x, y: y)
                if liveBridge.mouseDown(at: candidate, in: panel, allowed: true),
                   liveBridge.pressedID?.tool == .inputLang {
                    found = candidate
                    break search
                }
            }
        }
        let press = try XCTUnwrap(found, "The island offers the Input language tile")
        let moved = CGPoint(x: press.x, y: press.y - IslandHoverHitBridge.dragThreshold)
        liveBridge.mouseDragged(at: moved, in: panel, allowed: true)
        XCTAssertEqual(liveBridge.reorderingTool, .inputLang)
        layOut()
        let first = liveBridge.reorderGeneration
        XCTAssertEqual(liveBridge.stage.generation, first, "The island staged the first lift")
        XCTAssertNotNil(liveBridge.stage.content)

        liveBridge.mouseUp(at: press, in: panel, allowed: true)
        XCTAssertEqual(liveBridge.settlingTool, .inputLang)
        // The next press arrives in the same display pass.
        XCTAssertTrue(liveBridge.mouseDown(at: press, in: panel, allowed: true))
        liveBridge.mouseDragged(at: moved, in: panel, allowed: true)
        XCTAssertEqual(liveBridge.reorderingTool, .inputLang)
        let second = liveBridge.reorderGeneration
        XCTAssertGreaterThan(second, first)
        layOut()
        XCTAssertEqual(liveBridge.stage.generation, second, "The new lift has its own picture")
        liveBridge.didSettle(generation: first)
        XCTAssertNotNil(liveBridge.stage.content, "The older landing cannot erase the tile being dragged")
        XCTAssertTrue(liveBridge.isReordering)
        liveBridge.mouseUp(at: press, in: panel, allowed: true)
        XCTAssertFalse(panel.isVisible, "Offscreen: never shown over the person's work")
    }

    /// The real island mounted offscreen (never shown), with the press point
    /// of its Input language tile.
    private struct MountedIsland {
        let bridge: IslandHoverHitBridge
        let window: NSWindow
        let hosting: NSView
        let press: CGPoint
        var moved: CGPoint { CGPoint(x: press.x, y: press.y - IslandHoverHitBridge.dragThreshold) }

        func layOut() {
            for _ in 0..<4 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            }
        }

        func wait(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    }

    private func mountIsland() throws -> MountedIsland {
        let state = AppState()
        state.programmaticHoverExpansion = true
        let liveBridge = IslandHoverHitBridge()
        let hosting = NSHostingView(rootView: IslandView(appState: state, hoverHitBridge: liveBridge,
                                                         displayPreferences: DisplayPreferences(defaults: defaults),
                                                         hoverLayout: store)
            .frame(width: 700, height: 430, alignment: .top))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430),
                             styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        addTeardownBlock { await MainActor.run { panel.close() } }
        var found: CGPoint?
        let probe = MountedIsland(bridge: liveBridge, window: panel, hosting: hosting, press: .zero)
        probe.layOut()
        liveBridge.setEnabled(true)
        search: for y in stride(from: 4, to: 426, by: 8) {
            for x in stride(from: 4, to: 696, by: 8) {
                let candidate = CGPoint(x: x, y: y)
                if liveBridge.mouseDown(at: candidate, in: panel, allowed: true),
                   liveBridge.pressedID?.tool == .inputLang {
                    found = candidate
                    break search
                }
            }
        }
        let press = try XCTUnwrap(found, "The island offers the Input language tile")
        liveBridge.discardSequence()
        return MountedIsland(bridge: liveBridge, window: panel, hosting: hosting, press: press)
    }

    /// Two quick drags of the same tile, the second lift and release both
    /// before the island redraws: the latest lift gets the picture and lands;
    /// the first lift's enlarged picture does not linger.
    func testTwoQuickDragsOfTheSameTileWithoutARedrawLandTheLatest() throws {
        let island = try mountIsland()
        let bridge = island.bridge
        XCTAssertTrue(bridge.mouseDown(at: island.press, in: island.window, allowed: true))
        bridge.mouseDragged(at: island.moved, in: island.window, allowed: true)
        island.layOut()
        let first = bridge.reorderGeneration
        XCTAssertEqual(bridge.stage.generation, first)

        bridge.mouseUp(at: island.moved, in: island.window, allowed: true)
        XCTAssertTrue(bridge.mouseDown(at: island.press, in: island.window, allowed: true))
        bridge.mouseDragged(at: island.moved, in: island.window, allowed: true)
        bridge.mouseUp(at: island.moved, in: island.window, allowed: true)
        let second = bridge.reorderGeneration
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(bridge.settlingTool, .inputLang)
        island.layOut()
        XCTAssertEqual(bridge.stage.generation, second, "The latest lift has the picture, the first one is gone")
        XCTAssertEqual(bridge.stage.tool, .inputLang)
        XCTAssertNotNil(bridge.stage.settle, "The latest release lands")
        XCTAssertTrue(bridge.holdsDrawer, "The drawer stays for that landing")
        island.wait(1.2)
        XCTAssertNil(bridge.stage.content, "Nothing stays enlarged over the grid")
        XCTAssertFalse(bridge.holdsDrawer)
    }

    func testTwoQuickDragsOfTheSameTileWithARedrawBeforeTheSecondReleaseLandTheLatest() throws {
        let island = try mountIsland()
        let bridge = island.bridge
        XCTAssertTrue(bridge.mouseDown(at: island.press, in: island.window, allowed: true))
        bridge.mouseDragged(at: island.moved, in: island.window, allowed: true)
        island.layOut()
        bridge.mouseUp(at: island.moved, in: island.window, allowed: true)
        XCTAssertTrue(bridge.mouseDown(at: island.press, in: island.window, allowed: true))
        bridge.mouseDragged(at: island.moved, in: island.window, allowed: true)
        island.layOut()
        let second = bridge.reorderGeneration
        XCTAssertEqual(bridge.stage.generation, second)
        XCTAssertTrue(bridge.stage.lifted)
        bridge.mouseUp(at: island.moved, in: island.window, allowed: true)
        island.layOut()
        XCTAssertEqual(bridge.stage.generation, second)
        XCTAssertNotNil(bridge.stage.settle)
        island.wait(1.2)
        XCTAssertNil(bridge.stage.content)
        XCTAssertFalse(bridge.holdsDrawer)
    }

    /// The production layering: the floating layer is an overlay outside the
    /// drawer's glass surface, which clips its content on the macOS 14/15
    /// backdrop. The tile must stay visible below the drawer on both paths.
    func testTheFloatingTileStaysVisibleOutsideTheDrawerOnBothBackdrops() throws {
        let motion = IslandHoverReorderMotion()
        motion.follow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: -80))
        let stage = IslandHoverReorderStage()
        stage.begin(.notes, content: AnyView(Color.red.frame(width: 90, height: 52)),
                    origin: CGPoint(x: 100, y: 50), generation: 1)
        stage.lifted = true
        for legacy in [false, true] {
            let wasLegacy = IslandHoverGlass.drawsLegacyPathForReview
            IslandHoverGlass.drawsLegacyPathForReview = legacy
            defer { IslandHoverGlass.drawsLegacyPathForReview = wasLegacy }
            let scene = Color.clear.frame(width: 310, height: 100)
                .islandHoverGlassSurface()
                .frame(width: 310, height: 200, alignment: .top)
                .overlay(alignment: .topLeading) { IslandHoverFloatingLayer(stage: stage, motion: motion) }
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 1
            let data = try XCTUnwrap(renderer.nsImage?.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let color = try XCTUnwrap(bitmap.colorAt(x: 100, y: 130)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(color.redComponent, 0.8, legacy ? "macOS 14/15 backdrop" : "native glass")
            XCTAssertGreaterThan(color.alphaComponent, 0.8)
        }
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

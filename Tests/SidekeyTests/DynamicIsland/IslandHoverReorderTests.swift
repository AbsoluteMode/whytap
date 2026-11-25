import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Sidekey

/// Reordering the island's tools in the hover drawer, as a person does it:
/// a click still opens a tool; pressing a tile and moving it a few points
/// lifts it at once, moving the pointer over another tile puts it there, letting go keeps the order the
/// island shows (and Settings -> Features -> Hover shows the same order);
/// letting go far outside the tools puts everything back. Events go through
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
        up(at: CGPoint(x: point(1).x, y: point(1).y + 200))
        XCTAssertEqual(store.slots, original)
        XCTAssertNil(defaults.object(forKey: HoverLayoutStore.defaultsKey), "A cancel writes nothing")
    }

    func testTheCancelFlightStartsWhereThePointerLetGo() {
        XCTAssertTrue(down(0))
        drag(to: point(1))
        let released = CGPoint(x: point(1).x + 8, y: point(1).y + 105)
        up(at: released)
        XCTAssertEqual(store.slots, tools)
        XCTAssertEqual(bridge.motion.translation, CGSize(width: 68, height: -105))
    }

    func testTheDrawerStaysUntilTheTileHasLanded() async throws {
        XCTAssertTrue(down(0))
        drag(to: point(1))
        up(at: CGPoint(x: point(1).x, y: point(1).y + 200))
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

    func testAnOlderLandingNeverEndsANewerLiftOfTheSameTile() {
        XCTAssertTrue(down(0))
        drag(to: point(1))
        up(at: point(1))
        let first = bridge.reorderGeneration
        XCTAssertEqual(bridge.settlingTool, .inputLang)
        // The same tile is grabbed again while it is still landing.
        XCTAssertTrue(down(1))
        drag(to: point(0))
        XCTAssertEqual(bridge.reorderingTool, .notes, "The tile drawn in slot 1 of this static grid")
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

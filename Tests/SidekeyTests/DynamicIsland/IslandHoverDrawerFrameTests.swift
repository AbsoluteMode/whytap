import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// REV 7: the frame a dragged tile must leave is the drawer's visible glass
/// panel, measured in the real island (mounted offscreen, never shown), in
/// the same window coordinates as the dragged tile.
// WHY: .project-docs/decisions/2026-11-28-hover-drag-out-whole-tile.md
@MainActor
final class IslandHoverDrawerFrameTests: XCTestCase {
    private var suiteName = ""
    private var store: HoverLayoutStore!
    private var bridge: IslandHoverHitBridge!
    private var window: NSWindow!
    private var hosting: NSView!
    private let size = NSSize(width: 700, height: 520)

    override func setUp() async throws {
        suiteName = "IslandHoverDrawerFrameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: [.inputLang, .notes, .meetingRecord, .hotkeys, .monitor, .vocab])
        let state = AppState()
        state.programmaticHoverExpansion = true
        bridge = IslandHoverHitBridge()
        bridge.dragEffects = .silent
        let view = NSHostingView(rootView: IslandView(appState: state, hoverHitBridge: bridge,
                                                      displayPreferences: DisplayPreferences(defaults: defaults),
                                                      hoverLayout: store)
            .frame(width: size.width, height: size.height, alignment: .top))
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        hosting = view
        settle(0.8)
        bridge.setEnabled(true)
    }

    override func tearDown() async throws {
        window.contentView = nil
        window.close()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func settle(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
    }

    /// The tile's hit frame, the one a lift measures.
    private func tileFrame(_ tool: HoverTool) -> CGRect {
        bridge.targetFrame(.init(surface: .tile, tool: tool), in: window) ?? .null
    }

    private var compactWidth: CGFloat {
        IslandFrameLayout.leftSideWidth + IslandFrameLayout.syntheticNotchWidth + IslandFrameLayout.rightSideWidth
    }

    private var glassHeight: CGFloat {
        IslandView.hoverPanelHeight(for: .controls, musicActive: false, toolCount: store.slots.count, moreTools: nil)
            - IslandDropModeControl.detachedPanelGap
    }

    /// The removal frame is the glass panel: its size is the drawer's
    /// (compact width x drawer height), it holds every tile at the grid's
    /// inset, and it is far inside the island window on every side, which
    /// it was not before (the whole window, 700 x 520 here).
    func testTheRemovalFrameIsTheGlassPanelOnEverySide() throws {
        let glass = try XCTUnwrap(bridge.drawerFrame(in: window), "The glass reports its frame")
        XCTAssertEqual(glass.width, compactWidth, accuracy: 0.5, "Glass width")
        XCTAssertEqual(glass.height, glassHeight, accuracy: 0.5, "Glass height")
        XCTAssertEqual(glass.width, 310, accuracy: 0.5)
        XCTAssertEqual(glass.height, 311, accuracy: 0.5)
        let bounds = try XCTUnwrap(window.contentView?.bounds)
        // Distance from each side of the window: never the window itself.
        XCTAssertEqual(glass.minX - bounds.minX, 300, accuracy: 0.5, "Left")
        XCTAssertEqual(bounds.maxX - glass.maxX, 90, accuracy: 0.5, "Right")
        XCTAssertEqual(glass.minY - bounds.minY, 169, accuracy: 0.5, "Bottom")
        XCTAssertEqual(bounds.maxY - glass.maxY, 40, accuracy: 0.5, "Top (the pill above the drawer)")
        // Every tile sits inside, the first one at the grid's inset.
        let first = tileFrame(.inputLang)
        XCTAssertTrue(glass.contains(first))
        XCTAssertEqual(first.minX - glass.minX, IslandHoverControlsLayout.horizontalInset, accuracy: 0.5, "Left inset")
        for tool in [HoverTool.notes, .meetingRecord, .hotkeys, .monitor, .vocab, .settings] {
            XCTAssertTrue(glass.contains(tileFrame(tool)), "\(tool) is inside the glass")
        }
    }

    private enum Side { case left, right, below, above }

    /// The real island: a lifted tile shows the remove cue exactly when its
    /// picture has left the glass (1 pt past it), not while a 1 pt sliver is
    /// still over it, and a release past it removes the tool.
    private func throwOut(_ side: Side) throws {
        let glass = try XCTUnwrap(bridge.drawerFrame(in: window))
        let tile = tileFrame(.notes)
        let press = CGPoint(x: tile.midX, y: tile.midY)
        let halfWidth = tile.width * IslandHoverReorderMotionCurve.liftedScale / 2
        let halfHeight = tile.height * IslandHoverReorderMotionCurve.liftedScale / 2
        let (out, partly): (CGPoint, CGPoint)
        switch side {
        case .left:
            out = CGPoint(x: glass.minX - halfWidth - 1, y: press.y)
            partly = CGPoint(x: glass.minX - halfWidth + 1, y: press.y)
        case .right:
            out = CGPoint(x: glass.maxX + halfWidth + 1, y: press.y)
            partly = CGPoint(x: glass.maxX + halfWidth - 1, y: press.y)
        case .below:
            out = CGPoint(x: press.x, y: glass.minY - halfHeight - 1)
            partly = CGPoint(x: press.x, y: glass.minY - halfHeight + 1)
        case .above:
            out = CGPoint(x: press.x, y: glass.maxY + halfHeight + 1)
            partly = CGPoint(x: press.x, y: glass.maxY + halfHeight - 1)
        }
        XCTAssertTrue(bridge.mouseDown(at: press, in: window, allowed: true))
        bridge.mouseDragged(at: CGPoint(x: press.x + 6, y: press.y), in: window, allowed: true)
        XCTAssertEqual(bridge.reorderingTool, .notes)
        bridge.mouseDragged(at: partly, in: window, allowed: true)
        XCTAssertFalse(bridge.motion.outside, "A sliver over the glass is not a removal")
        bridge.mouseDragged(at: out, in: window, allowed: true)
        XCTAssertTrue(bridge.motion.outside, "Fully past the glass shows the cue")
        bridge.mouseUp(at: out, in: window, allowed: true)
        XCTAssertFalse(store.slots.contains(.notes), "Released fully past the glass: removed")
    }

    func testATileJustPastTheGlassOnTheLeftIsRemoved() throws { try throwOut(.left) }
    func testATileJustPastTheGlassOnTheRightIsRemoved() throws { try throwOut(.right) }
    func testATileJustPastTheGlassBelowIsRemoved() throws { try throwOut(.below) }
    func testATileJustPastTheGlassAboveTowardTheNotchIsRemoved() throws { try throwOut(.above) }

    /// A top-row tile grabbed near its top edge and dragged to the screen's
    /// top (here the window's top) is thrown out; just above the glass it is
    /// not.
    func testATileGrabbedNearItsTopIsRemovedAtTheScreensTop() throws {
        let glass = try XCTUnwrap(bridge.drawerFrame(in: window))
        let tile = tileFrame(.notes)
        let press = CGPoint(x: tile.midX, y: tile.maxY - 2)
        let top = window.frame.height
        XCTAssertGreaterThan(top, glass.maxY)
        XCTAssertTrue(bridge.mouseDown(at: press, in: window, allowed: true))
        bridge.mouseDragged(at: CGPoint(x: press.x + 6, y: press.y), in: window, allowed: true)
        XCTAssertEqual(bridge.reorderingTool, .notes)
        bridge.mouseDragged(at: CGPoint(x: press.x, y: glass.maxY + 4), in: window, allowed: true)
        XCTAssertFalse(bridge.motion.outside, "Just above the glass the picture is still over it")
        bridge.mouseDragged(at: CGPoint(x: press.x, y: top), in: window, allowed: true)
        XCTAssertTrue(bridge.motion.outside, "At the screen's top the whole picture has left the glass")
        bridge.mouseUp(at: CGPoint(x: press.x, y: top), in: window, allowed: true)
        XCTAssertFalse(store.slots.contains(.notes))
    }

    /// With 13+ tools the grid scrolls. A tile cut by the viewport is still
    /// lifted with its whole frame, the picture the layer draws, so its
    /// removal is judged on the whole tile and not on the visible sliver.
    func testAPartlyScrolledTileIsLiftedWithItsWholeFrame() throws {
        let many = HoverTool.allCases.filter { IslandHoverReorder.canLift($0, slots: HoverTool.allCases) }
        try XCTSkipIf(many.count < 14, "needs 14 liftable tools")
        store.replaceEditableSlots(with: Array(many.prefix(14)))
        settle(0.6)
        let scroll = try XCTUnwrap(Self.firstScrollView(in: hosting), "13+ tools scroll")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        settle(0.4)
        let full = tileFrame(.notes).height
        var cut: (HoverTool, CGRect)?
        for tool in store.slots where tool != .settings {
            let frame = tileFrame(tool)
            if !frame.isNull, frame.height > 4, frame.height < full - 4 { cut = (tool, frame); break }
        }
        let (tool, visible) = try XCTUnwrap(cut, "a row is partly scrolled out")
        let press = CGPoint(x: visible.midX, y: visible.midY)
        XCTAssertTrue(bridge.mouseDown(at: press, in: window, allowed: true))
        bridge.mouseDragged(at: CGPoint(x: press.x + 6, y: press.y), in: window, allowed: true)
        XCTAssertEqual(bridge.reorderingTool, tool)
        let lifted = try XCTUnwrap(bridge.liftedTileFrame)
        XCTAssertEqual(lifted.height, full, accuracy: 0.5, "the whole tile, not the visible \(visible.height) pt")
        bridge.mouseUp(at: CGPoint(x: press.x + 6, y: press.y), in: window, allowed: true)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = firstScrollView(in: child) { return found } }
        return nil
    }

    /// Twelve tiles fit in four rows; adding the 13th from More makes the
    /// grid scroll and must bring the new tool's row into view.
    func testAddingTheThirteenthToolScrollsItIntoView() throws {
        let liftable = HoverTool.allCases.filter { IslandHoverReorder.canLift($0, slots: HoverTool.allCases) }
        try XCTSkipIf(liftable.count < 12, "needs 12 pinnable tools")
        store.replaceEditableSlots(with: Array(liftable.prefix(11)))
        settle(0.5)
        XCTAssertEqual(store.slots.count, 12)
        XCTAssertNil(Self.firstScrollView(in: hosting), "twelve tiles need no scrolling")
        let added = liftable[11]
        XCTAssertTrue(store.pin(added))
        settle(0.8)
        let full = tileFrame(.notes).isNull ? 0 : tileFrame(.notes).height
        let frame = tileFrame(added)
        XCTAssertFalse(frame.isNull, "the 13th tool is visible after it was added")
        if full > 0 { XCTAssertEqual(frame.height, full, accuracy: 1, "and wholly in view") }
    }

    func testAReleaseWithTheTileStillOverTheGlassKeepsIt() throws {
        let glass = try XCTUnwrap(bridge.drawerFrame(in: window))
        let tile = tileFrame(.notes)
        let press = CGPoint(x: tile.midX, y: tile.midY)
        let halfHeight = tile.height * IslandHoverReorderMotionCurve.liftedScale / 2
        XCTAssertTrue(bridge.mouseDown(at: press, in: window, allowed: true))
        bridge.mouseDragged(at: CGPoint(x: press.x + 6, y: press.y), in: window, allowed: true)
        let partly = CGPoint(x: press.x, y: glass.minY - halfHeight + 1)
        bridge.mouseDragged(at: partly, in: window, allowed: true)
        XCTAssertFalse(bridge.motion.outside)
        bridge.mouseUp(at: partly, in: window, allowed: true)
        XCTAssertTrue(store.slots.contains(.notes))
    }
}

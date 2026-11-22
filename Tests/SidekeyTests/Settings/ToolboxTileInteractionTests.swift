import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Toolbox tiles must stay draggable (catalog -> hover, reorder in hover).
/// #400 added a press gesture to the tile and the user could no longer drag
/// tiles. A real drag cannot be tested: it starts a system drag session that
/// waits for the physical mouse. So the tile's gesture surface is pinned to
/// what coexists with `.draggable` (one tap), and press/hover/focus feedback
/// is checked on the observer that replaced the gesture.
// WHY: .project-docs/decisions/2026-11-22-toolbox-tile-drag.md
@MainActor
final class ToolboxTileInteractionTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func tileSource() throws -> Substring {
        let toolbox = try source("Sources/Sidekey/Settings/ToolboxSettingsView.swift")
        let start = try XCTUnwrap(toolbox.range(of: "struct ToolboxTileView: View {"))
        let end = try XCTUnwrap(toolbox.range(of: "final class ToolboxTilePointerTracker"))
        return toolbox[start.lowerBound..<end.lowerBound]
    }

    // MARK: - Drag stays possible

    func test_tile_has_no_gesture_that_competes_with_draggable() throws {
        let tile = try tileSource()
        for forbidden in ["simultaneousGesture", "highPriorityGesture", ".gesture(", "LongPressGesture",
                          "DragGesture", "@GestureState", "onLongPressGesture", "Button(",
                          "focusable(interactions:"] {
            XCTAssertFalse(tile.contains(forbidden), "ToolboxTileView must not use \(forbidden): it blocks .draggable")
        }
        XCTAssertEqual(tile.components(separatedBy: ".onTapGesture").count - 1, 1, "exactly one tap")
        XCTAssertTrue(tile.contains(".focusable()"), "the focus form that coexisted with .draggable before #400")
    }

    func test_catalog_and_hover_tiles_are_draggable_and_accepted() throws {
        let toolbox = try source("Sources/Sidekey/Settings/ToolboxSettingsView.swift")
        XCTAssertTrue(toolbox.contains("tile.draggable(tool.rawValue)"), "hover tiles reorder by drag")
        XCTAssertTrue(toolbox.contains(".draggable(tool.rawValue) {"), "catalog tiles drag onto hover")

        let defaults = UserDefaults(suiteName: "ToolboxTileInteractionTests.\(UUID().uuidString)")!
        let store = HoverLayoutStore(defaults: defaults)
        XCTAssertTrue(store.placeTool(.calendar, at: store.lockSlotIndex), "a catalog tool drops onto Add")
        XCTAssertTrue(store.placeTool(.calendar, at: 0), "a hover tool reorders")
        XCTAssertEqual(store.slots.first, .calendar)
    }

    // MARK: - Feedback without gestures

    func test_pointer_tracker_press_follows_the_button_and_hover() {
        let tracker = ToolboxTilePointerTracker()
        tracker.setHovering(true, installsMonitor: false)
        XCTAssertFalse(tracker.isPressed)
        tracker.observe(.leftMouseDown)
        XCTAssertTrue(tracker.isPressed)
        tracker.observe(.leftMouseUp)
        XCTAssertFalse(tracker.isPressed)

        // A drag session swallows the mouse up; leaving the tile resets it.
        tracker.observe(.leftMouseDown)
        tracker.setHovering(false)
        XCTAssertFalse(tracker.isPressed)
    }

    func test_click_focus_shows_no_ring_keyboard_focus_does() {
        let tracker = ToolboxTilePointerTracker()
        tracker.observe(.leftMouseDown)
        tracker.focusChanged(true)
        XCTAssertTrue(tracker.focusFromPointer, "a click's focus draws no ring")
        tracker.focusChanged(false)
        XCTAssertFalse(tracker.focusFromPointer)
        tracker.focusChanged(true)
        XCTAssertFalse(tracker.focusFromPointer, "Tab focus draws the ring")
    }

    func test_highlight_matches_mac_button() {
        XCTAssertEqual(ToolboxTileView.highlightOpacity(hovered: false, pressed: false), 0)
        XCTAssertEqual(ToolboxTileView.highlightOpacity(hovered: true, pressed: false), 0.10)
        XCTAssertEqual(ToolboxTileView.highlightOpacity(hovered: true, pressed: true), 0.18)
        XCTAssertEqual(ToolboxTileView.highlightOpacity(hovered: false, pressed: true), 0.18)
    }

    /// A click still selects. No `.draggable` here, so no drag session can
    /// start; the window is ordered far outside every display at zero opacity
    /// (SwiftUI only routes events to an ordered window) and is never key.
    func test_click_selects() throws {
        var taps = 0
        let tile = ToolboxTileView(title: "Notify", sfSymbol: "bell", isSelected: false, isLocked: false,
                                   isAdded: false, onTap: { taps += 1 })
            .padding(20)
        let host = NSHostingView(rootView: tile)
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 130)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 50, y: 82), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(taps, 1)
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a display")
    }
}

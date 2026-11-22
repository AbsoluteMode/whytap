import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The tile's press tint must not take the click from selection: a synthetic
/// mouse down/up still selects, the circle is tinted only while the button is
/// held, and a drag ends the press without selecting. SwiftUI gestures only
/// receive events in an ordered window, so the test orders one far outside
/// every display at zero opacity; it never becomes key or shows on screen.
// WHY: .project-docs/decisions/2026-11-22-toolbox-tool-hotkey.md
@MainActor
final class ToolboxTileInteractionTests: XCTestCase {
    private func host(onTap: @escaping () -> Void) -> (NSWindow, NSHostingView<AnyView>) {
        let tile = ToolboxTileView(title: "Notify", sfSymbol: "bell", isSelected: false, isLocked: false,
                                   isAdded: false, onTap: onTap)
            .padding(20)
            .background(MacSettingsTheme.bgCard)
        let host = NSHostingView(rootView: AnyView(tile))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 100, height: 130)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }

    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    private func circleColor(_ host: NSView) -> NSColor? {
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        // A point inside the circle, clear of the symbol (circle spans x 22...78, y 20...76 from top).
        let x = Int(Double(rep.pixelsWide) * 30 / 100), y = Int(Double(rep.pixelsHigh) * 48 / 130)
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    func test_click_selects_and_press_tints_only_while_held() throws {
        var taps = 0
        let (window, host) = host { taps += 1 }
        defer { window.close() }
        // Circle centre in window coordinates (origin bottom-left).
        let centre = NSPoint(x: 50, y: 130 - 48)
        let idle = try XCTUnwrap(circleColor(host))

        window.sendEvent(mouse(.leftMouseDown, at: centre, in: window))
        spin()
        let held = try XCTUnwrap(circleColor(host))
        window.sendEvent(mouse(.leftMouseUp, at: centre, in: window))
        spin()
        let released = try XCTUnwrap(circleColor(host))

        XCTAssertEqual(taps, 1, "the press gesture must not swallow the click")
        XCTAssertLessThan(held.brightnessComponent, idle.brightnessComponent - 0.02, "pressed tints the circle")
        XCTAssertEqual(released.brightnessComponent, idle.brightnessComponent, accuracy: 0.01, "release clears it")
        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a display")
    }

    func test_a_drag_ends_the_press_and_does_not_select() throws {
        var taps = 0
        let (window, host) = host { taps += 1 }
        defer { window.close() }
        let centre = NSPoint(x: 50, y: 130 - 48)
        let idle = try XCTUnwrap(circleColor(host))

        window.sendEvent(mouse(.leftMouseDown, at: centre, in: window))
        spin()
        window.sendEvent(mouse(.leftMouseDragged, at: NSPoint(x: centre.x + 12, y: centre.y), in: window))
        spin()
        let dragged = try XCTUnwrap(circleColor(host))
        window.sendEvent(mouse(.leftMouseUp, at: NSPoint(x: centre.x + 12, y: centre.y), in: window))
        spin()

        XCTAssertEqual(dragged.brightnessComponent, idle.brightnessComponent, accuracy: 0.01,
                       "moving past the slop clears the press tint")
        XCTAssertEqual(taps, 0, "a drag is not a click")
    }

    func test_highlight_matches_mac_button() {
        XCTAssertEqual(ToolboxTileView.highlightOpacity(hovered: false, pressed: false), 0)
        XCTAssertEqual(ToolboxTileView.highlightOpacity(hovered: true, pressed: false), 0.10)
        XCTAssertEqual(ToolboxTileView.highlightOpacity(hovered: true, pressed: true), 0.18)
        XCTAssertEqual(ToolboxTileView.highlightOpacity(hovered: false, pressed: true), 0.18)
    }
}

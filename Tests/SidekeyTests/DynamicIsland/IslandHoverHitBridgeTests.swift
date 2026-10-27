import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

final class IslandHoverHitBridgeTests: XCTestCase {
    private let frame = CGRect(x: 80, y: 120, width: 55, height: 72)
    private let center = CGPoint(x: 107, y: 156)

    private func target(owner: UUID = UUID(), tool: HoverTool = .outputLang,
                        context: String = "query:output", frame: CGRect? = nil) -> IslandHoverHitSnapshot {
        IslandHoverHitSnapshot(owner: owner, id: IslandHoverHitTargetID(surface: .result, tool: tool),
                               context: context, frame: frame ?? self.frame)
    }

    func testMatchingDownAndUpActivateExactlyOnce() {
        var tracking = IslandHoverPointerTracking()
        let result = target()
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        XCTAssertTrue(tracking.consumesSequence)
        XCTAssertEqual(tracking.captured?.id.tool, .outputLang)
        XCTAssertEqual(tracking.end(at: center, targets: [result], enabled: true), result.owner)
        XCTAssertFalse(tracking.consumesSequence)
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: true))
    }

    func testDraggingOutCancelsEvenIfPointerReturns() {
        var tracking = IslandHoverPointerTracking()
        let result = target()
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        tracking.move(at: CGPoint(x: 20, y: 20), targets: [result], enabled: true)
        XCTAssertNil(tracking.captured)
        XCTAssertTrue(tracking.consumesSequence, "A cancelled press still owns its mouse-up")
        tracking.move(at: center, targets: [result], enabled: true)
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: true))
    }

    func testUpOverDifferentToolNeverActivatesEitherTool() {
        var tracking = IslandHoverPointerTracking()
        let first = target()
        let other = target(tool: .monitor, frame: CGRect(x: 160, y: 120, width: 55, height: 72))
        XCTAssertTrue(tracking.begin(at: center, targets: [first, other], enabled: true))
        XCTAssertNil(tracking.end(at: CGPoint(x: 180, y: 155), targets: [first, other], enabled: true))
    }

    func testRemovedReplacedChangedOrMovedTargetCancelsPendingPress() {
        let original = target()
        let changedContext = target(owner: original.owner, context: "query:language")
        let replacement = target()
        let moved = target(owner: original.owner, frame: frame.offsetBy(dx: 0, dy: 5))
        for liveTargets in [[], [changedContext], [replacement], [moved]] {
            var tracking = IslandHoverPointerTracking()
            XCTAssertTrue(tracking.begin(at: center, targets: [original], enabled: true))
            XCTAssertNil(tracking.end(at: center, targets: liveTargets, enabled: true))
        }
    }

    func testClosedOrCancelledPanelCannotActivate() {
        let result = target()
        var tracking = IslandHoverPointerTracking()
        XCTAssertFalse(tracking.begin(at: center, targets: [result], enabled: false))
        XCTAssertFalse(tracking.begin(at: .zero, targets: [result], enabled: true))
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: false))
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        tracking.cancel()
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: true))
        XCTAssertTrue(tracking.begin(at: center, targets: [result], enabled: true))
        tracking.discardSequence()
        XCTAssertFalse(tracking.consumesSequence)
        XCTAssertNil(tracking.end(at: center, targets: [result], enabled: true))
    }

    func testScrollViewportClipsRowsAwayFromSearchAndFooter() {
        let viewport = CGRect(x: 20, y: 50, width: 300, height: 100)
        let partiallyVisible = CGRect(x: 30, y: 30, width: 280, height: 42)
        let clipped = IslandHoverHitGeometry.visibleFrame(target: partiallyVisible,
            visible: partiallyVisible, region: viewport)
        XCTAssertEqual(clipped, CGRect(x: 30, y: 50, width: 280, height: 22))
        XCTAssertFalse(clipped!.contains(CGPoint(x: 80, y: 40)), "Footer must not activate a clipped row")
        XCTAssertNil(IslandHoverHitGeometry.visibleFrame(target: CGRect(x: 30, y: 160, width: 280, height: 42),
            visible: CGRect(x: 30, y: 160, width: 280, height: 42), region: viewport))
    }

    @MainActor
    func testMeetingMagicUsesFirstMouseInToolsAndSearch() throws {
        for surface in [IslandHoverHitTargetID.Surface.tile, .result] {
            let bridge = IslandHoverHitBridge()
            bridge.setEnabled(true); bridge.setSurface(surface); bridge.setContext("session-off")
            var activations = 0
            let content = IslandMeetingAssistantControl(state: .init(available: true), setEnabled: { _ in activations += 1 },
                hitBridge: bridge, hitContext: "session-off").frame(width: 240, height: 44)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            host.frame = NSRect(x: 0, y: 0, width: 240, height: 44)
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertFalse(bridge.mouseDown(at: host.convert(NSPoint(x: 5, y: 22), to: nil), in: window, allowed: true),
                           "Outside the 28pt icon is not clickable")
            let point = host.convert(NSPoint(x: 120, y: 22), to: nil)
            XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
            bridge.mouseUp(at: point, in: window, allowed: true)
            XCTAssertEqual(activations, 1, "Bridge dispatches the magic icon once without opening the show-only tool")
            XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
            bridge.cancelPress(for: .meetingAssistant)
            bridge.mouseUp(at: point, in: window, allowed: true)
            XCTAssertEqual(activations, 1, "A state change cancels an old press")
        }
    }

    @MainActor
    func testAssistantPhaseChangePreservesOtherToolAndSearchPresses() {
        for surface in [IslandHoverHitTargetID.Surface.tile, .result] {
            let bridge = IslandHoverHitBridge()
            bridge.setEnabled(true); bridge.setSurface(surface); bridge.setContext("stable-geometry")
            var activations = 0
            let host = NSHostingView(rootView: Color.clear.frame(width: 240, height: 44)
                .islandHoverHitTarget(bridge: bridge, id: .init(surface: surface, tool: .settings),
                    context: "stable-geometry", action: { activations += 1 })
                .islandHoverHitRegion(bridge: bridge, surface: surface))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.close() }
            host.frame = NSRect(x: 0, y: 0, width: 240, height: 44)
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            let point = host.convert(NSPoint(x: 100, y: 22), to: nil)
            XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
            bridge.cancelPress(for: .meetingAssistant)
            bridge.mouseUp(at: point, in: window, allowed: true)
            XCTAssertEqual(activations, 1)
            bridge.setEnabled(false)
            XCTAssertFalse(bridge.mouseDown(at: point, in: window, allowed: true),
                           "Update's independent dispatch must not enable a disabled tools/search surface")
        }
    }

    @MainActor
    func testInternalFieldEditingEndDoesNotResignBeforeButtonMouseUp() {
        var focusChanges: [Bool] = []
        let field = IslandHoverSearchField(text: .constant("output"),
            onFocusChange: { focusChanges.append($0) }, onCommand: { _ in })
        let coordinator = field.makeCoordinator()
        coordinator.controlTextDidBeginEditing(Notification(name: NSText.didBeginEditingNotification))
        coordinator.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification))
        XCTAssertEqual(focusChanges, [true])
    }
}

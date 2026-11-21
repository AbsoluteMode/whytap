import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// In the island, clicks reach the window's first-mouse dispatcher
/// (IslandHoverHitBridge) before SwiftUI. The builder's review (queue ticket
/// 323) found the delete question's buttons unregistered there and the Back
/// button under the dimmed panel still taking the click.
/// WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
@MainActor
final class MonitorConfirmationHitTests: XCTestCase {
    private final class Calls { var back = 0, cancel = 0, confirm = 0 }

    private func host(showsCard: Bool, calls: Calls) -> (NSPanel, NSHostingView<AnyView>, IslandHoverHitBridge, MonitorStore) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = MonitorStore(root: directory, collector: { _ in throw CancellationError() })
        let bridge = IslandHoverHitBridge()
        bridge.setEnabled(true)
        bridge.setSurface(.navigation)
        bridge.setContext("monitor-test")
        let monitor = MonitorHoverPanel(store: store, onBack: { calls.back += 1 })
        let content = monitor.overlay {
            if showsCard {
                MonitorConfirmationCard(
                    message: MonitorDeletionConfirmation.question(title: "OpenAI"),
                    cancelTitle: "Cancel", confirmTitle: "Delete",
                    onCancel: { calls.cancel += 1 }, onConfirm: { calls.confirm += 1 })
            }
        }
        .environment(\.islandHoverNavigation, IslandHoverNavigationContext(bridge: bridge, context: "monitor-test"))
        .islandHoverHitRegion(bridge: bridge, surface: .navigation)
        let size = NSSize(width: 310, height: 290)
        let view = NSHostingView(rootView: AnyView(content))
        let window = NSPanel(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
        addTeardownBlock { @MainActor in
            store.stop()
            window.contentView = nil
            window.close()
        }
        return (window, view, bridge, store)
    }

    private func click(_ bridge: IslandHoverHitBridge, x: CGFloat, fromTop y: CGFloat,
                       view: NSView, window: NSWindow) -> Bool {
        let point = view.convert(NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y), to: nil)
        guard bridge.mouseDown(at: point, in: window, allowed: true) else { return false }
        bridge.mouseUp(at: point, in: window, allowed: true)
        return true
    }

    func testQuestionTakesTheClickAndBackUnderItDoesNot() {
        let calls = Calls()
        let (window, view, bridge, _) = host(showsCard: true, calls: calls)

        XCTAssertFalse(click(bridge, x: 26, fromTop: 23, view: view, window: window),
                       "Back under the question takes no click")
        XCTAssertEqual(calls.back, 0)

        // Sweep the card: both answers are reachable through the window's
        // dispatcher, and nothing else is.
        for y in stride(from: 60, through: 240, by: 4) {
            for x in stride(from: 20, through: 290, by: 4) {
                _ = click(bridge, x: CGFloat(x), fromTop: CGFloat(y), view: view, window: window)
            }
        }
        XCTAssertGreaterThan(calls.cancel, 0, "Cancel answers a native click")
        XCTAssertGreaterThan(calls.confirm, 0, "Delete answers a native click")
        XCTAssertEqual(calls.back, 0)
    }

    func testBackWorksAgainOnceTheQuestionIsGone() {
        let calls = Calls()
        let (window, view, bridge, _) = host(showsCard: false, calls: calls)
        XCTAssertTrue(click(bridge, x: 26, fromTop: 23, view: view, window: window))
        XCTAssertEqual(calls.back, 1)
        XCTAssertEqual(calls.cancel + calls.confirm, 0)
    }
}

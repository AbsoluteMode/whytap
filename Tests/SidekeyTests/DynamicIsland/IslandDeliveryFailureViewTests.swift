import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class IslandDeliveryFailureViewTests: XCTestCase {
    func testShortErrorsShrinkAndLongErrorsKeepBothActions() {
        let short = IslandDeliveryFailureView.faceWidth(message: "Failed")
        let normal = IslandDeliveryFailureView.faceWidth(message: IslandAgentFlowStore.deliveryFailedMessage)
        let long = IslandDeliveryFailureView.faceWidth(message: String(repeating: "Long error ", count: 40))
        XCTAssertLessThan(short, normal)
        XCTAssertLessThan(normal, IslandFrameLayout.agentWingDeliveryFailedWidth)
        XCTAssertEqual(long, IslandFrameLayout.agentWingDeliveryFailedWidth)
        XCTAssertGreaterThan(short, IslandDeliveryFailureView.retryWidth + IslandDeliveryFailureView.closeWidth)
    }

    func testFirstMouseSeparatesRetryCloseAndTextWithDrawerClosed() {
        let bridge = IslandHoverHitBridge()
        bridge.setEnabled(false); bridge.setSurface(.result); bridge.setContext("closed-drawer")
        var retries = 0, dismisses = 0
        let message = IslandAgentFlowStore.deliveryFailedMessage
        let width = IslandDeliveryFailureView.faceWidth(message: message)
        let host = NSHostingView(rootView: IslandDeliveryFailureView(message: message, height: 32,
            hitBridge: bridge, onRetry: { retries += 1 }, onDismiss: { dismisses += 1 }))
        let window = fixture(host: host, width: width)
        defer { window.close() }
        settle(host)
        let close = host.convert(NSPoint(x: width - 23, y: 16), to: nil)
        let retry = host.convert(NSPoint(x: width - 12 - 22 - 8 - IslandDeliveryFailureView.retryWidth / 2, y: 16), to: nil)
        let text = host.convert(NSPoint(x: 25, y: 16), to: nil)
        let gap = host.convert(NSPoint(x: width - 12 - 22 - 4, y: 16), to: nil)
        for point in [text, gap] { XCTAssertFalse(bridge.mouseDown(at: point, in: window, allowed: true)) }
        XCTAssertTrue(bridge.mouseDown(at: retry, in: window, allowed: true))
        bridge.mouseUp(at: retry, in: window, allowed: true)
        bridge.mouseUp(at: retry, in: window, allowed: true)
        XCTAssertEqual(retries, 1); XCTAssertEqual(dismisses, 0)
        XCTAssertTrue(bridge.mouseDown(at: close, in: window, allowed: true))
        bridge.mouseUp(at: close, in: window, allowed: true)
        XCTAssertEqual(retries, 1); XCTAssertEqual(dismisses, 1)
        XCTAssertTrue(bridge.mouseDown(at: retry, in: window, allowed: true))
        bridge.mouseDragged(at: close, in: window, allowed: true)
        bridge.mouseUp(at: close, in: window, allowed: true)
        XCTAssertEqual(retries, 1); XCTAssertEqual(dismisses, 1)
        XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
    }

    func testRemovedErrorAndDisabledActionsCannotActivate() {
        let bridge = IslandHoverHitBridge()
        bridge.setEnabled(false); bridge.setContext("fixture")
        var calls = 0
        let message = "Smart failed (503)"
        let width = IslandDeliveryFailureView.faceWidth(message: message)
        func content(visible: Bool, disabled: Bool) -> AnyView {
            if !visible { return AnyView(Color.clear.frame(width: width, height: 32)) }
            return AnyView(IslandDeliveryFailureView(message: message, height: 32,
                hitBridge: bridge, onRetry: { calls += 1 }, onDismiss: { calls += 1 }).disabled(disabled))
        }
        let host = NSHostingView(rootView: content(visible: true, disabled: false))
        let window = fixture(host: host, width: width)
        defer { window.close() }
        settle(host)
        let close = host.convert(NSPoint(x: width - 23, y: 16), to: nil)
        XCTAssertTrue(bridge.mouseDown(at: close, in: window, allowed: true))
        host.rootView = content(visible: false, disabled: false)
        settle(host)
        bridge.mouseUp(at: close, in: window, allowed: true)
        XCTAssertEqual(calls, 0)
        host.rootView = content(visible: true, disabled: true)
        settle(host)
        XCTAssertFalse(bridge.mouseDown(at: close, in: window, allowed: true))
        XCTAssertEqual(calls, 0)
    }

    func testRenderFailureStates() throws {
        guard let path = ProcessInfo.processInfo.environment["WHYTAP_DELIVERY_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_DELIVERY_RENDER_DIR for invisible native fixtures")
        }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, message) in [("offline", IslandAgentFlowStore.deliveryFailedMessage), ("smart", "Smart failed (503)")] {
            let width = IslandDeliveryFailureView.faceWidth(message: message)
            for disabled in [false, true] {
                let bridge = IslandHoverHitBridge()
                bridge.setEnabled(false); bridge.setContext("render")
                let host = NSHostingView(rootView: IslandDeliveryFailureView(message: message, height: 32,
                    hitBridge: bridge, onRetry: {}, onDismiss: {}).disabled(disabled).background(Color.black))
                let window = fixture(host: host, width: width)
                defer { window.close() }
                settle(host)
                for state in ["rest", "retry", "close"] {
                    if state != "rest" {
                        let x = state == "close" ? width - 23 : width - 42 - IslandDeliveryFailureView.retryWidth / 2
                        let captured = bridge.mouseDown(at: host.convert(NSPoint(x: x, y: 16), to: nil), in: window, allowed: true)
                        XCTAssertEqual(captured, !disabled)
                        settle(host)
                    }
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                        directory.appendingPathComponent("\(name)-\(disabled ? "disabled" : "enabled")-\(state).png"))
                    bridge.cancelPress()
                    settle(host)
                }
                XCTAssertFalse(window.isVisible); XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    private func fixture<Content: View>(host: NSHostingView<Content>, width: CGFloat) -> NSPanel {
        let window = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 32),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: 32)
        return window
    }

    private func settle<Content: View>(_ host: NSHostingView<Content>) {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

@MainActor
final class IslandHoverBackButtonTests: XCTestCase {
    func testTodoAndMonitorAcceptFirstClickAcrossTheirFullBackButtons() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let todo = TodoHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")))
        let monitor = MonitorStore(root: directory.appendingPathComponent("monitor"), collector: { _ in
            throw CancellationError()
        })
        defer { monitor.stop() }
        for width: CGFloat in [310, 360] {
            for tool in ["todo", "monitor"] {
                let bridge = makeBridge()
                var activations = 0
                let content = tool == "todo"
                    ? AnyView(TodoHoverView(model: todo, onBack: { activations += 1 }))
                    : AnyView(MonitorHoverPanel(store: monitor, onBack: { activations += 1 }))
                let (host, window) = host(content, bridge: bridge, size: NSSize(width: width, height: 290))
                defer { window.contentView = nil; window.close() }
                // Both the leading/trailing padding and the icon belong to Back.
                let xs: [CGFloat] = tool == "todo" ? [13, 28, 43] : [11, 54, 97]
                for x in xs {
                    let point = fromTop(x, 23, in: host)
                    let previous = activations
                    XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true), "\(tool) at \(x)")
                    XCTAssertEqual(activations, previous, "Navigation waits for mouse-up")
                    bridge.mouseUp(at: point, in: window, allowed: true)
                    XCTAssertEqual(activations, previous + 1)
                    bridge.mouseUp(at: point, in: window, allowed: true)
                    XCTAssertEqual(activations, previous + 1, "No duplicate activation")
                }
                XCTAssertFalse(bridge.mouseDown(at: fromTop(130, 23, in: host), in: window, allowed: true),
                               "The title beside Back is not a navigation target")
                XCTAssertFalse(window.isVisible || window.isKeyWindow)
            }
        }
    }

    func testChangedDestinationDisabledControlAndClosedPanelCancelPendingBack() {
        let bridge = makeBridge()
        var activations = 0
        func content(_ destination: String, enabled: Bool = true) -> AnyView {
            AnyView(IslandHoverBackButton(destination: destination, title: "Dashboards", width: 88) {
                activations += 1
            }.disabled(!enabled))
        }
        let (host, window) = host(content("monitor:one"), bridge: bridge, size: NSSize(width: 88, height: 26))
        defer { window.contentView = nil; window.close() }
        let point = fromTop(44, 13, in: host)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        host.rootView = wrap(content("monitor:two"), bridge: bridge)
        settle(host)
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(activations, 0, "An old press must not navigate the new dashboard")

        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        host.rootView = wrap(content("monitor:two", enabled: false), bridge: bridge)
        settle(host)
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(activations, 0)
        XCTAssertFalse(bridge.mouseDown(at: point, in: window, allowed: true))

        host.rootView = wrap(content("monitor:two"), bridge: bridge)
        settle(host)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.setEnabled(false)
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(activations, 0)
        XCTAssertFalse(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.setEnabled(true)
        bridge.setSurface(.tile)
        XCTAssertFalse(bridge.mouseDown(at: point, in: window, allowed: true), "Hidden submenu is inert in Tools")
    }

    func testDraggingOutEscapeAndContextChangesCancelBackButFreshRepeatedClicksWork() {
        let bridge = makeBridge()
        var activations = 0
        let content = AnyView(IslandHoverBackButton(destination: "calendar:agenda") { activations += 1 })
        let (host, window) = host(content, bridge: bridge, size: NSSize(width: 32, height: 26))
        defer { window.contentView = nil; window.close() }
        let point = fromTop(16, 13, in: host)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.mouseDragged(at: fromTop(-2, 13, in: host), in: window, allowed: true)
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(activations, 0)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.cancelPress() // The window's bare-Escape path.
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(activations, 0)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.setContext("replacement-panel")
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(activations, 0)
        bridge.setContext("fixture")
        for _ in 0..<8 {
            XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
            bridge.mouseUp(at: point, in: window, allowed: true)
        }
        XCTAssertEqual(activations, 8)
    }

    func testSubmenuDoesNotActivateLingeringMeetingMagicFromTools() {
        let bridge = makeBridge()
        var activations = 0
        let content = AnyView(IslandMeetingAssistantControl(state: .init(available: true),
            setEnabled: { _ in activations += 1 }, hitBridge: bridge, hitContext: "fixture")
            .frame(width: 240, height: 44))
        let (host, window) = host(content, bridge: bridge, size: NSSize(width: 240, height: 44))
        defer { window.contentView = nil; window.close() }
        let point = fromTop(120, 22, in: host)
        XCTAssertFalse(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.setSurface(.tile)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.setSurface(.navigation)
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertEqual(activations, 0, "Entering a submenu cancels the previous root control")
    }

    func testRenderBackStatesAndCompactPanels() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_BACK_RENDER_DIR"] else {
            throw XCTSkip("Set WHYTAP_BACK_RENDER_DIR for offscreen navigation fixtures")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let todo = TodoHoverModel(store: PlannerStore(url: directory.appendingPathComponent("planner.json")))
        let monitor = MonitorStore(root: directory.appendingPathComponent("monitor"), collector: { _ in throw CancellationError() })
        defer { monitor.stop() }
        for width: CGFloat in [310, 360] {
            for scheme in [ColorScheme.dark, .light] {
                for reduced in [false, true] {
                    try render(AnyView(TodoHoverView(model: todo, onBack: {})), width: width, scheme: scheme,
                        reduced: reduced, name: "todo", destination: destination)
                    try render(AnyView(MonitorHoverPanel(store: monitor, onBack: {})), width: width, scheme: scheme,
                        reduced: reduced, name: "monitor", destination: destination)
                }
            }
        }
        let states = AnyView(VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<5) { state in
                HStack {
                    Text(["Normal", "Hover", "Pressed", "Focus", "Disabled"][state]).frame(width: 70, alignment: .leading)
                    Label("Dashboards", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .semibold)).frame(width: 88, height: 26)
                        .background(IslandHoverBackSurface(hovered: state == 1 || state == 4,
                            pressed: state == 2 || state == 4, focused: state == 3 || state == 4, enabled: state != 4))
                        .opacity(state == 4 ? 0.42 : 1)
                }
            }
        }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.96)).padding(12))
        try render(states, width: 310, scheme: .dark, reduced: false, name: "states", destination: destination)
    }

    private func makeBridge() -> IslandHoverHitBridge {
        let bridge = IslandHoverHitBridge()
        bridge.setEnabled(true); bridge.setSurface(.navigation); bridge.setContext("fixture")
        return bridge
    }

    private func wrap(_ content: AnyView, bridge: IslandHoverHitBridge) -> AnyView {
        AnyView(content.environment(\.islandHoverNavigation, IslandHoverNavigationContext(bridge: bridge, context: "fixture"))
            .islandHoverHitRegion(bridge: bridge, surface: .navigation))
    }

    private func host(_ content: AnyView, bridge: IslandHoverHitBridge, size: NSSize) -> (NSHostingView<AnyView>, NSPanel) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: wrap(content, bridge: bridge))
        let window = NSPanel(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
        settle(host)
        return (host, window)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func fromTop(_ x: CGFloat, _ y: CGFloat, in host: NSView) -> NSPoint {
        host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
    }

    private func render(_ content: AnyView, width: CGFloat, scheme: ColorScheme, reduced: Bool,
                        name: String, destination: URL) throws {
        let view = AnyView(content.background(Color(white: 0.12))
            .environment(\.colorScheme, scheme)
            .transaction { if reduced { $0.animation = nil; $0.disablesAnimations = true } })
        let (host, window) = host(view, bridge: makeBridge(), size: NSSize(width: width, height: 290))
        defer { window.contentView = nil; window.close() }
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        settle(host)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
            destination.appendingPathComponent("\(name)-\(Int(width))-\(scheme)-reduced\(reduced).png"))
        XCTAssertFalse(window.isVisible || window.isKeyWindow)
    }
}

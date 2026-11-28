import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// REV 6: adding a tool must not make SwiftUI update the island inside the
/// click. A layout change in an animated transaction followed by another
/// change in a different transaction (the edit hold, the released press)
/// flushes the first one synchronously, so the new tile waits for that work
/// before its first frame. A view that observes the store and the bridge
/// counts its body evaluations: none may happen inside the add.
// WHY: .project-docs/decisions/2026-11-28-hover-drag-out-whole-tile.md
@MainActor
final class IslandHoverAddTransactionTests: XCTestCase {
    private final class Counter { var bodies = 0 }

    private struct Probe: View {
        @ObservedObject var store: HoverLayoutStore
        @ObservedObject var bridge: IslandHoverHitBridge
        let counter: Counter

        var body: some View {
            counter.bodies += 1
            return VStack(spacing: 0) {
                Text("\(store.slots.count) \(String(describing: bridge.editHold.phase))")
                Color.clear.frame(width: 120, height: 40)
                    .islandHoverHitTarget(bridge: bridge, id: .init(surface: .moreTools, tool: .filler),
                                          context: "more", action: { [bridge] in _ = bridge.pin(.filler) })
                    .opacity(bridge.pressedID == nil ? 1 : 0.5)
            }
            .islandHoverHitRegion(bridge: bridge, surface: .moreTools)
        }
    }

    private var suiteName = ""
    private var store: HoverLayoutStore!
    private var bridge: IslandHoverHitBridge!
    private var counter: Counter!
    private var window: NSWindow!
    private var host: NSView!

    override func setUp() async throws {
        suiteName = "IslandHoverAddTransactionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: [.inputLang, .notes, .monitor])
        bridge = IslandHoverHitBridge()
        bridge.layoutStore = store
        bridge.setEnabled(true)
        bridge.setSurface(.moreTools)
        bridge.setContext("more")
        counter = Counter()
        let hosting = NSHostingView(rootView: Probe(store: store, bridge: bridge, counter: counter))
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 80),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 120, height: 80)
        host = hosting
        settle()
    }

    override func tearDown() async throws {
        window.contentView = nil
        window.close()
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func settle() {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
    }

    private func bodies(during work: () -> Void) -> Int {
        let before = counter.bodies
        work()
        return counter.bodies - before
    }

    /// The harness itself: the old order (layout, then the hold) does make
    /// SwiftUI evaluate the island inside the call.
    func testTheProbeSeesASynchronousFlushWhenTransactionsAreMixed() {
        let flushed = bodies {
            withAnimation(IslandHoverHitBridge.reorderAnimation) { _ = store.pin(.filler) }
            bridge.objectWillChange.send()
        }
        XCTAssertGreaterThan(flushed, 0, "Mixed transactions are flushed inside the call")
    }

    func testAddingAToolUpdatesNothingInsideTheCall() {
        bridge.notePointer(inside: true)
        XCTAssertEqual(bodies { XCTAssertTrue(bridge.pin(.filler)) }, 0)
        XCTAssertTrue(store.slots.contains(.filler))
        XCTAssertTrue(bridge.editHold.holdsDrawer, "The hold still starts")
        settle()
        XCTAssertGreaterThan(counter.bodies, 0)
    }

    func testRemovingAToolUpdatesNothingInsideTheCall() {
        XCTAssertEqual(bodies { XCTAssertTrue(bridge.unpin(.notes)) }, 0)
        XCTAssertFalse(store.slots.contains(.notes))
    }

    /// The real click on a More row: the press is drawn, then the release
    /// adds the tool and clears the press in the same transaction.
    func testAClickOnAMoreRowAddsWithoutUpdatingInsideTheRelease() throws {
        let point = host.convert(NSPoint(x: 60, y: 20), to: nil)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        XCTAssertEqual(bridge.pressedID, .init(surface: .moreTools, tool: .filler))
        settle()
        XCTAssertEqual(bodies { bridge.mouseUp(at: point, in: window, allowed: true) }, 0)
        XCTAssertTrue(store.slots.contains(.filler))
        XCTAssertNil(bridge.pressedID, "The press is released with the add")
    }

    func testAnAddThatChangesNothingStillReleasesThePress() throws {
        XCTAssertTrue(bridge.pin(.filler))
        settle()
        let point = host.convert(NSPoint(x: 60, y: 20), to: nil)
        XCTAssertTrue(bridge.mouseDown(at: point, in: window, allowed: true))
        bridge.mouseUp(at: point, in: window, allowed: true)
        XCTAssertNil(bridge.pressedID)
        XCTAssertEqual(store.slots.filter { $0 == .filler }.count, 1)
    }
}

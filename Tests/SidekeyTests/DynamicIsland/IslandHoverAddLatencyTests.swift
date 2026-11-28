import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Adding a tool from More in the real island, mounted offscreen (never
/// shown): what the click costs on the main thread, the longest update while
/// the tile animates in, and frames at fixed moments, next to a reorder as
/// the reference. Opt-in: set WHYTAP_HOVER_MOTION_DIR.
@MainActor
final class IslandHoverAddLatencyTests: XCTestCase {
    private var suiteName = ""

    override func tearDown() async throws {
        if !suiteName.isEmpty { UserDefaults().removePersistentDomain(forName: suiteName) }
    }

    func testMeasureAddingFromMoreInTheRealIsland() throws {
        guard let output = ProcessInfo.processInfo.environment["WHYTAP_HOVER_MOTION_DIR"] else {
            throw XCTSkip("Set WHYTAP_HOVER_MOTION_DIR to measure adding a tool in the real island")
        }
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        suiteName = "IslandHoverAddLatencyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: [.inputLang, .notes, .meetingRecord, .hotkeys, .monitor, .vocab])
        let state = AppState()
        state.programmaticHoverExpansion = true
        let bridge = IslandHoverHitBridge()
        let size = NSSize(width: 700, height: 520)
        let hosting = NSHostingView(rootView: IslandView(appState: state, hoverHitBridge: bridge,
                                                         displayPreferences: DisplayPreferences(defaults: defaults),
                                                         hoverLayout: store)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(white: 0.32)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.contentView = nil; window.close() }
        pump(hosting, seconds: 0.8)
        bridge.setEnabled(true)

        func find(_ matches: (IslandHoverHitTargetID) -> Bool) -> CGPoint? {
            for y in stride(from: 4, to: size.height - 4, by: 6) {
                for x in stride(from: 4, to: size.width - 4, by: 6) {
                    let point = CGPoint(x: x, y: y)
                    if bridge.mouseDown(at: point, in: window, allowed: true), let id = bridge.pressedID, matches(id) {
                        bridge.cancelPress()
                        return point
                    }
                    bridge.cancelPress()
                }
            }
            return nil
        }
        // A real click: the press is drawn before the button comes up.
        func click(_ point: CGPoint) -> Double {
            _ = bridge.mouseDown(at: point, in: window, allowed: true)
            pump(hosting, seconds: 0.05)
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            bridge.mouseUp(at: point, in: window, allowed: true)
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
        }

        let toggle = try XCTUnwrap(find { $0 == .moreToolsToggle }, "The island offers More tools")
        _ = click(toggle)
        pump(hosting, seconds: 0.8)
        let row = try XCTUnwrap(find { $0.surface == .moreTools && $0.tool == .filler }, "More offers Filler")

        var report: [String] = []
        // 1. Add from More by a real click, measured.
        report.append(try measure("add-from-more (click)", host: hosting, change: {
            let cost = click(row)
            XCTAssertTrue(store.slots.contains(.filler))
            return String(format: "click handler %.1f ms", cost)
        }))
        let addedOrder = store.slots
        // Back, without animation, then frames of the same click.
        var plain = Transaction(); plain.disablesAnimations = true
        withTransaction(plain) { _ = store.unpin(.filler) }
        pump(hosting, seconds: 0.8)
        let rowAgain = try XCTUnwrap(find { $0.surface == .moreTools && $0.tool == .filler })
        try capture("add-from-more", host: hosting, destination: destination) { _ = click(rowAgain) }
        XCTAssertEqual(store.slots, addedOrder)
        pump(hosting, seconds: 0.8)
        // 2. The reorder reference in the same island.
        report.append(try measure("reorder (reference)", host: hosting, change: {
            withAnimation(IslandHoverHitBridge.reorderAnimation) { _ = store.placeTool(.vocab, at: 0) }
            return ""
        }))
        withTransaction(plain) { store.replaceEditableSlots(with: addedOrder) }
        pump(hosting, seconds: 0.8)
        try capture("reorder (reference)", host: hosting, destination: destination) {
            withAnimation(IslandHoverHitBridge.reorderAnimation) { _ = store.placeTool(.vocab, at: 0) }
        }

        // The first frame of each kind of edit, More open: medians of 6.
        func firstUpdate(_ change: () -> Void) -> Double {
            change()
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
        }
        var firsts: [String: [Double]] = [:]
        let spring = IslandHoverHitBridge.reorderAnimation
        for _ in 0..<6 {
            withTransaction(plain) { _ = store.unpin(.filler) }
            pump(hosting, seconds: 0.3)
            firsts["add", default: []].append(firstUpdate { withAnimation(spring) { _ = store.pin(.filler) } })
            pump(hosting, seconds: 0.4)
            firsts["remove", default: []].append(firstUpdate { withAnimation(spring) { _ = store.unpin(.filler) } })
            pump(hosting, seconds: 0.4)
            firsts["reorder", default: []].append(firstUpdate { withAnimation(spring) { _ = store.placeTool(.vocab, at: 0) } })
            pump(hosting, seconds: 0.4)
            withTransaction(plain) { _ = store.placeTool(.vocab, at: store.slots.count - 2) }
            pump(hosting, seconds: 0.2)
        }
        for (name, values) in firsts.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            report.append(String(format: "  first update, %@: median %.2f ms, max %.2f ms", name, sorted[sorted.count / 2], sorted.last ?? 0))
        }
        withTransaction(plain) { store.replaceEditableSlots(with: addedOrder) }
        pump(hosting, seconds: 0.3)

        // Where the click's time goes: repeated, the parts separately.
        func cost(_ work: () -> Void) -> Double {
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            work()
            return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6
        }
        var parts: [String: [Double]] = [:]
        for _ in 0..<8 {
            withTransaction(plain) { _ = store.unpin(.filler) }
            pump(hosting, seconds: 0.3)
            let rowNow = try XCTUnwrap(find { $0.surface == .moreTools && $0.tool == .filler })
            _ = bridge.mouseDown(at: rowNow, in: window, allowed: true)
            pump(hosting, seconds: 0.05)
            parts["release of the click (mouseUp, add)", default: []].append(cost { bridge.mouseUp(at: rowNow, in: window, allowed: true) })
            pump(hosting, seconds: 0.4)
            withTransaction(plain) { _ = store.unpin(.filler) }
            pump(hosting, seconds: 0.3)
            parts["bridge.pin", default: []].append(cost { _ = bridge.pin(.filler) })
            pump(hosting, seconds: 0.3)
            withTransaction(plain) { _ = store.unpin(.filler) }
            pump(hosting, seconds: 0.3)
            parts["withAnimation { store.pin } alone (write + persist)", default: []].append(cost {
                withAnimation(IslandHoverHitBridge.reorderAnimation) { _ = store.pin(.filler) } })
            pump(hosting, seconds: 0.3)
        }
        for (name, values) in parts.sorted(by: { $0.key < $1.key }) {
            let sorted = values.sorted()
            report.append(String(format: "  %@: median %.2f ms, max %.2f ms", name, sorted[sorted.count / 2], sorted.last ?? 0))
        }

        let text = report.joined(separator: "\n") + "\n"
        try text.write(to: destination.appendingPathComponent("add-latency-report.txt"), atomically: true, encoding: .utf8)
        print(text)
    }

    private func pump(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
    }

    private func measure(_ name: String, host: NSView, change: () -> String) throws -> String {
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let start = Date()
        var longest = 0.0, first = 0.0
        var steps = 0
        let note = change()
        while Date().timeIntervalSince(start) < 0.5 {
            let stepStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let step = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - stepStart) / 1e6
            if steps == 0 { first = step }
            longest = max(longest, step)
            steps += 1
        }
        let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1e6
        return String(format: "%@: %@; first update %.1f ms, longest update %.1f ms, main-thread CPU %.1f ms over 500 ms, %d updates",
                      name, note, first, longest, cpu, steps)
    }

    /// Frames at fixed moments after the change, cropped to the drawer.
    private func capture(_ name: String, host: NSView, destination: URL, change: () -> Void) throws {
        let moments: [Double] = [0, 0.016, 0.033, 0.05, 0.083, 0.12, 0.2, 0.35]
        var frames: [NSBitmapImageRep] = []
        let start = Date()
        change()
        for moment in moments {
            while Date().timeIntervalSince(start) < moment {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 480))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
            }
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            frames.append(rep)
        }
        let crop = NSRect(x: 150, y: 0, width: 400, height: 520)
        let strip = NSImage(size: NSSize(width: crop.width * CGFloat(frames.count), height: crop.height))
        strip.lockFocus()
        for (index, frame) in frames.enumerated() {
            frame.draw(in: NSRect(x: CGFloat(index) * crop.width, y: 0, width: crop.width, height: crop.height),
                       from: crop, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        strip.unlockFocus()
        let data = try XCTUnwrap(strip.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        try data.write(to: destination.appendingPathComponent("\(name).png"))
    }
}

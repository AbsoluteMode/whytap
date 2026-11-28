import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// The Smart/Fast switch animates the tile symbol and the island's
/// ON Smart/Fast status every time, from a click and from the hotkey. Before,
/// the status popped in, the symbol only crossfaded when a click's press
/// spring happened to carry it, and a hotkey switch cut it.
/// The real island is mounted offscreen (never shown) and captured frame by
/// frame; a frame that differs from both the start and the end is a frame of
/// the transition.
// WHY: .project-docs/decisions/2026-11-28-drop-mode-switch-motion.md
@MainActor
final class IslandDropModeSwitchMotionTests: XCTestCase {
    private struct Mounted {
        let state: AppState
        let prefs: UserPreferencesCache
        let bridge: IslandHoverHitBridge
        let window: NSWindow
        let host: NSView
        let press: CGPoint
        let rep: NSBitmapImageRep
        let tileRect: CGRect
        let bandRect: CGRect
    }

    private struct Frame { let tile: [UInt8]; let band: [UInt8] }

    func testSwitchAnimationHonorsReduceMotion() {
        XCTAssertNil(IslandDropModeControl.switchAnimation(reduceMotion: true))
        XCTAssertNotNil(IslandDropModeControl.switchAnimation(reduceMotion: false))
    }

    func testEveryClickAnimatesTheSymbolAndTheStatus() throws {
        let island = try mount()
        for round in 0..<3 {
            let before = island.prefs.currentMode
            let (tile, band) = try transition(island) {
                XCTAssertTrue(island.bridge.mouseDown(at: island.press, in: island.window, allowed: true))
                RunLoop.main.run(until: Date().addingTimeInterval(0.09))
            } change: {
                island.bridge.mouseUp(at: island.press, in: island.window, allowed: true)
            }
            XCTAssertNotEqual(island.prefs.currentMode, before, "round \(round) switched")
            XCTAssertGreaterThan(tile, 0, "round \(round): the symbol changes through intermediate frames")
            XCTAssertGreaterThan(band, 0, "round \(round): ON Smart/Fast enters through intermediate frames")
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
    }

    func testTheHotkeySwitchAnimatesTheSymbolToo() throws {
        let island = try mount()
        let next = IslandDropModeControl.nextMode(after: island.prefs.currentMode)
        let (tile, band) = try transition(island) {} change: {
            island.prefs.setMode(next)
            island.state.publishDropModeHotkeyToggle(next)
        }
        XCTAssertGreaterThan(tile, 0, "No press spring here: the symbol animates on its own")
        XCTAssertGreaterThan(band, 0)
    }

    // MARK: - Harness

    private func mount() throws -> Mounted {
        let suite = "IslandDropModeSwitchMotionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let prefs = UserPreferencesCache(defaults: defaults)
        let store = HoverLayoutStore(defaults: defaults)
        store.replaceEditableSlots(with: [.dropMode, .notes, .inputLang, .settings])
        var actions = IslandActions.noOp
        actions.currentDropMode = { prefs.currentMode }
        actions.toggleDropMode = {
            let next = IslandDropModeControl.nextMode(after: prefs.currentMode)
            prefs.setMode(next)
            return next
        }
        let state = AppState()
        state.programmaticHoverExpansion = true
        let bridge = IslandHoverHitBridge()
        let host = NSHostingView(rootView: IslandView(appState: state, hoverHitBridge: bridge, actions: actions,
                                                      displayPreferences: DisplayPreferences(defaults: defaults),
                                                      hoverLayout: store)
            .frame(width: 700, height: 430, alignment: .top))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 430),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { await MainActor.run { window.close() } }
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.025)) }
        bridge.setEnabled(true)
        var found: CGPoint?
        search: for y in stride(from: 4, to: 426, by: 6) {
            for x in stride(from: 4, to: 696, by: 6) {
                let candidate = CGPoint(x: x, y: y)
                let hit = bridge.mouseDown(at: candidate, in: window, allowed: true) && bridge.pressedID?.tool == .dropMode
                bridge.discardSequence()
                if hit { found = candidate; break search }
            }
        }
        let press = try XCTUnwrap(found, "The island offers the Drop Mode tile")
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        let scale = Double(rep.pixelsWide) / host.bounds.width
        let local = host.convert(press, from: nil)
        let top = host.isFlipped ? local.y : host.bounds.height - local.y
        // The first hit is the tile's lower left corner; its icon sits just inside.
        let tileRect = CGRect(x: (local.x - 2) * scale, y: (top - 50) * scale, width: 44 * scale, height: 52 * scale)
        let bandRect = CGRect(x: 0, y: 0, width: host.bounds.width * scale, height: 40 * scale)
        return Mounted(state: state, prefs: prefs, bridge: bridge, window: window, host: host, press: press,
                       rep: rep, tileRect: tileRect, bandRect: bandRect)
    }

    private func grab(_ island: Mounted) -> Frame {
        island.host.layoutSubtreeIfNeeded()
        island.host.cacheDisplay(in: island.host.bounds, to: island.rep)
        func bytes(_ rect: CGRect) -> [UInt8] {
            guard let image = island.rep.cgImage?.cropping(to: rect) else { return [] }
            let out = NSBitmapImageRep(cgImage: image)
            return Array(UnsafeBufferPointer(start: out.bitmapData, count: out.bytesPerRow * out.pixelsHigh))
        }
        return Frame(tile: bytes(island.tileRect), band: bytes(island.bandRect))
    }

    /// Intermediate frames of the tile and the band during 0.7 s after `change`.
    private func transition(_ island: Mounted, prepare: () -> Void, change: () -> Void) throws -> (Int, Int) {
        prepare()
        let initial = grab(island)
        change()
        var frames: [Frame] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 0.7 {
            frames.append(grab(island))
            RunLoop.main.run(until: Date().addingTimeInterval(0.008))
        }
        let final = try XCTUnwrap(frames.last)
        func distance(_ a: [UInt8], _ b: [UInt8]) -> Int {
            guard a.count == b.count else { return .max }
            var sum = 0
            for i in stride(from: 0, to: a.count, by: 4) { sum += abs(Int(a[i]) - Int(b[i])) + abs(Int(a[i + 1]) - Int(b[i + 1])) }
            return sum
        }
        func intermediate(_ part: KeyPath<Frame, [UInt8]>) -> Int {
            frames.dropLast().filter {
                distance($0[keyPath: part], initial[keyPath: part]) > 2000 && distance($0[keyPath: part], final[keyPath: part]) > 2000
            }.count
        }
        XCTAssertGreaterThan(distance(initial.tile, final.tile), 2000, "The symbol changed")
        return (intermediate(\.tile), intermediate(\.band))
    }
}

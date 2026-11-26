import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// Lil Bro moving over the real Settings window, drawn offscreen with real
/// time: his steps must not re-render the window under him, and the balloon
/// must not jump once it is drawn.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
@MainActor
final class LilBroSmoothnessTests: XCTestCase {
    private final class Host {
        let host: NSHostingView<AnyView>
        let window: NSWindow
        init(_ view: some View, size: NSSize = NSSize(width: 960, height: 560)) {
            host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, .light)))
            host.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
        }
        func turn(_ seconds: TimeInterval = 0.02) async {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }
        func close() { window.contentView = nil; window.close() }
    }

    private func moving(_ fixture: FeaturesFixture, _ selection: SettingsWindowSelection) -> LilBroController {
        LilBroController(selection: selection, preferences: LilBroPreferences(defaults: fixture.defaults),
                         remote: nil, reduceMotion: { false })
    }

    func test_his_steps_do_not_redraw_the_settings_window() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = moving(fixture, selection)
        let window = Host(fixture.shell(selection: selection, lilBro: lilBro))
        defer { window.close() }
        for _ in 0..<15 { await window.turn() }
        XCTAssertTrue(lilBro.placed)
        let home = try XCTUnwrap(lilBro.map.home)

        // 1. A stroll along his entry.
        SettingsWindowView.shellEvaluations = 0
        LilBroMascot.movingFrames = 0
        let from = lilBro.feet.x
        lilBro.stroll(to: CGPoint(x: home.maxX - 20, y: home.minY + 1))
        let start = Date()
        while Date().timeIntervalSince(start) < 2.5 { await window.turn(0.008) }
        let strollRenders = SettingsWindowView.shellEvaluations
        let movingFrames = LilBroMascot.movingFrames
        let moved = lilBro.feet.x

        // 2. One state change applied to the window, timed.
        var times: [Double] = []
        SettingsWindowView.shellEvaluations = 0
        for _ in 0..<60 {
            lilBro.hovering.toggle()
            let t = CFAbsoluteTimeGetCurrent()
            await window.turn(0)
            window.host.displayIfNeeded()
            times.append((CFAbsoluteTimeGetCurrent() - t) * 1000)
        }
        let toggleRenders = SettingsWindowView.shellEvaluations
        times.sort()
        XCTAssertGreaterThan(moved, from, "he strolled")
        XCTAssertGreaterThan(movingFrames, 0, "he was drawn while moving")
        XCTAssertEqual(strollRenders, 0, "a stroll redraws only his layer, never the window")
        XCTAssertEqual(toggleRenders, 0, "a change of his state redraws only his layer")
        let line = String(format: "LILBRO-MEASURE moved=%.0f->%.0f moving_frames=%d stroll_shell_renders=%d toggles=60 toggle_shell_renders=%d median_ms=%.2f p90_ms=%.2f",
                          from, moved, movingFrames, strollRenders, toggleRenders, times[30], times[54])
        print(line)
        try? line.write(toFile: (ProcessInfo.processInfo.environment["LILBRO_MEASURE_OUT"] ?? "/dev/null"),
                        atomically: true, encoding: .utf8)
    }

    func test_guided_to_drop_the_balloon_opens_in_place_and_stays() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        selection.select(.hotkeys)
        let lilBro = moving(fixture, selection)
        let window = Host(fixture.shell(selection: selection, lilBro: lilBro))
        defer { window.close() }
        for _ in 0..<15 { await window.turn() }
        lilBro.toggleFromSidebar()
        for _ in 0..<10 { await window.turn() }
        XCTAssertEqual(lilBro.bubble, .full)
        SettingsWindowView.shellEvaluations = 0
        LilBroMascot.movingFrames = 0
        LilBroLayer.balloonPlaces = []
        var movingTime: TimeInterval = 0
        lilBro.ask("Set up dictation")
        let start = Date()
        var last = Date()
        var balloonSeen: Date?
        while Date().timeIntervalSince(start) < 12 {
            await window.turn(0.004)
            let now = Date()
            if lilBro.segment != nil { movingTime += now.timeIntervalSince(last) }
            last = now
            // Only the balloon he opens at Drop counts.
            if lilBro.bubble != .full { LilBroLayer.balloonPlaces = [] }
            if lilBro.bubble == .full, balloonSeen == nil { balloonSeen = now }
            if let seen = balloonSeen, now.timeIntervalSince(seen) > 1.5 { break }
        }
        XCTAssertEqual(lilBro.bubble, .full)
        XCTAssertEqual(selection.shownFeature, .drop)
        let places = LilBroLayer.balloonPlaces
        var distinct: [CGRect] = []
        for p in places where distinct.last != p { distinct.append(p) }
        let jumps = zip(distinct, distinct.dropFirst()).map { max(abs($0.minX - $1.minX), abs($0.minY - $1.minY)) }
        let line = String(format: "LILBRO-GUIDE moving_s=%.2f moving_frames=%d fps=%.0f shell_renders=%d balloon_evals=%d balloon_places=%d jumps_pt=%@ proposal=%@",
                          movingTime, LilBroMascot.movingFrames, Double(LilBroMascot.movingFrames) / max(0.01, movingTime),
                          SettingsWindowView.shellEvaluations, places.count, distinct.count,
                          jumps.map { String(format: "%.0f", $0) }.joined(separator: ","),
                          lilBro.proposal == nil ? "none" : "yes")
        print(line)
        XCTAssertEqual(distinct.count, 1, "the balloon is drawn once where it belongs, never moved: \(jumps)")
        XCTAssertLessThanOrEqual(SettingsWindowView.shellEvaluations, 4,
                                 "only the two screen changes on his way redraw the window")
        XCTAssertNotNil(lilBro.proposal, "the one action is in place when the balloon opens")
        try? line.write(toFile: (ProcessInfo.processInfo.environment["LILBRO_GUIDE_OUT"] ?? "/dev/null"),
                        atomically: true, encoding: .utf8)
    }
}

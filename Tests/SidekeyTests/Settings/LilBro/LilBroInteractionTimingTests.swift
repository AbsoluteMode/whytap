import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// What the person feels with Lil Bro, timed on the real Settings shell drawn
/// offscreen: the main-thread work to show one hover change, one balloon
/// opening and one typed character, through the real text field.
// WHY: .project-docs/decisions/2026-11-24-lil-bro.md
@MainActor
final class LilBroInteractionTimingTests: XCTestCase {
    private func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in
            if let field = sub as? NSTextField { return [field] }
            return textFields(in: sub)
        }
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
    private func p90(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, values.count * 9 / 10)] }

    func test_hover_opening_and_typing_stay_within_a_frame() async throws {
        let fixture = try await FeaturesFixture(.freshInstall)
        defer { fixture.cleanUp() }
        let selection = SettingsWindowSelection()
        let lilBro = LilBroController(selection: selection, preferences: LilBroPreferences(defaults: fixture.defaults),
                                      remote: nil, reduceMotion: { true })
        let size = NSSize(width: 960, height: 560)
        let host = NSHostingView(rootView: fixture.shell(selection: selection, lilBro: lilBro)
            .environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func turn(_ seconds: TimeInterval = 0.02) async {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
        }
        /// The work to show one change: SwiftUI's update, layout and drawing.
        func apply(_ change: () -> Void) -> Double {
            change()
            let start = CFAbsoluteTimeGetCurrent()
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }
        for _ in 0..<15 { await turn() }
        XCTAssertTrue(lilBro.placed)

        SettingsWindowView.shellEvaluations = 0
        var hover: [Double] = []
        for _ in 0..<40 {
            hover.append(apply { lilBro.hovering.toggle() })
            await turn(0.005)
        }

        XCTAssertEqual(SettingsWindowView.shellEvaluations, 0, "hovering him redraws only his layer")
        var opening: [Double] = []
        for _ in 0..<12 {
            opening.append(apply { lilBro.toggleFromSidebar() })
            await turn(0.05)
            XCTAssertEqual(lilBro.bubble, .full)
            lilBro.toggleFromSidebar()
            for _ in 0..<10 { await turn() }
        }

        lilBro.toggleFromSidebar()
        for _ in 0..<10 { await turn() }
        let field = try XCTUnwrap(textFields(in: host).first { $0.placeholderString == LilBroCopy.placeholder },
                                  "the reply field is a real text field")
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        SettingsWindowView.shellEvaluations = 0
        LilBroLayer.evaluations = 0
        var typing: [Double] = []
        for character in "how do i use meeting notes" {
            typing.append(apply { editor.insertText(String(character), replacementRange: editor.selectedRange()) })
            await turn(0.005)
        }
        XCTAssertEqual(field.stringValue, "how do i use meeting notes")
        XCTAssertEqual(SettingsWindowView.shellEvaluations, 0, "typing never redraws the window")
        XCTAssertEqual(LilBroLayer.evaluations, 0, "typing redraws the field only, not Lil Bro or his balloon")
        // A frame at 60 Hz; offscreen on an M-series Mac these take about 1 ms.
        XCTAssertLessThan(median(hover), 16)
        XCTAssertLessThan(median(typing), 16)

        let line = String(format: "LILBRO-INTERACT hover_med=%.2f hover_p90=%.2f open_med=%.2f open_p90=%.2f type_med=%.2f type_p90=%.2f",
                          median(hover), p90(hover), median(opening), p90(opening), median(typing), p90(typing))
        print(line)
        try? line.write(toFile: ProcessInfo.processInfo.environment["LILBRO_INTERACT_OUT"] ?? "/dev/null",
                        atomically: true, encoding: .utf8)
    }
}

import AppKit
@testable import Sidekey
import XCTest

/// Real mouse events on the overlay panel, placed far outside every screen
/// (it never shows and never takes focus from the user's apps).
@MainActor
final class SubtitleOverlayCloseTests: XCTestCase {
    private func click(_ panel: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                           clickCount: 1, pressure: 1)
            panel.sendEvent(try! XCTUnwrap(event))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// A session with pairs, stopped, in a 760 x 190 pt overlay off screen.
    private func stoppedOverlay() async throws -> (TranslationWindowController, LiveSubtitleModel) {
        let speech = FakeSpeechTranslation()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in speech })
        model.sourceCode = "en"
        model.targetCode = "ru"
        let controller = TranslationWindowController(
            textModel: TextTranslationModel(makeService: { FixtureTranslator() }), subtitleModel: model,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "subtitle-close-\(UUID())")),
            openSettings: { _ in }, activityChanged: { _ in })
        model.start()
        for _ in 0..<200 where model.phase != .listening { try await Task.sleep(for: .milliseconds(5)) }
        speech.yieldRecorded(until: 20_000)
        for _ in 0..<200 where model.lines.count < 3 { try await Task.sleep(for: .milliseconds(5)) }
        model.stop()
        for _ in 0..<400 where model.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        controller.presentation.mode = .subtitles
        controller.resize(for: .subtitles)
        controller.window.setFrame(NSRect(x: -20_000, y: -20_000, width: 760, height: 190), display: false)
        controller.window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        return (controller, model)
    }

    /// × and Start take their click in the panel's `sendEvent`, from the
    /// frames their views measured: the first-mouse bridge to SwiftUI can drop
    /// a click on an inactive app's non-key panel.
    func testTheWindowDispatchesCloseAndStartFromTheMeasuredFrames() async throws {
        let (controller, model) = try await stoppedOverlay()
        let panel = controller.window
        XCTAssertFalse(panel.isKeyWindow)
        let close = try XCTUnwrap(controller.hitTargets.frame(of: .close, in: panel))
        let start = try XCTUnwrap(controller.hitTargets.frame(of: .session, in: panel))
        XCTAssertGreaterThanOrEqual(close.width, 28, "× has a 28 pt target")
        XCTAssertFalse(close.intersects(start))
        // A press that leaves the button does nothing.
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: close.midX, y: close.midY),
                                                    modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let away = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 100, y: 20),
                                                    modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(controller.hitTargets.handle(down, in: panel))
        XCTAssertTrue(controller.hitTargets.handle(away, in: panel))
        XCTAssertTrue(panel.isVisible)
        // Start, then × closes.
        click(panel, at: NSPoint(x: start.midX, y: start.midY))
        XCTAssertTrue(model.phase.isRunning, "Start began a session")
        model.cancel()
        try await Task.sleep(for: .milliseconds(200))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let closeAgain = try XCTUnwrap(controller.hitTargets.frame(of: .close, in: panel))
        click(panel, at: NSPoint(x: closeAgain.midX, y: closeAgain.midY))
        XCTAssertFalse(panel.isVisible, "× closed the overlay")
        panel.orderOut(nil)
    }

    /// The running overlay keeps its controls a moment after hover ends, so
    /// a press that loses hover still reaches Stop or ×.
    func testTheRunningControlsOutlastAShortLossOfHover() {
        XCTAssertGreaterThanOrEqual(TranslationView.controlsLinger, .milliseconds(500))
    }
}

import AppKit
import SwiftUI
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

    /// A press acts only on the button view, action and frame it began on,
    /// and only while the panel is shown.
    func testAPressActsOnlyOnTheActionItBeganOnWhileThePanelShows() throws {
        final class Probe: ObservableObject {
            @Published var action = "stop"
            var fired: [String] = []
        }
        let probe = Probe()
        let targets = SubtitleOverlayHitTargets()
        struct Buttons: View {
            @ObservedObject var probe: Probe
            let targets: SubtitleOverlayHitTargets
            var body: some View {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 80, height: 40)
                        .background(SubtitleOverlayHitReporter(control: .session, targets: targets, action: probe.action,
                                                               activate: { [action = probe.action] in probe.fired.append(action) }))
                    Color.clear.frame(width: 40, height: 40)
                        .background(SubtitleOverlayHitReporter(control: .close, targets: targets, action: "close",
                                                               activate: { probe.fired.append("close") }))
                }
            }
        }
        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: Buttons(probe: probe, targets: targets))
        panel.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 20), modifierFlags: [], timestamp: 0,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }

        // An ordinary click acts once, and the press shows while held.
        XCTAssertTrue(targets.handle(event(.leftMouseDown, 40), in: panel))
        XCTAssertEqual(targets.pressed, .session)
        XCTAssertTrue(targets.handle(event(.leftMouseUp, 40), in: panel))
        XCTAssertEqual(probe.fired, ["stop"])
        XCTAssertNil(targets.pressed)

        // Stop pressed, the button turns into Start under the pointer: nothing fires.
        XCTAssertTrue(targets.handle(event(.leftMouseDown, 40), in: panel))
        probe.action = "start"
        settle()
        XCTAssertNil(targets.pressed, "the press ended when its action changed")
        XCTAssertTrue(targets.handle(event(.leftMouseUp, 40), in: panel), "its mouse-up is still consumed")
        XCTAssertEqual(probe.fired, ["stop"])

        // Leaving the button ends the press, even if the pointer comes back.
        XCTAssertTrue(targets.handle(event(.leftMouseDown, 100), in: panel))
        XCTAssertTrue(targets.handle(event(.leftMouseDragged, 10), in: panel))
        XCTAssertTrue(targets.handle(event(.leftMouseDragged, 100), in: panel))
        XCTAssertTrue(targets.handle(event(.leftMouseUp, 100), in: panel))
        XCTAssertEqual(probe.fired, ["stop"])

        // × pressed, then the panel hides before the mouse-up: nothing fires.
        XCTAssertTrue(targets.handle(event(.leftMouseDown, 100), in: panel))
        panel.orderOut(nil)
        XCTAssertTrue(targets.handle(event(.leftMouseUp, 100), in: panel))
        XCTAssertEqual(probe.fired, ["stop"])
        // A hidden panel takes no new press.
        XCTAssertFalse(targets.handle(event(.leftMouseDown, 100), in: panel))
    }

    /// The build queue's #484 case: a press begun on Start, the model started
    /// by something else, the mouse-up before SwiftUI redraws the button.
    /// Releasing it never runs Stop; a held Stop never stops a newer session.
    func testAPressBegunOnStartNeverStopsASessionStartedMeanwhile() async throws {
        let speech = FakeSpeechTranslation()
        let model = LiveSubtitleModel(makeAudio: { FixtureSubtitleAudio() }, openTranslator: { _, _ in speech })
        let controller = TranslationWindowController(
            textModel: TextTranslationModel(makeService: { FixtureTranslator() }), subtitleModel: model,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "subtitle-press-phase-\(UUID())")),
            openSettings: { _ in }, activityChanged: { _ in })
        controller.presentation.mode = .subtitles
        controller.resize(for: .subtitles)
        let panel = controller.window
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 760, height: 190), display: false)
        panel.orderFrontRegardless()
        defer { controller.dismiss() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        panel.contentView?.layoutSubtreeIfNeeded()
        let start = try XCTUnwrap(controller.hitTargets.frame(of: .session, in: panel))
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.midX, y: start.midY),
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                             clickCount: 1, pressure: 1))
        }
        panel.sendEvent(try mouse(.leftMouseDown))
        XCTAssertEqual(controller.hitTargets.pressed, .session)
        XCTAssertNotNil(model.start())
        XCTAssertEqual(model.phase, .connecting)
        panel.sendEvent(try mouse(.leftMouseUp))
        XCTAssertEqual(model.phase, .connecting, "releasing a press begun on Start ran Stop")

        // A Stop drawn for one session leaves a newer one running.
        let old = model.sessionID
        await model.cancel().value
        XCTAssertNotNil(model.start())
        model.stop(session: old)
        XCTAssertTrue(model.phase.isRunning, "a stale Stop stopped the new session")
        await controller.cancel().value
    }

    /// The running overlay keeps its controls a moment after hover ends, so
    /// a press that loses hover still reaches Stop or ×.
    func testTheRunningControlsOutlastAShortLossOfHover() {
        XCTAssertGreaterThanOrEqual(TranslationView.controlsLinger, .milliseconds(500))
    }
}

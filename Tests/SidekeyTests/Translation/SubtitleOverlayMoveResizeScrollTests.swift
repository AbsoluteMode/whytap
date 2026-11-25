import AppKit
import SwiftUI
@testable import Sidekey
import XCTest

/// The subtitle overlay as the user handles it: dragged anywhere, resized by
/// its edges and corners, back where it was after a relaunch (or at the usual
/// place when its display is gone), and scrolled back through the session
/// while new pairs keep arriving. Real mouse and scroll events go to the panel
/// far outside every screen: it never shows and never takes focus.
// WHY: .project-docs/decisions/2026-11-25-subtitle-overlay-move-resize-scroll.md
@MainActor
final class SubtitleOverlayMoveResizeScrollTests: XCTestCase {
    /// A display far off the real ones, where the test panel lives.
    private let display = NSRect(x: -21_000, y: -21_000, width: 4_000, height: 3_000)
    private let start = NSRect(x: -20_000, y: -20_000, width: 760, height: 190)

    // MARK: Geometry

    func testEdgesAndCornersResizeAndTheInsideMoves() {
        let size = NSSize(width: 760, height: 190)
        typealias Handle = SubtitleOverlayFrame.Handle
        XCTAssertNil(SubtitleOverlayFrame.handle(at: NSPoint(x: 380, y: 95), in: size), "inside the box moves it")
        XCTAssertNil(SubtitleOverlayFrame.handle(at: NSPoint(x: 800, y: 95), in: size), "outside the panel is not ours")
        XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: 2, y: 95), in: size), Handle(horizontal: -1, vertical: 0))
        XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: 755, y: 95), in: size), Handle(horizontal: 1, vertical: 0),
                       "the margin and a few points inside the box's edge")
        XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: 380, y: 187), in: size), Handle(horizontal: 0, vertical: 1))
        XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: 380, y: 4), in: size), Handle(horizontal: 0, vertical: -1))
        XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: 3, y: 186), in: size), Handle(horizontal: -1, vertical: 1))
        XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: 756, y: 20), in: size), Handle(horizontal: 1, vertical: -1),
                       "along an edge near a corner: both ways")
        XCTAssertNil(SubtitleOverlayFrame.handle(at: NSPoint(x: 30, y: 95), in: size), "past the grip the box moves")
    }

    func testResizingKeepsTheOppositeEdgesAndStopsAtTheMinimumAndTheScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let frame = NSRect(x: 340, y: 72, width: 760, height: 190)
        let right = SubtitleOverlayFrame.resized(frame, handle: .init(horizontal: 1, vertical: 0),
                                                 by: CGVector(dx: 120, dy: 40), within: screen)
        XCTAssertEqual(right, NSRect(x: 340, y: 72, width: 880, height: 190), "an edge resizes one way only")
        let topLeft = SubtitleOverlayFrame.resized(frame, handle: .init(horizontal: -1, vertical: 1),
                                                   by: CGVector(dx: -100, dy: 300), within: screen)
        XCTAssertEqual(topLeft, NSRect(x: 240, y: 72, width: 860, height: 490))
        let tiny = SubtitleOverlayFrame.resized(frame, handle: .init(horizontal: -1, vertical: -1),
                                                by: CGVector(dx: 2_000, dy: 2_000), within: screen)
        XCTAssertEqual(tiny.size, SubtitleOverlayFrame.minimumSize)
        XCTAssertEqual(tiny.maxX, frame.maxX, "the right edge stays")
        XCTAssertEqual(tiny.maxY, frame.maxY, "the top edge stays")
        let past = SubtitleOverlayFrame.resized(frame, handle: .init(horizontal: 1, vertical: 1),
                                                by: CGVector(dx: 5_000, dy: 5_000), within: screen)
        XCTAssertEqual(past.maxX, screen.maxX)
        XCTAssertEqual(past.maxY, screen.maxY)
        let moved = SubtitleOverlayFrame.moved(frame, by: CGVector(dx: 5_000, dy: -500), within: screen)
        XCTAssertEqual(moved, NSRect(x: 680, y: 0, width: 760, height: 190), "a move stays on the display")
    }

    func testTheSavedFrameReturnsOnItsDisplayOrAtTheUsualPlaceWhenTheDisplayIsGone() {
        let laptop = NSRect(x: 0, y: 0, width: 1_440, height: 875)
        let external = NSRect(x: 1_440, y: 0, width: 2_560, height: 1_415)
        // Nothing saved: centred at the bottom of the island's display.
        let first = SubtitleOverlayFrame.restored(saved: nil, screens: [laptop], fallback: laptop)
        XCTAssertEqual(first, NSRect(x: 340, y: 72, width: 760, height: 190))
        // Saved on the external display, which is still there.
        let saved = NSRect(x: 2_000, y: 900, width: 900, height: 320)
        XCTAssertEqual(SubtitleOverlayFrame.restored(saved: saved, screens: [laptop, external], fallback: laptop), saved)
        // The external display is unplugged: the saved size at the usual place.
        let gone = SubtitleOverlayFrame.restored(saved: saved, screens: [laptop], fallback: laptop)
        XCTAssertEqual(gone.size, saved.size)
        XCTAssertEqual(gone.midX, laptop.midX, accuracy: 0.5)
        XCTAssertEqual(gone.minY, laptop.minY + SubtitleOverlayFrame.bottomInset)
        // A smaller display than the frame: kept inside it.
        let small = NSRect(x: 0, y: 0, width: 800, height: 500)
        let huge = NSRect(x: -50, y: 300, width: 1_200, height: 700)
        let fitted = SubtitleOverlayFrame.restored(saved: huge, screens: [small], fallback: small)
        XCTAssertTrue(small.contains(fitted), "\(fitted)")
        // Damaged values never produce an empty overlay.
        XCTAssertEqual(SubtitleOverlayFrame.restored(saved: NSRect(x: 10, y: 10, width: 0, height: 0),
                                                     screens: [laptop], fallback: laptop), first)
    }

    // MARK: The panel with real events

    private func overlay(defaults suite: String = "subtitle-frame-\(UUID())", pairs: Int = 3)
        async throws -> (TranslationWindowController, LiveSubtitleModel, UserDefaults) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let speech = FakeSpeechTranslation()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in speech })
        model.sourceCode = "en"
        model.targetCode = "ru"
        let controller = TranslationWindowController(
            textModel: TextTranslationModel(makeService: { FixtureTranslator() }), subtitleModel: model,
            defaults: defaults, openSettings: { _ in }, activityChanged: { _ in })
        let display = display
        controller.screens = { [display] }
        controller.islandScreen = { display }
        if pairs > 0 {
            model.start()
            for _ in 0..<200 where model.phase != .listening { try await Task.sleep(for: .milliseconds(5)) }
            speech.yieldRecorded(until: .max)
            for _ in 0..<200 where model.lines.count < pairs { try await Task.sleep(for: .milliseconds(5)) }
            model.stop()
            for _ in 0..<400 where model.phase != .idle { try await Task.sleep(for: .milliseconds(10)) }
        }
        controller.presentation.mode = .subtitles
        controller.resize(for: .subtitles)
        controller.window.setFrame(start, display: false)
        controller.window.orderFrontRegardless()
        settle(0.4)
        addTeardownBlock { controller.window.orderOut(nil) }
        return (controller, model, defaults)
    }

    private func settle(_ seconds: TimeInterval = 0.1) {
        controller?.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
    private weak var controller: TranslationWindowController?

    /// A mouse event at a point on the screen, located in the window as it is now.
    private func mouse(_ type: NSEvent.EventType, _ panel: NSWindow, screen point: NSPoint,
                       flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x - panel.frame.minX, y: point.y - panel.frame.minY),
                           modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ panel: NSWindow, from: NSPoint, by delta: CGVector) {
        panel.sendEvent(mouse(.leftMouseDown, panel, screen: from))
        for step in 1...4 {
            let fraction = CGFloat(step) / 4
            panel.sendEvent(mouse(.leftMouseDragged, panel,
                                  screen: NSPoint(x: from.x + delta.dx * fraction, y: from.y + delta.dy * fraction)))
        }
        panel.sendEvent(mouse(.leftMouseUp, panel, screen: NSPoint(x: from.x + delta.dx, y: from.y + delta.dy)))
        settle()
    }

    func testDraggingTheBoxMovesItAndTheEdgeResizesItAndBothAreRemembered() async throws {
        let (controller, _, defaults) = try await overlay()
        self.controller = controller
        let panel = controller.window
        XCTAssertFalse(panel.isKeyWindow)
        // A press on the caption, away from every control, moves the overlay.
        let caption = NSPoint(x: start.minX + 300, y: start.minY + 50)
        XCTAssertFalse(controller.hitTargets.isControl(at: NSPoint(x: 300, y: 50), in: panel))
        drag(panel, from: caption, by: CGVector(dx: 140, dy: 260))
        XCTAssertEqual(panel.frame, start.offsetBy(dx: 140, dy: 260))
        XCTAssertEqual(SubtitleOverlayFrame.load(from: defaults), panel.frame, "the new place is remembered")

        // The right edge makes it wider; the left edge stays.
        let moved = panel.frame
        drag(panel, from: NSPoint(x: moved.maxX - 3, y: moved.midY), by: CGVector(dx: 200, dy: 30))
        XCTAssertEqual(panel.frame, NSRect(x: moved.minX, y: moved.minY, width: moved.width + 200, height: moved.height))
        // The top-left corner makes it taller and narrower; the bottom-right corner stays.
        let wide = panel.frame
        drag(panel, from: NSPoint(x: wide.minX + 2, y: wide.maxY - 2), by: CGVector(dx: 100, dy: 150))
        XCTAssertEqual(panel.frame, NSRect(x: wide.minX + 100, y: wide.minY, width: wide.width - 100, height: wide.height + 150))
        // Never smaller than the minimum.
        let tall = panel.frame
        drag(panel, from: NSPoint(x: tall.maxX - 2, y: tall.minY + 2), by: CGVector(dx: -2_000, dy: 2_000))
        XCTAssertEqual(panel.frame.size, SubtitleOverlayFrame.minimumSize)
        XCTAssertEqual(panel.frame.minX, tall.minX)
        XCTAssertEqual(panel.frame.maxY, tall.maxY)
        XCTAssertEqual(SubtitleOverlayFrame.load(from: defaults), panel.frame)
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow, "moving and resizing never takes focus from the video")
    }

    func testControlsKeepTheirPressesAndTheTextPaletteIsNotMovedThisWay() async throws {
        let (controller, model, defaults) = try await overlay()
        self.controller = controller
        let panel = controller.window
        // The language menus are controls: their press is theirs.
        let languages = try XCTUnwrap(controller.hitTargets.frame(of: .controls, in: panel))
        let down = mouse(.leftMouseDown, panel, screen: NSPoint(x: start.minX + languages.midX, y: start.minY + languages.midY))
        XCTAssertFalse(controller.frameTracker.handle(down, in: panel))
        XCTAssertFalse(controller.frameTracker.isTracking)
        // Start still takes its click through the window.
        let session = try XCTUnwrap(controller.hitTargets.frame(of: .session, in: panel))
        let point = NSPoint(x: start.minX + session.midX, y: start.minY + session.midY)
        panel.sendEvent(mouse(.leftMouseDown, panel, screen: point))
        panel.sendEvent(mouse(.leftMouseUp, panel, screen: point))
        XCTAssertTrue(model.phase.isRunning, "Start began a session, the overlay did not move")
        XCTAssertEqual(panel.frame, start)
        model.cancel()
        // A control-click is the context menu's.
        let control = mouse(.leftMouseDown, panel, screen: NSPoint(x: start.minX + 300, y: start.minY + 50), flags: .control)
        XCTAssertFalse(controller.frameTracker.handle(control, in: panel))
        // The text palette keeps AppKit's own behaviour.
        controller.resize(for: .text)
        XCTAssertFalse(controller.frameTracker.isEnabled)
        let plain = mouse(.leftMouseDown, panel, screen: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        XCTAssertFalse(controller.frameTracker.handle(plain, in: panel))
        XCTAssertNil(SubtitleOverlayFrame.load(from: defaults), "nothing was moved, nothing saved")
    }

    func testTheOverlayReturnsWhereItWasAfterARelaunchAndAtTheUsualPlaceWhenItsDisplayIsGone() async throws {
        let suite = "subtitle-frame-relaunch-\(UUID())"
        let (controller, _, defaults) = try await overlay(defaults: suite, pairs: 0)
        self.controller = controller
        let panel = controller.window
        drag(panel, from: NSPoint(x: start.minX + 300, y: start.minY + 60), by: CGVector(dx: 500, dy: 400))
        drag(panel, from: NSPoint(x: panel.frame.maxX - 2, y: panel.frame.maxY - 2), by: CGVector(dx: 150, dy: 120))
        let left = panel.frame
        controller.dismiss()

        func relaunch(screens: [NSRect], island: NSRect) -> TranslationWindowController {
            let next = TranslationWindowController(
                textModel: TextTranslationModel(makeService: { FixtureTranslator() }),
                subtitleModel: LiveSubtitleModel(makeAudio: { FixtureSubtitleAudio() },
                                                 openTranslator: { _, _ in FixtureSubtitleUpstream() }),
                defaults: defaults, openSettings: { _ in }, activityChanged: { _ in })
            next.screens = { screens }
            next.islandScreen = { island }
            next.resize(for: .subtitles)
            return next
        }
        XCTAssertEqual(relaunch(screens: [display], island: display).window.frame, left, "same place and size")
        // Its display is gone: the remembered size at the bottom of the island's display.
        let other = NSRect(x: 30_000, y: 30_000, width: 1_512, height: 945)
        let moved = relaunch(screens: [other], island: other).window.frame
        XCTAssertEqual(moved.size, left.size)
        XCTAssertEqual(moved.midX, other.midX, accuracy: 0.5)
        XCTAssertEqual(moved.minY, other.minY + SubtitleOverlayFrame.bottomInset)
        // The text palette never takes the overlay's size.
        let text = relaunch(screens: [display], island: display)
        text.resize(for: .text)
        XCTAssertEqual(text.window.frame.width, TranslationWindowController.defaultTextWidth)
    }

    // MARK: Scrolling

    func testScrollingBackHoldsThePairsWhileNewOnesArriveAndLatestFollowsAgain() async throws {
        let speech = FakeSpeechTranslation()
        let model = LiveSubtitleModel(flushInterval: .milliseconds(5), makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in speech })
        model.sourceCode = "en"
        model.targetCode = "ru"
        let suite = "subtitle-scroll-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let controller = TranslationWindowController(
            textModel: TextTranslationModel(makeService: { FixtureTranslator() }), subtitleModel: model,
            defaults: defaults, openSettings: { _ in }, activityChanged: { _ in })
        self.controller = controller
        let display = display
        controller.screens = { [display] }
        controller.presentation.mode = .subtitles
        controller.resize(for: .subtitles)
        controller.window.setFrame(start, display: false)
        controller.window.orderFrontRegardless()
        addTeardownBlock { controller.window.orderOut(nil); model.cancel() }
        model.start()
        for _ in 0..<200 where model.phase != .listening { try await Task.sleep(for: .milliseconds(5)) }
        speech.yieldRecorded(until: 25_000)
        for _ in 0..<200 where model.lines.count < 4 { try await Task.sleep(for: .milliseconds(5)) }
        settle(0.5)
        let scroll = controller.scroll
        XCTAssertTrue(scroll.isFollowing)
        let placed = try XCTUnwrap(scroll.geometry.placed)
        XCTAssertGreaterThan(placed.rows.last?.bottom ?? 0, placed.height - 1, "the newest pair sits at the bottom")
        XCTAssertLessThan(placed.rows.first?.top ?? 0, 0, "older pairs are above the caption")

        // A trackpad scroll toward older pairs, through the window.
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                          wheel1: 60, wheel2: 0, wheel3: 0))
        controller.window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: wheel)))
        settle(0.4)
        let anchor = try XCTUnwrap(scroll.anchor, "scrolled back")
        func anchoredTop() -> CGFloat? { scroll.geometry.placed?.rows.first { $0.id == anchor.id }?.top }
        let before = try XCTUnwrap(anchoredTop())
        XCTAssertEqual(before, anchor.top, accuracy: 0.5)
        XCTAssertNotNil(controller.hitTargets.frame(of: .latest, in: controller.window), "Latest shows")

        // New pairs arrive: what is being read does not move.
        let count = model.lines.count
        speech.yieldRecorded(from: 25_000, until: .max)
        for _ in 0..<200 where model.lines.count <= count { try await Task.sleep(for: .milliseconds(5)) }
        settle(0.6)
        XCTAssertGreaterThan(model.lines.count, count)
        XCTAssertEqual(scroll.anchor?.id, anchor.id)
        XCTAssertEqual(try XCTUnwrap(anchoredTop()), before, accuracy: 0.5, "new lines never pull the reader down")

        // Latest returns to the newest pair.
        let latest = try XCTUnwrap(controller.hitTargets.frame(of: .latest, in: controller.window))
        let point = NSPoint(x: start.minX + latest.midX, y: start.minY + latest.midY)
        controller.window.sendEvent(mouse(.leftMouseDown, controller.window, screen: point))
        controller.window.sendEvent(mouse(.leftMouseUp, controller.window, screen: point))
        settle(0.4)
        XCTAssertTrue(scroll.isFollowing)
        XCTAssertEqual(controller.window.frame, start, "a click on Latest does not move the overlay")
        let following = try XCTUnwrap(scroll.geometry.placed)
        XCTAssertEqual(following.rows.last?.bottom ?? 0, following.height, accuracy: 0.5)

        // Scrolling back, then down past the newest pair, follows again.
        scroll.scroll(by: 80)
        settle(0.3)
        XCTAssertFalse(scroll.isFollowing)
        scroll.scroll(by: -10_000)
        settle(0.3)
        XCTAssertTrue(scroll.isFollowing)
        // Never past the oldest pair.
        scroll.scroll(by: 100_000)
        settle(0.3)
        let oldest = try XCTUnwrap(scroll.geometry.placed?.rows.first)
        XCTAssertEqual(oldest.top, 0, accuracy: 0.5, "the oldest pair stops at the top")
        XCTAssertEqual(oldest.id, model.lines.first?.id)
    }

    func testAnEmptyOrShortHistoryDoesNotScroll() {
        let scroll = SubtitleCaptionScroll()
        scroll.scroll(by: 120)
        XCTAssertTrue(scroll.isFollowing, "nothing laid out yet")
        let id = UUID()
        scroll.geometry.placed = .init(rows: [.init(id: id, top: 80, bottom: 140)], height: 146)
        scroll.scroll(by: 120)
        scroll.scroll(by: -120)
        XCTAssertTrue(scroll.isFollowing, "everything fits: nothing to scroll")
    }

    func testTheAnchoredPairStaysPutAndAGoneAnchorShowsTheOldestPair() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 150)
        let ids = (0..<6).map { _ in UUID() }
        let tops = ids.enumerated().map { (id: Optional($0.element), top: CGFloat($0.offset) * 60) }
        let total: CGFloat = 6 * 60 - 8
        XCTAssertEqual(SteadyPairsLayout.contentTop(rowTops: tops, total: total, bounds: bounds, anchor: nil),
                       150 - total, "following: the newest at the bottom")
        let anchor = SubtitleCaptionScroll.Anchor(id: ids[2], top: 10)
        XCTAssertEqual(SteadyPairsLayout.contentTop(rowTops: tops, total: total, bounds: bounds, anchor: anchor), 10 - 120)
        // A new pair below keeps the anchored one where it was.
        let longer = tops + [(id: Optional(UUID()), top: 360)]
        XCTAssertEqual(SteadyPairsLayout.contentTop(rowTops: longer, total: total + 60, bounds: bounds, anchor: anchor),
                       10 - 120)
        // The anchored pair left the history: the oldest pair at the top.
        let trimmed = Array(tops.dropFirst(3))
        XCTAssertEqual(SteadyPairsLayout.contentTop(rowTops: trimmed, total: 3 * 60 - 8, bounds: bounds,
                                                    anchor: anchor), 0)
        // Everything fits: always the bottom.
        XCTAssertEqual(SteadyPairsLayout.contentTop(rowTops: Array(tops.prefix(2)), total: 112, bounds: bounds,
                                                    anchor: anchor), 38)
    }
}

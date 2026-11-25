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

    /// Where the remembered frame opens on the test display.
    private func remembered(_ defaults: UserDefaults) -> NSRect? {
        guard let saved = SubtitleOverlayFrame.load(from: defaults) else { return nil }
        XCTAssertEqual(saved.display, "test-display", "the display is remembered by identity")
        return SubtitleOverlayFrame.restored(saved: saved, displays: [.init(id: "test-display", frame: display)],
                                             fallback: display)
    }

    /// Queue #563, finding 1: the right and top edges were a grip that resized
    /// nothing. Every point of the panel either moves the box or resizes it
    /// along at least one axis, also on the grip's exact boundaries.
    func testEveryGripPointResizesSomething() {
        for size in [NSSize(width: 760, height: 190), NSSize(width: 480, height: 150), NSSize(width: 1_001, height: 421)] {
            XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: size.width - 16, y: size.height / 2), in: size),
                           .init(horizontal: 1, vertical: 0), "the right grip's inner boundary")
            XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: size.width / 2, y: size.height - 16), in: size),
                           .init(horizontal: 0, vertical: 1), "the top grip's inner boundary")
            var x: CGFloat = 0
            while x < size.width {
                var y: CGFloat = 0
                while y < size.height {
                    if let handle = SubtitleOverlayFrame.handle(at: NSPoint(x: x, y: y), in: size) {
                        XCTAssertNotEqual(handle, .init(horizontal: 0, vertical: 0), "(\(x), \(y)) in \(size)")
                    }
                    y += y < 30 || y > size.height - 30 ? 1 : 7
                }
                x += x < 30 || x > size.width - 30 ? 1 : 7
            }
        }
        XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: 744, y: 95), in: NSSize(width: 760, height: 190)),
                       .init(horizontal: 1, vertical: 0))
        XCTAssertEqual(SubtitleOverlayFrame.handle(at: NSPoint(x: 380, y: 174), in: NSSize(width: 760, height: 190)),
                       .init(horizontal: 0, vertical: 1))
    }

    /// Queue #563, finding 2: a display is known by its identity, not by
    /// where it was. Unplugging the external display can give the laptop its
    /// origin; the overlay then opens at the usual place on the laptop.
    func testTheOverlayFollowsItsDisplayByIdentityNotByCoordinates() {
        let external = SubtitleOverlayFrame.Display(id: "external", frame: NSRect(x: 0, y: 0, width: 2_560, height: 1_415))
        let laptopRight = SubtitleOverlayFrame.Display(id: "laptop", frame: NSRect(x: 2_560, y: 0, width: 1_512, height: 945))
        let frame = NSRect(x: 40, y: 500, width: 800, height: 300)
        let saved = SubtitleOverlayFrame.saved(frame, among: [external, laptopRight])
        XCTAssertEqual(saved, .init(display: "external", frame: frame))
        // Unplugged: the laptop takes the external display's origin.
        let laptopAlone = SubtitleOverlayFrame.Display(id: "laptop", frame: NSRect(x: 0, y: 0, width: 1_512, height: 945))
        let reopened = SubtitleOverlayFrame.restored(saved: saved, displays: [laptopAlone], fallback: laptopAlone.frame)
        XCTAssertEqual(reopened, NSRect(x: 356, y: 72, width: 800, height: 300), "the usual place, the saved size")
        // The arrangement changed: the same place on the same display.
        let externalMoved = SubtitleOverlayFrame.Display(id: "external", frame: NSRect(x: 1_512, y: -200, width: 2_560, height: 1_415))
        XCTAssertEqual(SubtitleOverlayFrame.restored(saved: saved, displays: [laptopAlone, externalMoved],
                                                     fallback: laptopAlone.frame),
                       NSRect(x: 1_552, y: 300, width: 800, height: 300))
        // Saved and read back through the defaults.
        let suite = "subtitle-frame-identity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        SubtitleOverlayFrame.save(frame, among: [external, laptopRight], to: defaults)
        XCTAssertEqual(SubtitleOverlayFrame.load(from: defaults), saved)
        // A display without an identity: by coordinates, as before.
        let anonymous = SubtitleOverlayFrame.Display(id: nil, frame: external.frame)
        let global = SubtitleOverlayFrame.saved(frame, among: [anonymous])
        XCTAssertNil(global.display)
        XCTAssertEqual(SubtitleOverlayFrame.restored(saved: global, displays: [anonymous], fallback: anonymous.frame), frame)
        defaults.set("{{1, 2}, {3, 4}}", forKey: SubtitleOverlayFrame.defaultsKey)
        XCTAssertNil(SubtitleOverlayFrame.load(from: defaults), "an unreadable value is the default place")
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
        controller.displays = { [.init(id: "test-display", frame: display)] }
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
        XCTAssertEqual(remembered(defaults), panel.frame, "the new place is remembered")

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
        XCTAssertEqual(remembered(defaults), panel.frame)
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
        let testDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        // Keep the text width independent of AppKit's shared frame autosave.
        testDefaults.set(Double(TranslationWindowController.defaultTextWidth),
                         forKey: TranslationWindowController.textWidthKey)
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
            next.displays = { screens.map { .init(id: $0 == self.display ? "test-display" : "other", frame: $0) } }
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
        controller.displays = { [.init(id: "test-display", frame: display)] }
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

        // Queue #563, finding 4: a Control-click on Latest is the context
        // menu's, not Latest's.
        let latest = try XCTUnwrap(controller.hitTargets.frame(of: .latest, in: controller.window))
        let point = NSPoint(x: start.minX + latest.midX, y: start.minY + latest.midY)
        let menuClick = mouse(.leftMouseDown, controller.window, screen: point, flags: .control)
        XCTAssertFalse(controller.hitTargets.handle(menuClick, in: controller.window))
        XCTAssertFalse(controller.frameTracker.handle(menuClick, in: controller.window))
        XCTAssertEqual(scroll.anchor?.id, anchor.id, "still reading the older pairs")

        // Latest returns to the newest pair.
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
        scroll.geometry.record(.init(rows: [.init(id: id, top: 80, bottom: 140)], height: 146))
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

    /// Queue #563, finding 3: the geometry a scroll uses is the caption's on
    /// screen, a gesture toward the newest pair with it in view follows, and
    /// pairs that are gone leave nothing to scroll.
    func testScrollGeometryIsTheCaptionOnScreenAndGoesWithThePairs() {
        let scroll = SubtitleCaptionScroll()
        let ids = (0..<10).map { _ in UUID() }
        func placed(height: CGFloat) -> SubtitleCaptionGeometry.Placed {
            let top = height - CGFloat(ids.count) * 50
            return .init(rows: ids.enumerated().map { index, id in
                .init(id: id, top: top + CGFloat(index) * 50, bottom: top + CGFloat(index + 1) * 50)
            }, height: height, width: 700)
        }
        scroll.setViewport(CGSize(width: 700, height: 300))
        scroll.geometry.record(placed(height: 300))
        // A measurement pass at the ideal height lands after the real one.
        scroll.geometry.record(placed(height: 146))
        XCTAssertEqual(scroll.geometry.current?.height, 300, "the caption on screen, not the measurement")
        scroll.scroll(by: 40)
        XCTAssertFalse(scroll.isFollowing)
        // The window grew until the newest pair is in view: a gesture toward
        // newer pairs follows again instead of leaving Latest up.
        scroll.setViewport(CGSize(width: 700, height: 900))
        scroll.geometry.record(placed(height: 900))
        scroll.scroll(by: -3)
        XCTAssertTrue(scroll.isFollowing)
        // Clear: no rows, nothing to anchor.
        scroll.setViewport(CGSize(width: 700, height: 300))
        scroll.geometry.record(placed(height: 300))
        scroll.scroll(by: 40)
        XCTAssertFalse(scroll.isFollowing)
        scroll.reset()
        XCTAssertTrue(scroll.isFollowing)
        XCTAssertNil(scroll.geometry.current)
        scroll.scroll(by: 40)
        XCTAssertTrue(scroll.isFollowing, "a wheel over the emptied caption anchors nothing")
    }

    /// Queue #563, finding 3: following lays out enough pairs to fill any
    /// caption with the shortest rows, so a tall window shows every retained
    /// pair or has the rest above it to scroll to.
    func testFollowingLaysOutEnoughPairsForATallCaption() {
        XCTAssertEqual(SubtitleCaptionScroll.followedLimit(height: 0, minimum: 24), 24)
        XCTAssertEqual(SubtitleCaptionScroll.followedLimit(height: 146, minimum: 24), 24)
        for height: CGFloat in [1_520, 2_160] {
            let limit = SubtitleCaptionScroll.followedLimit(height: height, minimum: 24)
            XCTAssertGreaterThan(CGFloat(limit) * SubtitleCaptionScroll.shortestRow, height)
        }
        XCTAssertGreaterThanOrEqual(SubtitleCaptionScroll.followedLimit(height: 1_520, minimum: 24), 36)
    }

    /// Queue #563, finding 4: the inactive overlay's repair buttons act on the
    /// first click, through the window, without moving it.
    func testOpenKeysAndModelsActsOnTheFirstClick() async throws {
        let suite = "subtitle-fix-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = LiveSubtitleModel(makeAudio: { FixtureSubtitleAudio() },
                                      openTranslator: { _, _ in throw SubtitleAudioTranslate.Unavailable.missingKey })
        var opened: [AIFeature] = []
        let controller = TranslationWindowController(
            textModel: TextTranslationModel(makeService: { FixtureTranslator() }), subtitleModel: model,
            defaults: defaults, openSettings: { opened.append($0) }, activityChanged: { _ in })
        self.controller = controller
        let display = display
        controller.displays = { [.init(id: "test-display", frame: display)] }
        controller.islandScreen = { display }
        model.start()
        for _ in 0..<200 where model.issue == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.issue?.feature, .subtitlesAudio)
        controller.presentation.mode = .subtitles
        controller.resize(for: .subtitles)
        controller.window.setFrame(start, display: false)
        controller.window.orderFrontRegardless()
        addTeardownBlock { controller.window.orderOut(nil) }
        settle(0.4)
        let panel = controller.window
        XCTAssertFalse(panel.isKeyWindow)
        let fix = try XCTUnwrap(controller.hitTargets.frame(of: .fix, in: panel))
        let point = NSPoint(x: start.minX + fix.midX, y: start.minY + fix.midY)
        let menu = mouse(.leftMouseDown, panel, screen: point, flags: .control)
        XCTAssertFalse(controller.hitTargets.handle(menu, in: panel), "a Control-click is the menu's")
        panel.sendEvent(mouse(.leftMouseDown, panel, screen: point))
        panel.sendEvent(mouse(.leftMouseUp, panel, screen: point))
        XCTAssertEqual(opened, [.subtitlesAudio])
        XCTAssertEqual(panel.frame, start, "the click did not move the overlay")
    }

    func testOpenAudioPermissionsActsOnTheFirstClick() {
        let targets = SubtitleOverlayHitTargets()
        var opened: [URL] = []
        let open = TranslationView.openURL
        TranslationView.openURL = { opened.append($0) }
        defer { TranslationView.openURL = open }
        let panel = NSPanel(contentRect: NSRect(x: -20_000, y: -20_000, width: 320, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView:
            Button("Open audio permissions") { TranslationView.openAudioPermissions() }
                .background(SubtitleOverlayHitReporter(control: .audio, targets: targets, action: "audio",
                                                       activate: { TranslationView.openAudioPermissions() }))
                .frame(width: 320, height: 80))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let button = targets.frame(of: .audio, in: panel) else { return XCTFail("the button reports its frame") }
        let point = NSPoint(x: panel.frame.minX + button.midX, y: panel.frame.minY + button.midY)
        XCTAssertTrue(targets.isControl(at: NSPoint(x: button.midX, y: button.midY), in: panel), "a press there never moves the overlay")
        XCTAssertTrue(targets.handle(mouse(.leftMouseDown, panel, screen: point), in: panel))
        XCTAssertTrue(targets.handle(mouse(.leftMouseUp, panel, screen: point), in: panel))
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first?.absoluteString.contains("Privacy_AudioCapture") == true)
    }

}

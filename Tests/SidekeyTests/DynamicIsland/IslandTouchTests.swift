import AppKit
import XCTest
@testable import Sidekey

/// Taps on the island on a touch display (macOS 27). A finger has no hover
/// and no `mouseMoved`, so the island window, which claims events only under
/// the pointer, never saw them. Targets cover the visible surfaces on a touch
/// screen; a tap starts a session. A Mac without touch must keep every
/// routing decision it had.
@MainActor
final class IslandTouchTests: XCTestCase {
    private let compact = NSRect(x: 894, y: 961, width: 310, height: 32)
    private let wing = NSRect(x: 1204, y: 961, width: 120, height: 32)
    private let answer = NSRect(x: 988, y: 590, width: 336, height: 360)

    // MARK: - Screens without touch change nothing

    func test_noTargetsEverOnAScreenWithoutTouch() {
        for shown in [false, true] {
            for session in [false, true] {
                for ignoring in [false, true] {
                    for idle in [false, true] {
                        XCTAssertEqual(IslandTouchRouting.targetFrames(
                            touchCapable: false, shown: shown, sessionActive: session,
                            islandIgnoresMouse: ignoring, idleHidden: idle,
                            compactFrame: compact, agentSurfaceFrames: [wing, answer]), [])
                    }
                }
            }
        }
    }

    func test_withoutASessionThePointerDecidesExactlyAsBefore() {
        XCTAssertTrue(IslandTouchRouting.shouldIgnoreMouseEvents(pointerDecision: true, sessionActive: false))
        XCTAssertFalse(IslandTouchRouting.shouldIgnoreMouseEvents(pointerDecision: false, sessionActive: false))
    }

    // MARK: - Targets

    func test_targetsCoverTheCapsuleAndAgentSurfacesWhileTheIslandIgnoresTheMouse() {
        let frames = IslandTouchRouting.targetFrames(
            touchCapable: true, shown: true, sessionActive: false, islandIgnoresMouse: true,
            idleHidden: false, compactFrame: compact, agentSurfaceFrames: [wing, .zero, answer])
        XCTAssertEqual(frames, [compact, wing, answer], "empty agent rects are skipped")
    }

    func test_idleHiddenCapsuleGetsNoTargetSoTheMenuBarUnderItStaysTappable() {
        let frames = IslandTouchRouting.targetFrames(
            touchCapable: true, shown: true, sessionActive: false, islandIgnoresMouse: true,
            idleHidden: true, compactFrame: compact, agentSurfaceFrames: [])
        XCTAssertEqual(frames, [])
    }

    func test_targetsLeaveWhenTheIslandTakesEventsItself() {
        for (session, ignoring, shown) in [(true, true, true), (false, false, true), (false, true, false)] {
            XCTAssertEqual(IslandTouchRouting.targetFrames(
                touchCapable: true, shown: shown, sessionActive: session, islandIgnoresMouse: ignoring,
                idleHidden: false, compactFrame: compact, agentSurfaceFrames: [answer]), [])
        }
    }

    // MARK: - Tap actions

    func test_tapOnTheCollapsedCapsuleOpensTheDrawer() {
        XCTAssertEqual(IslandTouchRouting.action(
            for: NSPoint(x: compact.midX, y: compact.midY), compactFrame: compact, drawerExpanded: false),
            .openDrawer)
    }

    func test_tapOnAnOpenCapsuleOrAnAgentSurfaceIsDelivered() {
        XCTAssertEqual(IslandTouchRouting.action(
            for: NSPoint(x: compact.midX, y: compact.midY), compactFrame: compact, drawerExpanded: true),
            .deliver)
        XCTAssertEqual(IslandTouchRouting.action(
            for: NSPoint(x: answer.midX, y: answer.midY), compactFrame: compact, drawerExpanded: false),
            .deliver)
    }

    func test_sessionMakesTheIslandTakeEveryEventInItsFrame() {
        XCTAssertFalse(IslandTouchRouting.shouldIgnoreMouseEvents(pointerDecision: true, sessionActive: true))
    }

    func test_tapOnTheTransparentWindowAreaEndsTheSession() {
        let drawer = NSRect(x: 894, y: 700, width: 310, height: 253)
        XCTAssertTrue(IslandTouchRouting.endsSession(tapAt: NSPoint(x: 600, y: 900), activeFrames: [compact, drawer]))
        XCTAssertFalse(IslandTouchRouting.endsSession(tapAt: NSPoint(x: 1000, y: 800), activeFrames: [compact, drawer]))
    }

    // MARK: - Session

    func test_sessionLifecycle() {
        var session = IslandTouchSession()
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.end(), "ending nothing closes nothing")

        session.begin(at: 100, openedDrawer: true)
        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.hasExpired(now: 100 + IslandTouchSession.idleTimeout - 0.1))
        session.noteTouch(at: 105)
        XCTAssertFalse(session.hasExpired(now: 105 + IslandTouchSession.idleTimeout - 0.1))
        XCTAssertTrue(session.hasExpired(now: 105 + IslandTouchSession.idleTimeout))
        XCTAssertTrue(session.end(), "the drawer this session opened closes with it")
        XCTAssertEqual(session, IslandTouchSession())
    }

    func test_sessionThatOnlyDeliveredTapsLeavesTheDrawerAlone() {
        var session = IslandTouchSession()
        session.begin(at: 1, openedDrawer: false)
        session.begin(at: 2, openedDrawer: false)
        XCTAssertFalse(session.end())
    }

    func test_reopeningKeepsTheDrawerOwnership() {
        var session = IslandTouchSession()
        session.begin(at: 1, openedDrawer: true)
        session.begin(at: 2, openedDrawer: false)
        XCTAssertTrue(session.openedDrawer)
    }

    func test_touchesOutsideASessionAreIgnored() {
        var session = IslandTouchSession()
        session.noteTouch(at: 50)
        XCTAssertEqual(session, IslandTouchSession())
        XCTAssertFalse(session.hasExpired(now: 1_000))
    }

    // MARK: - Target windows (never ordered on screen)

    func test_targetWindowReportsTheTapsScreenPoint() throws {
        let targets = IslandTouchTargets(presentsWindows: false)
        var taps: [NSPoint] = []
        targets.onTap = { taps.append($0) }
        targets.update(frames: [compact, answer], level: .screenSaver, sharingType: .readOnly)
        XCTAssertEqual(targets.panels.count, 2)
        XCTAssertEqual(targets.activeFrames, [compact, answer])
        XCTAssertFalse(targets.panels.contains(where: \.isVisible))

        let panel = targets.panels[1]
        try send(.leftMouseDown, at: NSPoint(x: 20, y: 30), to: panel)
        XCTAssertEqual(taps, [NSPoint(x: answer.minX + 20, y: answer.minY + 30)])
    }

    func test_retiredTargetNeverReportsATap() throws {
        let targets = IslandTouchTargets(presentsWindows: false)
        var taps = 0
        targets.onTap = { _ in taps += 1 }
        targets.update(frames: [compact, answer], level: .screenSaver, sharingType: .readOnly)
        let retired = targets.panels[1]
        targets.update(frames: [compact], level: .screenSaver, sharingType: .readOnly)
        XCTAssertEqual(targets.activeFrames, [compact])
        try send(.leftMouseDown, at: NSPoint(x: 5, y: 5), to: retired)
        XCTAssertEqual(taps, 0)
        targets.update(frames: [], level: .screenSaver, sharingType: .readOnly)
        XCTAssertEqual(targets.activeFrames, [])
    }

    func test_pointerOverATargetHandsTheIslandBack() throws {
        let targets = IslandTouchTargets(presentsWindows: false)
        var pointer = 0
        targets.onPointer = { pointer += 1 }
        targets.update(frames: [compact], level: .screenSaver, sharingType: .readOnly)
        let view = try XCTUnwrap(targets.panels[0].contentView as? IslandTouchTargetView)
        view.onPointer()
        XCTAssertEqual(pointer, 1)
        targets.update(frames: [], level: .screenSaver, sharingType: .readOnly)
        view.onPointer()
        XCTAssertEqual(pointer, 1, "a retired target hands nothing back")
    }

    func test_longPressArrivesAsRightClickAndDoesNothing() throws {
        let targets = IslandTouchTargets(presentsWindows: false)
        var taps = 0
        targets.onTap = { _ in taps += 1 }
        targets.update(frames: [compact], level: .screenSaver, sharingType: .readOnly)
        try send(.rightMouseDown, at: NSPoint(x: 5, y: 5), to: targets.panels[0])
        XCTAssertEqual(taps, 0)
    }

    private func send(_ type: NSEvent.EventType, at location: NSPoint, to window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        // A window never ordered on screen has no window number, so AppKit's
        // own dispatch drops the event; deliver it the way sendEvent would:
        // to the view hitTest finds at that point.
        let view = try XCTUnwrap(window.contentView?.hitTest(location))
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        default: XCTFail("unsupported \(type)")
        }
    }
}

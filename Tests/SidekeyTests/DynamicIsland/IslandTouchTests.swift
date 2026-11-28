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
            for ignoring in [false, true] {
                XCTAssertEqual(IslandTouchRouting.targetFrames(
                    touchCapable: false, shown: shown, islandIgnoresMouse: ignoring,
                    activeFrames: [compact, wing, answer]), [])
            }
        }
    }

    // MARK: - Which screens get targets (Apple TN3212)

    func test_onlyATrustedTouchReportGetsTargets() {
        // The touch MacBook alone, or with an ordinary external monitor.
        XCTAssertTrue(IslandTouchRouting.acceptsTouch(screenReportsTouch: true, allScreensReportTouch: true, screenCount: 1))
        XCTAssertTrue(IslandTouchRouting.acceptsTouch(screenReportsTouch: true, allScreensReportTouch: false, screenCount: 2))
        // Today's Macs and the external monitor of a touch Mac.
        XCTAssertFalse(IslandTouchRouting.acceptsTouch(screenReportsTouch: false, allScreensReportTouch: false, screenCount: 1))
        XCTAssertFalse(IslandTouchRouting.acceptsTouch(screenReportsTouch: false, allScreensReportTouch: false, screenCount: 2))
        // A touch Sidecar connected: every display reports touch, none is trusted.
        XCTAssertFalse(IslandTouchRouting.acceptsTouch(screenReportsTouch: true, allScreensReportTouch: true, screenCount: 2))
        XCTAssertFalse(IslandTouchRouting.acceptsTouch(screenReportsTouch: true, allScreensReportTouch: true, screenCount: 3))
    }

    func test_resolverMarksTouchOnlyOnTheTrustedIslandScreen() {
        func screen(_ id: String, x: CGFloat, builtIn: Bool, touch: Bool) -> IslandScreenDescriptor {
            IslandScreenDescriptor(
                uuid: id, frame: NSRect(x: x, y: 0, width: 1512, height: 982),
                visibleFrame: NSRect(x: x, y: 0, width: 1512, height: 950), safeAreaTopInset: 0,
                auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, isBuiltIn: builtIn, isTouchCapable: touch)
        }
        func resolved(_ screens: [IslandScreenDescriptor], preferred: String? = nil) -> IslandScreenDescriptor {
            IslandScreenResolver.selectDescriptor(preferredUUID: preferred, descriptors: screens, placement: .automatic)
        }
        let touchMac = screen("mac", x: 0, builtIn: true, touch: true)
        let external = screen("external", x: 1512, builtIn: false, touch: false)
        XCTAssertTrue(resolved([touchMac]).acceptsTouchInput)
        XCTAssertTrue(resolved([touchMac, external]).acceptsTouchInput)
        XCTAssertFalse(resolved([touchMac, external], preferred: "external").acceptsTouchInput,
                       "the external monitor of a touch Mac is mouse-only")
        // Sidecar: the notched Mac and the iPad both report touch.
        let ordinaryMac = screen("mac", x: 0, builtIn: true, touch: true)
        let sidecar = screen("ipad", x: 1512, builtIn: false, touch: true)
        XCTAssertFalse(resolved([ordinaryMac, sidecar]).acceptsTouchInput)
        XCTAssertFalse(resolved([ordinaryMac, sidecar], preferred: "ipad").acceptsTouchInput)
        // Raw descriptors never accept touch.
        XCTAssertFalse(touchMac.acceptsTouchInput)
    }

    // MARK: - Targets

    func test_targetsCoverEveryRenderedSurfaceWhileTheIslandIgnoresTheMouse() {
        let drawer = NSRect(x: 894, y: 700, width: 310, height: 253)
        let music = NSRect(x: 894, y: 650, width: 310, height: 42)
        let frames = IslandTouchRouting.targetFrames(
            touchCapable: true, shown: true, islandIgnoresMouse: true,
            activeFrames: [compact, drawer, music, wing, .zero, answer])
        XCTAssertEqual(frames, [compact, drawer, music, wing, answer],
                       "a drawer opened by a hotkey and the music strip take the first tap too")
    }

    func test_targetsLeaveWhenTheIslandTakesThePointerOrIsHidden() {
        XCTAssertEqual(IslandTouchRouting.targetFrames(
            touchCapable: true, shown: true, islandIgnoresMouse: false, activeFrames: [compact]), [])
        XCTAssertEqual(IslandTouchRouting.targetFrames(
            touchCapable: true, shown: false, islandIgnoresMouse: true, activeFrames: [compact]), [])
    }

    func test_idleHiddenCapsuleClaimsNothingSoItGetsNoTarget() {
        let active = IslandPanelMouseEventPolicy.activeFrames(
            compactFrame: compact, expandedFrame: compact, leftNotificationFrame: .zero,
            musicStripFrame: .zero, agentSurfaceFrames: [], idleHidden: true, expanded: false,
            notificationActive: false, musicStripActive: false)
        XCTAssertEqual(IslandTouchRouting.targetFrames(
            touchCapable: true, shown: true, islandIgnoresMouse: true, activeFrames: active), [])
    }

    func test_targetsBesideTheSystemIslandNeverCoverIt() {
        let width: CGFloat = 1512, cutout: CGFloat = 172
        let left = (width - cutout) / 2
        let touchMac = IslandScreenDescriptor(
            uuid: "touch", frame: NSRect(x: 0, y: 0, width: width, height: 993),
            visibleFrame: NSRect(x: 0, y: 70, width: width, height: 891), safeAreaTopInset: 32,
            auxiliaryTopLeftArea: NSRect(x: 0, y: 961, width: left, height: 32),
            auxiliaryTopRightArea: NSRect(x: left + cutout, y: 961, width: left, height: 32),
            isBuiltIn: true, isTouchCapable: true)
        let screen = IslandScreenResolver.selectDescriptor(
            preferredUUID: nil, descriptors: [touchMac], placement: .automatic)
        let island = IslandFrameLayout.islandFrame(on: screen)
        let zone = IslandFrameLayout.systemIslandZone(on: screen)
        let hover = IslandHoverPanelHitZone(compactFrame: island, bandHeight: 243, musicStripActive: true)
        let active = IslandPanelMouseEventPolicy.activeFrames(
            compactFrame: island, expandedFrame: island, leftNotificationFrame: .zero,
            musicStripFrame: hover.transitionFrame, agentSurfaceFrames: [], idleHidden: false, expanded: true,
            notificationActive: false, musicStripActive: true, hoverFrames: hover.activeFrames)
        let targets = IslandTouchRouting.targetFrames(
            touchCapable: screen.acceptsTouchInput, shown: true, islandIgnoresMouse: true, activeFrames: active)
        XCTAssertFalse(targets.isEmpty)
        for target in targets {
            XCTAssertFalse(target.intersects(zone), "\(target) claims the system island band \(zone)")
        }
    }

    // MARK: - Tap actions

    func test_tapOnTheCollapsedCapsuleOpensTheDrawer() {
        XCTAssertEqual(IslandTouchRouting.action(
            for: NSPoint(x: compact.midX, y: compact.midY), compactFrame: compact,
            drawerExpanded: false, sessionOpenedDrawer: false), .openDrawer)
    }

    func test_secondTapOnTheCapsuleClosesTheDrawerATapOpened() {
        XCTAssertEqual(IslandTouchRouting.action(
            for: NSPoint(x: compact.midX, y: compact.midY), compactFrame: compact,
            drawerExpanded: true, sessionOpenedDrawer: true), .closeDrawer)
    }

    func test_tapOnAnOpenCapsuleOrAnAgentSurfaceIsDelivered() {
        XCTAssertEqual(IslandTouchRouting.action(
            for: NSPoint(x: compact.midX, y: compact.midY), compactFrame: compact,
            drawerExpanded: true, sessionOpenedDrawer: false), .deliver,
            "a drawer a hotkey opened is not the session's to close")
        XCTAssertEqual(IslandTouchRouting.action(
            for: NSPoint(x: answer.midX, y: answer.midY), compactFrame: compact,
            drawerExpanded: false, sessionOpenedDrawer: false), .deliver)
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

    func test_scrollOverATargetIsForwarded() throws {
        let targets = IslandTouchTargets(presentsWindows: false)
        var scrolled: [NSPoint] = []
        targets.onScroll = { _, point in scrolled.append(point) }
        targets.update(frames: [compact], level: .screenSaver, sharingType: .readOnly)
        let view = try XCTUnwrap(targets.panels[0].contentView as? IslandTouchTargetView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 4, y: 6), modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        view.onScroll(event)
        XCTAssertEqual(scrolled, [NSPoint(x: compact.minX + 4, y: compact.minY + 6)])
    }

    // MARK: - Island window wiring (source contract: IslandPanel is a singleton)

    private func panelSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Sidekey/DynamicIsland/IslandPanel.swift"),
                          encoding: .utf8)
    }

    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    func test_firstShowPlacesTargetsOnceTheIslandCountsAsShown() throws {
        let show = try body(of: "func show() {", in: try panelSource())
        let shown = try XCTUnwrap(show.range(of: "isShown = true"))
        XCTAssertNotNil(show[shown.upperBound...].range(of: "refreshMouseEventRouting()"),
                        "targets need isShown; a finger sends no move to place them later")
    }

    func test_displayChangeEndsTheSessionAndMovesTheTargets() throws {
        let change = try body(of: "@objc private func handleScreenChange() {", in: try panelSource())
        let end = try XCTUnwrap(change.range(of: "endTouchSession(refresh: false)"))
        let apply = try XCTUnwrap(change.range(of: "applyCurrentLayout(display: true)"))
        XCTAssertLessThan(end.lowerBound, apply.lowerBound)
        XCTAssertNotNil(change[apply.upperBound...].range(of: "refreshMouseEventRouting()"))
    }

    func test_aSessionNeverMakesTheIslandWindowClaimItsTransparentArea() throws {
        let source = try panelSource()
        let routing = try body(of: "private func refreshMouseEventRouting(layout: Layout? = nil) {", in: source)
        XCTAssertNil(routing.range(of: "touchSession"), "only the pointer decides what the window claims")
        XCTAssertNotNil(source.range(of: "touchCapable: screen.acceptsTouchInput"),
                        "targets follow the trusted touch report, not the raw one")
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

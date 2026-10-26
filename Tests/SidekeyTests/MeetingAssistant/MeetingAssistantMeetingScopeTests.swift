import XCTest
@testable import Sidekey

@MainActor
final class MeetingAssistantMeetingScopeTests: XCTestCase {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Condition timed out")
    }

    func testSuccessiveMeetingsEachStartOnceAndEndAfterTheGracePeriod() async throws {
        let probe = MeetingAssistantFixtureProbe()
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(20), makeProbe: { probe })
        var started = 0, ended = 0
        scope.onStart = { started += 1 }; scope.onEnd = { ended += 1 }
        scope.begin(); scope.begin()
        XCTAssertEqual(probe.subscriptions, 1)
        probe.emit(true); probe.emit(false)
        try await wait { ended == 1 }
        XCTAssertEqual(started, 1); XCTAssertEqual(probe.stops, 0)
        probe.emit(true); probe.emit(false)
        try await wait { ended == 2 }
        XCTAssertEqual(started, 2); XCTAssertEqual(probe.subscriptions, 1)
        scope.stop(); XCTAssertEqual(probe.stops, 1)
    }

    func testBriefReconnectCancelsEndAndExplicitOffCancelsDelayedEnd() async throws {
        let probe = MeetingAssistantFixtureProbe()
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(60), makeProbe: { probe })
        var ended = 0; scope.onEnd = { ended += 1 }
        scope.begin(); probe.emit(true); probe.emit(false)
        try await Task.sleep(for: .milliseconds(10))
        probe.emit(true)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(ended, 0)
        probe.emit(false)
        try await Task.sleep(for: .milliseconds(10))
        scope.stop()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(ended, 0); XCTAssertEqual(probe.stops, 1)
    }

    func testManualListeningBeforeRecognizedContextIsNotImmediatelyStopped() async throws {
        let probe = MeetingAssistantFixtureProbe()
        let scope = MeetingAssistantMeetingScope(endGrace: .milliseconds(10), makeProbe: { probe })
        var ended = 0; scope.onEnd = { ended += 1 }
        scope.begin(); probe.emit(false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(ended, 0)
        scope.stop()
    }

    func testHoverStateHasVisibleConnectingAndDisabledCleanup() {
        XCTAssertFalse(MeetingAssistantHoverState().visible)
        XCTAssertTrue(MeetingAssistantHoverState(available: true).visible)
        XCTAssertFalse(MeetingAssistantHoverState(available: true).isOn)
        for phase in [MeetingAssistantHoverState.Phase.connecting, .listening] {
            XCTAssertTrue(MeetingAssistantHoverState(phase: phase).isOn)
        }
        let stopping = MeetingAssistantHoverState(phase: .stopping)
        XCTAssertTrue(stopping.visible); XCTAssertFalse(stopping.canToggle); XCTAssertFalse(stopping.isOn)
    }

    func testMagicRemainsAvailableAfterOptingOutOfAnAutomaticallyDetectedMeeting() {
        let ready = MeetingAssistantHoverState(available: true)
        XCTAssertTrue(IslandMeetingAssistantPlacement.isVisible(recording: true, assistant: ready, hoverExpanded: true, controls: true, obscured: false))
        XCTAssertFalse(IslandMeetingAssistantPlacement.isVisible(recording: false, assistant: ready, hoverExpanded: true, controls: true, obscured: false))
        XCTAssertTrue(IslandMeetingAssistantPlacement.isVisible(recording: false,
            assistant: .init(available: true, meetingActive: true), hoverExpanded: true, controls: true, obscured: false))
        XCTAssertFalse(IslandMeetingAssistantPlacement.isVisible(recording: true, assistant: ready, hoverExpanded: false, controls: true, obscured: false))
        XCTAssertFalse(IslandMeetingAssistantPlacement.isVisible(recording: true, assistant: ready, hoverExpanded: true, controls: false, obscured: false))
        XCTAssertFalse(IslandMeetingAssistantPlacement.isVisible(recording: true, assistant: ready, hoverExpanded: true, controls: true, obscured: true))
        XCTAssertFalse(IslandMeetingAssistantPlacement.isVisible(recording: true, assistant: .init(), hoverExpanded: true, controls: true, obscured: false))
        for phase in [MeetingAssistantHoverState.Phase.connecting, .listening, .stopping] {
            XCTAssertTrue(IslandMeetingAssistantPlacement.isVisible(recording: false, assistant: .init(phase: phase), hoverExpanded: true, controls: true, obscured: false))
        }
    }

    func testMagicOverlayKeepsAnOpenDrawerButCannotReopenAClosedOne() {
        XCTAssertTrue(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false,
            meetingAssistantHovering: true, wasExpanded: true, glance: false),
            "The icon owns hover even if its overlay occludes the timer's tracking area")
        XCTAssertFalse(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false,
            meetingAssistantHovering: true, wasExpanded: false, glance: false),
            "An exiting icon must not reopen the drawer")
        XCTAssertFalse(IslandView.mouseHoldsDrawer(pillHovering: false, panelHovering: false,
            meetingAssistantHovering: false, wasExpanded: true, glance: false))
    }

    func testNativeMagicHitZoneClaimsOnlyTheVisibleExtension() {
        let compact = CGRect(x: 120, y: 700, width: 312, height: 38)
        let extensionFrame = IslandMeetingAssistantPlacement.frame(beside: compact)
        XCTAssertEqual(extensionFrame, CGRect(x: 432, y: 700, width: 36, height: 38))
        func frames(_ visible: Bool, _ expanded: Bool = true, _ hidden: Bool = false) -> [CGRect] {
            IslandPanelMouseEventPolicy.activeFrames(compactFrame: compact, expandedFrame: compact,
                leftNotificationFrame: .zero, musicStripFrame: .zero, agentSurfaceFrames: [],
                idleHidden: hidden, expanded: expanded, notificationActive: false, musicStripActive: false,
                hoverFrames: [], meetingAssistantMagicVisible: visible)
        }
        XCTAssertTrue(frames(true).contains(extensionFrame))
        XCTAssertFalse(frames(false).contains(extensionFrame))
        XCTAssertFalse(frames(true, false).contains(extensionFrame))
        XCTAssertFalse(frames(true, true, true).contains(extensionFrame))
        XCTAssertFalse(frames(true).contains { $0.contains(CGPoint(x: 470, y: 719)) })
        XCTAssertEqual(IslandMeetingAssistantControl.glow(at: 0), IslandMeetingAssistantControl.glow(at: 3.2), accuracy: 0.0001)
    }

}

@MainActor
final class MeetingAssistantFixtureProbe: MicInUseProbing {
    private var continuation: AsyncStream<Bool>.Continuation?
    private(set) var subscriptions = 0
    private(set) var stops = 0
    func subscribe() -> AsyncStream<Bool> {
        subscriptions += 1
        let pair = AsyncStream<Bool>.makeStream(); continuation = pair.continuation
        return pair.stream
    }
    func emit(_ value: Bool) { continuation?.yield(value) }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
}

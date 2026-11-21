import AppKit
import XCTest
@testable import Sidekey

/// A Screenshot press shows at most one permission window: the first press
/// without access only asks macOS, later presses show Whytap's help.
@MainActor
final class ScreenshotPermissionPromptTests: XCTestCase {
    private final class Probe {
        var granted = false
        var requests = 0
        var helps = 0
        var captures = 0
        var failures: [String] = []
        var activity: [Bool] = []
        var clock = Date(timeIntervalSinceReferenceDate: 0)
    }

    private func makeCoordinator(_ probe: Probe, requested: XCTestExpectation? = nil,
                                 helped: XCTestExpectation? = nil, captured: XCTestExpectation? = nil,
                                 holdHelp: (() async -> Void)? = nil) -> ScreenshotCoordinator {
        let gate = ScreenshotPermissionGate(access: ScreenRecordingAccess(isGranted: { probe.granted }, request: {
            probe.requests += 1
            requested?.fulfill()
        }, now: { probe.clock }))
        let environment = ScreenshotCaptureEnvironment(applicationNotifications: NotificationCenter(),
                                                       workspaceNotifications: NotificationCenter(),
                                                       frontmostApplication: { nil })
        return ScreenshotCoordinator(activityChanged: { probe.activity.append($0) }, captureOverride: {
            probe.captures += 1
            captured?.fulfill()
            throw CancellationError()
        }, captureFailure: { probe.failures.append($0) }, environment: environment,
           permissionGate: gate, permissionHelp: {
            probe.helps += 1
            helped?.fulfill()
        })
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testFirstPressWithoutAccessOnlyAsksMacOS() async {
        let probe = Probe()
        let requested = expectation(description: "System request")
        let coordinator = makeCoordinator(probe, requested: requested)
        coordinator.start()
        await fulfillment(of: [requested], timeout: 2)
        await settle()
        XCTAssertEqual(probe.requests, 1)
        XCTAssertEqual(probe.helps, 0, "Whytap's help must not open beside the system dialog")
        XCTAssertEqual(probe.captures, 0)
        XCTAssertTrue(probe.failures.isEmpty)
        XCTAssertEqual(probe.activity, [], "No capture session starts while macOS is asking")
        XCTAssertFalse(coordinator.isActive)
    }

    func testGrantedAccessCapturesWithoutAsking() async {
        let probe = Probe(); probe.granted = true
        let captured = expectation(description: "Capture")
        let coordinator = makeCoordinator(probe, captured: captured)
        coordinator.start()
        await fulfillment(of: [captured], timeout: 2)
        await settle()
        XCTAssertEqual(probe.requests, 0)
        XCTAssertEqual(probe.helps, 0)
        XCTAssertEqual(probe.captures, 1)
    }

    func testDeniedAccessShowsHelpOnTheNextPressWithoutAskingAgain() async {
        let probe = Probe()
        let requested = expectation(description: "System request"), helped = expectation(description: "Help")
        let coordinator = makeCoordinator(probe, requested: requested, helped: helped)
        coordinator.start()
        await fulfillment(of: [requested], timeout: 2)
        probe.clock += 5
        coordinator.start()
        await fulfillment(of: [helped], timeout: 2)
        await settle()
        XCTAssertEqual(probe.requests, 1, "macOS shows its dialog once; asking again shows nothing")
        XCTAssertEqual(probe.helps, 1)
        XCTAssertEqual(probe.captures, 0)
        XCTAssertTrue(probe.failures.isEmpty)
    }

    func testRepeatsOfTheFirstPressOpenNoSecondWindow() async {
        let probe = Probe()
        let requested = expectation(description: "System request")
        let coordinator = makeCoordinator(probe, requested: requested)
        // A held shortcut or a double delivery of the same press.
        coordinator.start()
        probe.clock += 0.3; coordinator.start()
        probe.clock += 0.3; coordinator.start()
        await fulfillment(of: [requested], timeout: 2)
        await settle()
        XCTAssertEqual(probe.requests, 1)
        XCTAssertEqual(probe.helps, 0, "Only the system dialog is on screen")
        XCTAssertTrue(probe.failures.isEmpty)
        XCTAssertEqual(probe.activity, [])
    }

    func testPressesWhileTheDialogStaysOpenAskOnceAndShowHelpOnce() async {
        let probe = Probe()
        let requested = expectation(description: "System request"), helped = expectation(description: "Help")
        let coordinator = makeCoordinator(probe, requested: requested, helped: helped)
        coordinator.start()
        await fulfillment(of: [requested], timeout: 2)
        // The user presses again later without answering the dialog.
        probe.clock += 10
        coordinator.start(); coordinator.start()
        await fulfillment(of: [helped], timeout: 2)
        await settle()
        XCTAssertEqual(probe.requests, 1, "The system is never asked twice")
        XCTAssertEqual(probe.helps, 1, "Presses while Whytap's help is pending show it once")
        XCTAssertTrue(probe.failures.isEmpty)
    }

    func testGrantAfterTheRequestCapturesOnTheNextPress() async {
        let probe = Probe()
        let requested = expectation(description: "System request"), captured = expectation(description: "Capture")
        let coordinator = makeCoordinator(probe, requested: requested, captured: captured)
        coordinator.start()
        await fulfillment(of: [requested], timeout: 2)
        probe.granted = true
        coordinator.start()
        await fulfillment(of: [captured], timeout: 2)
        await settle()
        XCTAssertEqual(probe.requests, 1)
        XCTAssertEqual(probe.helps, 0)
        XCTAssertEqual(probe.captures, 1)
    }

    func testGateRemembersTheRequestOnlyForThisLaunch() {
        var granted = false
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let gate = ScreenshotPermissionGate(access: ScreenRecordingAccess(isGranted: { granted }, request: {}, now: { clock }))
        XCTAssertEqual(gate.step(), .requestOnly)
        clock += 0.5
        XCTAssertEqual(gate.step(), .ignoreRepeat)
        clock += ScreenshotPermissionGate.repeatInterval
        XCTAssertEqual(gate.step(), .showHelp)
        granted = true
        XCTAssertEqual(gate.step(), .capture)
        let nextLaunch = ScreenRecordingAccess(isGranted: { false }, request: {})
        XCTAssertFalse(nextLaunch.requested)
        XCTAssertEqual(ScreenshotPermissionGate(access: nextLaunch).step(), .requestOnly)
    }

    func testAnotherSurfaceAskingFirstMakesShotShowHelpWithoutAskingAgain() async {
        // The onboarding and Shot share one ScreenRecordingAccess per launch.
        let probe = Probe()
        let requested = expectation(description: "System request"), helped = expectation(description: "Help")
        let access = ScreenRecordingAccess(isGranted: { probe.granted }, request: {
            probe.requests += 1
            requested.fulfill()
        }, now: { probe.clock })
        XCTAssertEqual(access.requestOnce(), .requested)
        await fulfillment(of: [requested], timeout: 2)
        probe.clock += 30
        let environment = ScreenshotCaptureEnvironment(applicationNotifications: NotificationCenter(),
                                                       workspaceNotifications: NotificationCenter(),
                                                       frontmostApplication: { nil })
        let coordinator = ScreenshotCoordinator(activityChanged: { probe.activity.append($0) }, captureOverride: {
            probe.captures += 1; throw CancellationError()
        }, environment: environment, permissionGate: ScreenshotPermissionGate(access: access), permissionHelp: {
            probe.helps += 1; helped.fulfill()
        })
        coordinator.start()
        await fulfillment(of: [helped], timeout: 2)
        XCTAssertEqual(probe.requests, 1)
        XCTAssertEqual(probe.helps, 1)
        XCTAssertEqual(access.requestOnce(), .alreadyRequested(secondsAgo: 30))
    }

    func testRequestOnceAsksAtMostOncePerLaunch() async {
        var requests = 0, granted = false
        let done = expectation(description: "Request")
        let access = ScreenRecordingAccess(isGranted: { granted }, request: { requests += 1; done.fulfill() },
                                           now: { Date(timeIntervalSinceReferenceDate: 0) })
        XCTAssertEqual(access.requestOnce(), .requested)
        XCTAssertEqual(access.requestOnce(), .alreadyRequested(secondsAgo: 0))
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(requests, 1)
        granted = true
        XCTAssertEqual(access.requestOnce(), .granted)
        XCTAssertTrue(access.isGranted)
    }

    func testScreenshotSourceAsksThroughOneAPI() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Sidekey/Screenshots/ScreenshotCoordinator.swift"),
                                encoding: .utf8)
        XCTAssertFalse(source.contains("CGRequestScreenCaptureAccess"),
                       "The legacy request beside ScreenCaptureKit would show a second dialog")
        XCTAssertFalse(source.contains("CGPreflightScreenCaptureAccess"))
    }

    func testDefaultRequestUsesTheSettingsRequest() async {
        // The gate's production request is ScreenRecordingPermissionRequest,
        // whose failure while the dialog is up is not an error.
        var requests = 0
        await ScreenRecordingPermissionRequest.request(isGranted: { false }, requestContent: {
            requests += 1
            throw NSError(domain: "PermissionTest", code: 1)
        })
        XCTAssertEqual(requests, 1)
    }
}

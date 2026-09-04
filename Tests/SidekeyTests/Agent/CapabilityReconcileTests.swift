import XCTest
@testable import Sidekey

final class CapabilityReconcileTests: XCTestCase {
    typealias D = AppDelegate.CapabilityReconcileDecision

    // MARK: - Both off, monitor stays armed for the enable prompt

    func test_bothOff_armed_keepsMonitorAndStopsMeetings() {
        XCTAssertEqual(
            AppDelegate.reconcileDecision(agent: false, google: false, meetings: false, monitorArmed: true),
            D(armMonitor: false, disarmMonitor: false, startMeetings: false, stopMeetings: true))
    }

    // MARK: - Google on, monitor down -> arm + startMeetings

    func test_googleOn_monitorDown_armsAndStartsMeetings() {
        XCTAssertEqual(
            AppDelegate.reconcileDecision(agent: false, google: true, meetings: true, monitorArmed: false),
            D(armMonitor: true, disarmMonitor: false, startMeetings: true, stopMeetings: false))
    }

    // MARK: - Agent on, monitor already up -> no arm (idempotent)

    func test_agentOn_alreadyArmed_noArmNoDisarm() {
        let d = AppDelegate.reconcileDecision(agent: true, google: false, meetings: false, monitorArmed: true)
        XCTAssertFalse(d.armMonitor, "should not re-arm an already-armed monitor")
        XCTAssertFalse(d.disarmMonitor, "should not disarm when agent is enabled")
    }

    // MARK: - Meetings on/off mapping

    func test_meetingsOn_startMeetingsTrue() {
        let d = AppDelegate.reconcileDecision(agent: false, google: false, meetings: true, monitorArmed: false)
        XCTAssertTrue(d.startMeetings)
        XCTAssertFalse(d.stopMeetings)
    }

    func test_meetingsOff_stopMeetingsTrue() {
        let d = AppDelegate.reconcileDecision(agent: false, google: false, meetings: false, monitorArmed: false)
        XCTAssertFalse(d.startMeetings)
        XCTAssertTrue(d.stopMeetings)
    }

    // MARK: - Both agent + google on, monitor down -> arm

    func test_bothOn_monitorDown_arms() {
        let d = AppDelegate.reconcileDecision(agent: true, google: true, meetings: true, monitorArmed: false)
        XCTAssertTrue(d.armMonitor)
        XCTAssertFalse(d.disarmMonitor)
    }

    // MARK: - All off, monitor down -> arm for the enable prompt

    func test_allOff_monitorDown_armsMonitor() {
        let d = AppDelegate.reconcileDecision(agent: false, google: false, meetings: false, monitorArmed: false)
        XCTAssertTrue(d.armMonitor)
        XCTAssertFalse(d.disarmMonitor)
    }
}

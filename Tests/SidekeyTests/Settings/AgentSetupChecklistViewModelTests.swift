import XCTest
@testable import Sidekey

/// Thread-safe call counter for closures that run off the main actor.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@MainActor
final class AgentSetupChecklistViewModelTests: XCTestCase {
    private func makeProbes(
        brew: Bool = true,
        node: Bool = true,
        cli: Bool = true,
        probe: @escaping () async -> ConnectOutcome = { .connected(sessionID: nil) }
    ) -> AgentSetupProbes {
        AgentSetupProbes(
            brewInstalled: { brew },
            nodeInstalled: { node },
            cliInstalled: { cli },
            probe: probe
        )
    }

    func testInitialSnapshotIsCheckingAndNotReady() {
        let vm = AgentSetupChecklistViewModel(probes: makeProbes())
        XCTAssertEqual(vm.snapshot.homebrew, .checking)
        XCTAssertEqual(vm.snapshot.node, .checking)
        XCTAssertEqual(vm.snapshot.cli, .checking)
        XCTAssertEqual(vm.snapshot.signedIn, .checking)
        XCTAssertFalse(vm.snapshot.allSatisfied)
    }

    func testRefreshMarksAllSatisfiedWhenEverythingPresent() async {
        let vm = AgentSetupChecklistViewModel(probes: makeProbes())
        vm.refresh()
        await vm.refreshTask?.value
        XCTAssertEqual(vm.snapshot.homebrew, .satisfied)
        XCTAssertEqual(vm.snapshot.node, .satisfied)
        XCTAssertEqual(vm.snapshot.cli, .satisfied)
        XCTAssertEqual(vm.snapshot.signedIn, .satisfied)
        XCTAssertTrue(vm.snapshot.allSatisfied)
    }

    func testMissingBrewUnsatisfiedWhileOthersStillChecked() async {
        let vm = AgentSetupChecklistViewModel(probes: makeProbes(brew: false))
        vm.refresh()
        await vm.refreshTask?.value
        XCTAssertEqual(vm.snapshot.homebrew, .unsatisfied)
        XCTAssertEqual(vm.snapshot.node, .satisfied)
        XCTAssertEqual(vm.snapshot.cli, .satisfied)
        XCTAssertEqual(vm.snapshot.signedIn, .satisfied)
        XCTAssertFalse(vm.snapshot.allSatisfied)
    }

    /// Probing sign-in without a binary is pointless — step 4 must stay
    /// unsatisfied and the probe must NOT spawn.
    func testMissingCliSkipsProbeAndUnsatisfiesSignIn() async {
        let probeCalls = CallCounter()
        let vm = AgentSetupChecklistViewModel(probes: makeProbes(cli: false, probe: {
            probeCalls.increment()
            return .connected(sessionID: nil)
        }))
        vm.refresh()
        await vm.refreshTask?.value
        XCTAssertEqual(vm.snapshot.cli, .unsatisfied)
        XCTAssertEqual(vm.snapshot.signedIn, .unsatisfied)
        XCTAssertEqual(probeCalls.value, 0)
    }

    func testNotLoggedInLeavesSignInUnsatisfied() async {
        let vm = AgentSetupChecklistViewModel(probes: makeProbes(probe: { .notLoggedIn }))
        vm.refresh()
        await vm.refreshTask?.value
        XCTAssertEqual(vm.snapshot.cli, .satisfied)
        XCTAssertEqual(vm.snapshot.signedIn, .unsatisfied)
        XCTAssertFalse(vm.snapshot.allSatisfied)
    }

    func testProbeFailureCountsAsNotSignedIn() async {
        let vm = AgentSetupChecklistViewModel(
            probes: makeProbes(probe: { .failed(code: "exit_7", message: "boom") }))
        vm.refresh()
        await vm.refreshTask?.value
        XCTAssertEqual(vm.snapshot.signedIn, .unsatisfied)
    }

    /// A tick that lands mid-cycle must be skipped — no overlapping spawn
    /// storms. The next cycle after completion runs normally.
    func testRefreshCyclesAreSerialized() async {
        let probeCalls = CallCounter()
        let probeStarted = expectation(description: "probe started")
        // The probe runs once per cycle and this test drives two cycles.
        probeStarted.assertForOverFulfill = false
        let vm = AgentSetupChecklistViewModel(probes: makeProbes(probe: {
            probeCalls.increment()
            probeStarted.fulfill()
            try? await Task.sleep(nanoseconds: 150_000_000)
            return .connected(sessionID: nil)
        }))
        vm.refresh()
        await fulfillment(of: [probeStarted], timeout: 2)
        vm.refresh()
        vm.refresh()
        await vm.refreshTask?.value
        XCTAssertEqual(probeCalls.value, 1)

        vm.refresh()
        await vm.refreshTask?.value
        XCTAssertEqual(probeCalls.value, 2)
    }

    func testStartKicksImmediateRefreshAndStopIsSymmetric() async {
        // Large interval: the test exercises the immediate refresh, not ticks.
        let vm = AgentSetupChecklistViewModel(probes: makeProbes(), pollInterval: 60)
        vm.start()
        XCTAssertTrue(vm.isPolling)
        XCTAssertNotNil(vm.refreshTask)
        await vm.refreshTask?.value
        XCTAssertTrue(vm.snapshot.allSatisfied)
        vm.stop()
        XCTAssertFalse(vm.isPolling)
        XCTAssertNil(vm.refreshTask)
    }

    func testStopCancelsInFlightRefresh() async {
        let probeStarted = expectation(description: "probe started")
        let vm = AgentSetupChecklistViewModel(
            probes: makeProbes(probe: {
                probeStarted.fulfill()
                try? await Task.sleep(nanoseconds: 150_000_000)
                return .connected(sessionID: nil)
            }),
            pollInterval: 60
        )
        vm.start()
        await fulfillment(of: [probeStarted], timeout: 2)
        let inFlight = vm.refreshTask
        vm.stop()
        XCTAssertNil(vm.refreshTask)
        await inFlight?.value
        // The cancelled cycle must not publish its (stale) result.
        XCTAssertEqual(vm.snapshot.signedIn, .checking)
    }

    func testProviderFactoriesExist() {
        _ = AgentSetupProbes.claude()
        _ = AgentSetupProbes.codex()
    }
}

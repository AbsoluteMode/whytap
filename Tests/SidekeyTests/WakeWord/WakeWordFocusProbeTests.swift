import XCTest
@testable import Sidekey

/// An Electron app answers "no focus" until asked for its accessibility tree.
/// The wake word must get real evidence from it, and still never start
/// without evidence.
@MainActor
final class WakeWordFocusProbeTests: XCTestCase {
    private final class World {
        var front: (pid: pid_t, bundleIdentifier: String?)? = (500, "com.example.electron")
        /// Looks after which the app reports an editable field; nil = never.
        var editableAfterLooks: Int? = 0
        var looks = 0
        var requests: [pid_t] = []
        var started = 0
        var wanted = true
    }

    private func probe(_ world: World) -> WakeWordFocusProbe {
        WakeWordFocusProbe(
            hasEditableFocus: { _, _ in
                world.looks += 1
                guard let after = world.editableAfterLooks else { return false }
                return world.looks > after
            },
            requestTree: { world.requests.append($0) },
            frontmost: { world.front },
            sleep: { _ in await Task.yield() }
        )
    }

    private func settle(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testAnAppThatAlreadyShowsAnEditableFieldStartsAtOnceWithoutBeingAsked() {
        let world = World()
        probe(world).whenEditable(stillWanted: { world.wanted }, start: { world.started += 1 })
        XCTAssertEqual(world.started, 1)
        XCTAssertTrue(world.requests.isEmpty)
    }

    func testAnElectronAppIsAskedOnceAndStartsWhenItsFieldAppears() async {
        let world = World()
        world.editableAfterLooks = 3  // no focus on the first three looks
        let probe = probe(world)
        probe.whenEditable(stillWanted: { world.wanted }, start: { world.started += 1 })
        XCTAssertEqual(world.started, 0, "never starts before the evidence")
        XCTAssertEqual(world.requests, [500])
        await settle { world.started == 1 }
        XCTAssertEqual(world.started, 1)
        XCTAssertEqual(world.requests, [500])
    }

    func testAnAppThatNeverShowsAnEditableFieldNeverStarts() async {
        let world = World()
        world.editableAfterLooks = nil
        let probe = probe(world)
        probe.whenEditable(stillWanted: { world.wanted }, start: { world.started += 1 })
        await settle { world.looks > WakeWordFocusProbe.retryDelays.count }
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(world.started, 0)
        XCTAssertEqual(world.looks, WakeWordFocusProbe.retryDelays.count + 1)
    }

    func testSwitchingAppsOrLosingTheReasonAbandonsTheStart() async {
        let switched = World()
        switched.editableAfterLooks = 2
        let first = probe(switched)
        first.whenEditable(stillWanted: { switched.wanted }, start: { switched.started += 1 })
        switched.front = (900, "com.example.other")
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(switched.started, 0, "the field belonged to another app")

        let busy = World()
        busy.editableAfterLooks = 2
        let second = probe(busy)
        second.whenEditable(stillWanted: { busy.wanted }, start: { busy.started += 1 })
        busy.wanted = false  // a hotkey take began meanwhile
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(busy.started, 0)

        let cancelled = World()
        cancelled.editableAfterLooks = 2
        let third = probe(cancelled)
        third.whenEditable(stillWanted: { cancelled.wanted }, start: { cancelled.started += 1 })
        third.cancel()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(cancelled.started, 0)

        let nothing = World()
        nothing.front = nil
        probe(nothing).whenEditable(stillWanted: { true }, start: { nothing.started += 1 })
        XCTAssertEqual(nothing.started, 0)
    }

    func testPreparingAsksASilentAppOncePerLaunchAndLeavesOthersAlone() {
        let world = World()
        world.editableAfterLooks = nil
        let probe = probe(world)
        probe.prepare(pid: 500, bundleIdentifier: nil)
        probe.prepare(pid: 500, bundleIdentifier: nil)
        XCTAssertEqual(world.requests, [500])
        probe.forget(pid: 500)  // the app quit; its relaunch starts silent again
        probe.prepare(pid: 500, bundleIdentifier: nil)
        XCTAssertEqual(world.requests, [500, 500])

        probe.prepare(pid: 0, bundleIdentifier: nil)
        probe.prepare(pid: ProcessInfo.processInfo.processIdentifier, bundleIdentifier: nil)
        XCTAssertEqual(world.requests, [500, 500], "never an invalid pid or Whytap itself")

        let native = World()  // already shows an editable field
        self.probe(native).prepare(pid: 700, bundleIdentifier: nil)
        XCTAssertTrue(native.requests.isEmpty)
    }
}

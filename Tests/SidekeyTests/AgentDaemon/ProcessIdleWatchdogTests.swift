import XCTest
@testable import Sidekey

final class ProcessIdleWatchdogTests: XCTestCase {
    func testHardFiresAfterSilence() async {
        let hard = expectation(description: "onHard")
        let wd = ProcessIdleWatchdog(softTimeout: 0.05, hardTimeout: 0.1,
                                     onSoft: {}, onHard: { hard.fulfill() })
        wd.start()
        await fulfillment(of: [hard], timeout: 1)
    }

    func testKickResetsAndPreventsHard() async {
        let soft = expectation(description: "onSoft"); soft.isInverted = true
        let wd = ProcessIdleWatchdog(softTimeout: 1.0, hardTimeout: 2.0,
                                     onSoft: { soft.fulfill() }, onHard: {})
        wd.start()
        for _ in 0..<18 { try? await Task.sleep(nanoseconds: 100_000_000); wd.kick() }
        await fulfillment(of: [soft], timeout: 0.2)
        wd.cancel()
    }

    func testSoftFiresBeforeHard() async {
        let soft = expectation(description: "onSoft")
        let wd = ProcessIdleWatchdog(softTimeout: 0.05, hardTimeout: 5,
                                     onSoft: { soft.fulfill() }, onHard: {})
        wd.start()
        await fulfillment(of: [soft], timeout: 1)
        wd.cancel()
    }

    func testCancelPreventsBoth() async {
        let fired = expectation(description: "none"); fired.isInverted = true
        let wd = ProcessIdleWatchdog(softTimeout: 0.05, hardTimeout: 0.1,
                                     onSoft: { fired.fulfill() }, onHard: { fired.fulfill() })
        wd.start(); wd.cancel()
        await fulfillment(of: [fired], timeout: 0.3)
    }
}

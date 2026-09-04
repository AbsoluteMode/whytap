import XCTest
@testable import Sidekey

final class StreamingProgressMonitorTests: XCTestCase {
    /// Audio starts flowing but no partial ever comes back: once `stallSeconds`
    /// elapse from the first-audio mark the monitor reports stalled. A later
    /// partial resets the clock; letting `stallSeconds` elapse again from that
    /// partial re-stalls.
    func testStallWhenAudioFlowsButNoPartial() {
        var now = 0.0
        var m = StreamingProgressMonitor(stallSeconds: 3, now: { now })
        m.noteAudioSent()
        now = 1
        XCTAssertFalse(m.isStalled())                    // 1s since audio start, < 3
        now = 4
        XCTAssertTrue(m.isStalled())                     // 4s since audio start, no partial
        m.notePartial()                                  // partial lands at now == 4
        now = 8
        XCTAssertTrue(m.isStalled())                     // 8-4 = 4 >= 3 → stalled again
    }

    func testPartialResetsTheClock() {
        var now = 0.0
        var m = StreamingProgressMonitor(stallSeconds: 3, now: { now })
        m.noteAudioSent()
        now = 2
        m.notePartial()
        now = 4
        XCTAssertFalse(m.isStalled())                    // 4-2 = 2 < 3
        now = 6
        XCTAssertTrue(m.isStalled())                     // 6-2 = 4 >= 3
    }

    func testNoStallBeforeAnyAudio() {
        var now = 0.0
        let m = StreamingProgressMonitor(stallSeconds: 3, now: { now })
        now = 100
        XCTAssertFalse(m.isStalled())                    // no audio yet → never stalled
    }
}

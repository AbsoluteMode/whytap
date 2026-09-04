import XCTest
@testable import Sidekey

/// Tests for `MeetingContextActiveProbe`: the meeting-bundle allow-list it
/// mirrors from `AudioProcessProbe`, the transitions-only emission contract
/// it shares with `MicInUseProbe`, and the off-main threading of the HAL scan.
@MainActor
final class MeetingContextActiveProbeTests: XCTestCase {

    func testRecognizesSafariWebKitGPUProcessAsMeetingContext() {
        XCTAssertTrue(
            AudioProcessProbe.matchesAnyBrowserBundle("com.apple.WebKit.GPU"),
            "Safari/WebKit can surface active getUserMedia capture as the shared WebKit GPU process"
        )
        XCTAssertTrue(
            MeetingContextActiveProbe.isMeetingContextBundle("com.apple.WebKit.GPU"),
            "MeetingContextActiveProbe's inlined browser mirror must stay in sync with AudioProcessProbe"
        )
    }

    func testRecognizesWebKitHelperNamespaceForVersionVariance() {
        XCTAssertTrue(AudioProcessProbe.matchesAnyBrowserBundle("com.apple.WebKit.WebContent"))
        XCTAssertTrue(MeetingContextActiveProbe.isMeetingContextBundle("com.apple.WebKit.WebContent"))
    }

    func testKeepsKnownSelfNoiseBundlesExcludedFromMeetingContext() {
        for bundleID in ["com.apple.CoreSpeech", "com.rootwise.sidekey"] {
            XCTAssertFalse(AudioProcessProbe.matchesAnyBrowserBundle(bundleID))
            XCTAssertFalse(MeetingContextActiveProbe.isMeetingContextBundle(bundleID))
        }
    }

    func testUnrecognizedBrowsersStayOutsideMeetingContext() {
        // Browsers outside the allow-list (Yandex, Opera) recording the mic do
        // not count as a meeting context; the detector stays quiet for them.
        for bundleID in ["ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera"] {
            XCTAssertFalse(MeetingContextActiveProbe.isMeetingContextBundle(bundleID))
        }
    }

    // MARK: - Emission contract

    /// Same contract as `MicInUseProbe`: a subscriber sees the current state
    /// first, then transitions only. Repeated identical polls must not
    /// re-emit, and a late subscriber is primed with the last emitted value.
    func testHandlePollEmitsCurrentStateThenTransitionsOnly() async throws {
        // A scanner that never sees a meeting bundle, polled rarely: the poll
        // task contributes exactly one initial `false` tick and then stays out
        // of the way while the test drives `handlePoll` by hand.
        let probe = MeetingContextActiveProbe(pollInterval: 3600, scanner: { [] })
        var iterator = probe.subscribe().makeAsyncIterator()

        let initial = await iterator.next()
        XCTAssertEqual(initial, false, "first value is the current (inactive) state")

        probe.handlePoll(active: true, meetingBundles: ["us.zoom.xos"], allBundles: ["us.zoom.xos"])
        probe.handlePoll(active: true, meetingBundles: ["us.zoom.xos"], allBundles: ["us.zoom.xos"])
        probe.handlePoll(active: false, meetingBundles: [], allBundles: [])

        let second = await iterator.next()
        let third = await iterator.next()
        XCTAssertEqual(second, true, "activation is a transition")
        XCTAssertEqual(third, false, "the repeated active tick is swallowed; release is the next transition")

        var late = probe.subscribe().makeAsyncIterator()
        let primed = await late.next()
        XCTAssertEqual(primed, false, "a late subscriber is primed with the last emitted value")

        probe.stop()
    }

    // MARK: - Scan threading

    /// The HAL process scan is ~50 synchronous Mach IPCs to coreaudiod
    /// (6–25 ms at rest, unbounded while a meeting's audio devices are
    /// coming up). Running it on the main thread froze clicks on the
    /// meeting nudge, so the poll loop must invoke the scanner off-main.
    func testPollScannerRunsOffMainThread() async throws {
        let sawMainThread = FirstValueBox()
        let probe = MeetingContextActiveProbe(
            pollInterval: 0.05,
            scanner: {
                sawMainThread.set(Thread.isMainThread)
                return []
            }
        )
        _ = probe.subscribe()

        for _ in 0..<100 {
            if sawMainThread.get() != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        probe.stop()

        XCTAssertEqual(
            sawMainThread.get(), false,
            "HAL scan must run off the main thread (nil = scan never ran)"
        )
    }

    /// Same requirement for the detector's frontmost-app path: its 2s
    /// poll-while-mic-active loop lives on the MainActor, so
    /// `isInMeetingContext` must move the HAL scan off-main itself.
    func testFrontmostMeetingContextScanRunsOffMainThread() async {
        let sawMainThread = FirstValueBox()
        let stub = StubFrontmostDetecting()

        _ = await stub.isInMeetingContext(scan: {
            sawMainThread.set(Thread.isMainThread)
            return []
        })

        XCTAssertEqual(
            sawMainThread.get(), false,
            "HAL scan must run off the main thread (nil = scan never ran)"
        )
    }
}

/// Records the FIRST value set; later sets are ignored. Thread-safe so a
/// `@Sendable` scanner running on any executor can write while the
/// MainActor test polls.
private final class FirstValueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = newValue }
    }

    func get() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Minimal conformer so the extension's `isInMeetingContext` can be
/// exercised without touching NSWorkspace / AppleScript.
@MainActor
private final class StubFrontmostDetecting: FrontmostAppDetecting {
    func isMeetingAppFrontmost() -> Bool { false }
    func isMeetingURLOpenInBrowser() -> Bool { false }
    func isMeetingAppRunning() -> Bool { false }
}

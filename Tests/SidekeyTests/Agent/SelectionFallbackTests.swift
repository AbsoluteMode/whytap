import AppKit
import XCTest
@testable import Sidekey

/// Selection fallback (Cmd+C dance) tests. v3 architecture: the fallback
/// runs OUTSIDE the NSEvent monitor closure (`DispatchQueue.main.async`)
/// after the gesture commits, so synthesised CGEvents have no monitor to
/// re-enter. v1 (#103) and v2 (#106) both broke Right Cmd by posting the
/// CGEvents synchronously inside the flagsChanged handler — these tests
/// codify that the v3 path does not regress to that pattern.
@MainActor
final class SelectionFallbackTests: XCTestCase {
    override func tearDown() {
        ClipboardSuppression.shared.setSuppressed(false)
        super.tearDown()
    }

    // MARK: - Test isolation: real-pasteboard tests must not pollute NSPasteboard.general

    /// Guards against the failure that motivated this fix: the
    /// `testFallbackPreserves…Pasteboard` family used to write fixtures
    /// into `NSPasteboard.general` and leak strings like
    /// `"user-clipboard-string"` into the developer's real clipboard
    /// (then into `ClipboardWatcher` history cards on every test run).
    ///
    /// This meta-test captures the user's pasteboard `changeCount` and
    /// last string, runs every real-pasteboard test inline, and asserts
    /// that the system pasteboard is byte-for-byte the same afterwards.
    /// A regression here means a new test (or a regression in an
    /// existing one) is writing to `.general` again.
    func testRealPasteboardTestsDoNotMutateSystemPasteboard() {
        let general = NSPasteboard.general
        let baselineChangeCount = general.changeCount
        let baselineString = general.string(forType: .string)
        let baselineItems = general.pasteboardItems?.flatMap { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            }
        } ?? []

        testFallbackPreservesStringPasteboard()
        testFallbackPreservesImagePasteboard()
        testFallbackPreservesFileURLsPasteboard()

        XCTAssertEqual(
            general.changeCount,
            baselineChangeCount,
            "Real-pasteboard tests must not mutate NSPasteboard.general. " +
            "If this fails, the fallback's test fixtures are leaking into the developer's clipboard."
        )
        XCTAssertEqual(
            general.string(forType: .string),
            baselineString,
            "NSPasteboard.general string content must be untouched after running real-pasteboard tests."
        )
        let afterItems = general.pasteboardItems?.flatMap { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            }
        } ?? []
        XCTAssertEqual(
            afterItems.map { $0.0 },
            baselineItems.map { $0.0 },
            "Pasteboard item types must match baseline after running real-pasteboard tests."
        )
        XCTAssertEqual(
            afterItems.map { $0.1 },
            baselineItems.map { $0.1 },
            "Pasteboard item data must match baseline after running real-pasteboard tests."
        )
    }

    // MARK: - Architectural regression: no re-entry

    /// **The test v1 and v2 missed.** Verifies that `captureAsync` defers
    /// the Cmd+C dance through its dispatcher rather than running it
    /// synchronously. With the production dispatcher = `DispatchQueue.main.async`,
    /// the dance executes on a fresh runloop tick, outside the NSEvent
    /// monitor closure that started it — synth Cmd+C cannot re-enter the
    /// monitor and cancel the gesture.
    func testSelectionFallbackDoesNotReEnterNSEventMonitor() {
        var dispatcherInvoked = false
        var danceRanSynchronously = false
        var workItem: (() -> Void)?
        let env = makeEnv(
            postCmdCRecorder: { danceRanSynchronously = true },
            dispatcher: { block in
                dispatcherInvoked = true
                workItem = block
            }
        )

        SelectionFallback.captureAsync(
            targetPID: 100,
            env: env.env
        ) { _ in }

        XCTAssertTrue(
            dispatcherInvoked,
            "captureAsync must hand the dance off to the dispatcher; running synchronously means the synthesised Cmd+C re-enters the NSEvent monitor and cancels the gesture."
        )
        XCTAssertFalse(
            danceRanSynchronously,
            "Cmd+C must not be posted inline with the captureAsync call site. v1 and v2 both posted inline and broke Right Cmd."
        )

        workItem?()

        XCTAssertTrue(
            danceRanSynchronously,
            "Once the dispatched block runs, the Cmd+C dance is expected to execute."
        )
    }

    // MARK: - Frontmost-PID guard

    func testFallbackSkippedWhenFrontmostPidChanged() {
        var posted = false
        let env = makeEnv(
            frontmostPID: { 200 },
            postCmdCRecorder: { posted = true }
        )

        var completionValue: String? = "unset"
        var completionCalled = false
        SelectionFallback.captureAsync(
            targetPID: 100,
            env: env.env
        ) { result in
            completionValue = result
            completionCalled = true
        }
        env.runDispatched()

        XCTAssertFalse(posted, "Must not synth Cmd+C into the wrong app.")
        XCTAssertTrue(completionCalled)
        XCTAssertNil(completionValue, "Mismatched frontmost PID returns nil.")
    }

    // MARK: - Happy path

    func testFallbackInvokedWhenFrontmostPidMatches() {
        var posted = false
        var changeCount = 0
        let env = makeEnv(
            frontmostPID: { 100 },
            // A real copy clears + writes the pasteboard, bumping changeCount.
            postCmdCRecorder: { posted = true; changeCount += 1 },
            readPasteboard: { "selected text" },
            currentChangeCount: { changeCount }
        )

        var captured: String? = nil
        SelectionFallback.captureAsync(
            targetPID: 100,
            env: env.env
        ) { result in
            captured = result
        }
        env.runDispatched()

        XCTAssertTrue(posted)
        XCTAssertEqual(captured, "selected text")
    }

    func testFallbackReturnsNilWhenSelectionEmpty() {
        var changeCount = 0
        let env = makeEnv(
            frontmostPID: { 100 },
            postCmdCRecorder: { changeCount += 1 },   // copy happened, but yielded ""
            readPasteboard: { "" },
            currentChangeCount: { changeCount }
        )

        var captured: String? = "untouched"
        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { result in
            captured = result
        }
        env.runDispatched()

        XCTAssertNil(captured, "Empty pasteboard → nil; do not propagate empty selection.")
    }

    func testFallbackReturnsNilWhenPasteboardReadsNil() {
        var changeCount = 0
        let env = makeEnv(
            frontmostPID: { 100 },
            postCmdCRecorder: { changeCount += 1 },   // copy happened, but string read is nil
            readPasteboard: { nil },
            currentChangeCount: { changeCount }
        )

        var captured: String? = "untouched"
        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { result in
            captured = result
        }
        env.runDispatched()

        XCTAssertNil(captured)
    }

    /// The stale-clipboard bug: when the target app has no selection, the
    /// synthetic Cmd+C is a no-op — it copies nothing, so the pasteboard
    /// still holds the user's PREVIOUS clipboard. `changeCount` is the only
    /// reliable signal that a copy actually happened; if it did not move,
    /// the fallback must report "no selection" (nil) instead of leaking the
    /// stale clipboard to the agent as if it were the selected text.
    func testFallbackReturnsNilWhenCmdCDidNotChangePasteboard() {
        let env = makeEnv(
            frontmostPID: { 100 },
            readPasteboard: { "stale clipboard the user copied an hour ago" },
            currentChangeCount: { 7 }   // constant → Cmd+C copied nothing
        )

        var captured: String? = "untouched"
        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { result in
            captured = result
        }
        env.runDispatched()

        XCTAssertNil(
            captured,
            "No selection → Cmd+C is a no-op → changeCount unchanged → must return nil, not the stale clipboard."
        )
    }

    // MARK: - Pasteboard preserve correctness

    func testFallbackPreservesStringPasteboard() {
        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        pb.setString("user-clipboard-string", forType: .string)
        let initialChangeCount = pb.changeCount

        let env = realPasteboardEnv(
            pasteboard: pb,
            frontmostPID: { 100 },
            postCmdCRecorder: {
                // Real Cmd+C is not posted in tests — simulate the app's
                // copy handler placing a different string on the
                // pasteboard, then SelectionFallback restores after read.
                pb.clearContents()
                pb.setString("captured-via-cmd-c", forType: .string)
            }
        )

        var captured: String?
        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { result in
            captured = result
        }
        env.runDispatched()

        XCTAssertEqual(captured, "captured-via-cmd-c")
        XCTAssertEqual(pb.string(forType: .string), "user-clipboard-string")
        XCTAssertGreaterThan(pb.changeCount, initialChangeCount)
    }

    func testFallbackPreservesImagePasteboard() {
        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        let imageBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xDE, 0xAD, 0xBE, 0xEF])
        let item = NSPasteboardItem()
        item.setData(imageBytes, forType: .png)
        pb.writeObjects([item])

        let env = realPasteboardEnv(
            pasteboard: pb,
            frontmostPID: { 100 },
            postCmdCRecorder: {
                pb.clearContents()
                pb.setString("transient-cmd-c-text", forType: .string)
            }
        )

        var captured: String?
        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { result in
            captured = result
        }
        env.runDispatched()

        XCTAssertEqual(captured, "transient-cmd-c-text")
        XCTAssertEqual(
            pb.data(forType: .png),
            imageBytes,
            "PNG bytes must survive the round trip."
        )
    }

    func testFallbackPreservesFileURLsPasteboard() {
        let pb = makeIsolatedPasteboard()
        pb.clearContents()
        let url = URL(fileURLWithPath: "/private/tmp/selection-fallback-test-fixture.txt")
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        pb.writeObjects([item])

        let env = realPasteboardEnv(
            pasteboard: pb,
            frontmostPID: { 100 },
            postCmdCRecorder: {
                pb.clearContents()
                pb.setString("transient", forType: .string)
            }
        )

        var captured: String?
        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { result in
            captured = result
        }
        env.runDispatched()

        XCTAssertEqual(captured, "transient")
        XCTAssertEqual(
            pb.string(forType: .fileURL),
            url.absoluteString,
            "File URL must survive the round trip."
        )
    }

    // MARK: - Suppression timing

    func testFallbackSetsSuppressionDuringAndClearsAfter700ms() {
        var suppressionStates: [Bool] = []
        var scheduledDelay: TimeInterval?
        var scheduledBlock: (() -> Void)?
        let env = makeEnv(
            frontmostPID: { 100 },
            setSuppressed: { flag in suppressionStates.append(flag) },
            scheduleUnsuppress: { delay, block in
                scheduledDelay = delay
                scheduledBlock = block
            }
        )

        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { _ in }
        env.runDispatched()

        XCTAssertEqual(
            suppressionStates,
            [true],
            "Suppression must be raised before pasteboard mutation; unsuppress must be deferred."
        )
        XCTAssertEqual(
            scheduledDelay,
            SelectionFallback.unsuppressDelaySeconds,
            "Delay must exceed one ClipboardWatcher poll interval (500 ms) plus safety margin."
        )

        scheduledBlock?()

        XCTAssertEqual(
            suppressionStates,
            [true, false],
            "Deferred block clears the flag so ClipboardWatcher resumes."
        )
    }

    func testClipboardWatcherSkipsDuringFallbackSuppression() {
        // Exercises the existing contract: while ClipboardSuppression.shared
        // is suppressed, callers can observe that. SelectionFallback must
        // raise it before pasteboard mutation begins.
        ClipboardSuppression.shared.setSuppressed(false)
        var observedDuringDance: Bool = false

        let env = makeEnv(
            frontmostPID: { 100 },
            postCmdCRecorder: {
                observedDuringDance = ClipboardSuppression.shared.isSuppressed
            },
            setSuppressed: { flag in
                ClipboardSuppression.shared.setSuppressed(flag)
            },
            scheduleUnsuppress: { _, block in
                // Run immediately in tests so we can assert post-state.
                block()
            }
        )

        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { _ in }
        env.runDispatched()

        XCTAssertTrue(
            observedDuringDance,
            "ClipboardSuppression must be raised before Cmd+C is posted."
        )
        XCTAssertFalse(
            ClipboardSuppression.shared.isSuppressed,
            "Scheduled unsuppress must clear the flag."
        )
    }

    /// Belt-and-suspenders: after the dance restores the original
    /// pasteboard, the fallback raises the watcher's `skipThrough`
    /// threshold to the post-restore changeCount. The 700 ms
    /// unsuppress delay already covers most race windows, but the
    /// threshold makes the contract independent of timing.
    func testFallbackRaisesSuppressionThresholdAfterRestore() {
        var thresholdCalls: [Int] = []
        let env = makeEnv(
            frontmostPID: { 100 },
            currentChangeCount: { 42 },
            suppressThrough: { count in thresholdCalls.append(count) }
        )

        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { _ in }
        env.runDispatched()

        XCTAssertEqual(
            thresholdCalls,
            [42],
            "fallback must raise the skip-through threshold to the post-restore changeCount"
        )
    }

    /// The threshold call must land AFTER `pasteboardRestore` (so it
    /// reflects the restored changeCount) and BEFORE the deferred
    /// `setSuppressed(false)` fires (so even if unsuppress races a
    /// poll, the threshold catches it).
    func testFallbackOrdersThresholdBeforeUnsuppress() {
        var events: [String] = []
        let env = makeEnv(
            frontmostPID: { 100 },
            postCmdCRecorder: { events.append("postCmdC") },
            setSuppressed: { flag in events.append("flag=\(flag)") },
            scheduleUnsuppress: { _, block in
                events.append("schedule_unsuppress")
                block()
            },
            currentChangeCount: { 7 },
            suppressThrough: { _ in events.append("threshold") },
            pasteboardRestore: { _ in events.append("restore") }
        )

        SelectionFallback.captureAsync(targetPID: 100, env: env.env) { _ in }
        env.runDispatched()

        guard
            let restoreIdx = events.firstIndex(of: "restore"),
            let thresholdIdx = events.firstIndex(of: "threshold"),
            let scheduleIdx = events.firstIndex(of: "schedule_unsuppress")
        else {
            XCTFail("expected all three events in the sequence: \(events)")
            return
        }
        XCTAssertLessThan(restoreIdx, thresholdIdx, "threshold reads post-restore changeCount")
        XCTAssertLessThan(thresholdIdx, scheduleIdx, "threshold must precede unsuppress scheduling")
    }

    // MARK: - Test helpers

    /// Stub environment with a deferred dispatcher. Capture work via
    /// `runDispatched()` instead of calling the production
    /// `DispatchQueue.main.async`.
    private func makeEnv(
        frontmostPID: @escaping () -> pid_t = { 100 },
        postCmdCRecorder: @escaping () -> Void = {},
        readPasteboard: @escaping () -> String? = { "captured" },
        setSuppressed: @escaping (Bool) -> Void = { _ in },
        scheduleUnsuppress: @escaping (TimeInterval, @escaping () -> Void) -> Void = { _, _ in },
        currentChangeCount: @escaping () -> Int = { 0 },
        suppressThrough: @escaping (Int) -> Void = { _ in },
        pasteboardRestore: @escaping (PasteboardSnapshot) -> Void = { _ in },
        dispatcher: ((@escaping () -> Void) -> Void)? = nil
    ) -> StubEnv {
        StubEnv(
            frontmostPID: frontmostPID,
            postCmdCRecorder: postCmdCRecorder,
            readPasteboard: readPasteboard,
            setSuppressed: setSuppressed,
            scheduleUnsuppress: scheduleUnsuppress,
            currentChangeCount: currentChangeCount,
            suppressThrough: suppressThrough,
            pasteboardRestore: pasteboardRestore,
            customDispatcher: dispatcher
        )
    }

    /// Variant that drives the snapshot / restore through a real
    /// `NSPasteboard` instance so pasteboard-preserve tests can
    /// round-trip the actual data the system stores. Tests must pass
    /// an isolated pasteboard (see `makeIsolatedPasteboard()`) — using
    /// `NSPasteboard.general` here would leak test fixtures into the
    /// developer's clipboard and `ClipboardWatcher` history on every
    /// test run.
    private func realPasteboardEnv(
        pasteboard pb: NSPasteboard,
        frontmostPID: @escaping () -> pid_t,
        postCmdCRecorder: @escaping () -> Void
    ) -> StubEnv {
        StubEnv(
            frontmostPID: frontmostPID,
            postCmdCRecorder: postCmdCRecorder,
            readPasteboard: { pb.string(forType: .string) },
            setSuppressed: { _ in },
            scheduleUnsuppress: { _, _ in },
            currentChangeCount: { pb.changeCount },
            suppressThrough: { _ in },
            pasteboardSnapshot: { Pasteboard.snapshot(of: pb) },
            pasteboardRestore: { snap in Pasteboard.restore(snap, into: pb) },
            customDispatcher: nil
        )
    }

    /// A unique private `NSPasteboard` for one test. Named pasteboards
    /// are persistent across processes, so each test uses a fresh
    /// UUID-suffixed name to avoid bleed between tests, between runs,
    /// and across the developer's other tooling. The released pasteboard
    /// is freed automatically when the test scope ends.
    private func makeIsolatedPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name(rawValue: "SidekeyTestPasteboard.\(UUID().uuidString)")
        let pb = NSPasteboard(name: name)
        pb.clearContents()
        return pb
    }
}

/// Wrapper that fits a `SelectionFallback.Env` plus a captured-block list
/// for controlled dispatcher behaviour in tests. The fallback's
/// `dispatcher` parameter is exposed as an injectable closure so this
/// stub can record the dispatched work and run it on demand.
@MainActor
private final class StubEnv {
    private var pending: [() -> Void] = []
    let env: SelectionFallback.Env

    init(
        frontmostPID: @escaping () -> pid_t,
        postCmdCRecorder: @escaping () -> Void,
        readPasteboard: @escaping () -> String?,
        setSuppressed: @escaping (Bool) -> Void,
        scheduleUnsuppress: @escaping (TimeInterval, @escaping () -> Void) -> Void,
        currentChangeCount: @escaping () -> Int = { 0 },
        suppressThrough: @escaping (Int) -> Void = { _ in },
        pasteboardSnapshot: @escaping () -> PasteboardSnapshot = { PasteboardSnapshot(items: []) },
        pasteboardRestore: @escaping (PasteboardSnapshot) -> Void = { _ in },
        customDispatcher: ((@escaping () -> Void) -> Void)?
    ) {
        var collectedPending: [() -> Void] = []
        let recordDispatch: (@escaping () -> Void) -> Void = { block in
            collectedPending.append(block)
        }
        let dispatcher = customDispatcher ?? recordDispatch
        self.env = SelectionFallback.Env(
            frontmostPID: frontmostPID,
            pasteboardSnapshot: pasteboardSnapshot,
            pasteboardRestore: pasteboardRestore,
            setSuppressed: setSuppressed,
            scheduleUnsuppress: scheduleUnsuppress,
            postCmdC: postCmdCRecorder,
            sleepAfterPost: {},
            readPasteboardString: readPasteboard,
            currentChangeCount: currentChangeCount,
            suppressThrough: suppressThrough,
            dispatcher: dispatcher
        )
        // Drain into our list each time runDispatched is invoked.
        self.flushSource = { [unowned self] in
            self.pending.append(contentsOf: collectedPending)
            collectedPending.removeAll()
        }
    }

    private var flushSource: () -> Void = {}

    /// Pull any work that the fallback handed to its dispatcher and run
    /// it inline. Mirrors what `DispatchQueue.main.async` would do once
    /// the runloop ticks, but synchronous so tests assert deterministically.
    func runDispatched() {
        flushSource()
        while !pending.isEmpty {
            let block = pending.removeFirst()
            block()
        }
    }
}

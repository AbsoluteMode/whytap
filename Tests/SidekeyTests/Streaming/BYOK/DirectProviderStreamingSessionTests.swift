import XCTest
@testable import Sidekey

@MainActor
final class DirectProviderStreamingSessionTests: XCTestCase {
    // Minimal fakes
    final class FakeAudio: StreamingAudioSourcing, @unchecked Sendable {
        let chunks: AsyncStream<Data>
        private let cont: AsyncStream<Data>.Continuation
        init() { var c: AsyncStream<Data>.Continuation!; chunks = AsyncStream { c = $0 }; cont = c }
        func start() throws {}
        func stop() { cont.finish() }
        func push(_ d: Data) { cont.yield(d) }
        private(set) var didFinish = false
        func finish() {
            didFinish = true
            stop()
        }
    }
    final class FakeSession: BYOKUpstreamSession, @unchecked Sendable {
        let events: AsyncStream<BYOKStreamEvent>
        let cont: AsyncStream<BYOKStreamEvent>.Continuation
        private(set) var sent: [Data] = []
        private(set) var ended = false
        var finalsJoin: BYOKTranscriptJoin = .wordBoundary
        init() { var c: AsyncStream<BYOKStreamEvent>.Continuation!; events = AsyncStream { c = $0 }; cont = c }
        func sendAudio(_ pcm: Data) async { sent.append(pcm) }
        func endInput() async { ended = true }
        func close() async {}
    }
    struct FakeAdapter: BYOKTranscriptionAdapter {
        let session: FakeSession
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession { session }
    }

    /// Adapter whose `open()` suspends until the test signals, so a `cancel()`
    /// can be made to land WHILE the upstream is being opened (Task 7(e) v2).
    /// Tracks whether the opened upstream was subsequently closed.
    final class GatedAdapter: BYOKTranscriptionAdapter, @unchecked Sendable {
        let session: TrackingSession
        private let gate: AsyncStream<Void>
        private let gateCont: AsyncStream<Void>.Continuation
        init(session: TrackingSession) {
            self.session = session
            (gate, gateCont) = AsyncStream<Void>.makeStream()
        }
        func releaseOpen() { gateCont.yield(()); gateCont.finish() }
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession {
            for await _ in gate { break }  // block until the test releases
            return session
        }
    }

    /// Upstream double that records whether it was closed and never emits a
    /// terminal event on its own (so `run()` only resolves via cancel/teardown
    /// or the watchdog).
    final class TrackingSession: BYOKUpstreamSession, @unchecked Sendable {
        let events: AsyncStream<BYOKStreamEvent>
        let cont: AsyncStream<BYOKStreamEvent>.Continuation
        private(set) var closed = false
        private(set) var ended = false
        init() { var c: AsyncStream<BYOKStreamEvent>.Continuation!; events = AsyncStream { c = $0 }; cont = c }
        func sendAudio(_ pcm: Data) async {}
        func endInput() async { ended = true }
        func close() async { closed = true; cont.finish() }
    }

    /// Task 7(e) v2: a `cancel()` that lands while `adapter.open()` is still
    /// in flight must close the freshly-opened upstream and resolve
    /// `.cancelled`. Before the fix, `run()` did not re-check the cancelled
    /// flag after `open()` returned, leaving a live upstream that could later
    /// resolve `.transcript(...)` (pasting onto whatever has focus on wake).
    func testCancelDuringOpenClosesUpstreamAndCancels() async {
        let audio = FakeAudio()
        let upstream = TrackingSession()
        let adapter = GatedAdapter(session: upstream)
        let session = DirectProviderStreamingSession(
            audioEngine: audio, adapter: adapter, language: nil, terms: []
        )

        let runTask = Task { await session.run() }
        // Let run() reach the suspended `adapter.open()`.
        try? await Task.sleep(nanoseconds: 30_000_000)
        // Cancel lands DURING open.
        await session.cancel()
        // Now let open() return — run() must observe the cancel post-open,
        // close the upstream, and resolve .cancelled.
        adapter.releaseOpen()

        let result = await runTask.value
        XCTAssertEqual(result, .cancelled)
        // Give the post-open teardown a tick.
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(upstream.closed, "upstream opened during cancel must be closed")
    }

    /// Adapter returning a `TrackingSession` (whose `close()` finishes the
    /// event stream, mirroring the real `SonioxBYOKSession`
    /// — `FakeSession.close()` is a no-op and would itself wedge `run()`).
    struct TrackingAdapter: BYOKTranscriptionAdapter {
        let session: TrackingSession
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession { session }
    }

    /// Task 7(b): after the user stops, a hung upstream that never emits
    /// `.done` must not wedge `run()` forever. The watchdog fires, records
    /// `.watchdogTimeout` (its own case so telemetry separates hung finalizes
    /// from transport errors), and closes the upstream (which finishes the
    /// event stream), so `run()` resolves `.failed(.watchdogTimeout)`.
    func testStopWatchdogResolvesFailedWhenUpstreamNeverFinishes() async {
        let audio = FakeAudio()
        let upstream = TrackingSession()  // never emits .done; close() finishes events
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: TrackingAdapter(session: upstream),
            language: nil,
            terms: [],
            stopWatchdog: .milliseconds(80)
        )
        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await session.stop()
        let result = await runTask.value
        XCTAssertEqual(result, .failed(.watchdogTimeout))
        XCTAssertTrue(upstream.closed, "watchdog must close the hung upstream")
    }

    /// Audio source whose `failures` stream is test-drivable — unlike
    /// `FakeAudio`, which inherits the protocol's empty default. Simulates
    /// the engine dying mid-session (route-change restart exhausted).
    final class FailingAudio: StreamingAudioSourcing, @unchecked Sendable {
        let chunks: AsyncStream<Data>
        private let cont: AsyncStream<Data>.Continuation
        let failures: AsyncStream<StreamingAudioEngineError>
        private let failCont: AsyncStream<StreamingAudioEngineError>.Continuation
        init() {
            var c: AsyncStream<Data>.Continuation!
            chunks = AsyncStream { c = $0 }
            cont = c
            var f: AsyncStream<StreamingAudioEngineError>.Continuation!
            failures = AsyncStream { f = $0 }
            failCont = f
        }
        func start() throws {}
        func stop() { cont.finish(); failCont.finish() }
        func fail(_ e: StreamingAudioEngineError) { failCont.yield(e) }
    }

    /// Task 7 review fix 3+4: an engine death mid-recording resolves
    /// `.failed(.audioEngineFailed)` — distinct from transport errors so the
    /// AppDelegate fallback predicate can refuse to re-arm the recorder
    /// against the same dead device.
    func testEngineFailureResolvesAudioEngineFailed() async {
        let audio = FailingAudio()
        let upstream = TrackingSession()  // close() finishes events → run() falls through
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: TrackingAdapter(session: upstream),
            language: nil,
            terms: []
        )
        let runTask = Task { await session.run() }
        // Let run() wire up the failure watcher.
        try? await Task.sleep(nanoseconds: 30_000_000)
        audio.fail(.restartFailed)
        let result = await runTask.value
        XCTAssertEqual(result, .failed(.audioEngineFailed))
        XCTAssertTrue(upstream.closed, "engine failure must close the upstream")
    }

    func testDoneResolvesToTranscript() async {
        let audio = FakeAudio()
        let upstream = FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: audio, adapter: FakeAdapter(session: upstream), language: "en", terms: ["Whytap"]
        )
        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        audio.push(Data([0x01]))
        try? await Task.sleep(nanoseconds: 20_000_000)
        upstream.cont.yield(.done("hello world"))
        let result = await runTask.value
        XCTAssertEqual(result, .transcript("hello world"))
        XCTAssertEqual(upstream.sent, [Data([0x01])])
    }

    /// Soniox-shaped hub/BYOK streams emit committed final segments separately
    /// from the current non-final tail. The live wing must receive the combined
    /// display snapshot once, not blink through "committed prefix" and then
    /// "tail only" as two separate transcript updates.
    func testLiveTranscriptCombinesCommittedFinalWithPartialTail() async {
        let audio = FakeAudio()
        let upstream = FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: FakeAdapter(session: upstream),
            language: nil,
            terms: []
        )
        var updates: [String] = []
        session.onTranscriptUpdate = { updates.append($0) }

        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        upstream.cont.yield(.final("Privet"))
        upstream.cont.yield(.partial(" mir"))
        try? await Task.sleep(nanoseconds: 20_000_000)

        upstream.cont.yield(.done("Privet mir"))
        _ = await runTask.value

        XCTAssertEqual(updates, ["Privet mir"])
    }

    /// Soniox emits per-token finals whose texts carry their own leading
    /// spaces only at word boundaries ("Фи","чи"," по"," фа","кту"). A
    /// `.verbatim` upstream must concatenate them untouched — the prior
    /// word-boundary heuristic inserted a space between every mid-word
    /// subword pair, corrupting `lastDropPartial` into "Фи чи по фа кту"
    /// (pasted raw by the rung-3 degraded salvage).
    func testVerbatimJoinConcatenatesSonioxTokenFinalsWithoutInsertedSpaces() async {
        let audio = FakeAudio()
        let upstream = FakeSession()
        upstream.finalsJoin = .verbatim
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: FakeAdapter(session: upstream),
            language: nil,
            terms: []
        )
        var updates: [String] = []
        session.onTranscriptUpdate = { updates.append($0) }

        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        for token in ["Фи", "чи", " по", " фа", "кту"] {
            upstream.cont.yield(.final(token))
        }
        upstream.cont.yield(.partial(" э"))
        try? await Task.sleep(nanoseconds: 20_000_000)

        upstream.cont.yield(.done("Фичи по факту э"))
        _ = await runTask.value

        XCTAssertEqual(updates.last, "Фичи по факту э")
    }

    /// Punctuation arrives as its own final token (","); `.verbatim` must
    /// keep it tight against the preceding word, not float it with a space.
    func testVerbatimJoinKeepsPunctuationTight() async {
        let audio = FakeAudio()
        let upstream = FakeSession()
        upstream.finalsJoin = .verbatim
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: FakeAdapter(session: upstream),
            language: nil,
            terms: []
        )
        var updates: [String] = []
        session.onTranscriptUpdate = { updates.append($0) }

        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        upstream.cont.yield(.final("вод"))
        upstream.cont.yield(.final(","))
        upstream.cont.yield(.partial(""))
        try? await Task.sleep(nanoseconds: 20_000_000)

        upstream.cont.yield(.done("вод,"))
        _ = await runTask.value

        XCTAssertEqual(updates.last, "вод,")
    }

    /// Regression guard for BYOK providers (Deepgram/ElevenLabs/OpenAI):
    /// their finals are whole words/segments WITHOUT their own spacing, so
    /// the default `.wordBoundary` join must keep inserting the separator.
    func testWordBoundaryJoinStillSeparatesWholeWordFinals() async {
        let audio = FakeAudio()
        let upstream = FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: FakeAdapter(session: upstream),
            language: nil,
            terms: []
        )
        var updates: [String] = []
        session.onTranscriptUpdate = { updates.append($0) }

        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 20_000_000)

        upstream.cont.yield(.final("hello"))
        upstream.cont.yield(.final("world"))
        upstream.cont.yield(.partial(""))
        try? await Task.sleep(nanoseconds: 20_000_000)

        upstream.cont.yield(.done("hello world"))
        _ = await runTask.value

        XCTAssertEqual(updates.last, "hello world")
    }

    func testErrorResolvesToFailed() async {
        let audio = FakeAudio()
        let upstream = FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: audio, adapter: FakeAdapter(session: upstream), language: nil, terms: []
        )
        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        upstream.cont.yield(.error("provider"))
        let result = await runTask.value
        if case .failed = result {} else { XCTFail("expected .failed, got \(result)") }
    }

    func testEndOfStreamSendFailureEventResolvesTypedFailure() async {
        let audio = FakeAudio()
        let upstream = FakeSession()
        // resilient: false — this pins the typed-failure MAPPING (the old
        // immediate-fail path). With resilient ON (the unconditional gate
        // default), `end_of_stream_send_failed` is transport-class and DEGRADES
        // instead of failing — covered by `testEndOfStreamSendFailedDegradesWhenResilient`
        // in the degraded suite. Without this flag the session would degrade and
        // wait for a stop() this test never sends, wedging `run()` (and the suite).
        let session = DirectProviderStreamingSession(
            audioEngine: audio, adapter: FakeAdapter(session: upstream), language: nil, terms: [],
            resilient: false
        )
        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        upstream.cont.yield(.error("end_of_stream_send_failed"))
        let result = await runTask.value
        XCTAssertEqual(result, .failed(.endOfStreamSendFailed))
    }

    /// The hotkey-release path must use the graceful finish (post-release
    /// tail), not the immediate stop — otherwise the engine cuts the mic
    /// at keyUp and the spoken tail is lost. cancel() keeps immediate stop.
    func testStopRequestsGracefulFinish() async {
        let audio = FakeAudio()
        let upstream = FakeSession()
        let session = DirectProviderStreamingSession(
            audioEngine: audio, adapter: FakeAdapter(session: upstream), language: "en", terms: []
        )
        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await session.stop()
        XCTAssertTrue(audio.didFinish, "stop() must call finish() on the engine for graceful post-release tail")
        // Resolve the session so the run task does not leak.
        upstream.cont.yield(.done("tail word"))
        _ = await runTask.value
    }

    /// cancel() (Escape / sleep / quit) must keep the IMMEDIATE stop —
    /// never the graceful finish. The stop()/cancel() asymmetry is the
    /// point of the feature: a release captures the tail, a cancel
    /// discards the take instantly.
    /// (TrackingSession, not FakeSession: cancel() resolves run() via
    /// upstream.close() finishing the events stream, and FakeSession's
    /// close() is a no-op that would wedge run().)
    func testCancelUsesImmediateStopNotFinish() async {
        let audio = FakeAudio()
        let upstream = TrackingSession()
        let session = DirectProviderStreamingSession(
            audioEngine: audio, adapter: TrackingAdapter(session: upstream), language: nil, terms: []
        )
        let runTask = Task { await session.run() }
        try? await Task.sleep(nanoseconds: 30_000_000)
        await session.cancel()
        XCTAssertFalse(audio.didFinish, "cancel() must use immediate stop(), not finish()")
        _ = await runTask.value
    }
}

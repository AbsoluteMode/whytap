import XCTest
@testable import Sidekey

/// B1-T1: ports the v1-hub "resilient Drop delivery" degrade machine to
/// `DirectProviderStreamingSession` (the default v2-whytap-hub path). A
/// transport-class `.error` (or a silent stall) mid-recording must NOT tear
/// down the capture: the session marks the turn `degraded`, closes only the
/// upstream, and keeps the audio engine running so the tee keeps filling the
/// turn buffer. Only on the user's `stop()` does it resolve `.degraded` (never
/// `.failed`), handing the retained audio to the batch-recovery path. With the
/// flag OFF the same error fails immediately (pre-B1 behavior).
///
/// Mirrors `SonioxStreamingSessionDegradedTests` (reusing its
/// `CapturingStubAudioSource`, which keeps `chunks` open on `finish()` and only
/// closes on `stop()`, and returns real bytes from `capturedPCM16()`).
@MainActor
final class DirectProviderStreamingSessionDegradedTests: XCTestCase {

    /// Upstream double whose `events` are test-drivable (so a transport `.error`
    /// can be injected mid-recording) and whose `close()` finishes the events
    /// stream (mirroring `SonioxBYOKSession`). `sendAudio`/
    /// `endInput` are prompt no-ops, so `await audioTask?.value` (the degraded
    /// wait) can never hang on them.
    final class DrivableUpstream: BYOKUpstreamSession, @unchecked Sendable {
        let events: AsyncStream<BYOKStreamEvent>
        private let cont: AsyncStream<BYOKStreamEvent>.Continuation
        private(set) var closed = false
        private(set) var ended = false
        init() {
            var c: AsyncStream<BYOKStreamEvent>.Continuation!
            events = AsyncStream { c = $0 }
            cont = c
        }
        func emit(_ ev: BYOKStreamEvent) { cont.yield(ev) }
        func sendAudio(_ pcm: Data) async {}
        func endInput() async { ended = true }
        func close() async { closed = true; cont.finish() }
    }

    struct DrivableAdapter: BYOKTranscriptionAdapter {
        let session: DrivableUpstream
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession { session }
    }

    /// Resilient ON: a transport `.error` mid-recording degrades the turn (does
    /// NOT resolve, does NOT stop the engine) and keeps capturing. On the user's
    /// stop the result is `.degraded` and `capturedAudioPCM16()` returns the
    /// bytes the tee retained.
    func testTransportErrorMidRecordingDegradesAndKeepsCapturing() async {
        let captured = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let engine = CapturingStubAudioSource(captured: captured)
        let upstream = DrivableUpstream()
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: DrivableAdapter(session: upstream),
            language: nil,
            terms: [],
            resilient: true
        )

        let runTask = Task<StreamingSessionResult, Never> { await session.run() }
        // Let run() open the upstream and wire the event loop.
        try? await Task.sleep(nanoseconds: 40_000_000)

        // The live socket dies mid-recording.
        upstream.emit(.error("transport"))
        // Give the event loop a tick to handle the transport error.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Contract: capture is NOT torn down, the session is NOT resolved.
        XCTAssertFalse(
            engine.didStop,
            "transport error must NOT stop the audio engine — capture continues"
        )
        XCTAssertFalse(
            runTask.isCancelled,
            "session must remain unresolved until the user releases"
        )
        XCTAssertTrue(upstream.closed, "the upstream WS must be closed on degrade")

        // Capture keeps running: a post-error chunk is still accepted.
        engine.emit(Data([0xEE]))

        // The user releases the hotkey. The upstream is already closed, so stop()
        // must skip the watchdog and resolve `.degraded` directly.
        await session.stop()

        let result = await runTask.value
        XCTAssertEqual(
            result, .degraded,
            "broken live stream + retained audio must resolve .degraded"
        )
        XCTAssertTrue(engine.didStop, "stop() must tear the engine down once degraded")
        XCTAssertEqual(
            session.capturedAudioPCM16(), captured,
            "capturedAudioPCM16() must surface the retained PCM for batch recovery"
        )
    }

    /// Flag OFF (default): a transport `.error` mid-recording must take the OLD
    /// path — tear the engine + upstream down and resolve `.failed` immediately,
    /// NEVER `.degraded`. Gating contract: with resilient delivery disabled the
    /// session behaves exactly as before B1.
    func testTransportErrorWhenNotResilientFailsImmediately() async {
        let engine = CapturingStubAudioSource(captured: Data([0xAA, 0xBB]))
        let upstream = DrivableUpstream()
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: DrivableAdapter(session: upstream),
            language: nil,
            terms: [],
            resilient: false
        )

        let runTask = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(nanoseconds: 40_000_000)

        // The live socket dies mid-recording. With resilient OFF the session
        // must resolve on its own (no waiting for stop()) the OLD way: `"transport"`
        // is not a typed code, so it maps to `.unknown`.
        upstream.emit(.error("transport"))

        let result = await runTask.value
        XCTAssertEqual(
            result, .failed(.unknown),
            "flag OFF: a mid-recording transport error must fail immediately (pre-B1), not degrade"
        )
        XCTAssertTrue(
            engine.didStop,
            "flag OFF: the engine must be torn down on the error, as before"
        )
    }

    /// `end_of_stream_send_failed` IS transport-class (socket broke on EOF send,
    /// but audio was captured): resilient ON degrades and keeps capturing.
    func testEndOfStreamSendFailedDegradesWhenResilient() async {
        let captured = Data([0x11, 0x22, 0x33])
        let engine = CapturingStubAudioSource(captured: captured)
        let upstream = DrivableUpstream()
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: DrivableAdapter(session: upstream),
            language: nil,
            terms: [],
            resilient: true
        )

        let runTask = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(nanoseconds: 40_000_000)

        upstream.emit(.error(BYOKStreamErrorCode.endOfStreamSendFailed))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(engine.didStop, "EOF-send-failed (transport) must keep capturing")

        await session.stop()
        let result = await runTask.value
        XCTAssertEqual(result, .degraded)
        XCTAssertEqual(session.capturedAudioPCM16(), captured)
    }

    /// Silent stall (audio flowing, no partial coming back) with resilient ON
    /// degrades the SAME way as a transport error: the stall task marks
    /// `degraded`, closes the upstream, and the session resolves `.degraded` on
    /// the user's stop. Uses a tiny `stallSeconds` so the 1 s poll catches it.
    func testStallMidRecordingDegradesWhenResilient() async {
        let captured = Data([0x44, 0x55, 0x66])
        let engine = CapturingStubAudioSource(captured: captured)
        let upstream = DrivableUpstream()  // never emits a partial → clock never resets
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: DrivableAdapter(session: upstream),
            language: nil,
            terms: [],
            // Watchdog long so it can't be the cause; tiny stall so the poll
            // (1 s tick) trips on the second tick.
            stopWatchdog: .seconds(30),
            stallSeconds: 0.01,
            resilient: true
        )

        let runTask = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(nanoseconds: 40_000_000)
        // Push a chunk so `noteAudioSent()` fires → isStalled() can start to count.
        engine.emit(Data([0x77]))

        // Wait out two stall-check ticks (~2.2 s) so the detector trips and
        // closes the upstream.
        try? await Task.sleep(nanoseconds: 2_300_000_000)
        XCTAssertFalse(
            engine.didStop,
            "stall must close only the upstream, NOT the capture engine"
        )
        XCTAssertTrue(upstream.closed, "stall detector must close the upstream")

        await session.stop()
        let result = await runTask.value
        XCTAssertEqual(result, .degraded, "a silent stall must resolve .degraded")
        XCTAssertEqual(session.capturedAudioPCM16(), captured)
    }

    // MARK: - Task 4: session no-progress hard resolve

    /// Task 4 (BYOK mirror): resilient ON + no partial ever arrives + user never
    /// stops → `run()` must resolve `.degraded` on its own after
    /// `noProgressResolveSeconds`. Mirrors the Soniox session test.
    func testNoProgressResolvesWithoutStop() async {
        let captured = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let engine = CapturingStubAudioSource(captured: captured)
        let upstream = DrivableUpstream()
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: DrivableAdapter(session: upstream),
            language: nil,
            terms: [],
            stopWatchdog: .seconds(30),
            stallSeconds: 0.05,
            noProgressResolveSeconds: 0.15,
            resilient: true
        )

        let runTask = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(nanoseconds: 40_000_000)
        // Push a chunk so `noteAudioSent()` fires and the progress clock starts.
        engine.emit(Data([0x01]))

        // run() must return on its own; no stop() called.
        let result = await runTask.value
        XCTAssertEqual(result, .degraded, "no-progress past threshold must resolve .degraded without stop")
        XCTAssertEqual(
            session.capturedAudioPCM16(), captured,
            "capturedAudioPCM16() must surface the retained PCM for batch recovery"
        )
    }

    /// Task 4 flag-OFF (BYOK mirror): with resilient == false the no-progress
    /// resolve must NOT fire.
    func testNoProgressDoesNotResolveWhenNotResilient() async {
        let engine = CapturingStubAudioSource(captured: Data([0x01, 0x02]))
        let upstream = DrivableUpstream()
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: DrivableAdapter(session: upstream),
            language: nil,
            terms: [],
            stopWatchdog: .seconds(30),
            stallSeconds: 0.05,
            noProgressResolveSeconds: 0.15,
            resilient: false
        )

        let runTask = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(nanoseconds: 40_000_000)
        engine.emit(Data([0x01]))

        // Wait well past the no-progress threshold.
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Must still be unresolved.
        XCTAssertFalse(runTask.isCancelled, "flag OFF: must NOT auto-resolve")

        // Clean up: deliver .done so runTask finishes.
        upstream.emit(.done("ok"))
        let result = await runTask.value
        XCTAssertEqual(result, StreamingSessionResult.transcript("ok"))
    }

    /// Flag OFF: no stall detection at all — audio flows, no partial comes back,
    /// but the session must NOT degrade. It resolves only via the user's stop +
    /// the upstream's terminal `.done` (here delivered after stop), proving the
    /// stall task was never spawned.
    func testStallDoesNotDegradeWhenNotResilient() async {
        let engine = CapturingStubAudioSource(captured: Data([0x01]))
        let upstream = DrivableUpstream()
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: DrivableAdapter(session: upstream),
            language: nil,
            terms: [],
            stopWatchdog: .seconds(30),
            stallSeconds: 0.01,
            resilient: false
        )

        let runTask = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(nanoseconds: 40_000_000)
        engine.emit(Data([0x77]))

        // Well past several stall windows: with the flag off nothing degrades.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertFalse(upstream.closed, "flag OFF: stall detector must not run / close the upstream")

        // Resolve normally so the run task doesn't leak: the provider commits.
        upstream.emit(.done("hello"))
        let result = await runTask.value
        XCTAssertEqual(
            result, .transcript("hello"),
            "flag OFF: no stall degrade — resolves via the normal terminal .done"
        )
    }

    // MARK: - Cancel priority over degrade

    /// Cancel (Escape) AFTER the turn already degraded (transport / stall) must
    /// resolve `.cancelled`, NOT `.degraded`. The user explicitly cancelled, so
    /// the DeliveryResolver must NOT batch-recover and paste the retained audio.
    /// Soniox is immune (its `cancel()` resolves the continuation `.cancelled`
    /// under an exactly-once guard); the BYOK event-loop model resolves by which
    /// after-loop branch wins, so cancel must be checked before the degrade path.
    func testCancelAfterDegradeResolvesCancelledNotDegraded() async {
        let engine = CapturingStubAudioSource(captured: Data([0x01, 0x02, 0x03]))
        let upstream = DrivableUpstream()
        let session = DirectProviderStreamingSession(
            audioEngine: engine,
            adapter: DrivableAdapter(session: upstream),
            language: nil,
            terms: [],
            resilient: true
        )

        let runTask = Task<StreamingSessionResult, Never> { await session.run() }
        try? await Task.sleep(nanoseconds: 40_000_000)

        // Degrade mid-recording (transport error → degraded, capture kept).
        upstream.emit(.error("transport"))
        try? await Task.sleep(nanoseconds: 50_000_000)

        // The user hits Escape → cancel. Must win over the prior degrade.
        await session.cancel()

        let result = await runTask.value
        XCTAssertEqual(
            result, .cancelled,
            "cancel after degrade must resolve .cancelled — Escape means do not deliver"
        )
    }
}

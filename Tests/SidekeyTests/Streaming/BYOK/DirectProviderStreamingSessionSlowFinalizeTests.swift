import XCTest
@testable import Sidekey

/// Production repro of the "thinking hangs 20-40s after release" tail
/// (client_events 2026-06/07: 10 turns in 30 days waited 20-42s between
/// `stop_requested` and `resolving`, 6 of them COMPLETED — i.e. the terminal
/// transcript was applied long after the 10s stop-watchdog should have killed
/// the session).
///
/// The simulated provider mirrors the incident shape (user 15, 2026-07-08):
/// partials keep arriving after the user releases, and the terminal `done`
/// lands only after several stop-watchdog periods (ElevenLabs finalize
/// stalling behind its ~36s force-commit cadence). The contract under test:
/// once `stop()` runs, the session must resolve within ~1 watchdog period —
/// a terminal that arrives later must NOT be waited for.
@MainActor
final class DirectProviderStreamingSessionSlowFinalizeTests: XCTestCase {
    final class FakeAudio: StreamingAudioSourcing, @unchecked Sendable {
        let chunks: AsyncStream<Data>
        private let cont: AsyncStream<Data>.Continuation
        init() { var c: AsyncStream<Data>.Continuation!; chunks = AsyncStream { c = $0 }; cont = c }
        func start() throws {}
        func stop() { cont.finish() }
        func push(_ d: Data) { cont.yield(d) }
        func finish() { stop() }
    }

    /// Upstream that keeps emitting partials and delivers `done` only after
    /// `doneDelay` from `endInput()` — a slow provider finalize. `close()`
    /// finishes the event stream (mirrors `SonioxBYOKSession.close()`).
    final class SlowFinalizeSession: BYOKUpstreamSession, @unchecked Sendable {
        let events: AsyncStream<BYOKStreamEvent>
        let cont: AsyncStream<BYOKStreamEvent>.Continuation
        let doneDelay: Duration
        private(set) var closed = false
        private var doneTask: Task<Void, Never>?
        private var partialTask: Task<Void, Never>?

        init(doneDelay: Duration) {
            self.doneDelay = doneDelay
            var c: AsyncStream<BYOKStreamEvent>.Continuation!
            events = AsyncStream { c = $0 }
            cont = c
        }

        func startPartialDrip(every interval: Duration) {
            partialTask = Task { [cont] in
                var i = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    i += 1
                    cont.yield(.partial("hypothesis \(i)"))
                }
            }
        }

        func sendAudio(_ pcm: Data) async {}

        func endInput() async {
            doneTask = Task { [cont, doneDelay] in
                try? await Task.sleep(for: doneDelay)
                guard !Task.isCancelled else { return }
                cont.yield(.done("final transcript"))
                cont.finish()
            }
        }

        func close() async {
            closed = true
            partialTask?.cancel()
            doneTask?.cancel()
            cont.finish()
        }
    }

    struct SlowAdapter: BYOKTranscriptionAdapter {
        let session: SlowFinalizeSession
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession { session }
    }

    /// Upstream whose `sendAudio` takes `sendDelay` per chunk REGARDLESS of
    /// `close()` — models a half-open socket / throttled uplink where
    /// `URLSessionWebSocketTask.cancel()` does not promptly fail the in-flight
    /// `send` (the "provably non-hanging" comment's assumption turned false).
    final class StuckSendSession: BYOKUpstreamSession, @unchecked Sendable {
        let events: AsyncStream<BYOKStreamEvent>
        let cont: AsyncStream<BYOKStreamEvent>.Continuation
        let sendDelay: Duration
        private(set) var closed = false

        init(sendDelay: Duration) {
            self.sendDelay = sendDelay
            var c: AsyncStream<BYOKStreamEvent>.Continuation!
            events = AsyncStream { c = $0 }
            cont = c
        }

        func sendAudio(_ pcm: Data) async {
            // Unconditional slow send: sleep is not tied to Task cancellation
            // via try (mirrors a URLSession send whose completion only comes
            // back on a TCP timeout, not on task.cancel()).
            let deadline = ContinuousClock.now + sendDelay
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        func endInput() async {}

        func close() async {
            closed = true
            cont.finish()
        }
    }

    struct StuckAdapter: BYOKTranscriptionAdapter {
        let session: StuckSendSession
        func open(language: String?, terms: [String]) async throws -> BYOKUpstreamSession { session }
    }

    /// Degraded-path drain has NO timeout: after a mid-record transport
    /// degrade, `run()` waits on `audioTask` to flush every buffered chunk
    /// into the (closed, but slow) upstream before resolving `.degraded`.
    /// With 20 buffered chunks x 150ms stuck sends, the user stares at
    /// "thinking" for ~3s in this scaled-down repro (20-40s in prod at real
    /// uplink rates) — the stop-watchdog is NOT armed on this path at all.
    func testDegradedStopResolvesPromptlyDespiteStuckSends() async {
        let audio = FakeAudio()
        let upstream = StuckSendSession(sendDelay: .milliseconds(150))
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: StuckAdapter(session: upstream),
            language: nil,
            terms: [],
            stopWatchdog: .milliseconds(200),
            resilient: true
        )

        let runTask = Task { await session.run() }
        try? await Task.sleep(for: .milliseconds(50))
        // Mid-record transport death -> degraded (capture kept, upstream closed).
        upstream.cont.yield(.error("transport"))
        try? await Task.sleep(for: .milliseconds(50))
        // The uplink was slow the whole time: 20 chunks are still queued.
        for _ in 0..<20 { audio.push(Data([0x01])) }

        let stopAt = ContinuousClock.now
        await session.stop()
        let result = await runTask.value
        let waited = ContinuousClock.now - stopAt

        XCTAssertEqual(result, .degraded)
        XCTAssertLessThan(
            waited, .milliseconds(600),
            "degraded drain took \(waited) with stuck sends — no timeout bounds the audioTask flush (prod: 37.6s stop->resolving, user 15 EE2A 2026-07-08)"
        )
    }

    /// Watchdog 200ms, provider `done` at 1.2s (6 watchdog periods late),
    /// partials dripping every 60ms the whole time. After `stop()`, `run()`
    /// must resolve within ~1 watchdog period (allow 3x for CI scheduling),
    /// NOT wait out the late terminal.
    func testStopResolvesWithinWatchdogWhenTerminalIsLate() async {
        let audio = FakeAudio()
        let upstream = SlowFinalizeSession(doneDelay: .milliseconds(1200))
        let session = DirectProviderStreamingSession(
            audioEngine: audio,
            adapter: SlowAdapter(session: upstream),
            language: nil,
            terms: [],
            stopWatchdog: .milliseconds(200),
            resilient: true
        )

        let runTask = Task { await session.run() }
        try? await Task.sleep(for: .milliseconds(50))
        upstream.startPartialDrip(every: .milliseconds(60))
        audio.push(Data([0x01]))
        try? await Task.sleep(for: .milliseconds(150))

        let stopAt = ContinuousClock.now
        await session.stop()
        let result = await runTask.value
        let waited = ContinuousClock.now - stopAt

        XCTAssertLessThan(
            waited, .milliseconds(600),
            "post-stop resolve took \(waited) — the 200ms stop-watchdog did not bound the wait (prod: 20-42s waits against a 10s watchdog)"
        )
        // The late terminal must not have been applied as a full transcript.
        if case .transcript = result {
            XCTFail("late done was applied as .transcript — watchdog never cut the session (result: \(result))")
        }
    }
}

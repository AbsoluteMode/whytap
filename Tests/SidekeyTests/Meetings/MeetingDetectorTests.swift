import XCTest
@testable import Sidekey

/// Stage 2 tests for `MeetingDetector` — the aggregator that turns
/// `MicInUseProbe` (mic running somewhere?) and `SystemAudioVADProbe`
/// (speech in the system mix?) into a single `.triggered(meetingId)` event
/// whenever the heuristic for "a meeting is happening" is satisfied.
///
/// All six tests use hand-driven `AsyncStream`s so the detector's
/// time-based logic can be exercised in milliseconds, not minutes:
///
/// 1. mic ON + system speech ≥ 5s within 10s → fires `.triggered` once
/// 2. mic ON only briefly (< 5s) without system speech → no fire
/// 3. mic ON long (30s) without any system speech → no fire
/// 4. system speech long without mic ever turning on → no fire
/// 5. dismiss → 30-minute cooldown blocks new triggers in same mic-session
/// 6. mic released ≥ 10s then re-acquired starts a new mic-session, which
///    clears the cooldown so a fresh detection can fire
///
/// Time is injected via a `VirtualClock` so the 5s / 10s / 30 min spec
/// constants from `MeetingsConfig` are exercised exactly as production
/// would see them, with zero wall-clock waiting.
@MainActor
final class MeetingDetectorTests: XCTestCase {

    // MARK: - Test scaffolding

    /// Synthetic clock used by `MeetingDetector` for cooldown / window
    /// math. Tests advance it directly so the 30-minute cooldown rule can
    /// be tested in microseconds. Wall-clock time is never consulted.
    final class VirtualClock: MeetingDetectorClocking, @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(start: Date = Date(timeIntervalSince1970: 0)) {
            self.current = start
        }

        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    /// Drives one of the two input streams the detector subscribes to.
    /// `feed(_:)` pushes a state-change onto the stream; the detector picks
    /// it up via `for await`. We keep a continuation handle so the test can
    /// emit deterministically (no real timing involved).
    final class ScriptedProbe: @unchecked Sendable {
        let stream: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation

        init() {
            var captured: AsyncStream<Bool>.Continuation!
            self.stream = AsyncStream { cont in
                captured = cont
            }
            self.continuation = captured
        }

        func feed(_ value: Bool) {
            continuation.yield(value)
        }

        func finish() {
            continuation.finish()
        }
    }

    /// Mic-probe stub backed by a ScriptedProbe. Stage 2's detector also
    /// subscribes via the `MicInUseProbing` seam, so the stub conforms.
    @MainActor
    final class StubMicProbe: MicInUseProbing {
        let scripted = ScriptedProbe()
        private(set) var stopCalls = 0

        nonisolated func feed(_ value: Bool) {
            scripted.feed(value)
        }

        func subscribe() -> AsyncStream<Bool> {
            scripted.stream
        }

        func stop() {
            stopCalls += 1
            scripted.finish()
        }
    }

    /// VAD-probe stub backed by a ScriptedProbe. Each `Bool` represents one
    /// VAD chunk decision (chunk duration is configurable via the detector
    /// init parameter, so tests can keep the numbers round).
    @MainActor
    final class StubVADProbe: SystemAudioVADProbing {
        let scripted = ScriptedProbe()
        private(set) var stopCalls = 0

        nonisolated func feed(_ value: Bool) {
            scripted.feed(value)
        }

        func subscribe() -> AsyncStream<Bool> {
            scripted.stream
        }

        func stop() async {
            stopCalls += 1
            scripted.finish()
        }
    }

    /// Collects events from the detector with a deadline. Single-task
    /// consumer so we never accidentally double-iterate the AsyncStream
    /// (it only supports one iteration).
    private func collectEvents(
        from stream: AsyncStream<MeetingDetectorEvent>,
        count: Int,
        within seconds: Double
    ) async -> [MeetingDetectorEvent] {
        await withTaskGroup(of: [MeetingDetectorEvent].self) { group in
            group.addTask {
                var collected: [MeetingDetectorEvent] = []
                for await event in stream {
                    collected.append(event)
                    if collected.count >= count { return collected }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    /// Confirms the detector did NOT emit within `seconds`. Used by the
    /// "no trigger" tests so we never wait the full 30 minutes etc.
    private func assertNoEvent(
        in stream: AsyncStream<MeetingDetectorEvent>,
        within seconds: Double
    ) async {
        let events = await collectEvents(
            from: stream,
            count: 1,
            within: seconds
        )
        XCTAssertEqual(events.count, 0, "Expected no event but got \(events)")
    }

    /// Convenience: chunk duration we use throughout. 0.25s × 20 chunks = 5s.
    /// Matches FluidAudio's native chunk size (256ms) closely enough to keep
    /// the rolling-window math honest, while letting tests advance time in
    /// big steps.
    private let chunkDuration: TimeInterval = 0.25

    /// Pushes `n` chunks onto the VAD stream with the given decision and
    /// advances the virtual clock by `n × chunkDuration`. Yields between
    /// chunks so the detector's consumer task observes each event.
    private func feedVADChunks(
        _ value: Bool,
        count n: Int,
        vad: StubVADProbe,
        clock: VirtualClock
    ) async {
        for _ in 0..<n {
            clock.advance(chunkDuration)
            vad.feed(value)
            await Task.yield()
        }
        // One extra yield so the last chunk drains before assertions.
        try? await Task.sleep(nanoseconds: 5_000_000)
    }

    private func makeDetector(
        mic: MicInUseProbing,
        vad: SystemAudioVADProbing,
        clock: VirtualClock,
        config: MeetingsConfig
    ) -> MeetingDetector {
        MeetingDetector(
            micProbe: mic,
            vadProbe: vad,
            config: config,
            clock: clock,
            chunkDurationSeconds: chunkDuration
        )
    }

    // MARK: - 6 spec-mandated tests

    /// (1) Happy path: mic on, ≥ 5s of speech within 10s → `.triggered`.
    /// 20 speech-chunks at 0.25s = exactly the 5s minSpeech threshold,
    /// inside a 10s window that the rolling sum keeps.
    func test_triggered_on_mic_and_system_speech_5s_within_10s_window() async {
        let clock = VirtualClock()
        let mic = StubMicProbe()
        let vad = StubVADProbe()
        let config = MeetingsConfig(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        )

        let detector = makeDetector(mic: mic, vad: vad, clock: clock, config: config)
        let stream = detector.events
        detector.subscribe()
        defer { Task { await detector.stop() } }

        // Wait for the consumer task to subscribe.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Mic comes on.
        mic.feed(true)
        await Task.yield()

        // 20 chunks of speech (5s total) within 10s window.
        await feedVADChunks(true, count: 20, vad: vad, clock: clock)

        let events = await collectEvents(from: stream, count: 1, within: 2.0)
        XCTAssertEqual(events.count, 1)
        if case .triggered = events.first {
            // Pass — UUID payload is non-deterministic, only the shape matters.
        } else {
            XCTFail("Expected .triggered, got \(String(describing: events.first))")
        }
    }

    /// (2) Sidekey dictation pattern: mic on for only 3s, no system speech
    /// the whole time. Detector must NOT fire.
    func test_not_triggered_on_short_mic_only_3s() async {
        let clock = VirtualClock()
        let mic = StubMicProbe()
        let vad = StubVADProbe()
        let config = MeetingsConfig(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        )

        let detector = makeDetector(mic: mic, vad: vad, clock: clock, config: config)
        let stream = detector.events
        detector.subscribe()
        defer { Task { await detector.stop() } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        mic.feed(true)
        await Task.yield()

        // 3s of NO speech chunks (12 × 0.25s = 3s).
        await feedVADChunks(false, count: 12, vad: vad, clock: clock)

        // Mic releases at 3s.
        mic.feed(false)
        await Task.yield()

        await assertNoEvent(in: stream, within: 0.5)
    }

    /// (3) Claude web dictation pattern: mic open for 30s but never any
    /// speech detected in the system audio (the dictation feeds the mic,
    /// not the speakers). Detector must NOT fire.
    func test_not_triggered_on_mic_only_30s_no_system_speech() async {
        let clock = VirtualClock()
        let mic = StubMicProbe()
        let vad = StubVADProbe()
        let config = MeetingsConfig(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        )

        let detector = makeDetector(mic: mic, vad: vad, clock: clock, config: config)
        let stream = detector.events
        detector.subscribe()
        defer { Task { await detector.stop() } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        mic.feed(true)
        await Task.yield()

        // 30 seconds of NO speech (120 × 0.25s = 30s).
        await feedVADChunks(false, count: 120, vad: vad, clock: clock)

        await assertNoEvent(in: stream, within: 0.5)
    }

    /// (4) YouTube pattern: lots of speech in system audio, but mic never
    /// turns on. Detector must NOT fire — the "two-way conversation" arm
    /// is missing.
    func test_not_triggered_on_system_audio_no_mic() async {
        let clock = VirtualClock()
        let mic = StubMicProbe()
        let vad = StubVADProbe()
        let config = MeetingsConfig(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        )

        let detector = makeDetector(mic: mic, vad: vad, clock: clock, config: config)
        let stream = detector.events
        detector.subscribe()
        defer { Task { await detector.stop() } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Mic explicitly false; YouTube-like long speech burst (10s).
        mic.feed(false)
        await Task.yield()
        await feedVADChunks(true, count: 40, vad: vad, clock: clock)

        await assertNoEvent(in: stream, within: 0.5)
    }

    /// (5) Cooldown: detector fires once → `engageCooldown()` blocks new
    /// triggers in the same mic-session for the spec's 30 minutes. We
    /// advance the clock by 29 minutes (still within cooldown) and feed
    /// another bursty speech segment; detector must NOT fire again.
    func test_cooldown_30min_after_dismiss_in_same_mic_session() async {
        let clock = VirtualClock()
        let mic = StubMicProbe()
        let vad = StubVADProbe()
        let config = MeetingsConfig(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        )

        let detector = makeDetector(mic: mic, vad: vad, clock: clock, config: config)
        let stream = detector.events
        detector.subscribe()
        defer { Task { await detector.stop() } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        mic.feed(true)
        await Task.yield()

        // First fire.
        await feedVADChunks(true, count: 20, vad: vad, clock: clock)
        let firstBatch = await collectEvents(from: stream, count: 1, within: 2.0)
        XCTAssertEqual(firstBatch.count, 1, "Detector should fire the first time")

        // User dismisses the pill → engage cooldown.
        detector.engageCooldown()

        // 29 minutes of wall-time later (still inside cooldown).
        clock.advance(29 * 60)
        // More speech — but we are still inside the cooldown window AND
        // still inside the same mic-session.
        await feedVADChunks(true, count: 20, vad: vad, clock: clock)

        // Drain a few hundred millis: detector MUST stay silent.
        await assertNoEvent(in: stream, within: 0.3)
    }

    /// (6) Mic-session boundary: same setup as (5), but instead of just
    /// waiting through the cooldown, the mic is released for > 10s then
    /// re-acquired (defines a new mic-session per spec). A subsequent
    /// 5s-speech burst MUST trigger because the cooldown is per-session.
    func test_new_mic_session_resets_cooldown() async {
        let clock = VirtualClock()
        let mic = StubMicProbe()
        let vad = StubVADProbe()
        let config = MeetingsConfig(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        )

        let detector = makeDetector(mic: mic, vad: vad, clock: clock, config: config)
        let stream = detector.events
        detector.subscribe()
        defer { Task { await detector.stop() } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Session 1: fire then cooldown.
        mic.feed(true)
        await Task.yield()
        await feedVADChunks(true, count: 20, vad: vad, clock: clock)
        let firstBatch = await collectEvents(from: stream, count: 1, within: 2.0)
        XCTAssertEqual(firstBatch.count, 1)
        detector.engageCooldown()

        // Mic releases.
        mic.feed(false)
        await Task.yield()

        // 11s of mic-released time → defines a new session per
        // `MeetingsConfig.autoEndMicReleasedSeconds` (10s).
        clock.advance(11)
        // Feed a "still false" tick to give the detector a chance to
        // observe the elapsed time; this is what the production probe's
        // 2s polling cadence would also do.
        mic.feed(false)
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)

        // Session 2 begins.
        mic.feed(true)
        await Task.yield()
        await feedVADChunks(true, count: 20, vad: vad, clock: clock)

        let secondBatch = await collectEvents(from: stream, count: 1, within: 2.0)
        XCTAssertEqual(secondBatch.count, 1, "New mic-session should clear cooldown")
    }

    func test_quick_meeting_context_reconnect_resets_dismissed_suggestion_latch() async {
        let clock = VirtualClock()
        let mic = StubMicProbe()
        let vad = StubVADProbe()
        let config = MeetingsConfig(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        )

        let detector = makeDetector(mic: mic, vad: vad, clock: clock, config: config)
        let stream = detector.events
        detector.subscribe()
        defer { Task { await detector.stop() } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        mic.feed(true)
        await Task.yield()
        await feedVADChunks(true, count: 20, vad: vad, clock: clock)
        let firstBatch = await collectEvents(from: stream, count: 1, within: 2.0)
        XCTAssertEqual(firstBatch.count, 1)

        detector.engageCooldown()
        mic.feed(false)
        await Task.yield()
        clock.advance(0.5)

        mic.feed(true)
        await Task.yield()
        await feedVADChunks(true, count: 20, vad: vad, clock: clock)

        let secondBatch = await collectEvents(from: stream, count: 1, within: 2.0)
        XCTAssertEqual(
            secondBatch.count,
            1,
            "A meeting-context false→true edge is a reconnect even when it is quicker than the recorder auto-end threshold."
        )
    }

    func test_meeting_context_end_after_trigger_emits_contextEnded() async {
        let clock = VirtualClock()
        let mic = StubMicProbe()
        let vad = StubVADProbe()
        let config = MeetingsConfig(
            defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        )

        let detector = makeDetector(mic: mic, vad: vad, clock: clock, config: config)
        let stream = detector.events
        detector.subscribe()
        defer { Task { await detector.stop() } }
        try? await Task.sleep(nanoseconds: 50_000_000)

        mic.feed(true)
        await Task.yield()
        await feedVADChunks(true, count: 20, vad: vad, clock: clock)
        let firstBatch = await collectEvents(from: stream, count: 1, within: 2.0)
        XCTAssertEqual(firstBatch.count, 1)

        mic.feed(false)
        await Task.yield()

        let secondBatch = await collectEvents(from: stream, count: 1, within: 1.0)
        XCTAssertEqual(secondBatch, [.contextEnded])
    }
}

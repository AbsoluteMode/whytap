import Foundation
import XCTest
@testable import Sidekey

/// Stage 9 tests for the sleep/wake lifecycle hooks on
/// `MeetingsCoordinator`. Two new public entry points are exercised:
///
/// - `pauseRecordingIfActive()` — called by `AppDelegate` from
///   `PowerStateCoordinator.onPause` (i.e. `NSWorkspace.willSleep`).
///   Must: pause the active recorder (flushing current chunk), and put
///   the pill into `.paused`.
/// - `resumeRecordingIfPaused(reason:)` — called from
///   `PowerStateCoordinator.onRearm` on both `.full` and `.soft` wakes.
///   Must: try to resume the recorder. On success → pill flips back
    ///   to `.recording`. On failure (audio inputs cannot be reattached
    ///   post-sleep) → finalize the recording via
///   `recorder.stop(reason: .systemError, interruptedBySleep: true)`
///   so the backend pipeline can flag the partial transcript.
///
/// The tests use the same stub seams as the Stage 4 coordinator tests
/// (mic / system / mic-in-use stubs injected via `MeetingRecorder`).
/// PowerStateCoordinator itself is exercised in
/// `PowerStateCoordinatorTests`; here we drive the new coordinator
/// methods directly so the sleep/wake state machine and the meetings
/// lifecycle can be regression-tested in isolation.
@MainActor
final class MeetingsCoordinatorLifecycleTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var stagingRoot: URL!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "com.sidekey.meetings.lifecycle.tests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-lifecycle-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stagingRoot)
        stagingRoot = nil
        testDefaults.removePersistentDomain(forName: defaultsSuiteName)
        testDefaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    // MARK: - (1) Pause on sleep during recording

    /// While `.recording` is active, calling `pauseRecordingIfActive()`
    /// must:
    /// - Mark the underlying recorder as paused (mic released, current
    ///   chunk flushed).
    /// - Transition the pill into `.paused` so the SwiftUI body renders
    ///   the dimmed waveform + Paused affordance.
    func test_pause_on_sleep_during_recording() async throws {
        let env = try await startActiveRecording()
        defer { env.teardown() }

        await env.coordinator.pauseRecordingIfActive()

        // Wait until both the mic stub's stop() has been observed AND
        // the pill's state has rolled into `.paused`. The wait window
        // is generous so a slow CI box does not flake the assertion.
        await waitFor(condition: {
            env.mic.stopCalls >= 1 && {
                if case .paused = env.pill.state { return true }
                return false
            }()
        }, timeout: 2.0)

        XCTAssertGreaterThanOrEqual(env.mic.stopCalls, 1,
                                    "Sleep pause must release the mic source")
        XCTAssertTrue(env.recorder.isPaused,
                      "Recorder must report isPaused after sleep pause")
        switch env.pill.state {
        case .paused(let id, _, _):
            XCTAssertEqual(id, env.meetingId,
                           "Pill must carry the same meetingId across the pause")
        default:
            XCTFail("Pill must be in .paused after sleep pause; got \(env.pill.state)")
        }
    }

    /// Pausing when no recording is active is a no-op (concurrent state
    /// transition guard — if sleep fires while the pill is in
    /// `.suggesting` or `.hidden`, the coordinator must not crash or
    /// touch the pill state).
    func test_pause_on_sleep_is_noop_when_no_active_recording() async {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true
        let detector = LifecycleStubDetector()
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            meetingsEnabled: { true }
        )
        XCTAssertFalse(coordinator.isRecording)
        // Should not crash; should not mutate any state.
        await coordinator.pauseRecordingIfActive()
        XCTAssertFalse(coordinator.isRecording)
    }

    // MARK: - (2) Resume on wake (.full)

    /// After a sleep-induced pause, an `onRearm(.full)` from
    /// `PowerStateCoordinator` must:
    /// - Re-acquire the mic source (start() observed on the stub).
    /// - Flip the pill back to `.recording` with the meetingId preserved.
    /// - Keep the recorder running (isRecording stays true).
    func test_resume_on_wake_full() async throws {
        let env = try await startActiveRecording()
        defer { env.teardown() }

        await env.coordinator.pauseRecordingIfActive()
        await waitFor(condition: {
            if case .paused = env.pill.state { return true }
            return false
        }, timeout: 2.0)

        let micStartsBefore = env.mic.startCalls

        await env.coordinator.resumeRecordingIfPaused(reason: .full)

        await waitFor(condition: {
            env.mic.startCalls > micStartsBefore && {
                if case .recording = env.pill.state { return true }
                return false
            }()
        }, timeout: 2.0)

        XCTAssertGreaterThan(env.mic.startCalls, micStartsBefore,
                             "Wake-resume must re-call mic source start()")
        XCTAssertFalse(env.recorder.isPaused,
                       "Recorder must report isPaused == false after wake-resume")
        XCTAssertTrue(env.coordinator.isRecording,
                      "isRecording must remain true across the sleep/wake cycle")
        switch env.pill.state {
        case .recording(let id, _, _):
            XCTAssertEqual(id, env.meetingId,
                           "Pill must carry the same meetingId across resume")
        default:
            XCTFail("Pill must be in .recording after wake-resume; got \(env.pill.state)")
        }
    }

    // MARK: - (3) Resume on wake (.soft) — same reinstall path

    /// `WakeReason.soft` (wake without paired will-sleep) must take the
    /// same defensive reinstall path as `.full` — the spec calls out
    /// that some macOS sleep modes (display-only, dark sleep) silently
    /// invalidate audio output, so on every wake we reinstall and
    /// resume regardless of which wake flavour fired.
    func test_resume_on_wake_soft_reinstalls_audio_output() async throws {
        let env = try await startActiveRecording()
        defer { env.teardown() }

        await env.coordinator.pauseRecordingIfActive()
        await waitFor(condition: {
            if case .paused = env.pill.state { return true }
            return false
        }, timeout: 2.0)

        let micStartsBefore = env.mic.startCalls

        await env.coordinator.resumeRecordingIfPaused(reason: .soft)

        await waitFor(condition: {
            env.mic.startCalls > micStartsBefore && {
                if case .recording = env.pill.state { return true }
                return false
            }()
        }, timeout: 2.0)

        XCTAssertGreaterThan(env.mic.startCalls, micStartsBefore,
                             ".soft wake must also re-call mic source start()")
        XCTAssertTrue(env.coordinator.isRecording,
                      "isRecording must remain true across a .soft wake")
        if case .recording = env.pill.state {} else {
            XCTFail("Pill must be in .recording after .soft wake; got \(env.pill.state)")
        }
    }

    /// Resume when the coordinator is NOT in a paused recording (sleep
    /// fired without an active meeting, then a wake) must be a no-op —
    /// no crash, no spurious state mutation, no recorder calls.
    func test_resume_is_noop_when_not_paused() async {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true
        let detector = LifecycleStubDetector()
        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            meetingsEnabled: { true }
        )
        await coordinator.resumeRecordingIfPaused(reason: .full)
        await coordinator.resumeRecordingIfPaused(reason: .soft)
        XCTAssertFalse(coordinator.isRecording)
    }

    // MARK: - (4) Reinstall failure → finalize with interruptedBySleep

    /// If `recorder.resume()` throws (audio inputs cannot be reinstalled on
    /// wake), the coordinator must:
    /// - Finalize the recording via `recorder.stop(.systemError,
    ///   interruptedBySleep: true)` so the partial transcript still
    ///   reaches the backend.
    /// - Surface `FinalizedEvent.interruptedBySleep == true` so Stage 6
    ///   can prepend the "interrupted by sleep" marker to the LLM
    ///   prompt context.
    /// - Clear `isRecording` (normal finalize path).
    func test_reinstall_failure_emits_finalize_with_interrupted_flag() async throws {
        let env = try await startActiveRecording(throwingMicOnSecondStart: true)
        defer { env.teardown() }

        await env.coordinator.pauseRecordingIfActive()
        await waitFor(condition: {
            if case .paused = env.pill.state { return true }
            return false
        }, timeout: 2.0)

        // `resumeRecordingIfPaused` returns the forced FinalizedEvent
        // when reinstall fails. Reading the return value lets the test
        // observe the `interruptedBySleep` flag without competing with
        // the coordinator's own finalize-stream drain task (AsyncStream
        // is single-consumer; a `for await` loop here would race the
        // coordinator's internal drain).
        let event = await env.coordinator.resumeRecordingIfPaused(reason: .full)

        XCTAssertNotNil(event, "Resume-failure path must return a finalized event")
        XCTAssertEqual(event?.reason, .systemError,
                       "Finalize reason must be .systemError when resume fails")
        XCTAssertTrue(event?.interruptedBySleep ?? false,
                      "FinalizedEvent.interruptedBySleep must be true on resume failure")

        // Cleanup also runs through the recorder's finalize stream
        // → coordinator's drain task → `handleFinalizedEvent` → activeRecorder nullified.
        await waitFor(condition: {
            !env.coordinator.isRecording
        }, timeout: 2.0)
        XCTAssertFalse(env.coordinator.isRecording,
                       "isRecording must flip false after the forced finalize")
    }

    // MARK: - (5) Pause provenance: user-pause must survive sleep/wake

    /// Privacy invariant: a recording the USER paused must remain paused
    /// even when the system fires a wake event. The wake path
    /// (`resumeRecordingIfPaused`) must distinguish a system-induced pause
    /// from a user-initiated one and skip auto-resume for the latter.
    func test_user_pause_survives_sleep_and_wake() async throws {
        let env = try await startActiveRecording()
        defer { env.teardown() }

        // User taps Pause on the pill — this is the user-initiated path.
        // Wait on the RECORDER-side effect, not the pill state: the pill
        // flips itself to `.paused` synchronously inside `pill.pause()`,
        // BEFORE the coordinator's pillEventConsumer has drained the
        // `.pause` event — so a pill-state wait can be satisfied before
        // `handlePillEvent` sets `pauseProvenance = .user`, and the
        // subsequent `pauseRecordingIfActive()` would stomp provenance to
        // `.system` (flaky on a loaded box). `recorder.isPaused` only
        // flips via `handlePillEvent(.pause)`, which sets provenance
        // BEFORE awaiting `recorder.pause()` — observing it guarantees
        // provenance is already in place.
        env.pill.pause()
        await waitFor(condition: { env.recorder.isPaused }, timeout: 2.0)

        // System sleep fires. `pauseRecordingIfActive` must recognise the
        // recorder is already paused and must NOT overwrite the user provenance.
        await env.coordinator.pauseRecordingIfActive()

        // Wake fires. The coordinator must NOT auto-resume because the pause
        // originated from the user, not the system.
        let event = await env.coordinator.resumeRecordingIfPaused(reason: .full)

        // No forced finalize — we do not expect an event on the return.
        XCTAssertNil(event,
                     "User-paused recording must not trigger a forced finalize on wake")

        // Pill must still be paused — user controls resume via the play button.
        switch env.pill.state {
        case .paused:
            break // correct
        default:
            XCTFail("Pill must remain .paused after wake when the user paused it; got \(env.pill.state)")
        }

        // Recorder must still be paused — no audio reattach happened.
        XCTAssertTrue(env.recorder.isPaused,
                      "Recorder must remain paused — wake must not auto-resume a user-paused recording")

        // isRecording must remain true (the coordinator still has an active recorder).
        XCTAssertTrue(env.coordinator.isRecording,
                      "isRecording must remain true — the recording was paused, not stopped")
    }

    /// Complementary provenance test: a system-induced pause (sleep) MUST be
    /// auto-resumed on wake. This ensures the provenance flag doesn't
    /// accidentally block the normal sleep/wake cycle.
    func test_system_pause_is_auto_resumed_on_wake() async throws {
        let env = try await startActiveRecording()
        defer { env.teardown() }

        // System sleep pauses the recording.
        await env.coordinator.pauseRecordingIfActive()
        await waitFor(condition: {
            if case .paused = env.pill.state { return true }
            return false
        }, timeout: 2.0)

        let micStartsBefore = env.mic.startCalls

        // Wake fires — coordinator must auto-resume because provenance is .system.
        let event = await env.coordinator.resumeRecordingIfPaused(reason: .full)
        XCTAssertNil(event, "System-paused recording must resume without a forced finalize")

        await waitFor(condition: {
            env.mic.startCalls > micStartsBefore && {
                if case .recording = env.pill.state { return true }
                return false
            }()
        }, timeout: 2.0)

        if case .recording = env.pill.state {} else {
            XCTFail("Pill must return to .recording after system-pause + wake; got \(env.pill.state)")
        }
        XCTAssertFalse(env.recorder.isPaused,
                       "Recorder must not be paused after system-pause + wake resume")
    }

    /// Provenance-clobber guard: user pauses THEN the system sleep path also
    /// fires (e.g. the user paused just before closing the lid). The sleep
    /// path must NOT overwrite the user provenance with system provenance,
    /// so wake still does NOT auto-resume.
    func test_sleep_does_not_clobber_user_provenance() async throws {
        let env = try await startActiveRecording()
        defer { env.teardown() }

        // User pauses first. Wait on `recorder.isPaused` (not pill state):
        // the pill flips to `.paused` synchronously, before the coordinator
        // has drained the `.pause` event and set `pauseProvenance = .user`.
        // The recorder-side effect strictly implies provenance is set (see
        // test_user_pause_survives_sleep_and_wake for the full rationale).
        env.pill.pause()
        await waitFor(condition: { env.recorder.isPaused }, timeout: 2.0)

        // System sleep fires while already paused.
        await env.coordinator.pauseRecordingIfActive()

        // Wake fires — must still not auto-resume (user provenance is preserved).
        let event = await env.coordinator.resumeRecordingIfPaused(reason: .full)
        XCTAssertNil(event, "Provenance must not be clobbered: user-paused + sleep must not auto-resume on wake")

        switch env.pill.state {
        case .paused:
            break
        default:
            XCTFail("Pill must still be .paused after user-pause + sleep + wake; got \(env.pill.state)")
        }
    }

    /// Provenance cleared on stop: stopping a user-paused recording must clear
    /// the provenance so a subsequent recording starts clean.
    func test_provenance_cleared_on_stop() async throws {
        let env = try await startActiveRecording()
        defer { env.teardown() }

        // User pauses.
        env.pill.pause()
        await waitFor(condition: {
            if case .paused = env.pill.state { return true }
            return false
        }, timeout: 2.0)

        // User stops (from the paused state).
        await env.coordinator.handleStop(meetingId: env.meetingId, reason: .user)
        await waitFor(condition: { !env.coordinator.isRecording }, timeout: 2.0)

        XCTAssertFalse(env.coordinator.isRecording,
                       "isRecording must be false after stop")
        // After stop, a wake call must be a no-op (no recorder, no provenance).
        let event = await env.coordinator.resumeRecordingIfPaused(reason: .full)
        XCTAssertNil(event, "resumeRecordingIfPaused must be a no-op after stop")
    }

    // MARK: - (6) Idempotent start()

    /// `start()` called twice must not double-wire event consumers. The
    /// observable symptom of double-wiring is that a single detector event
    /// drives `handleDetectorEvent` twice, putting the pill into `.suggesting`
    /// and immediately overwriting with another `.suggesting` — or more
    /// catastrophically, `acceptEvents` fires twice for a single accept. We
    /// assert that the pill transitions to `.suggesting` exactly once, and
    /// that a single dismiss fires `buffer.gc()` exactly once.
    func test_double_start_events_handled_once() async throws {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = LifecycleEmittingDetector()
        let buffer = CountingBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            meetingsEnabled: { true }
        )

        // Call start() twice — the second call must be a no-op.
        coordinator.start()
        coordinator.start()

        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))

        await waitFor(condition: {
            if case .suggesting = pill.state { return true }
            return false
        }, timeout: 2.0)

        // Let a small extra window pass to catch any second handler that might
        // fire asynchronously.
        try await Task.sleep(nanoseconds: 50_000_000)

        // buffer.startCalls must be exactly 1 — if two consumers raced,
        // the count would be 2.
        XCTAssertEqual(buffer.startCalls, 1,
                       "Double start() must not cause buffer.start() to be called twice")

        // Dismiss to assert gc() fires once.
        await pill._testTapDismiss()
        await waitFor(condition: { buffer.gcCalls >= 1 }, timeout: 2.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(buffer.gcCalls, 1,
                       "Double start() must not cause buffer.gc() to be called twice on dismiss")
    }

    // MARK: - Test environment

    /// Container holding the wired-up stubs + concrete recorder for one
    /// test. Created via `startActiveRecording()`; torn down by the
    /// caller in a `defer`.
    private struct LifecycleTestEnv {
        let coordinator: MeetingsCoordinator
        let pill: MeetingPillController
        let recorder: MeetingRecorder
        let mic: ThrowingMicSource
        let sys: LifecycleStubSystemSource
        let micInUse: LifecycleStubMicInUse
        let meetingId: UUID

        @MainActor
        func teardown() {
            mic.finishStream()
            sys.finishStream()
            micInUse.finishStream()
        }
    }

    /// Wire the full Stage 9 surface: detector → pill → coordinator
    /// with a real `MeetingRecorder` running against stub sources. The
    /// recorder is driven into `.recording` so the sleep/wake methods
    /// have a live recorder to act on. Returns the assembled environment;
    /// the caller is responsible for tearing it down (continuations
    /// must be finished so background drain tasks exit).
    private func startActiveRecording(
        throwingMicOnSecondStart: Bool = false
    ) async throws -> LifecycleTestEnv {
        let config = MeetingsConfig(defaults: testDefaults)
        config.isEnabled = true

        let detector = LifecycleEmittingDetector()
        let buffer = LifecycleStubBuffer()
        let pill = MeetingPillController(buffer: buffer)

        let mic = ThrowingMicSource(throwOnSecondStart: throwingMicOnSecondStart)
        let sys = LifecycleStubSystemSource()
        let micInUse = LifecycleStubMicInUse()

        let recorderHolder = LifecycleRecorderHolder()
        let stagingRootCopy = stagingRoot
        let factory: MeetingsCoordinator.RecorderFactory = { _ in
            let recorder = MeetingRecorder(
                micSource: mic,
                systemSource: sys,
                micInUseProbe: micInUse,
                stagingRoot: stagingRootCopy!,
                chunkRotationSeconds: 60,
                autoEndMicReleasedSeconds: 60,
                sampleRate: 16_000
            )
            recorderHolder.recorder = recorder
            return recorder
        }

        let coordinator = MeetingsCoordinator(
            config: config,
            detector: detector,
            pill: pill,
            buffer: buffer,
            recorderFactory: factory,
            meetingsEnabled: { true }
        )
        coordinator.start()

        let meetingId = UUID()
        detector.feed(.triggered(meetingId: meetingId))
        await waitFor(condition: {
            if case .suggesting = pill.state { return true }
            return false
        }, timeout: 2.0)

        await pill._testTapAccept()
        await waitFor(condition: {
            coordinator.isRecording && {
                if case .recording = pill.state { return true }
                return false
            }()
        }, timeout: 2.0)

        guard let recorder = recorderHolder.recorder else {
            throw NSError(domain: "MeetingsCoordinatorLifecycleTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Recorder factory never fired"])
        }

        return LifecycleTestEnv(
            coordinator: coordinator,
            pill: pill,
            recorder: recorder,
            mic: mic,
            sys: sys,
            micInUse: micInUse,
            meetingId: meetingId
        )
    }

    // MARK: - Async helpers (mirrored from MeetingsCoordinatorTests)

    private func waitFor(
        condition: @escaping () async -> Bool,
        timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        work: @escaping () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

// MARK: - Lifecycle test stubs

/// MainActor holder used by the recorder factory closure to expose the
/// created `MeetingRecorder` instance back to the test. The factory
/// runs synchronously on MainActor inside `MeetingsCoordinator.start`,
/// so the assignment is safe.
@MainActor
private final class LifecycleRecorderHolder {
    var recorder: MeetingRecorder?
}

/// Detector stub conforming to `MeetingDetectorEventEmitting`. Mirrors
/// the pattern from `MeetingsCoordinatorTests.StubEmittingDetector` —
/// kept local so this test file stays self-contained.
@MainActor
private final class LifecycleEmittingDetector: MeetingDetectorEventEmitting {
    let events: AsyncStream<MeetingDetectorEvent>
    private let continuation: AsyncStream<MeetingDetectorEvent>.Continuation

    init() {
        let (stream, cont) = AsyncStream<MeetingDetectorEvent>.makeStream()
        self.events = stream
        self.continuation = cont
    }

    func subscribe() {}
    func engageCooldown() {}

    nonisolated func feed(_ event: MeetingDetectorEvent) {
        continuation.yield(event)
    }
}

/// Bare detector stub for the no-op tests that never reach Stage 3
/// wiring.
@MainActor
private final class LifecycleStubDetector: MeetingDetectorProtocol {
    func subscribe() {}
}

/// Buffer stub — no-op snapshot, no-op gc. Lifecycle tests do not
/// exercise the buffer; the recorder factory consumes the snapshot
/// directly via `pill._testTapAccept()`.
private final class LifecycleStubBuffer: MeetingPillBufferAttaching, @unchecked Sendable {
    func start() async {}
    func snapshot() async -> Data { Data() }
    func gc() async {}
}

/// Mic source that can be configured to throw on its second start() —
    /// used to simulate the audio reattach failure path on wake. The
/// first start() always succeeds so `startActiveRecording()` can drive
/// the recorder into `.recording` before sleep is simulated.
private final class ThrowingMicSource: MicSourcing, @unchecked Sendable {
    let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation
    private let lock = NSLock()
    private var _startCalls = 0
    private var _stopCalls = 0
    private let throwOnSecondStart: Bool

    init(throwOnSecondStart: Bool = false) {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        self.samples = stream
        self.continuation = cont
        self.throwOnSecondStart = throwOnSecondStart
    }

    var startCalls: Int { lock.lock(); defer { lock.unlock() }; return _startCalls }
    var stopCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopCalls }

    func start() async throws {
        lock.lock()
        _startCalls += 1
        let calls = _startCalls
        lock.unlock()
        if throwOnSecondStart, calls >= 2 {
            throw NSError(
                domain: "ThrowingMicSource", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Simulated audio reattach failure"]
            )
        }
    }

    func stop() async {
        lock.lock(); defer { lock.unlock() }
        _stopCalls += 1
    }

    nonisolated func finishStream() {
        continuation.finish()
    }
}

/// System audio source stub — vends an `AsyncStream` the recorder
/// drains. Test never feeds samples; we only care about lifecycle.
private final class LifecycleStubSystemSource: SystemAudioBufferStreaming, @unchecked Sendable {
    private let stream: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation

    init() {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        self.stream = stream
        self.continuation = cont
    }

    func audioBufferStream() -> AsyncStream<[Float]> { stream }

    nonisolated func finishStream() {
        continuation.finish()
    }
}

/// MicInUseProbe stub — never feeds anything, so the auto-end watcher
/// stays armed but harmless for the duration of the test.
private final class LifecycleStubMicInUse: MicInUseProbing, @unchecked Sendable {
    private let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    init() {
        let (stream, cont) = AsyncStream<Bool>.makeStream()
        self.stream = stream
        self.continuation = cont
    }

    func subscribe() -> AsyncStream<Bool> { stream }
    func stop() {}

    nonisolated func finishStream() {
        continuation.finish()
    }
}

/// Buffer stub that counts calls to `start()` and `gc()`. Used by the
/// double-start idempotency test to assert that a second `start()` call
/// does not install a second event consumer that causes every event to
/// be handled twice.
private final class CountingBuffer: MeetingPillBufferAttaching, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCalls = 0
    private var _gcCalls = 0

    var startCalls: Int { lock.lock(); defer { lock.unlock() }; return _startCalls }
    var gcCalls: Int { lock.lock(); defer { lock.unlock() }; return _gcCalls }

    func start() async {
        lock.lock(); defer { lock.unlock() }
        _startCalls += 1
    }

    func snapshot() async -> Data { Data() }

    func gc() async {
        lock.lock(); defer { lock.unlock() }
        _gcCalls += 1
    }
}

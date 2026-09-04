import CryptoKit
import Foundation
import XCTest
@testable import Sidekey

/// Stage 4 tests for `MeetingRecorder` — the mixer + chunked writer that
/// takes mic + system audio, mixes them to 16 kHz mono PCM16, and writes
/// `chunk-NNN.wav` files (plus `chunk-NNN.sha256` sidecars) to a per-meeting
/// staging directory.
///
/// All audio sources are injected via the `MicSourcing` /
/// `SystemAudioBufferStreaming` seams so the suite never touches live CoreAudio
/// or `AVAudioEngine`. The chunk-writer math is therefore
/// fully testable; live mic / system audio integration is a user-handoff
/// gate per the Stage 4 plan.
@MainActor
final class MeetingRecorderTests: XCTestCase {

    // MARK: - Test seams

    /// Hand-driven mic source. Tests `feed(_:)` arbitrary `[Float]`
    /// chunks; the recorder consumes them via `samples`.
    final class StubMicSource: MicSourcing, @unchecked Sendable {
        let samples: AsyncStream<[Float]>
        private let continuation: AsyncStream<[Float]>.Continuation
        private let onStart: (@Sendable () -> Void)?
        private(set) var startCalls = 0
        private(set) var stopCalls = 0

        init(onStart: (@Sendable () -> Void)? = nil) {
            let (stream, cont) = AsyncStream<[Float]>.makeStream()
            self.samples = stream
            self.continuation = cont
            self.onStart = onStart
        }

        func start() async throws {
            startCalls += 1
            onStart?()
        }
        func stop() async { stopCalls += 1 }

        nonisolated func feed(_ chunk: [Float]) {
            continuation.yield(chunk)
        }

        nonisolated func finish() {
            continuation.finish()
        }
    }

    /// Hand-driven system audio source — same shape as `StubMicSource`
    /// but conforms to the `SystemAudioBufferStreaming` seam used by
    /// `MeetingRecorder` so the mixer logic sees independent inputs.
    final class StubSystemSource: SystemAudioBufferStreaming, @unchecked Sendable {
        private let stream: AsyncStream<[Float]>
        private let continuation: AsyncStream<[Float]>.Continuation
        private let onSubscribe: (@Sendable () -> Void)?
        private(set) var stopCalls = 0

        init(onSubscribe: (@Sendable () -> Void)? = nil) {
            let (stream, cont) = AsyncStream<[Float]>.makeStream()
            self.stream = stream
            self.continuation = cont
            self.onSubscribe = onSubscribe
        }

        func audioBufferStream() -> AsyncStream<[Float]> {
            onSubscribe?()
            return stream
        }

        func stop() async { stopCalls += 1 }

        nonisolated func feed(_ chunk: [Float]) {
            continuation.yield(chunk)
        }

        nonisolated func finish() {
            continuation.finish()
        }
    }

    /// Hand-driven mic-in-use probe so the auto-end test can flip the
    /// stream from `true` (mic active) to `false` (mic released) without
    /// touching CoreAudio.
    final class StubMicInUse: MicInUseProbing, @unchecked Sendable {
        private let stream: AsyncStream<Bool>
        private let continuation: AsyncStream<Bool>.Continuation
        private(set) var stopCalls = 0

        init() {
            let (stream, cont) = AsyncStream<Bool>.makeStream()
            self.stream = stream
            self.continuation = cont
        }

        func subscribe() -> AsyncStream<Bool> { stream }
        func stop() { stopCalls += 1 }

        nonisolated func feed(_ inUse: Bool) {
            continuation.yield(inUse)
        }
    }

    /// Thread-safe lifecycle trace used by the Bluetooth route regression
    /// test. The production callbacks are MainActor-bound today, but keeping
    /// the seam Sendable prevents the test itself from baking in that detail.
    final class CaptureLifecycleTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [String] = []

        func record(_ event: String) {
            lock.lock()
            events.append(event)
            lock.unlock()
        }

        func snapshot() -> [String] {
            lock.lock()
            let copy = events
            lock.unlock()
            return copy
        }
    }

    // MARK: - Helpers

    /// Allocates a unique temp staging dir for the test, cleaning up on
    /// tear-down so successive runs do not interfere.
    private var stagingRoot: URL!

    override func setUp() {
        super.setUp()
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-meeting-recorder-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stagingRoot)
        stagingRoot = nil
        super.tearDown()
    }

    private func waitFor(
        timeout: TimeInterval,
        condition: @escaping () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - (1) Mixer correctness

    /// Regression (1.18.0): when both input and output use a Bluetooth
    /// headset, starting AVAudioEngine switches the device from its playback
    /// profile to the bidirectional headset profile. The old order subscribed
    /// (and therefore started/rebuilt the CoreAudio process tap) first, then
    /// started the mic. The tap retained the pre-switch ASBD while its
    /// aggregate device ran on the post-switch clock, shrinking the system
    /// track to ~5.3 kHz while the mic remained 16 kHz.
    ///
    /// Stabilize the mic route first; only then may the system source create
    /// its tap and snapshot the route's format.
    func test_start_stabilizes_mic_route_before_system_audio_subscription() async throws {
        let trace = CaptureLifecycleTrace()
        let mic = StubMicSource(onStart: { trace.record("mic.start") })
        let sys = StubSystemSource(onSubscribe: { trace.record("system.subscribe") })
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: StubMicInUse(),
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        try await recorder.start(prerecordSnapshot: Data(), meetingId: UUID())
        XCTAssertEqual(
            trace.snapshot(),
            ["mic.start", "system.subscribe"],
            "Bluetooth mic/profile negotiation must finish before the system tap snapshots its format"
        )

        _ = await recorder.stop(reason: .user)
    }

    /// Mixer must produce per-sample average of mic + system (sum/2),
    /// clamped to [-1, 1], converted to little-endian Int16 PCM. The
    /// recorder runs the mixer on every aligned sample pair it receives;
    /// we feed equal-length arrays and check the produced WAV body.
    func test_mixer_correctness_on_synthesized_inputs() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,           // single chunk for this test
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // Mic: [0.5, -0.5, 1.0]; System: [0.5, 0.5, -1.0].
        // Expected mix: [0.5, 0.0, 0.0] -> PCM16 [16383, 0, 0]
        let micChunk: [Float] = [0.5, -0.5, 1.0]
        let sysChunk: [Float] = [0.5, 0.5, -1.0]
        mic.feed(micChunk)
        sys.feed(sysChunk)

        // Let the recorder process; we don't expect a chunk rotation
        // since chunkRotationSeconds is 60s, but stop() flushes.
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await recorder.stop(reason: .user)

        let chunk = try firstChunk(meetingId: meetingId)
        let pcm = try pcmSamples(from: chunk)
        XCTAssertEqual(pcm.count, 3, "Expected 3 mixed PCM samples")

        // (0.5 + 0.5) / 2 = 0.5 -> 16383 (Int16.max / 2 rounded down)
        XCTAssertEqual(pcm[0], Int16((0.5 as Float) * Float(Int16.max)),
                       "First sample must be the per-sample average scaled to Int16")
        XCTAssertEqual(pcm[1], 0,
                       "Second sample = (-0.5 + 0.5) / 2 = 0")
        XCTAssertEqual(pcm[2], 0,
                       "Third sample = (1.0 + -1.0) / 2 = 0")
    }

    /// Regression (1.15.x): `stop()` must tear down the system-audio source
    /// (the CoreAudio process tap), not just the mic. A lost
    /// `await systemSource.stop()` left the tap running after every meeting,
    /// so `kAudioProcessPropertyIsRunningInput` stayed true for the app and
    /// the macOS "recording" indicator never cleared until the next meeting
    /// rebuilt the tap. Both sources must be released on stop.
    func test_stop_tears_down_both_mic_and_system_audio_sources() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        try await recorder.start(prerecordSnapshot: Data(), meetingId: UUID())
        _ = await recorder.stop(reason: .user)

        XCTAssertEqual(sys.stopCalls, 1,
                       "stop() must tear down the system-audio source (CoreAudio tap) so the recording indicator clears")
        XCTAssertEqual(mic.stopCalls, 1,
                       "stop() must also stop the mic source")
    }

    // MARK: - (2) Chunk rotation at chunkRotationSeconds boundary

    /// Feeding enough samples to cross the chunk rotation boundary must
    /// produce a new `chunk-NNN.wav` on disk. The test feeds two chunks
    /// of 0.5s + 0.6s (= 1.1s) with a 1s rotation budget, then asserts
    /// `chunk-001.wav` exists after `stop()`.
    func test_chunk_rotation_at_30s() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        // 1s rotation budget instead of 30s so the test runs fast.
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 1,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // First half-second (8000 samples per channel)
        let half = [Float](repeating: 0.2, count: 8_000)
        mic.feed(half)
        sys.feed(half)
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Second 0.6s (9600 samples) — total now 1.1s, crosses rotation.
        let extra = [Float](repeating: 0.2, count: 9_600)
        mic.feed(extra)
        sys.feed(extra)
        try? await Task.sleep(nanoseconds: 300_000_000)

        _ = await recorder.stop(reason: .user)

        let dir = stagingDir(meetingId: meetingId)
        let chunks = try chunkURLs(in: dir)
        XCTAssertGreaterThanOrEqual(chunks.count, 2,
                                    "Crossing the rotation boundary must produce ≥ 2 chunks; got \(chunks.count)")
        XCTAssertEqual(chunks[0].lastPathComponent, "chunk-000.wav",
                       "Chunks are 0-indexed")
        XCTAssertEqual(chunks[1].lastPathComponent, "chunk-001.wav",
                       "Second chunk follows the rotation")
    }

    func test_reconnect_appends_chunks_without_overwriting_previous_segment() async throws {
        let meetingId = UUID()

        let firstMic = StubMicSource()
        let firstSystem = StubSystemSource()
        let first = MeetingRecorder(
            micSource: firstMic,
            systemSource: firstSystem,
            micInUseProbe: StubMicInUse(),
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )
        try await first.start(prerecordSnapshot: Data(), meetingId: meetingId)
        firstMic.feed([0.2, 0.2])
        firstSystem.feed([0.2, 0.2])
        try? await Task.sleep(nanoseconds: 100_000_000)
        let firstEvent = await first.stop(reason: .autoEnd)
        let originalBytes = try Data(contentsOf: firstEvent.chunkURLs[0])

        let secondMic = StubMicSource()
        let secondSystem = StubSystemSource()
        let second = MeetingRecorder(
            micSource: secondMic,
            systemSource: secondSystem,
            micInUseProbe: StubMicInUse(),
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )
        try await second.start(prerecordSnapshot: Data(), meetingId: meetingId)
        secondMic.feed([0.7, 0.7])
        secondSystem.feed([0.7, 0.7])
        try? await Task.sleep(nanoseconds: 100_000_000)
        let combined = await second.stop(reason: .user)

        XCTAssertEqual(
            combined.chunkURLs.map(\.lastPathComponent),
            ["chunk-000.wav", "chunk-001.wav"]
        )
        XCTAssertEqual(try Data(contentsOf: combined.chunkURLs[0]), originalBytes)
        XCTAssertNotEqual(try Data(contentsOf: combined.chunkURLs[1]), originalBytes)
        XCTAssertGreaterThan(combined.totalDurationSeconds, firstEvent.totalDurationSeconds)
    }

    // MARK: - (3) Chunk format: 16 kHz mono PCM16 RIFF header

    /// Every chunk on disk must be a valid 16 kHz mono PCM16 WAV — the
    /// first 44 bytes form the canonical RIFF/WAVE/fmt /data header
    /// (PCM = format 1, channels = 1, sampleRate = 16000, bits = 16).
    func test_chunk_format_pcm16_mono_16khz_riff_header() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        let chunk = [Float](repeating: 0.1, count: 1000)
        mic.feed(chunk)
        sys.feed(chunk)
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await recorder.stop(reason: .user)

        let chunkURL = try firstChunk(meetingId: meetingId)
        let data = try Data(contentsOf: chunkURL)
        XCTAssertGreaterThanOrEqual(data.count, 44, "WAV file must have at least the 44-byte header")

        // RIFF header
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")

        // fmt sub-chunk: size=16, audioFormat=1 (PCM), channels=1, sampleRate=16000, bitsPerSample=16
        let fmtChunkSize = readUInt32LE(data, at: 16)
        XCTAssertEqual(fmtChunkSize, 16)
        let audioFormat = readUInt16LE(data, at: 20)
        XCTAssertEqual(audioFormat, 1, "Audio format must be 1 (PCM)")
        let channels = readUInt16LE(data, at: 22)
        XCTAssertEqual(channels, 1, "Channels must be 1 (mono)")
        let sampleRate = readUInt32LE(data, at: 24)
        XCTAssertEqual(sampleRate, 16_000, "Sample rate must be 16000")
        let bitsPerSample = readUInt16LE(data, at: 34)
        XCTAssertEqual(bitsPerSample, 16, "Bits per sample must be 16")

        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
    }

    // MARK: - (4) SHA256 sidecar matches chunk bytes

    /// Each `chunk-NNN.wav` must be accompanied by a `chunk-NNN.sha256`
    /// sidecar whose content is the hex-encoded SHA256 of the chunk
    /// file's bytes. Stage 5 chunked upload uses the sidecar to verify
    /// resumability without rereading the file.
    func test_chunk_sha256_sidecar_written() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        let chunk = [Float](repeating: 0.3, count: 500)
        mic.feed(chunk)
        sys.feed(chunk)
        try? await Task.sleep(nanoseconds: 200_000_000)
        _ = await recorder.stop(reason: .user)

        let chunkURL = try firstChunk(meetingId: meetingId)
        let sidecarURL = chunkURL.deletingPathExtension()
            .appendingPathExtension("sha256")

        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path),
                      "Sidecar .sha256 must exist next to the chunk")

        let chunkBytes = try Data(contentsOf: chunkURL)
        let expectedHash = Self.hexSHA256(chunkBytes)
        let sidecarContent = try String(contentsOf: sidecarURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(sidecarContent, expectedHash,
                       "Sidecar must contain the hex SHA256 of the chunk file")
    }

    // MARK: - (5) Auto-end after autoEndMicReleasedSeconds

    /// Once the mic-in-use probe has reported `true`, a later `false` for
    /// longer than
    /// `autoEndMicReleasedSeconds`, the recorder must auto-finalize and
    /// emit a `FinalizedEvent` with `reason: .autoEnd`.
    func test_auto_end_after_10s_mic_release() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        // 100ms threshold for the test so we don't wait 10s real time.
        // Startup grace 0: this test exercises the bare release timer.
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 0.1,
            autoEndStartupGraceSeconds: 0,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // Feed a sample first so a non-empty chunk gets written.
        let chunk = [Float](repeating: 0.05, count: 200)
        mic.feed(chunk)
        sys.feed(chunk)

        // Drain the finalize stream for the auto-end event.
        let finalizedStream = recorder.finalizedStream
        let collector = Task { () -> MeetingRecorder.FinalizedEvent? in
            for await event in finalizedStream {
                return event
            }
            return nil
        }

        // Establish a real active -> released transition. An initial false
        // alone is only the probe's cached pre-recording state.
        micInUse.feed(true)
        micInUse.feed(false)

        // Wait up to 2s for the auto-end to land.
        let event = await withTaskGroup(of: MeetingRecorder.FinalizedEvent?.self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        XCTAssertNotNil(event, "auto-end watcher must fire FinalizedEvent within 2s")
        XCTAssertEqual(event?.reason, .autoEnd,
                       "FinalizedEvent.reason must be .autoEnd when mic-released > threshold")
        XCTAssertEqual(event?.meetingId, meetingId,
                       "FinalizedEvent must carry the same meetingId")
    }

    func test_initial_inactive_mic_does_not_auto_end_recording() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 0.1,
            sampleRate: 16_000
        )

        try await recorder.start(prerecordSnapshot: Data(), meetingId: UUID())
        mic.feed([Float](repeating: 0.05, count: 200))
        sys.feed([Float](repeating: 0.05, count: 200))

        // The production probe seeds subscribers with its cached state. A
        // meeting that has not used its own mic yet commonly starts as false.
        micInUse.feed(false)
        try? await Task.sleep(nanoseconds: 300_000_000)

        let stillRunning = await recorder.isRunning
        XCTAssertTrue(stillRunning, "cached initial false must not stop Notes")

        let event = await recorder.stop(reason: .user)
        XCTAssertEqual(event.reason, .user)
    }

    /// Meeting apps flap the mic while joining a call (Zoom holds it in
    /// the prejoin preview, releases it, then re-acquires it once
    /// conference audio connects). A release observed during the
    /// recording's first `autoEndStartupGraceSeconds` must therefore not
    /// finalize at the bare `autoEndMicReleasedSeconds` threshold — the
    /// watcher defers so auto-end cannot land before the recording is at
    /// least grace-old. If the mic stays released past the grace, the
    /// recording still auto-ends.
    func test_auto_end_defers_until_startup_grace_elapses() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 0.1,
            autoEndStartupGraceSeconds: 1.0,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)
        mic.feed([Float](repeating: 0.05, count: 200))
        sys.feed([Float](repeating: 0.05, count: 200))

        let finalizedStream = recorder.finalizedStream
        let collector = Task { () -> MeetingRecorder.FinalizedEvent? in
            for await event in finalizedStream {
                return event
            }
            return nil
        }

        // Join-flap right after start: active, then released.
        micInUse.feed(true)
        micInUse.feed(false)

        // Well past the 0.1s threshold but inside the 1s grace: the
        // recording must still be running.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let runningDuringGrace = await recorder.isRunning
        XCTAssertTrue(
            runningDuringGrace,
            "auto-end must not fire during the startup grace"
        )

        // Mic stays released: once the grace elapses auto-end fires.
        let event = await withTaskGroup(of: MeetingRecorder.FinalizedEvent?.self) { group in
            group.addTask { await collector.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        XCTAssertEqual(
            event?.reason, .autoEnd,
            "auto-end must still fire once the startup grace has elapsed"
        )
        XCTAssertEqual(event?.meetingId, meetingId)
    }

    // MARK: - (6) Stop during chunk writes partial chunk + sidecar

    /// Calling `stop()` mid-chunk must flush the partial samples already
    /// captured into a chunk file (with sidecar) — we must not lose the
    /// in-flight portion of the recording. The test feeds < rotation
    /// worth of samples, then stops.
    func test_stop_during_chunk_writes_partial_chunk_and_sidecar() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // Only 0.05 s of audio — far less than 60 s rotation budget.
        let small = [Float](repeating: 0.4, count: 800)
        mic.feed(small)
        sys.feed(small)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let event = await recorder.stop(reason: .user)
        XCTAssertEqual(event.reason, .user)

        let chunkURL = try firstChunk(meetingId: meetingId)
        let sidecarURL = chunkURL.deletingPathExtension().appendingPathExtension("sha256")

        XCTAssertTrue(FileManager.default.fileExists(atPath: chunkURL.path),
                      "Partial chunk must be persisted on stop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path),
                      "Sidecar must be persisted alongside the partial chunk")

        let pcm = try pcmSamples(from: chunkURL)
        XCTAssertEqual(pcm.count, 800,
                       "Partial chunk must contain the 800 mixed samples we fed before stop")
    }

    // MARK: - (7) Asymmetric source handling — single-source fallback

    /// When the system audio source never delivers samples (e.g. Slack
    /// Huddle is muted, the system source stops callbacks because no app is
    /// emitting sound, or the source dies silently), the recorder must
    /// still persist mic samples to disk. Before this fix `drainAlignedPairs`
    /// blocked on `min(mic, system) == 0` and `finalize()` discarded the
    /// accumulated mic queue, so a 15-minute meeting could finalize with
    /// zero audio written. The expected behavior is that all mic samples
    /// survive to the chunk file.
    func test_chunk_written_with_mic_only_samples_when_system_stream_silent() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // 1.0 s of mic only — system source never feeds.
        let micSamples = [Float](repeating: 0.4, count: 16_000)
        mic.feed(micSamples)

        try? await Task.sleep(nanoseconds: 300_000_000)
        _ = await recorder.stop(reason: .user)

        let chunkURL = try firstChunk(meetingId: meetingId)
        let pcm = try pcmSamples(from: chunkURL)
        XCTAssertEqual(
            pcm.count, 16_000,
            "Recorder must persist mic samples to disk even when system audio stream emits no callbacks; current code drops them on finalize."
        )
    }

    func test_finalized_duration_uses_written_audio_samples_not_wall_clock() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // Feed exactly 1s of audio immediately. Wall-clock elapsed before
        // stop is much smaller, so this pins billing duration to written
        // audio samples rather than the UI/live timer.
        let oneSecond = [Float](repeating: 0.25, count: 16_000)
        mic.feed(oneSecond)
        sys.feed(oneSecond)
        try? await Task.sleep(nanoseconds: 200_000_000)

        let event = await recorder.stop(reason: .user)

        XCTAssertEqual(event.totalDurationSeconds, 1.0, accuracy: 0.0001)
        let chunkURL = try firstChunk(meetingId: meetingId)
        XCTAssertEqual(try pcmSamples(from: chunkURL).count, 16_000)
    }

    /// Variant of the above where the system source delivers samples for
    /// the first second, then goes silent for the rest of the recording.
    /// Mirrors the production failure: chunks 000-002 captured fine, then
    /// system audio stalled for 15 min while mic kept talking.
    func test_chunk_keeps_mic_audio_after_system_stream_goes_silent_midway() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // Phase A: 0.5 s of both → mixed pairs.
        let phaseA = [Float](repeating: 0.4, count: 8_000)
        mic.feed(phaseA)
        sys.feed(phaseA)
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Phase B: 0.5 s of mic only — system source has died.
        let phaseB = [Float](repeating: 0.4, count: 8_000)
        mic.feed(phaseB)
        try? await Task.sleep(nanoseconds: 200_000_000)

        _ = await recorder.stop(reason: .user)

        let chunkURL = try firstChunk(meetingId: meetingId)
        let pcm = try pcmSamples(from: chunkURL)
        XCTAssertEqual(
            pcm.count, 16_000,
            "Recorder must keep writing mic samples after system audio stalls (phase A 0.5s mixed + phase B 0.5s mic-only = 1.0s total)."
        )
    }

    func test_audio_level_stream_reacts_to_mic_only_samples_without_system_audio() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let expectation = expectation(description: "mic-only level emitted")
        var detectedLevel: MeetingRecorderAudioLevel?
        let collector = Task {
            for await level in recorder.audioLevelStream {
                if level > 0.05 {
                    await MainActor.run {
                        detectedLevel = level
                        expectation.fulfill()
                    }
                    return
                }
            }
        }

        try await recorder.start(prerecordSnapshot: Data(), meetingId: UUID())

        mic.feed([Float](repeating: 0.8, count: 1_024))

        await fulfillment(of: [expectation], timeout: 0.7)
        collector.cancel()

        _ = await recorder.stop(reason: .user)

        XCTAssertNotNil(
            detectedLevel,
            "Meeting recording waveform should react to the user's mic even when system audio is silent."
        )
    }

    func test_audio_level_stream_uses_db_metering_for_quiet_mic_samples() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let expectation = expectation(description: "quiet mic level emitted")
        var detectedLevel: MeetingRecorderAudioLevel?
        let collector = Task {
            for await level in recorder.audioLevelStream {
                if level > 0 {
                    await MainActor.run {
                        detectedLevel = level
                        expectation.fulfill()
                    }
                    return
                }
            }
        }

        try await recorder.start(prerecordSnapshot: Data(), meetingId: UUID())

        mic.feed([Float](repeating: 0.02, count: 1_024))

        await fulfillment(of: [expectation], timeout: 0.7)
        collector.cancel()

        _ = await recorder.stop(reason: .user)

        XCTAssertGreaterThan(
            detectedLevel ?? 0,
            0.40,
            "Quiet but real mic speech should use the same dBFS meter curve as Drop/streaming."
        )
    }

    func test_audio_level_stream_keeps_mic_level_when_system_silence_follows() async throws {
        let mic = StubMicSource()
        let sys = StubSystemSource()
        let micInUse = StubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let expectation = expectation(description: "latest mic level survives system silence")
        var observedLevels: [MeetingRecorderAudioLevel] = []
        let collector = Task {
            for await level in recorder.audioLevelStream {
                await MainActor.run {
                    observedLevels.append(level)
                }
                if await MainActor.run(body: { observedLevels.count >= 4 }) {
                    await MainActor.run {
                        expectation.fulfill()
                    }
                    return
                }
            }
        }

        try await recorder.start(prerecordSnapshot: Data(), meetingId: UUID())

        mic.feed([Float](repeating: 0.8, count: 1_024))
        sys.feed([Float](repeating: 0, count: 4_096))

        await fulfillment(of: [expectation], timeout: 0.7)
        collector.cancel()

        _ = await recorder.stop(reason: .user)

        XCTAssertGreaterThan(
            observedLevels.last ?? 0,
            0.05,
            "Meeting recording waveform should still react to the user's mic when the system stream emits silence."
        )
    }

    // MARK: - Helpers

    private func stagingDir(meetingId: UUID) -> URL {
        stagingRoot.appendingPathComponent(meetingId.uuidString)
    }

    private func chunkURLs(in dir: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: nil)
        return entries
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func firstChunk(meetingId: UUID) throws -> URL {
        let dir = stagingDir(meetingId: meetingId)
        let chunks = try chunkURLs(in: dir)
        guard let first = chunks.first else {
            throw NSError(domain: "MeetingRecorderTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No chunk written to \(dir.path)"])
        }
        return first
    }

    private func pcmSamples(from url: URL) throws -> [Int16] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else { return [] }
        let body = data.subdata(in: 44..<data.count)
        return body.withUnsafeBytes { raw -> [Int16] in
            let count = raw.count / 2
            guard let base = raw.baseAddress, count > 0 else { return [] }
            return Array(UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: Int16.self),
                count: count
            ))
        }
    }

    private func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func hexSHA256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import XCTest
@testable import Sidekey

/// Stage 9 tests for `MeetingRecorder.pause()` / `resume()` chunk
/// continuity. The Stage 4 code path already exists for the user-driven
/// pill Pause button — Stage 9 reuses it for system-initiated sleep
/// pauses. The two requirements specific to Stage 9 are:
///
/// 1. `pause()` mid-recording must flush whatever is in the current
///    chunk to disk (with sidecar), even if the chunk is shorter than
///    the rotation budget. Otherwise a sleep that lands mid-30-s-chunk
///    would lose the audio captured since the last rotation.
/// 2. `resume()` must continue chunk numbering — chunk-001.wav must
///    follow chunk-000.wav with no gaps. Equivalently: the recording
///    must not lose audio across the pause/resume boundary; we verify
///    by feeding samples on both sides and checking the on-disk chunk
///    layout.
@MainActor
final class MeetingRecorderPauseResumeTests: XCTestCase {
    private var stagingRoot: URL!

    override func setUp() {
        super.setUp()
        stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekey-recorder-pause-resume-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stagingRoot)
        stagingRoot = nil
        super.tearDown()
    }

    // MARK: - (1) Pause flushes current chunk as a partial

    /// Feeding < rotation worth of samples and then calling `pause()`
    /// must persist the in-flight samples to `chunk-000.wav` with the
    /// matching `.sha256` sidecar. Without the flush we'd lose the
    /// audio captured since the last rotation — i.e. anything between
    /// 0 s and ~30 s when sleep fires mid-chunk.
    func test_pause_flushes_current_chunk_as_partial() async throws {
        let mic = PauseResumeStubMicSource()
        let sys = PauseResumeStubSystemSource()
        let micInUse = PauseResumeStubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,           // never auto-rotates in the test
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: Data(), meetingId: meetingId)

        // Feed 0.05 s of audio (800 samples) — well under the 60 s
        // rotation budget. Stage 9 contract: pause() flushes this
        // partial chunk to disk regardless of size.
        let partial = [Float](repeating: 0.2, count: 800)
        mic.feed(partial)
        sys.feed(partial)
        try? await Task.sleep(nanoseconds: 200_000_000)

        await recorder.pause()

        let meetingDir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        let chunk0 = meetingDir.appendingPathComponent("chunk-000.wav")
        let sidecar0 = meetingDir.appendingPathComponent("chunk-000.sha256")

        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk0.path),
                      "pause() must flush the in-flight chunk to chunk-000.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar0.path),
                      "pause() must persist the matching .sha256 sidecar")

        // The chunk must contain the 800 samples we fed — pause is
        // not allowed to drop in-flight audio.
        let pcmCount = try Self.pcmSampleCount(in: chunk0)
        XCTAssertEqual(pcmCount, 800,
                       "Partial chunk written by pause() must contain the 800 samples we fed")

        XCTAssertTrue(recorder.isPaused, "Recorder must report isPaused after pause()")

        // Clean up the recorder so background drain tasks exit.
        _ = await recorder.stop(reason: .user)
        mic.finishStream()
        sys.finishStream()
    }

    // MARK: - (2) Resume increments chunk idx — no audio loss across boundary

    /// `pause() → resume()` must produce continuous chunk numbering on
    /// disk: chunk-000.wav (pre-pause partial) followed by chunk-001.wav
    /// (post-resume samples). The post-resume chunk index must be the
    /// pre-pause index + 1 — no audio loss, no overwrite, no gap.
    func test_resume_increments_chunk_idx_no_audio_loss() async throws {
        let mic = PauseResumeStubMicSource()
        let sys = PauseResumeStubSystemSource()
        let micInUse = PauseResumeStubMicInUse()
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

        // Pre-pause samples: chunk-000.wav
        let preSamples = [Float](repeating: 0.3, count: 600)
        mic.feed(preSamples)
        sys.feed(preSamples)
        try? await Task.sleep(nanoseconds: 200_000_000)

        await recorder.pause()
        XCTAssertTrue(recorder.isPaused, "Recorder must be paused after pause()")

        try await recorder.resume()
        XCTAssertFalse(recorder.isPaused, "Recorder must not be paused after resume()")

        // Brief settle so the resume-side drain tasks have a chance to
        // subscribe to the stream before we feed new samples.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Post-resume samples: must land in chunk-001.wav (next idx).
        let postSamples = [Float](repeating: 0.5, count: 700)
        mic.feed(postSamples)
        sys.feed(postSamples)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // stop() flushes the in-flight post-resume chunk.
        _ = await recorder.stop(reason: .user)

        let meetingDir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        let chunk0 = meetingDir.appendingPathComponent("chunk-000.wav")
        let chunk1 = meetingDir.appendingPathComponent("chunk-001.wav")

        // If chunk-001 is missing, include the directory listing in
        // the failure message so a regression report tells us whether
        // resume produced no chunk, a chunk-002 (rotation skipped an
        // index), or anything unexpected.
        let entries = (try? FileManager.default.contentsOfDirectory(at: meetingDir, includingPropertiesForKeys: nil)) ?? []
        let entryNames = entries.map { $0.lastPathComponent }.sorted().joined(separator: ", ")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk0.path),
                      "chunk-000.wav must exist from the pre-pause segment. dir contains: [\(entryNames)]")
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk1.path),
                      "chunk-001.wav must exist from the post-resume segment (idx + 1, no gap). dir contains: [\(entryNames)]")

        // The continuity check: chunk-000 must hold exactly the
        // 600-sample pre-pause segment, chunk-001 must hold exactly the
        // 700-sample post-resume segment. If pause/resume dropped or
        // duplicated samples, these counts would diverge.
        let preCount = try Self.pcmSampleCount(in: chunk0)
        let postCount = try Self.pcmSampleCount(in: chunk1)

        XCTAssertEqual(preCount, 600,
                       "chunk-000.wav must contain exactly the 600 pre-pause samples")
        XCTAssertEqual(postCount, 700,
                       "chunk-001.wav must contain exactly the 700 post-resume samples")

        mic.finishStream()
        sys.finishStream()
    }

    // MARK: - (3) Privacy: system audio captured WHILE PAUSED must not be written

    /// PRIVACY contract: the user presses Pause precisely to stop capture.
    /// The system-audio stream is a CoreAudio tap that keeps producing
    /// samples through the pause (its lifecycle is owned elsewhere and the
    /// drain Task intentionally stays alive across pause). Nothing the
    /// system stream emits between `pause()` and `resume()` may reach a
    /// chunk on disk.
    ///
    /// Regression shape: the writer's single-source fallback solo-drains
    /// the system queue once it crosses the ~5 s grace threshold while the
    /// mic queue is empty. We feed > 5 s of system audio during the pause
    /// so the pre-fix code would solo-drain it into a chunk. The fix gates
    /// the writer on pause state, so the paused system audio is discarded.
    func test_system_audio_during_pause_is_not_written() async throws {
        let mic = PauseResumeStubMicSource()
        let sys = PauseResumeStubSystemSource()
        let micInUse = PauseResumeStubMicInUse()
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

        await recorder.pause()
        XCTAssertTrue(recorder.isPaused, "Recorder must be paused before we feed system audio")

        // Feed 6 s of system audio (96 000 samples > the 5 s = 80 000
        // sample solo-drain threshold) with NO mic samples. On the pre-fix
        // code the system side would solo-drain straight into chunk-000.wav.
        let pausedSystemAudio = [Float](repeating: 0.4, count: 96_000)
        sys.feed(pausedSystemAudio)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Finalize. No chunk may exist, because nothing was captured
        // before pause and everything fed during pause must be discarded.
        _ = await recorder.stop(reason: .user)

        let meetingDir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: meetingDir, includingPropertiesForKeys: nil)) ?? []
        let wavChunks = entries.filter { $0.pathExtension == "wav" }
        let entryNames = entries.map { $0.lastPathComponent }.sorted().joined(separator: ", ")

        XCTAssertTrue(wavChunks.isEmpty,
                      "No chunk may be written from system audio captured while paused. dir contains: [\(entryNames)]")

        mic.finishStream()
        sys.finishStream()
    }

    /// After `resume()`, fresh mic + system samples must pair 1:1 with no
    /// pause-era backlog. Regression shape: if the writer keeps the system
    /// samples that arrived during the pause in its queue, then on resume
    /// the fresh mic audio pairs against that stale backlog and the entire
    /// post-resume mix is time-shifted by the pause duration.
    ///
    /// The assertion is on chunk CONTENT, not just sample count — counts
    /// can coincide between the clean and the time-shifted mix (e.g. if
    /// the backlog were exactly consumed by the post-resume feed), but
    /// sample values cannot. The three phases feed distinguishable
    /// amplitudes (pre 0.3, pause-era 0.9, post 0.5): a correctly aligned
    /// post-resume mix is uniformly (0.5 + 0.5) * 0.5 = 0.5 -> PCM 16383,
    /// while any leaked backlog pairs post-resume mic 0.5 against
    /// pause-era system 0.9 -> (0.5 + 0.9) * 0.5 = 0.7 -> PCM 22936 (and
    /// a solo-drained backlog tail reads 0.9 -> 29490). Asserting ALL
    /// samples (not just the first) also catches a partial leak.
    func test_post_resume_pairing_has_no_pause_era_backlog() async throws {
        let mic = PauseResumeStubMicSource()
        let sys = PauseResumeStubSystemSource()
        let micInUse = PauseResumeStubMicInUse()
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

        // Pre-pause: a small amount of BOTH so chunk-000 holds a clean,
        // fully-paired pre-pause segment. 400 samples each.
        let preSamples = [Float](repeating: 0.3, count: 400)
        mic.feed(preSamples)
        sys.feed(preSamples)
        try? await Task.sleep(nanoseconds: 200_000_000)

        await recorder.pause()

        // During the pause the system tap keeps producing. Stay UNDER the
        // 5 s solo-drain threshold (40 000 samples) so the only way these
        // survive is as backlog in the system queue that pairs against
        // post-resume mic audio — i.e. the time-shift bug, not the
        // solo-drain bug covered by the test above.
        let pauseEraSystem = [Float](repeating: 0.9, count: 40_000)
        sys.feed(pauseEraSystem)
        try? await Task.sleep(nanoseconds: 200_000_000)

        try await recorder.resume()
        // Settle so the resume-side drain tasks resubscribe.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Post-resume: 700 samples of BOTH. With aligned pairing this
        // yields exactly 700 mixed samples in chunk-001. If the pause-era
        // 40 000 system samples were still queued, the mix would be
        // time-shifted and chunk-001 would not hold a clean 700.
        let postSamples = [Float](repeating: 0.5, count: 700)
        mic.feed(postSamples)
        sys.feed(postSamples)
        try? await Task.sleep(nanoseconds: 400_000_000)

        _ = await recorder.stop(reason: .user)

        let meetingDir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        let chunk1 = meetingDir.appendingPathComponent("chunk-001.wav")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: meetingDir, includingPropertiesForKeys: nil)) ?? []
        let entryNames = entries.map { $0.lastPathComponent }.sorted().joined(separator: ", ")

        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk1.path),
                      "chunk-001.wav must exist from the post-resume segment. dir contains: [\(entryNames)]")

        // The alignment check, part 1 (count): exactly 700 post-resume
        // samples, no pause-era backlog folded in.
        let postCount = try Self.pcmSampleCount(in: chunk1)
        XCTAssertEqual(postCount, 700,
                       "chunk-001.wav must contain exactly the 700 post-resume samples with no pause-era backlog (got \(postCount))")

        // The alignment check, part 2 (content): EVERY sample must be the
        // clean 0.5 mic / 0.5 system mix. A time-shifted mix would pair
        // post-resume mic 0.5 against pause-era system 0.9 and read 22936
        // instead of 16383 — a corruption the count alone cannot prove
        // absent. `allSatisfy` over the full body also catches a partial
        // leak that only shifts a sub-range.
        let expectedMixed = Int16((0.5 as Float) * Float(Int16.max)) // 16383
        let pcm = try Self.pcmSamples(in: chunk1)
        let distinctValues = Set(pcm).sorted()
        XCTAssertTrue(pcm.allSatisfy { $0 == expectedMixed },
                      "every post-resume sample must be the clean (0.5 + 0.5) * 0.5 mix = \(expectedMixed); pause-era 0.9 backlog would shift samples to 22936. distinct values seen: \(distinctValues)")

        mic.finishStream()
        sys.finishStream()
    }

    // MARK: - (4) Header-only prerecord snapshot must not be written

    /// `PrerecordBuffer.append` has no callers (the pre-record capture
    /// feature was never wired), so `snapshot()` returns a 44-byte
    /// header-only WAV. A header-only snapshot carries no audio and must
    /// NOT be written / uploaded as `chunk-000-prerecord.wav` — otherwise
    /// every meeting ships a junk 44-byte chunk. We pass a real header-only
    /// snapshot (from a started-but-never-fed buffer) and assert no
    /// prerecord file lands on disk.
    func test_header_only_prerecord_snapshot_is_not_written() async throws {
        let mic = PauseResumeStubMicSource()
        let sys = PauseResumeStubSystemSource()
        let micInUse = PauseResumeStubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        // A real, header-only snapshot: started buffer, nothing appended.
        let buffer = PrerecordBuffer(sampleRate: 16_000, capacitySeconds: 60)
        await buffer.start()
        let headerOnlySnapshot = await buffer.snapshot()
        XCTAssertEqual(headerOnlySnapshot.count, 44,
                       "Sanity: an empty prerecord buffer snapshots to a 44-byte header-only WAV")

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: headerOnlySnapshot, meetingId: meetingId)
        _ = await recorder.stop(reason: .user)

        let meetingDir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        let prerecord = meetingDir.appendingPathComponent("chunk-000-prerecord.wav")
        let prerecordSidecar = meetingDir.appendingPathComponent("chunk-000-prerecord.sha256")

        XCTAssertFalse(FileManager.default.fileExists(atPath: prerecord.path),
                       "A header-only prerecord snapshot must not be written as a chunk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prerecordSidecar.path),
                       "No sidecar may be written for a skipped header-only prerecord snapshot")

        mic.finishStream()
        sys.finishStream()
    }

    /// Counterpart to the header-only test: a prerecord snapshot that DOES
    /// carry audio (body bytes beyond the 44-byte header) must still be
    /// persisted. This pins the boundary so the empty-guard does not
    /// accidentally suppress a real pre-record once that feature is wired.
    func test_prerecord_snapshot_with_audio_is_written() async throws {
        let mic = PauseResumeStubMicSource()
        let sys = PauseResumeStubSystemSource()
        let micInUse = PauseResumeStubMicInUse()
        let recorder = MeetingRecorder(
            micSource: mic,
            systemSource: sys,
            micInUseProbe: micInUse,
            stagingRoot: stagingRoot,
            chunkRotationSeconds: 60,
            autoEndMicReleasedSeconds: 60,
            sampleRate: 16_000
        )

        // A snapshot with real audio: 100 PCM16 samples appended.
        let buffer = PrerecordBuffer(sampleRate: 16_000, capacitySeconds: 60)
        await buffer.start()
        await buffer.append(samples: [Int16](repeating: 1234, count: 100))
        let snapshotWithAudio = await buffer.snapshot()
        XCTAssertGreaterThan(snapshotWithAudio.count, 44,
                             "Sanity: a fed prerecord buffer snapshots to more than the 44-byte header")

        let meetingId = UUID()
        try await recorder.start(prerecordSnapshot: snapshotWithAudio, meetingId: meetingId)
        _ = await recorder.stop(reason: .user)

        let meetingDir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        let prerecord = meetingDir.appendingPathComponent("chunk-000-prerecord.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: prerecord.path),
                      "A prerecord snapshot carrying real audio must still be persisted")

        mic.finishStream()
        sys.finishStream()
    }

    // MARK: - Helpers

    /// Read PCM16 sample count from a WAV file (skipping the 44-byte
    /// header). Used to assert exact per-chunk sample boundaries.
    private static func pcmSampleCount(in url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else { return 0 }
        let body = data.subdata(in: 44..<data.count)
        return body.count / 2  // PCM16: 2 bytes per sample
    }

    /// Read the PCM16 sample VALUES from a WAV file (skipping the 44-byte
    /// header). Used by the content-level alignment assertion — sample
    /// values, not just counts, are what prove the post-resume mix carries
    /// no pause-era backlog.
    private static func pcmSamples(in url: URL) throws -> [Int16] {
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
}

// MARK: - Test seams

/// Hand-driven mic source. The protocol exposes a single `samples`
/// stream; production swaps the underlying AVAudioEngine in/out across
/// start/stop without recreating the stream. Tests follow the same
/// shape — the recorder's pause/resume contract guarantees it re-
/// subscribes the same stream object.
///
/// NSLock-guarded continuation so `feed(...)` (called from MainActor
/// in the test body) does not race with the drain Task's iterator
/// drop on cancellation.
private final class PauseResumeStubMicSource: MicSourcing, @unchecked Sendable {
    let samples: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation

    init() {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        self.samples = stream
        self.continuation = cont
    }

    func start() async throws {}
    func stop() async {}

    nonisolated func feed(_ chunk: [Float]) {
        continuation.yield(chunk)
    }

    nonisolated func finishStream() {
        continuation.finish()
    }
}

/// Hand-driven system audio source. Mirrors the mic stub's contract:
/// the same stream is re-subscribed across pause/resume.
private final class PauseResumeStubSystemSource: SystemAudioBufferStreaming, @unchecked Sendable {
    private let stream: AsyncStream<[Float]>
    private let continuation: AsyncStream<[Float]>.Continuation

    init() {
        let (stream, cont) = AsyncStream<[Float]>.makeStream()
        self.stream = stream
        self.continuation = cont
    }

    func audioBufferStream() -> AsyncStream<[Float]> { stream }

    nonisolated func feed(_ chunk: [Float]) {
        continuation.yield(chunk)
    }

    nonisolated func finishStream() {
        continuation.finish()
    }
}

/// Mic-in-use probe stub — never feeds, so the auto-end watcher stays
/// armed but never fires for the duration of the test.
private final class PauseResumeStubMicInUse: MicInUseProbing, @unchecked Sendable {
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

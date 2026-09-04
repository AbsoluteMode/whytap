import AVFoundation
import CryptoKit
import Foundation
import os.log

// MARK: - Public surface

/// Why a recording finished. The coordinator uses this to thread the
/// reason through to FinalizedEvent observability (`auto-end` vs user
/// Stop).
enum MeetingRecorderStopReason: Sendable, Equatable {
    /// User clicked the Stop button on the recording pill.
    case user
    /// Mic released for `MeetingsConfig.autoEndMicReleasedSeconds`.
    case autoEnd
    /// Coordinator forced a shutdown (app quit, feature flag flipped off).
    case forced
    /// Stage 9: resume after system sleep could not reinstall audio inputs
    /// — the coordinator falls back to finalizing the partial recording so
    /// the user still gets a (truncated) note.
    /// Pairs with `FinalizedEvent.interruptedBySleep == true`.
    case systemError
}

/// Test seam over the mic-side audio source. Production injects a CoreAudio
/// + `AVAudioEngine`-backed adapter that yields 16 kHz mono Float32
/// samples from the default input device; tests inject `StubMicSource`
/// which feeds hand-crafted arrays.
///
/// Single-consumer: `MeetingRecorder` calls `start()` once, drains
/// `samples` until `stop()` is awaited.
protocol MicSourcing: AnyObject, Sendable {
    /// Stream of 16 kHz mono Float32 sample chunks. Each yielded `[Float]`
    /// corresponds to one mic buffer; the recorder mixes them with the
    /// system audio stream.
    var samples: AsyncStream<[Float]> { get }

    /// Begin streaming. May throw on permission denial or audio engine
    /// failure. Idempotent.
    func start() async throws

    /// Stop streaming. Idempotent. The recorder calls this on `stop()`
    /// or `pause()` so the mic / engine can be released — pause means
    /// "release resources, resume reacquires" per the Stage 4 design
    /// (recorder doesn't keep AVAudioEngine running while paused).
    func stop() async
}

/// Snapshot of state the recorder publishes to UI on the audio-level
/// stream. Plain `Double` instead of `Float` so SwiftUI bindings stay
/// platform-default and bridging is straightforward.
typealias MeetingRecorderAudioLevel = Double

// MARK: - MeetingRecorder

/// Stage 4 owner of meeting audio capture: mixes mic + system audio,
/// rotates 30 s WAV chunks to staging, computes SHA256 sidecars,
/// publishes audio level + duration for the recording pill, and emits a
/// `FinalizedEvent` when the user clicks Stop OR the mic-released
/// auto-end watcher fires.
///
/// **Concurrency:** The class is `@MainActor` because the rest of the
/// meetings module (coordinator, pill controller, MicInUseProbe) is
/// MainActor — keeping the recorder on the same actor avoids cross-actor
/// hops on every event. The heavy lifting (chunk file writes, SHA256)
/// runs on an internal `ChunkWriter` actor that the recorder talks to
/// via `await`; the source-of-truth for byte counts / chunk indexing
/// lives there so concurrent appends from mic + system tasks cannot
/// race on shared state.
///
/// **Chunk format pinned** to the Stage 4 spec: 16 kHz mono PCM16 WAV
/// with the canonical 44-byte RIFF/WAVE/fmt /data header. Tests pin every
/// header field.
///
/// **Pause semantics:** `pause()` flushes the current chunk to disk (even
/// if shorter than the rotation budget), stops the mic input, gates the
/// writer so system-tap audio is discarded while paused (the tap is owned
/// by `SystemAudioVADProbe` and keeps producing through a pause — only
/// the writer gate keeps it out of chunks), and freezes the duration
/// timer. `resume()` re-acquires the mic, re-opens the writer gate,
/// starts a new chunk (next chunk index), continues the timer from the
/// paused elapsed value. Safer than keeping AVAudioEngine running through
/// a long pause — releases microphone resources.
@MainActor
final class MeetingRecorder: MeetingRecording {

    /// os_log surface for the `recorder` category — spec / plan call it
    /// out. Never logs audio content; only ids, counts, durations.
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "recorder")

    // MARK: - FinalizedEvent

    /// Emitted on `finalizedStream` when recording stops (user, auto-end,
    /// or forced). Stage 5 (upload) consumes this to chunk-upload the
    /// staged files; Stage 7 (store) uses it to flip the meeting status
    /// from `uploading` to `transcribing`.
    struct FinalizedEvent: Sendable, Equatable {
        let meetingId: UUID
        /// Absolute chunk URLs on disk. Order is chunk-000 → chunk-NNN.
        let chunkURLs: [URL]
        /// Exact recorded-audio duration in seconds, computed from the
        /// sample counts that actually reached chunk WAV files.
        let totalDurationSeconds: TimeInterval
        let reason: MeetingRecorderStopReason
        /// Stage 9: set to `true` when the recording was forcibly
        /// finalized because resume after sleep could not reinstall audio
        /// inputs. Default `false` for all other paths
        /// (user Stop, auto-end, forced quit). The processors read this to
        /// prepend an "interrupted by sleep" marker to the LLM prompt
        /// context.
        var interruptedBySleep: Bool = false
        /// Present only when `retainSeparateTracks` was on (the fully-local
        /// transcription path). Points at the raw mic-only and system-only
        /// WAVs written alongside the mixed chunks. `nil` for the BYOK path,
        /// which consumes the mixed chunks in `chunkURLs` and never needs
        /// the un-mixed tracks.
        var separateTrackURLs: SeparateTrackURLs? = nil
    }

    /// Stage 5a: absolute URLs of the raw, un-mixed per-source tracks
    /// retained for local transcription. Both are 16 kHz mono PCM16 WAVs
    /// with the same canonical header as the mixed chunks.
    struct SeparateTrackURLs: Sendable, Equatable {
        let micURL: URL
        let systemURL: URL
    }


    // MARK: - Dependencies

    private let micSource: MicSourcing
    private let systemSource: SystemAudioBufferStreaming
    private let micInUseProbe: MicInUseProbing
    private let stagingRoot: URL
    private let chunkRotationSeconds: TimeInterval
    private let autoEndMicReleasedSeconds: TimeInterval
    private let autoEndStartupGraceSeconds: TimeInterval
    private let sampleRate: Int
    /// Stage 5a: when `true`, the writer retains the raw mic-only and
    /// system-only tracks (in addition to the mixed chunks) and flushes
    /// them to `mic.wav` / `system.wav` on finalize. Default `false`
    /// keeps the BYOK path byte-for-byte identical.
    private let retainSeparateTracks: Bool

    // MARK: - State

    private(set) var meetingId: UUID?
    private(set) var isRunning = false
    private(set) var isPaused = false

    /// Owned by `ChunkWriter`. The recorder calls into it via `await`.
    private var writer: ChunkWriter?

    private var micDrainTask: Task<Void, Never>?
    private var systemDrainTask: Task<Void, Never>?
    private var micInUseDrainTask: Task<Void, Never>?
    private var levelEmitTask: Task<Void, Never>?
    private var durationEmitTask: Task<Void, Never>?
    private var autoEndArmTask: Task<Void, Never>?

    /// Captures elapsed seconds at the moment of `pause()` so `resume()`
    /// can continue counting from there instead of resetting to 0.
    private var pausedElapsed: TimeInterval = 0
    /// Wall-clock when the current "running" segment started. `nil` while
    /// paused / not running.
    private var segmentStartedAt: Date?

    // MARK: - Publishers

    /// Yields the FinalizedEvent exactly once on stop / auto-end, then
    /// terminates so consumers exit their `for await` loop cleanly.
    let finalizedStream: AsyncStream<FinalizedEvent>
    private let finalizedContinuation: AsyncStream<FinalizedEvent>.Continuation

    /// Audio level [0…1] re-emitted at ~30 Hz so the pill
    /// waveform can react in real time. While paused emits 0 so the
    /// waveform visibly freezes / dims.
    let audioLevelStream: AsyncStream<MeetingRecorderAudioLevel>
    private let audioLevelContinuation: AsyncStream<MeetingRecorderAudioLevel>.Continuation

    /// Emits the recorder's elapsed wall-clock duration every 200 ms so
    /// the pill timer updates without polling.
    let durationStream: AsyncStream<TimeInterval>
    private let durationContinuation: AsyncStream<TimeInterval>.Continuation

    // MARK: - Init

    init(
        micSource: MicSourcing,
        systemSource: SystemAudioBufferStreaming,
        micInUseProbe: MicInUseProbing,
        stagingRoot: URL,
        chunkRotationSeconds: TimeInterval = MeetingsConfig.chunkRotationSeconds,
        autoEndMicReleasedSeconds: TimeInterval = MeetingsConfig.autoEndMicReleasedSeconds,
        autoEndStartupGraceSeconds: TimeInterval = MeetingsConfig.autoEndStartupGraceSeconds,
        sampleRate: Int = 16_000,
        retainSeparateTracks: Bool = false
    ) {
        self.micSource = micSource
        self.systemSource = systemSource
        self.micInUseProbe = micInUseProbe
        self.stagingRoot = stagingRoot
        self.chunkRotationSeconds = chunkRotationSeconds
        self.autoEndMicReleasedSeconds = autoEndMicReleasedSeconds
        self.autoEndStartupGraceSeconds = autoEndStartupGraceSeconds
        self.sampleRate = sampleRate
        self.retainSeparateTracks = retainSeparateTracks

        let (finStream, finCont) = AsyncStream<FinalizedEvent>.makeStream()
        self.finalizedStream = finStream
        self.finalizedContinuation = finCont

        let (lvlStream, lvlCont) = AsyncStream<MeetingRecorderAudioLevel>.makeStream()
        self.audioLevelStream = lvlStream
        self.audioLevelContinuation = lvlCont

        let (durStream, durCont) = AsyncStream<TimeInterval>.makeStream()
        self.durationStream = durStream
        self.durationContinuation = durCont
    }

    deinit {
        finalizedContinuation.finish()
        audioLevelContinuation.finish()
        durationContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Begin recording. `prerecordSnapshot` is the WAV bytes from
    /// `PrerecordBuffer.snapshot()` captured at pill `Yes` time; the
    /// recorder writes them as `chunk-000-prerecord.wav` *before* live
    /// capture starts so the recording starts at "60 s before detector
    /// trigger" instead of at "moment of accept".
    func start(prerecordSnapshot: Data, meetingId: UUID) async throws {
        guard !isRunning else { return }

        self.meetingId = meetingId
        let meetingDir = stagingRoot.appendingPathComponent(meetingId.uuidString)
        try FileManager.default.createDirectory(
            at: meetingDir,
            withIntermediateDirectories: true
        )

        let writer = ChunkWriter(
            meetingDir: meetingDir,
            sampleRate: sampleRate,
            chunkRotationSeconds: chunkRotationSeconds,
            retainSeparateTracks: retainSeparateTracks
        )
        self.writer = writer

        // Persist the prerecord snapshot first, but ONLY if it carries
        // actual audio. `PrerecordBuffer.append` currently has no callers
        // (the pre-record capture feature was never wired), so
        // `snapshot()` returns a header-only WAV. A plain `!isEmpty`
        // check treats those header bytes as content and ships a junk
        // `chunk-000-prerecord.wav` on every meeting. Gate on a
        // sample-bearing body instead: the snapshot must have bytes
        // beyond `PrerecordBuffer.emptySnapshotByteCount` (the buffer's
        // own definition of a zero-sample snapshot). The snapshot already
        // has a complete header, so when it does carry audio we drop it on
        // disk as a standalone `chunk-000-prerecord.wav` before the live
        // chunks start at `chunk-000.wav`; Stage 5 upload includes the
        // prerecord file separately and the WAV header lets Soniox
        // concatenate them losslessly.
        if prerecordSnapshot.count > PrerecordBuffer.emptySnapshotByteCount {
            try await writer.persistPrerecord(prerecordSnapshot)
        }

        // Order matters for Bluetooth headsets: starting AVAudioEngine can
        // switch the device from its playback profile to the bidirectional
        // headset profile without changing the default-output UID. A system
        // tap created before that switch keeps the old ASBD while its
        // aggregate runs on the new hardware clock; the 48 kHz -> 16 kHz
        // resampler then shrinks an already-16-kHz callback stream to ~5.3
        // kHz. Start the mic first so route/profile negotiation has completed
        // before SystemAudioVADProbe creates (or rebuilds) the process tap.
        // The recording clock starts only after both streams are acquired, so
        // this ordering does not shorten the recorded meeting.
        try await micSource.start()
        let micStream = micSource.samples
        let systemStream = systemSource.audioBufferStream()

        isRunning = true
        isPaused = false
        pausedElapsed = 0
        segmentStartedAt = Date()

        os_log(
            "recorder started (meetingId: %{public}@, prerecord_bytes: %{public}d)",
            log: Self.log, type: .info,
            meetingId.uuidString, prerecordSnapshot.count
        )

        startDrainTasks(micStream: micStream, systemStream: systemStream)
        startPublisherTasks()
        startAutoEndWatcher()
    }

    /// Flush the current chunk, release inputs, freeze timer. UI shows
    /// the `.paused` state until `resume()`.
    ///
    /// **Drain tasks intentionally stay alive across pause.**
    /// `AsyncStream` is single-iterator-per-lifetime — once a Task that
    /// is iterating gets cancelled, the stream's storage is marked
    /// terminated and future yields are dropped. So instead of
    /// cancelling + restarting the drain tasks on pause/resume, we
    /// stop the source (no new values yielded), flush the writer,
    /// freeze the timer, and let the drain Tasks idle on `await`.
    /// On resume the source starts yielding again and the same Tasks
    /// pick up where they left off.
    func pause() async {
        guard isRunning, !isPaused else { return }
        isPaused = true

        // Snapshot elapsed BEFORE clearing segmentStartedAt so resume()
        // can continue counting from this value.
        if let started = segmentStartedAt {
            pausedElapsed += Date().timeIntervalSince(started)
        }
        segmentStartedAt = nil

        cancelAutoEndWatcher()
        await micSource.stop()

        // Flush in-flight (already-mixed) samples to a chunk, clear the
        // input queues, and gate the writer so paused-era audio is
        // discarded. The system tap keeps producing and its drain Task
        // stays alive across pause (see doc above), so this writer-side
        // gate — not `micSource.stop()` — is what enforces "no audio
        // captured while paused reaches a chunk".
        if let writer {
            await writer.beginPause()
        }

        // Force an immediate 0-level emission so the waveform visibly
        // dims; production observers can also key off `isPaused` if
        // they want a different visual.
        audioLevelContinuation.yield(0)
        durationContinuation.yield(pausedElapsed)

        os_log("recorder paused (elapsed: %{public}.2f)", log: Self.log, type: .info, pausedElapsed)
    }

    /// Re-acquire inputs, start a new chunk index, continue timer from
    /// `pausedElapsed`. The drain Tasks were never cancelled in
    /// `pause()` (see doc on `pause` for the AsyncStream constraint) —
    /// they pick up new samples as soon as the source starts yielding
    /// again.
    func resume() async throws {
        guard isRunning, isPaused else { return }
        try await micSource.start()

        // Re-open the writer gate so the drain Tasks' samples start
        // landing in chunks again. Queues were cleared in `beginPause()`,
        // so post-resume mic / system pairing starts aligned with no
        // pause-era backlog.
        if let writer {
            await writer.endPause()
        }

        isPaused = false
        segmentStartedAt = Date()

        startAutoEndWatcher()

        os_log("recorder resumed", log: Self.log, type: .info)
    }

    /// Final stop: flush the in-flight chunk, finalize, emit
    /// `FinalizedEvent`. Subsequent calls are no-ops.
    ///
    /// `interruptedBySleep` defaults to `false`. Stage 9's
    /// `MeetingsCoordinator.resumeRecordingIfPaused` passes `true`
    /// together with `reason: .systemError` when resume after wake
    /// cannot reinstall audio inputs, so the processing pipeline can mark
    /// the partial transcript as sleep-interrupted.
    @discardableResult
    func stop(
        reason: MeetingRecorderStopReason,
        interruptedBySleep: Bool = false
    ) async -> FinalizedEvent {
        guard isRunning, let meetingId = meetingId else {
            // Already stopped — return a synthetic empty event so the
            // caller does not crash on optional unwrap. Production
            // observers should never see this path because stop() is
            // wired once.
            return FinalizedEvent(
                meetingId: meetingId ?? UUID(),
                chunkURLs: [],
                totalDurationSeconds: 0,
                reason: reason,
                interruptedBySleep: interruptedBySleep
            )
        }

        isRunning = false
        cancelDrainTasks()
        cancelPublisherTasks()
        cancelAutoEndWatcher()
        await micSource.stop()
        // Tear down the system-audio process tap too. Without this the
        // CoreAudio tap (and its aggregate-device IOProc) stays alive after
        // the meeting ends, keeping the app flagged as recording-input — the
        // macOS recording indicator never clears until the next meeting
        // rebuilds the tap.
        // WHY: docs/decisions/2026-06-30-meetings-tap-teardown-and-polling-refresh.md
        await systemSource.stop()

        if let started = segmentStartedAt {
            pausedElapsed += Date().timeIntervalSince(started)
            segmentStartedAt = nil
        }

        let urls: [URL]
        let audioDurationSeconds: TimeInterval
        let separateTracks: SeparateTrackURLs?
        if let writer {
            let finalized = await writer.finalize()
            urls = finalized.chunkURLs
            audioDurationSeconds = finalized.audioDurationSeconds
            separateTracks = finalized.separateTrackURLs
        } else {
            urls = []
            audioDurationSeconds = 0
            separateTracks = nil
        }

        let event = FinalizedEvent(
            meetingId: meetingId,
            chunkURLs: urls,
            totalDurationSeconds: audioDurationSeconds,
            reason: reason,
            interruptedBySleep: interruptedBySleep,
            separateTrackURLs: separateTracks
        )

        os_log(
            "recorder finalized (meetingId: %{public}@, chunks: %{public}d, duration_s: %{public}.2f, reason: %{public}@, interruptedBySleep: %{public}@)",
            log: Self.log, type: .info,
            meetingId.uuidString, urls.count, audioDurationSeconds,
            reasonLabel(reason),
            interruptedBySleep ? "true" : "false"
        )

        finalizedContinuation.yield(event)
        finalizedContinuation.finish()
        return event
    }

    // MARK: - Drain tasks

    private func startDrainTasks(
        micStream: AsyncStream<[Float]>,
        systemStream: AsyncStream<[Float]>
    ) {
        // Mic-side drain
        micDrainTask = Task { [weak self] in
            for await chunk in micStream {
                guard let self else { return }
                let writer = await self.writer
                await writer?.appendMicSamples(chunk)
            }
        }
        // System-side drain
        systemDrainTask = Task { [weak self] in
            for await chunk in systemStream {
                guard let self else { return }
                let writer = await self.writer
                await writer?.appendSystemSamples(chunk)
            }
        }
    }

    private func cancelDrainTasks() {
        micDrainTask?.cancel()
        micDrainTask = nil
        systemDrainTask?.cancel()
        systemDrainTask = nil
    }

    // MARK: - Publisher tasks

    private func startPublisherTasks() {
        levelEmitTask = Task { [weak self] in
            // ~30 Hz emit cadence — matches AudioRecorder meter rate.
            let intervalNs: UInt64 = 33_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard let self else { return }
                if await self.isPaused { continue }
                let writer = await self.writer
                let level = await writer?.currentLevel() ?? 0
                await MainActor.run {
                    self.audioLevelContinuation.yield(MeetingRecorderAudioLevel(level))
                }
            }
        }
        durationEmitTask = Task { [weak self] in
            // 5 Hz emit cadence — matches 200 ms tick from Stage 4 plan.
            let intervalNs: UInt64 = 200_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard let self else { return }
                let elapsed = await self.currentElapsed()
                await MainActor.run {
                    self.durationContinuation.yield(elapsed)
                }
            }
        }
    }

    private func cancelPublisherTasks() {
        levelEmitTask?.cancel()
        levelEmitTask = nil
        durationEmitTask?.cancel()
        durationEmitTask = nil
    }

    /// Wall-clock elapsed including the current segment. Safe to call
    /// while paused (segmentStartedAt is nil; just returns pausedElapsed).
    private func currentElapsed() -> TimeInterval {
        if let started = segmentStartedAt {
            return pausedElapsed + Date().timeIntervalSince(started)
        }
        return pausedElapsed
    }

    // MARK: - Auto-end watcher

    /// Subscribes to the mic-in-use probe and arms a per-release timer.
    /// If the mic stays released for `autoEndMicReleasedSeconds` without
    /// flipping back to `true`, the recorder auto-finalizes with
    /// `.autoEnd`. Re-acquiring the mic cancels the pending timer.
    private func startAutoEndWatcher() {
        let probe = micInUseProbe
        let threshold = autoEndMicReleasedSeconds
        micInUseDrainTask = Task { [weak self] in
            let stream = await MainActor.run { probe.subscribe() }
            // A new subscription is seeded from the probe's cached value.
            // When Notes starts before the meeting app has opened its mic,
            // that value is `false` and is not evidence that a call ended.
            // Require a real active-mic observation before treating a later
            // release as an auto-end transition.
            var hasObservedActiveMic = false
            for await inUse in stream {
                guard let self else { return }
                if inUse {
                    hasObservedActiveMic = true
                    await self.cancelAutoEndArmInternal()
                } else if hasObservedActiveMic {
                    await self.armAutoEnd(after: threshold)
                }
            }
        }
    }

    private func armAutoEnd(after seconds: TimeInterval) {
        // Cancel any prior arm so the timer always reflects the latest
        // mic-released transition, not whatever was scheduled earlier.
        autoEndArmTask?.cancel()
        // Meeting apps flap the mic while joining a call (Zoom prejoin →
        // conference audio), so a release seen early in the recording's
        // life defers: auto-end can only land once the recording is at
        // least `autoEndStartupGraceSeconds` old. Age is active wall-clock
        // time (`currentElapsed()`): paused stretches don't count.
        // WHY: docs/decisions/2026-07-20-silent-reconnect-and-autoend-startup-grace.md
        let seconds = max(seconds, autoEndStartupGraceSeconds - currentElapsed())
        let ns = UInt64(seconds * 1_000_000_000)
        autoEndArmTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ns)
            if Task.isCancelled { return }
            guard let self else { return }
            os_log("auto-end fired (reason: mic_released_%{public}.0fs)",
                   log: Self.log, type: .info, seconds)
            _ = await self.stop(reason: .autoEnd)
        }
    }

    private func cancelAutoEndArmInternal() {
        autoEndArmTask?.cancel()
        autoEndArmTask = nil
    }

    private func cancelAutoEndWatcher() {
        micInUseDrainTask?.cancel()
        micInUseDrainTask = nil
        cancelAutoEndArmInternal()
    }

    // MARK: - Helpers

    private func reasonLabel(_ reason: MeetingRecorderStopReason) -> String {
        switch reason {
        case .user: return "user"
        case .autoEnd: return "auto_end"
        case .forced: return "forced"
        case .systemError: return "system_error"
        }
    }
}

// MARK: - ChunkWriter

/// Actor that owns the on-disk chunk state for a single meeting. The
/// recorder calls `appendMicSamples` / `appendSystemSamples` from two
/// drain tasks concurrently; the actor keeps mic + system queues, mixes
/// only when both have samples available, and writes mixed PCM16 into the
/// current chunk file. Rotations happen lazily inside `appendMixed` when
/// the accumulated sample count for the current chunk exceeds the
/// budget.
///
/// File-write contract: each chunk is written as `chunk-NNN.wav.tmp`,
/// flushed via `synchronizeFile`, then atomically renamed to
/// `chunk-NNN.wav`. The SHA256 sidecar (`chunk-NNN.sha256`) is computed
/// from the final bytes and written immediately after. Half-written
/// files crashes are recoverable because the `.tmp` extension is never
/// claimed as a real chunk by Stage 5 upload.
private struct ChunkWriterFinalizeResult: Sendable {
    let chunkURLs: [URL]
    let audioDurationSeconds: TimeInterval
    /// Stage 5a: set only when `retainSeparateTracks` was on and at least
    /// one of the raw tracks carried audio. `nil` for the mixed-only path.
    let separateTrackURLs: MeetingRecorder.SeparateTrackURLs?
}

private actor ChunkWriter {
    private let meetingDir: URL
    private let sampleRate: Int
    /// Maximum samples per chunk before rotation. Stored separately from
    /// the seconds value so the rotation check is a single integer
    /// compare against the running sample counter.
    private let chunkSampleBudget: Int

    /// Per-input FIFO buffer. Mic samples are pulled from the front in
    /// pairs with system samples to produce mixed output.
    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []

    /// Stage 5a: when `true`, retain the raw mic-only and system-only
    /// tracks (un-mixed) so the local transcription path can transcribe
    /// each source separately. Independent of the mixing logic below —
    /// the mixed chunk path is unchanged regardless of this flag.
    private let retainSeparateTracks: Bool

    /// Raw per-source Int16 samples accumulated in arrival order while
    /// `retainSeparateTracks` is on. Captured BEFORE mixing and BEFORE
    /// the solo-drain/pair logic touches the queues, so they hold the
    /// true mic and system signals, independent of stream alignment.
    /// Flushed to `mic.wav` / `system.wav` on `finalize()`. Empty (and
    /// never written) when retention is off.
    private var micTrackSamples: [Int16] = []
    private var systemTrackSamples: [Int16] = []

    /// True between `beginPause()` and `endPause()`. While paused the
    /// writer discards EVERY incoming sample (mic and system) so nothing
    /// captured during a user / sleep pause reaches a chunk.
    ///
    /// WHY this lives in the writer and not just the recorder: the
    /// system-audio drain Task intentionally stays alive across pause (the
    /// `AsyncStream` single-iterator constraint documented on
    /// `MeetingRecorder.pause()` means we cannot cancel + restart it), and
    /// the system tap (owned by `SystemAudioVADProbe`) keeps producing
    /// callbacks regardless of our pause state. So the only place that can
    /// reliably drop paused-era audio is the actor that receives it. A
    /// privacy bug otherwise: the single-source fallback would solo-drain
    /// the system queue into a chunk while the user believes capture is
    /// stopped.
    private var isPaused = false

    /// Mixed Int16 samples accumulated for the current chunk. Flushed
    /// to disk on rotation or finalize.
    private var currentChunkSamples: [Int16] = []
    private var currentChunkIndex: Int = 0

    /// Recent raw input samples per source — used by `currentLevel()` to
    /// derive a smoothed [0…1] level for the recording pill waveform.
    /// The windows are intentionally separate: the system stream can
    /// emit silence continuously, and a shared window would let those
    /// zeros erase the user's mic level before the next UI tick.
    private var micRMSWindow: [Float] = []
    private var systemRMSWindow: [Float] = []
    private static let rmsWindowSampleCount = 1024


    /// URLs of chunks written so far (rotation + finalize all push here).
    private var writtenChunks: [URL] = []
    /// Exact duration of audio that successfully reached chunk files.
    private var writtenAudioDurationSeconds: TimeInterval = 0

    /// Threshold (in samples) at which a single producing queue is allowed
    /// to drain solo without the other side. Picked at ~5 s @ 16 kHz so a
    /// brief mic / system pause does not desync the streams, but a stalled
    /// source — system audio stops callbacks when the system is silent,
    /// mic input may go idle on OS mic mute — does not buffer
    /// indefinitely. The other side gets dropped silence (not mixed in)
    /// for the duration; on `finalize()` any residual samples drain solo
    /// too so a 15-minute mic-only segment is preserved instead of erased.
    private let soloDrainThresholdSamples: Int

    init(
        meetingDir: URL,
        sampleRate: Int,
        chunkRotationSeconds: TimeInterval,
        retainSeparateTracks: Bool = false
    ) {
        self.meetingDir = meetingDir
        self.sampleRate = sampleRate
        self.chunkSampleBudget = Int(chunkRotationSeconds * TimeInterval(sampleRate))
        self.soloDrainThresholdSamples = sampleRate * 5
        self.retainSeparateTracks = retainSeparateTracks

        // Reconnect deliberately reuses the recorder id and staging
        // directory. Resume after the last live chunk instead of replacing
        // chunk-000, and return the complete recording on finalization.
        let existing = Self.existingChunks(in: meetingDir)
        self.writtenChunks = existing.urls
        self.currentChunkIndex = existing.nextLiveIndex
        self.writtenAudioDurationSeconds = existing.audioDurationSeconds

        // The fully-local path consumes raw mic/system tracks. Seed those
        // accumulators too, so reconnect produces one combined pair rather
        // than overwriting the first segment's tracks.
        if retainSeparateTracks {
            self.micTrackSamples = Self.pcm16Samples(
                at: meetingDir.appendingPathComponent("mic.wav")
            )
            self.systemTrackSamples = Self.pcm16Samples(
                at: meetingDir.appendingPathComponent("system.wav")
            )
        }
    }

    private nonisolated static func existingChunks(
        in directory: URL
    ) -> (urls: [URL], nextLiveIndex: Int, audioDurationSeconds: TimeInterval) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let urls = contents.filter {
            $0.pathExtension.lowercased() == "wav"
                && $0.lastPathComponent.hasPrefix("chunk-")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        let liveIndices = urls.compactMap { url -> Int? in
            let name = url.deletingPathExtension().lastPathComponent
            guard !name.hasSuffix("-prerecord") else { return nil }
            return Int(name.dropFirst("chunk-".count))
        }
        let duration = urls.reduce(0) { total, url in
            guard let data = try? Data(contentsOf: url) else { return total }
            return total + (wavDurationSeconds(data) ?? 0)
        }
        return (urls, (liveIndices.max() ?? -1) + 1, duration)
    }

    private nonisolated static func pcm16Samples(at url: URL) -> [Int16] {
        guard let data = try? Data(contentsOf: url), data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE",
              readUInt16LE(data, at: 34) == 16 else { return [] }
        let declaredBytes = Int(readUInt32LE(data, at: 40))
        let end = min(data.count, 44 + declaredBytes)
        guard end > 44 else { return [] }
        var samples: [Int16] = []
        samples.reserveCapacity((end - 44) / 2)
        var offset = 44
        while offset + 1 < end {
            let bits = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            samples.append(Int16(bitPattern: bits))
            offset += 2
        }
        return samples
    }

     // MARK: - Public surface

    /// Persist the prerecord WAV blob captured from `PrerecordBuffer.snapshot()`
    /// at pill `Yes` time. Written as a standalone `chunk-000-prerecord.wav`
    /// before live capture starts so Stage 5 can upload it alongside the
    /// rest. The blob already has a valid WAV header.
    func persistPrerecord(_ snapshot: Data) async throws {
        let url = meetingDir.appendingPathComponent(
            String(format: "chunk-%03d-prerecord.wav", currentChunkIndex)
        )
        try snapshot.write(to: url, options: [.atomic])
        let hash = Self.hexSHA256(snapshot)
        let sidecar = url.deletingPathExtension().appendingPathExtension("sha256")
        try hash.write(to: sidecar, atomically: true, encoding: .utf8)
        writtenChunks.append(url)
        writtenAudioDurationSeconds += Self.wavDurationSeconds(snapshot) ?? 0
    }

    /// Mic samples drain entry point. Adds to mic queue, mixes any pairs
    /// already aligned with system queue.
    ///
    /// Dropped while paused: the user pressed Pause to stop capture, so
    /// nothing the mic emits between `beginPause()` and `endPause()` may
    /// reach a chunk. (Production also releases the mic engine on pause,
    /// so this is a belt-and-braces guard against any in-flight buffer the
    /// drain Task delivers after `micSource.stop()`.)
    func appendMicSamples(_ samples: [Float]) {
        guard !isPaused else { return }
        guard !samples.isEmpty else { return }
        appendMeteringSamples(samples, into: &micRMSWindow)
        if retainSeparateTracks {
            appendRawTrack(samples, into: &micTrackSamples)
        }
        micQueue.append(contentsOf: samples)
        drainAlignedPairs()
    }

    /// System samples drain entry point. Adds to system queue, mixes
    /// any pairs already aligned with mic queue.
    ///
    /// Dropped while paused: the system tap (owned by
    /// `SystemAudioVADProbe`) keeps producing through the pause and the
    /// drain Task stays alive, so this is the gate that actually enforces
    /// the privacy contract — other-party audio captured while paused is
    /// discarded here rather than solo-drained into a chunk.
    func appendSystemSamples(_ samples: [Float]) {
        guard !isPaused else { return }
        guard !samples.isEmpty else { return }
        appendMeteringSamples(samples, into: &systemRMSWindow)
        if retainSeparateTracks {
            appendRawTrack(samples, into: &systemTrackSamples)
        }
        systemQueue.append(contentsOf: samples)
        drainAlignedPairs()
    }

    /// Enter the paused state. Flush the in-flight chunk so legitimately
    /// captured (and already mixed) pre-pause audio is persisted, then
    /// clear BOTH input queues and flip the pause gate so subsequent
    /// `appendMicSamples` / `appendSystemSamples` calls are dropped.
    ///
    /// Why clear the queues HERE (at pause) rather than at resume: after
    /// the flush, anything left in `micQueue` / `systemQueue` is unpaired
    /// residual — samples that arrived but never mixed with the other
    /// source. Clearing them now guarantees two things the resume path
    /// relies on: (i) no paused-era audio survives in a queue to be
    /// written later; (ii) post-resume mic / system samples pair from a
    /// clean slate, so the mix is not time-shifted by a pause-era backlog.
    /// The trade-off — dropping the unpaired residual at the pause instant
    /// (at most one un-mixed buffer per source, well under the 5 s
    /// solo-drain grace) — is acceptable and strictly safer than the prior
    /// behavior, which let paused-era system audio reach disk. `finalize()`
    /// still solo-drains residuals on the Stop path, so a real mic-only or
    /// system-only tail is preserved there; pause is the one place we
    /// deliberately discard it.
    func beginPause() {
        flushCurrentChunk(includeAnyResiduals: true)
        micQueue.removeAll(keepingCapacity: true)
        systemQueue.removeAll(keepingCapacity: true)
        isPaused = true
    }

    /// Leave the paused state so the append entry points start accepting
    /// samples again. Chunk index already advanced past the pre-pause
    /// chunk in `beginPause()`'s flush, so post-resume audio lands on a
    /// fresh chunk. The recorder may also finalize while still gated
    /// (Stop pressed during a pause); `finalize()` is gate-agnostic by
    /// design — `beginPause()` left every buffer empty and the gate kept
    /// paused-era audio out, so there is nothing stale to flush.
    func endPause() {
        isPaused = false
    }

    /// dBFS-derived level over the latest mic and system source windows,
    /// scaled to [0…1] with the same meter curve the Drop and streaming
    /// flows use. Pure-Swift helper that lets the recorder publish without
    /// re-deriving audio power in the MainActor hot path.
    func currentLevel() -> Double {
        max(normalizedLevel(for: micRMSWindow), normalizedLevel(for: systemRMSWindow))
    }

    private func normalizedLevel(for samples: [Float]) -> Double {
        Double(AudioMeter.normalize(samples: samples))
    }

    /// Stop accepting samples, flush the current chunk (if any), return
    /// the list of all chunk URLs in write order. Any residual samples
    /// in either queue that never paired up with the other source are
    /// drained solo so a long mic-only or system-only tail is preserved
    /// — the prior implementation dropped these residuals and lost up to
    /// the full duration of any stalled-source segment.
    func finalize() -> ChunkWriterFinalizeResult {
        if !micQueue.isEmpty {
            drainSoloMic(count: micQueue.count)
        }
        if !systemQueue.isEmpty {
            drainSoloSystem(count: systemQueue.count)
        }
        flushCurrentChunk(includeAnyResiduals: true)
        micQueue.removeAll(keepingCapacity: false)
        systemQueue.removeAll(keepingCapacity: false)

        let separateTracks = writeSeparateTracksIfNeeded()

        return ChunkWriterFinalizeResult(
            chunkURLs: writtenChunks,
            audioDurationSeconds: writtenAudioDurationSeconds,
            separateTrackURLs: separateTracks
        )
    }

     /// Stage 5a: flush the retained raw mic / system tracks to
    /// `mic.wav` / `system.wav`. Returns the URLs when at least one track
    /// carried audio; `nil` when retention was off or both tracks are
    /// empty (so a silent/aborted recording does not surface phantom
    /// track files). Each WAV uses the same 16 kHz mono PCM16 header as
    /// the mixed chunks.
    private func writeSeparateTracksIfNeeded() -> MeetingRecorder.SeparateTrackURLs? {
        guard retainSeparateTracks else { return nil }
        guard !micTrackSamples.isEmpty || !systemTrackSamples.isEmpty else { return nil }

        let micURL = meetingDir.appendingPathComponent("mic.wav")
        let systemURL = meetingDir.appendingPathComponent("system.wav")
        let micOK = writeTrackWAV(samples: micTrackSamples, to: micURL)
        let systemOK = writeTrackWAV(samples: systemTrackSamples, to: systemURL)

        micTrackSamples.removeAll(keepingCapacity: false)
        systemTrackSamples.removeAll(keepingCapacity: false)

        // Surface the URLs only if both files are on disk. The local
        // transcriber reads both; a half-written pair is not actionable,
        // so fall back to nil (the local path will report "no audio").
        guard micOK, systemOK else { return nil }
        return MeetingRecorder.SeparateTrackURLs(micURL: micURL, systemURL: systemURL)
    }

    @discardableResult
    private func writeTrackWAV(samples: [Int16], to url: URL) -> Bool {
        let wav = Self.wavData(samples: samples, sampleRate: sampleRate)
        do {
            try wav.write(to: url, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Mixing

    private func drainAlignedPairs() {
        // Mix as many samples as both queues can support.
        let aligned = min(micQueue.count, systemQueue.count)
        if aligned > 0 {
            drainMixedPairs(count: aligned)
        }

        // Single-source fallback: if one side is empty AND the other has
        // accumulated more than the grace threshold, drain the producing
        // side solo (no halving, since there is no second source to add
        // headroom for). This is the path that recovers a meeting where
        // System audio stops calling back during silence or the mic engine
        // goes idle — the prior behavior buffered indefinitely and lost
        // everything on finalize.
        if micQueue.count >= soloDrainThresholdSamples, systemQueue.isEmpty {
            drainSoloMic(count: micQueue.count)
        } else if systemQueue.count >= soloDrainThresholdSamples, micQueue.isEmpty {
            drainSoloSystem(count: systemQueue.count)
        }
    }

    private func drainMixedPairs(count: Int) {
        currentChunkSamples.reserveCapacity(currentChunkSamples.count + count)
        for i in 0..<count {
            let m = micQueue[i]
            let s = systemQueue[i]
            // Per-sample average so combined amplitude stays in [-1, 1].
            let mixed = (m + s) * 0.5
            appendFrame(mixed: mixed, mic: m, system: s)
        }
        micQueue.removeFirst(count)
        systemQueue.removeFirst(count)
    }

    private func drainSoloMic(count: Int) {
        currentChunkSamples.reserveCapacity(currentChunkSamples.count + count)
        for i in 0..<count {
            let mic = micQueue[i]
            appendFrame(mixed: mic, mic: mic, system: 0)
        }
        micQueue.removeFirst(count)
    }

    private func drainSoloSystem(count: Int) {
        currentChunkSamples.reserveCapacity(currentChunkSamples.count + count)
        for i in 0..<count {
            let system = systemQueue[i]
            appendFrame(mixed: system, mic: 0, system: system)
        }
        systemQueue.removeFirst(count)
    }

    private func appendFrame(mixed: Float, mic: Float, system: Float) {
        _ = mic
        _ = system
        currentChunkSamples.append(Self.pcm16(mixed))
        if currentChunkSamples.count >= chunkSampleBudget {
            flushCurrentChunk(includeAnyResiduals: false)
        }
    }

    private nonisolated static func pcm16(_ sample: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, sample))
        return Int16(clamped * Float(Int16.max))
    }

    /// Stage 5a: convert raw Float samples to clamped Int16 PCM and append
    /// to a per-source track buffer. Same clamp/scale as `appendPCM` so the
    /// separate tracks match the codec used for the mixed chunks. No
    /// rotation — the whole track is written once at finalize.
    private func appendRawTrack(_ samples: [Float], into track: inout [Int16]) {
        track.reserveCapacity(track.count + samples.count)
        for sample in samples {
            track.append(Self.pcm16(sample))
        }
    }

    private func appendMeteringSamples(_ samples: [Float], into window: inout [Float]) {
        window.reserveCapacity(min(Self.rmsWindowSampleCount, window.count + samples.count))
        for sample in samples {
            window.append(max(-1.0, min(1.0, sample)))
        }
        if window.count > Self.rmsWindowSampleCount {
            window.removeFirst(window.count - Self.rmsWindowSampleCount)
        }
    }

    // MARK: - File I/O

    private func flushCurrentChunk(includeAnyResiduals: Bool) {
        guard !currentChunkSamples.isEmpty else {
            if includeAnyResiduals { /* nothing to flush */ }
            return
        }
        let idx = currentChunkIndex
        let url = writeChunk(samples: currentChunkSamples, prefix: "chunk-", idx: idx)

        if let url {
            writtenChunks.append(url)
            writtenAudioDurationSeconds += Double(currentChunkSamples.count) / Double(sampleRate)
        }

        currentChunkSamples.removeAll(keepingCapacity: true)
        currentChunkIndex += 1
    }

    private func writeChunk(samples: [Int16], prefix: String, idx: Int) -> URL? {
        let url = meetingDir.appendingPathComponent(String(format: "%@%03d.wav", prefix, idx))
        let tmpURL = url.appendingPathExtension("tmp")
        let wav = Self.wavData(samples: samples, sampleRate: sampleRate)
        do {
            try? FileManager.default.removeItem(at: tmpURL)
            try wav.write(to: tmpURL, options: [.atomic])
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmpURL, to: url)
            let hash = Self.hexSHA256(wav)
            let sidecar = url.deletingPathExtension().appendingPathExtension("sha256")
            try hash.write(to: sidecar, atomically: true, encoding: .utf8)
            return url
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }
    }

    // MARK: - WAV header

    /// Build a complete 16 kHz mono PCM16 WAV from the given Int16
    /// samples. The header math is identical to `PrerecordBuffer.snapshot()`
    /// — kept duplicated rather than shared because the prerecord buffer
    /// is a frozen Stage 3 artifact whose 44-byte format is part of the
    /// FluidAudio fixture interface (a shared helper would couple the
    /// two modules tighter than necessary for ~30 lines of bytes).
    private static func wavData(samples: [Int16], sampleRate: Int) -> Data {
        let bodyBytes = samples.count * 2
        let bodySize = UInt32(bodyBytes)
        let totalSize = UInt32(36 + bodyBytes)
        let byteRate = UInt32(sampleRate * 1 * 16 / 8)
        let blockAlign: UInt16 = 1 * 16 / 8

        var header = Data(capacity: 44)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        header.append(uint32LE: totalSize)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        header.append(uint32LE: 16)                          // PCM fmt chunk size
        header.append(uint16LE: 1)                           // PCM
        header.append(uint16LE: 1)                           // mono
        header.append(uint32LE: UInt32(sampleRate))
        header.append(uint32LE: byteRate)
        header.append(uint16LE: blockAlign)
        header.append(uint16LE: 16)                          // bits per sample
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        header.append(uint32LE: bodySize)

        var wav = header
        let body = samples.withUnsafeBufferPointer { ptr -> Data in
            Data(buffer: ptr)
        }
        wav.append(body)
        return wav
    }

    private static func hexSHA256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func wavDurationSeconds(_ data: Data) -> TimeInterval? {
        guard data.count >= 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE",
              String(data: data[36..<40], encoding: .ascii) == "data" else {
            return nil
        }
        let channels = Int(readUInt16LE(data, at: 22))
        let sampleRate = Int(readUInt32LE(data, at: 24))
        let bitsPerSample = Int(readUInt16LE(data, at: 34))
        let dataBytes = Int(readUInt32LE(data, at: 40))
        let bytesPerFrame = channels * (bitsPerSample / 8)
        guard channels > 0, sampleRate > 0, bytesPerFrame > 0 else { return nil }
        return Double(dataBytes) / Double(bytesPerFrame) / Double(sampleRate)
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }
}

// MARK: - Data little-endian helpers

private extension Data {
    mutating func append(uint16LE value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32LE value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

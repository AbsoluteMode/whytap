import AVFoundation
import Foundation
import os.log
import os.lock

/// Fatal audio-engine errors surfaced to the session so a dead mic resolves
/// the drop as `.failed` instead of silently recording nothing or crashing.
///
/// `invalidInputFormat`: the input node reported a 0 Hz / 0 channel format
/// (a Mac with no input device). Feeding that to `installTap` raises an
/// *uncatchable* ObjC exception — we detect it up front and throw instead.
///
/// `restartFailed`: an `.AVAudioEngineConfigurationChange` (AirPods
/// connect/disconnect mid-drop) stopped the engine and every restart attempt
/// failed. The mic is dead; recording dead air and pasting a truncated
/// transcript as success is worse than failing fast.
enum StreamingAudioEngineError: Error, Equatable {
    case invalidInputFormat
    case restartFailed
}

/// Protocol the streaming transcription sessions depend on for audio input.
/// Decoupled from the concrete `StreamingAudioEngine` so tests can inject
/// a stub that yields nothing (the WS event stream alone is enough to
/// drive session resolution paths in unit tests).
protocol StreamingAudioSourcing: AnyObject, Sendable {
    /// Stream of PCM16 byte chunks (~120 ms each at 16 kHz mono).
    var chunks: AsyncStream<Data> { get }
    /// Fatal-failure signal. Emits at most one element when the engine dies
    /// in a way the session cannot recover from (bad input format, restart
    /// exhausted). The session races this against the WS event stream and
    /// resolves `.failed` so a dead mic never pastes a truncated transcript
    /// as success.
    ///
    /// A real audio source MUST override this; the empty default (finishes
    /// immediately, never emits) is for test doubles only — relying on it in
    /// production silently disables dead-mic detection.
    var failures: AsyncStream<StreamingAudioEngineError> { get }
    /// Start the input pipeline. Throws on TCC / hardware failure.
    func start() throws
    /// Idempotent teardown. Safe across error paths.
    ///
    /// `@MainActor`: teardown mutates engine state that has no lock and
    /// relies on single-actor access (see `StreamingAudioEngine`'s
    /// concurrency note) — the annotation makes the contract
    /// compiler-enforced for every caller, including existential ones.
    @MainActor
    func stop()
    /// Graceful end-of-capture: keep the tap alive briefly to capture
    /// the word tail spoken across the hotkey release, then stop.
    /// Implementations without a live capture pipeline fall back to
    /// `stop()` (see extension default). Idempotent. `@MainActor` for
    /// the same single-actor engine-state contract as `stop()`.
    @MainActor
    func finish()
    /// PCM16 captured this turn for batch fallback. Empty for test stubs.
    func capturedPCM16() -> Data
}

extension StreamingAudioSourcing {
    /// Stubs that never fail (unit-test doubles) inherit an empty, already
    /// finished stream so consuming `for await _ in failures` returns at
    /// once and the session's failure-watch task exits cleanly.
    var failures: AsyncStream<StreamingAudioEngineError> {
        AsyncStream { $0.finish() }
    }

    /// Default: no tail to capture — immediate stop. Real engines
    /// override with a silence-gated tail; cancel paths keep calling
    /// `stop()` directly for immediate teardown (Escape, sleep, quit).
    @MainActor
    func finish() { stop() }

    /// Default: test stubs have no real audio; return empty data.
    func capturedPCM16() -> Data { Data() }
}

/// AVAudioEngine-backed mic capture that yields 16 kHz mono PCM16 audio
/// chunks as raw bytes. Each chunk is ~120 ms (1920 samples × 2 bytes =
/// 3840 bytes) — the frame size the realtime providers expect.
///
/// Lifecycle:
///   1. `start()` — install tap, build converter, start engine. Throws on
///      engine.start failure (TCC denial, mic in use by another process).
///   2. `chunks` — `AsyncStream<Data>` of PCM16 byte chunks. Drain from
///      a single consumer.
///   3. `stop()` — remove tap, stop engine, flush residual via `drain()`,
///      finish the chunk stream. Idempotent.
///
/// Concurrency: `AVAudioEngine`'s tap callback runs on an internal audio
/// thread. We forward Float samples through a `StreamingAudioChunker`
/// guarded by a serial dispatch queue to keep the chunker invariant
/// (`pending` array) single-threaded. The continuation handoff is
/// `Sendable` per Foundation.
///
/// Why not reuse `MicCaptureSource`: Stage 4 already ships a similar
/// engine for the meetings recorder, but that one emits `[Float]` samples
/// (the meeting recorder needs to mix mic + system audio before PCM16
/// encoding). The streaming flow doesn't mix — it goes Float → PCM16
/// directly — so a thinner adapter is cleaner than threading PCM16
/// conversion through `MicCaptureSource`'s consumers.
final class StreamingAudioEngine: StreamingAudioSourcing, @unchecked Sendable {
    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "streaming-engine")

    /// 30 Hz publish cadence — matches `AudioRecorder.meterInterval` so the
    /// orb behaves identically whether the user is on the async or
    /// streaming pipeline. Pinned by `testMeterIntervalMatchesAsyncPathThirtyHertz`
    /// so bumping it requires touching both files (drift between paths
    /// would produce visibly different orb responsiveness).
    static let meterInterval: TimeInterval = 1.0 / 30.0

    private let engine = AVAudioEngine()
    private let targetSampleRate: Double = 16_000
    private let targetFormat: AVAudioFormat?

    /// Serial queue guarding the chunker — the audio tap callback can fire
    /// before the previous callback's chunker work has returned.
    private let chunkerQueue = DispatchQueue(label: "com.rootwise.sidekey.streaming-chunker")

    private var chunker = StreamingAudioChunker()
    private var finishGate = StreamingFinishGate()
    /// Failsafe bound for the finishing tail: gate maxTail (450 ms) +
    /// scheduling margin. If tap callbacks die right at release (BT
    /// route glitch) the gate never observes another buffer — this
    /// timer guarantees stop() regardless.
    static let finishFailsafeSeconds: TimeInterval = 0.6
    private var converter: AVAudioConverter?

    /// Public chunk stream. Consumers drain it via `for await chunk in ...`.
    let chunks: AsyncStream<Data>
    private let chunksContinuation: AsyncStream<Data>.Continuation

    /// Fatal-failure signal (see `StreamingAudioSourcing.failures`). Emits
    /// once when the engine cannot keep capturing — bad format or restart
    /// exhausted after a route change.
    let failures: AsyncStream<StreamingAudioEngineError>
    private let failuresContinuation: AsyncStream<StreamingAudioEngineError>.Continuation

    /// State guard so `start()` / `stop()` are idempotent across error
    /// paths.
    private var isRunning: Bool = false

    /// Full PCM16 captured this turn, teed off the same bytes yielded to
    /// `chunks`. Feeds the batch fallback when the live stream degrades.
    let turnAudio = TurnAudioBuffer()

    /// True once `start()` has succeeded and the caller has NOT yet asked to
    /// stop. Gates the route-change restart: a configuration change that
    /// arrives after the user stopped (or before they started) must not
    /// resurrect the engine. Mirrors `MicCaptureSource.isCaptureRequested`.
    private var isCaptureRequested = false

    /// Token observer for `.AVAudioEngineConfigurationChange`, scoped to THIS
    /// engine instance (`object: engine`) so an unrelated subsystem's route
    /// change can't trigger our restart. Removed in `deinit`.
    private var configurationObserver: NSObjectProtocol?

    /// Debounces route-change notifications and runs the restart only while
    /// capture is requested. Same primitive the meeting recorder uses
    /// (`MicCaptureSource`), so both subsystems handle AirPods churn
    /// identically. Lazily built so `self` is fully initialised first.
    private lazy var restartMonitor = AudioCaptureRestartMonitor(
        debounceNanoseconds: Self.restartDebounceNanoseconds
    ) { [weak self] in
        await self?.restartAfterConfigurationChange()
    }

    /// Bluetooth route switches can publish several transient input formats
    /// before CoreAudio settles. A shorter debounce than the meeting
    /// recorder's 2.5 s is fine here — the drop flow owns the mic outright
    /// (no competing WebRTC graph to race), and a snappier restart keeps the
    /// truncated-audio window small.
    private static let restartDebounceNanoseconds: UInt64 = 400_000_000

    /// Restart backoff after a route change. CoreAudio can expose stale
    /// formats for a beat; a later attempt usually succeeds once the HAL
    /// graph catches up. Same shape as `MicCaptureSource`.
    private static let restartRetryDelaysNanoseconds: [UInt64] = [
        0,
        300_000_000,
        750_000_000,
        1_500_000_000
    ]

    /// Latest normalized [0..1] audio level. Written from the audio thread
    /// (`process(inputBuffer:)` → `cacheAudioLevel(_:)`); read from the
    /// main thread (`publishLatestLevel()` via `levelTimer`). Guarded by
    /// `levelLock` — the audio thread must never block on the main run
    /// loop, and `os_unfair_lock` is ~2-3 ns uncontended which is well
    /// under the budget of a 1024-sample tap callback at 48 kHz (~21 ms).
    ///
    /// Why decouple from the tap callback at all: pre-1.1.3 the tap
    /// dispatched `Task { @MainActor in pushAudioLevel(...) }` per buffer
    /// (~48 Hz). Each `Task` schedules an actor-hop continuation which
    /// queues behind any pending main-thread work; perceived effect was
    /// an orb pulse trailing the user's voice. Caching here + publishing
    /// from a Timer 30 Hz mirrors the async path exactly (see
    /// `AudioRecorder.tickMeter`) — Timer body runs on the main run loop
    /// directly, no hop.
    private var _latestLevel: Float = 0
    private let levelLock = OSAllocatedUnfairLock()

    /// Read-only view of `_latestLevel`. Internal (not `private`) so tests
    /// can verify the cache contract without driving a real `AVAudioEngine`
    /// tap — the tap requires a mic + TCC grant not available on CI.
    var latestLevel: Float {
        levelLock.lock()
        defer { levelLock.unlock() }
        return _latestLevel
    }

    /// Main-thread `Timer` driving `publishLatestLevel()` at
    /// `meterInterval`. Lifecycle owned by `start()` / `stop()`; nil
    /// between sessions so a residual fire can't push stale levels into
    /// `AppState` after the engine has been torn down.
    private var levelTimer: Timer?

    init() {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        let (stream, cont) = AsyncStream<Data>.makeStream()
        self.chunks = stream
        self.chunksContinuation = cont
        let (failStream, failCont) = AsyncStream<StreamingAudioEngineError>.makeStream()
        self.failures = failStream
        self.failuresContinuation = failCont

        // Observe ONLY this engine's configuration changes (route swap,
        // sample-rate renegotiation). The notification fires on an arbitrary
        // thread; the monitor debounces and hops to the main actor before
        // touching the engine. Scoped via `object: engine` so we don't react
        // to the meeting recorder's engine.
        self.configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.restartMonitor.trigger()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        restartMonitor.setActive(false)
        chunksContinuation.finish()
        failuresContinuation.finish()
    }

    /// Validate the input node's reported format before we hand it to
    /// `installTap`. A Mac with no input device reports 0 Hz / 0 channels;
    /// `AVAudioFormat` refuses to build that (the call site receives `nil`),
    /// and `installTap` with such a format raises an *uncatchable* ObjC
    /// exception. We turn that into a typed Swift `throw` so the session can
    /// resolve `.failed` instead of crashing.
    ///
    /// Static + pure so it is unit-testable without a mic, exactly like
    /// `computeAudioLevel`.
    @discardableResult
    static func validate(inputFormat: AVAudioFormat?) throws -> AVAudioFormat {
        guard let inputFormat,
              inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0 else {
            throw StreamingAudioEngineError.invalidInputFormat
        }
        return inputFormat
    }

    /// Install tap + start the engine. Safe to call multiple times — a
    /// repeat call when already running is a no-op. Throws on a bad input
    /// format (no device) or engine start failure (TCC denial, mic in use).
    func start() throws {
        // Record intent first so a configuration change racing the start
        // (or a stop arriving before we finish) is honoured by the restart
        // gate. Mirrors `MicCaptureSource.isCaptureRequested`.
        isCaptureRequested = true
        guard !isRunning else { return }
        try startEngine()
        // Arm the route-change monitor only after a clean start so a change
        // that fires before we ever ran can't trigger a restart of a
        // never-started engine.
        restartMonitor.setActive(true)
    }

    /// Core install-tap-and-start. Shared by `start()` and the route-change
    /// restart so both paths build the converter from the *current* input
    /// format. Leaves `isRunning == true` on success.
    private func startEngine() throws {
        guard let targetFormat else {
            throw StreamingAudioEngineError.invalidInputFormat // target unbuildable
        }

        let inputNode = engine.inputNode
        // Validate BEFORE installTap — a 0/0 format here would otherwise
        // raise an uncatchable ObjC exception inside installTap.
        let inputFormat = try Self.validate(inputFormat: inputNode.outputFormat(forBus: 0))
        self.converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        // Buffer size 1024 = ~21 ms at 48 kHz (typical Mac input). Smaller
        // = lower latency between mic and outbound chunk; larger = fewer
        // tap callbacks. 1024 matches the existing meeting recorder so
        // both subsystems exert similar input pressure.
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.process(inputBuffer: buffer)
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
            engine.reset()
            os_log(
                "engine.start failed: %{public}@",
                log: Self.log, type: .error,
                String(describing: error)
            )
            throw error
        }
        isRunning = true
        startLevelTimer()
    }

    /// Remove tap, stop engine, flush any residual chunk, finish the stream.
    /// After `stop()` the engine is NOT reusable — the chunk stream is
    /// finished, matching the one-session-per-engine lifecycle the factory
    /// uses (a fresh `StreamingAudioEngine` is built per drop).
    ///
    /// `@MainActor` so all engine-state mutation (`isCaptureRequested`,
    /// `isRunning` via `stopEngineOnly()`, restart arming) stays on the
    /// same actor as `start()` / `restartAfterConfigurationChange()` —
    /// the state has no lock and relies on single-actor access.
    @MainActor
    func stop() {
        // Clear intent + disarm the route-change monitor first so a change
        // landing during teardown can't kick off a restart against a stream
        // we're about to finish.
        isCaptureRequested = false
        restartMonitor.setActive(false)
        guard isRunning else {
            // Stop arrived before start() ever ran — an instant tap-release
            // during a slow session-setup window. The engine produced no audio,
            // but the chunk stream must still be finished so the session's
            // forward loop ends and sends endInput()/EOF upstream; otherwise the
            // provider waits, the wing spins, and nothing is pasted until the
            // stop watchdog fires (slow / VPN setup windows).
            // WHY: docs/decisions/2026-06-16-streaming-stop-before-run.md
            chunksContinuation.finish()
            return
        }
        stopEngineOnly()
        // Flush residual on the chunker queue so we don't race with an
        // in-flight tap callback. The tap is already removed, but the
        // callback may still be on the call stack.
        chunkerQueue.async { [weak self] in
            guard let self else { return }
            if let residual = self.chunker.drain() {
                self.accumulate(residual)            // tee residual into turn buffer
                self.chunksContinuation.yield(residual)
            }
            self.chunksContinuation.finish()
        }
        // Mirror the async path: collapse the orb's audio-level buffer
        // back to empty when the session ends so the next idle paint
        // doesn't briefly show the trailing wobble from the previous
        // recording. `AudioRecorder.stop()` / `.cancel()` do the same.
        Task { @MainActor in AppState.shared.clearAudioLevels() }
    }

    /// Graceful stop for the hotkey-release path: keep capturing until
    /// the finish gate reports the spoken tail is complete (silence
    /// hold) or the max-tail bound hits, then run the normal `stop()`.
    /// Cancel paths (Escape / sleep / quit) bypass this and call
    /// `stop()` directly. Idempotent; safe when never started.
    ///
    /// `@MainActor` for the same single-actor engine-state contract as
    /// `stop()` (mutates `isCaptureRequested`, disarms the restart
    /// monitor).
    @MainActor
    func finish() {
        // No restart should resurrect capture while we are finishing.
        isCaptureRequested = false
        restartMonitor.setActive(false)
        guard isRunning else {
            stop()
            return
        }
        os_log("streaming engine: finish requested", log: Self.log, type: .info)
        chunkerQueue.async { [weak self] in
            self?.finishGate.beginFinish()
        }
        // Failsafe: if the tap stops delivering buffers the gate can
        // never fire — bound the tail by wall clock. stop() is
        // idempotent, so a gate-fired stop followed by this is a no-op.
        // The main queue IS the main actor's executor, so assumeIsolated
        // is sound here (same idiom as the meter Timer callback).
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.finishFailsafeSeconds
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    /// Tear the engine down WITHOUT finishing the chunk stream — used both
    /// by `stop()` (which then finishes the stream itself) and the
    /// route-change restart (which must keep the stream open so the
    /// consumer's `for await` survives the swap). Idempotent.
    private func stopEngineOnly() {
        isRunning = false
        // Invalidate the meter Timer BEFORE removing the tap so a final
        // timer fire can't observe a half-torn-down engine and push a
        // stale level. The timer is `@MainActor`-scheduled; invalidating
        // it here is safe from any thread per Foundation.
        stopLevelTimer()
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        // Reset the cache so a subsequent start doesn't have the previous
        // session's tail level visible until the first tap callback fires.
        cacheAudioLevel(0)
    }

    /// React to an `.AVAudioEngineConfigurationChange` (AirPods connect /
    /// disconnect, sample-rate renegotiation) by rebuilding the tap +
    /// converter from the *new* input format and restarting the engine.
    /// Ported from `MicCaptureSource.restartAfterConfigurationChange`,
    /// including its retry-or-fail-fast shape.
    ///
    /// On exhaustion we emit `.restartFailed` on the `failures` stream so the
    /// session resolves `.failed` rather than silently recording dead air and
    /// pasting a truncated transcript as success.
    ///
    /// `@MainActor` so all engine-state mutation (`isRunning`, `converter`,
    /// tap install) stays on the same actor as `start()` / `stop()` — the
    /// engine has no lock around that state and relies on single-actor
    /// access. The monitor's closure `await`s the hop.
    @MainActor
    private func restartAfterConfigurationChange() async {
        guard isCaptureRequested, isRunning else { return }
        // Disarm while we restart so the restart's own teardown/start
        // notifications don't re-trigger us; `startEngine()` does not
        // re-arm (only the public `start()` does), so we re-arm explicitly
        // on success below.
        restartMonitor.setActive(false)
        os_log(
            "streaming engine: configuration changed; restarting capture",
            log: Self.log, type: .info
        )
        stopEngineOnly()

        let retrier = AudioCaptureRestartRetrier(
            delaysNanoseconds: Self.restartRetryDelaysNanoseconds
        )
        do {
            try await retrier.run(
                operation: { [weak self] attempt in
                    // Engine state has no lock; mutate it on the main actor
                    // only (same actor as start()/stop()). The retrier's
                    // sleep runs off-actor; this hop keeps the install/start
                    // on main.
                    try await MainActor.run {
                        guard let self else { throw CancellationError() }
                        guard self.isCaptureRequested else { throw CancellationError() }
                        try self.startEngine()
                    }
                    os_log(
                        "streaming engine: restart attempt %{public}d succeeded",
                        log: Self.log, type: .info, attempt
                    )
                },
                onFailure: { attempt, _ in
                    // Log the attempt count only — never the error payload
                    // (could carry device strings). Type-only diagnostics.
                    os_log(
                        "streaming engine: restart attempt %{public}d failed",
                        log: Self.log, type: .error, attempt
                    )
                }
            )
            // Re-arm so a SECOND route change during the same drop is also
            // handled. Only if the user still wants capture.
            if isCaptureRequested { restartMonitor.setActive(true) }
        } catch is CancellationError {
            // User stopped mid-restart — not a failure, just stop.
            os_log(
                "streaming engine: restart cancelled (capture no longer requested)",
                log: Self.log, type: .info
            )
        } catch {
            // Every attempt failed: the mic is dead. Surface a fatal error so
            // the session fails fast instead of recording silence.
            os_log(
                "streaming engine: restart exhausted retries; failing session",
                log: Self.log, type: .error
            )
            failuresContinuation.yield(.restartFailed)
        }
    }

    // MARK: - Tap callback

    private func process(inputBuffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }

        let capacity = AVAudioFrameCount(max(1024, Int(inputBuffer.frameLength)))
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            return
        }

        var error: NSError?
        var didFeedInput = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if didFeedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didFeedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard status != .error, error == nil else { return }

        let frameCount = Int(outBuffer.frameLength)
        guard frameCount > 0,
              let channelData = outBuffer.floatChannelData?.pointee
        else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

        // Cache a normalized [0..1] amplitude for the meter Timer to
        // publish on the main run loop. Before 1.1.3 the streaming path
        // dispatched `Task { @MainActor in pushAudioLevel(...) }` per
        // tap buffer (~48 Hz at 1024-sample tap @ 48 kHz). Each `Task`
        // schedules an actor-hop continuation that queues behind any
        // pending main-thread work; observed effect was an orb pulse
        // trailing the user's voice. The async path doesn't have this
        // problem because `AudioRecorder.tickMeter` runs directly on a
        // main-thread `Timer` — no hop. We now mirror that exactly:
        // tap caches, Timer publishes (`publishLatestLevel`).
        let level = Self.computeAudioLevel(samples: samples)
        cacheAudioLevel(level)

        // 16 kHz mono post-converter: samples-per-ms = 16. Sample-derived
        // duration keeps the gate deterministic (no wall clock).
        let durationMs = Double(samples.count) / 16.0
        chunkerQueue.async { [weak self] in
            guard let self else { return }
            // Feed the chunker FIRST so the buffer that completes the
            // tail is itself part of the outbound audio, then ask the
            // gate. A fire dispatches the normal stop() (idempotent).
            let produced = self.chunker.feed(samples: samples)
            for chunk in produced {
                self.accumulate(chunk)               // tee into turn buffer
                self.chunksContinuation.yield(chunk)
            }
            if let reason = self.finishGate.observe(
                level: level, durationMs: durationMs
            ) {
                os_log(
                    "streaming engine: finish gate fired reason=%{public}@",
                    log: Self.log, type: .info, reason.rawValue
                )
                // Hop to the main actor for stop() — engine state is
                // main-actor-only. The main queue is the main actor's
                // executor, so assumeIsolated is sound.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.stop() }
                }
            }
        }
    }

    // MARK: - Audio metering

    /// Compute a normalized [0..1] audio level from a buffer of mono
    /// Float32 samples (post-converter, 16 kHz). The pipeline mirrors
    /// the async path's `AudioMeter.normalize(dB:)` so the orb's
    /// floor/ceiling calibration stays identical across paths:
    ///
    ///   1. RMS over the samples (`sqrt(mean(x²))`).
    ///   2. Convert to dBFS via `20 · log10(rms)`. RMS of 0 maps to
    ///      `-.infinity`, which `AudioMeter.normalize` treats as the
    ///      floor (returns 0).
    ///   3. Clamp + normalize to [0..1] using the same -60 dB floor
    ///      `AudioRecorder` uses, so the orb's voice gate
    ///      (`NoiseFloorEstimator`, `displayEnergy`) reads consistent
    ///      values whether the user is on the async or streaming flow.
    ///
    /// Exposed as `static` (no instance state) so it can be unit-tested
    /// without an `AVAudioEngine` — the engine itself needs a mic and
    /// TCC grant which aren't available on CI.
    static func computeAudioLevel(samples: [Float]) -> Float {
        AudioMeter.normalize(samples: samples)
    }

    // MARK: - Level cache / publish (orb throttle)

    /// Tee a yielded PCM16 chunk into the per-turn buffer. Called on the
    /// chunker queue alongside `chunksContinuation.yield`. Internal so the
    /// tee contract is unit-testable without an `AVAudioEngine` tap.
    func accumulate(_ chunk: Data) { turnAudio.append(chunk) }

    /// PCM16 captured this turn (for batch fallback).
    func capturedPCM16() -> Data { turnAudio.snapshotPCM16() }

    /// Store the latest normalized [0..1] level for the meter Timer to
    /// pick up. Safe to call from the audio thread — `OSAllocatedUnfairLock`
    /// is non-blocking on the uncontended path, which is the common case
    /// (writer at ~48 Hz, reader at 30 Hz, both <1 ms each).
    ///
    /// Internal (not `private`) so `StreamingAudioEngineTests` can verify
    /// the cache contract without driving a real `AVAudioEngine` tap.
    func cacheAudioLevel(_ level: Float) {
        levelLock.lock()
        _latestLevel = level
        levelLock.unlock()
    }

    /// Read the cached level and forward to `AppState.shared.audioLevels`.
    /// Driven by `levelTimer` at `meterInterval` on the main run loop —
    /// no actor hop, no Task scheduling cost per sample. This is the
    /// behavioural twin of `AudioRecorder.tickMeter`.
    ///
    /// Internal so the test suite can exercise the publish step in
    /// isolation from the timer + tap callback.
    @MainActor
    func publishLatestLevel() {
        let level = latestLevel
        AppState.shared.pushAudioLevel(level)
    }

    /// Schedule the meter Timer on the main run loop. Called from
    /// `start()` after the engine successfully starts. Using
    /// `RunLoop.main.add(_:forMode: .common)` keeps the timer firing
    /// during menu / event tracking — same trick `AudioRecorder` uses
    /// so the orb doesn't freeze while the status menu is open.
    private func startLevelTimer() {
        // Timer scheduling must happen on the main thread because we add
        // to `RunLoop.main`. `start()` is called from `@MainActor` context
        // (the streaming session's `run()`), so on the common path this
        // runs synchronously; the dispatch is a defensive guard in case
        // a future caller invokes `start()` off-main.
        let schedule: () -> Void = { [weak self] in
            guard let self else { return }
            self.levelTimer?.invalidate()
            let timer = Timer(timeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishLatestLevel()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.levelTimer = timer
        }
        if Thread.isMainThread {
            schedule()
        } else {
            DispatchQueue.main.async(execute: schedule)
        }
    }

    /// Invalidate the meter Timer. Safe across error paths (no-op if no
    /// timer is currently scheduled). Mirrors `AudioRecorder.stopMeterTimer`.
    private func stopLevelTimer() {
        let invalidate: () -> Void = { [weak self] in
            self?.levelTimer?.invalidate()
            self?.levelTimer = nil
        }
        if Thread.isMainThread {
            invalidate()
        } else {
            DispatchQueue.main.async(execute: invalidate)
        }
    }
}

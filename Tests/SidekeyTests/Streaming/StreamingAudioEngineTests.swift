import AVFoundation
import XCTest
@testable import Sidekey

/// Pure-logic tests for the audio-level metering helper inside
/// `StreamingAudioEngine`. Driven by feedback "all работает но орб не
/// реагирует на голос" against 1.1.1: the streaming pipeline switched
/// from `AVAudioRecorder` (which exports per-channel `averagePower` via
/// `isMeteringEnabled`) to `AVAudioEngine` input taps, but the engine
/// didn't compute power from the tap buffers — so `AppState.audioLevels`
/// stayed empty and the orb sat static while the user spoke.
///
/// The engine itself depends on a real mic + TCC grant (not viable on
/// CI), so we exercise the static helper that does the RMS → dBFS →
/// normalized [0..1] math on the post-conversion 16 kHz Float samples
/// the tap callback already constructs.
final class StreamingAudioEngineTests: XCTestCase {

    // MARK: - computeAudioLevel

    /// Silence (all-zero samples) maps to 0 — clamped through the same
    /// `AudioMeter.normalize` floor the async path uses so the orb's
    /// rest behaviour stays identical across paths.
    func testComputeAudioLevelSilenceIsZero() {
        let level = StreamingAudioEngine.computeAudioLevel(
            samples: Array(repeating: Float(0.0), count: 1024)
        )
        XCTAssertEqual(level, 0.0, accuracy: 0.0001)
    }

    /// Empty buffer maps to 0 — guard against the chunker being called
    /// with no samples (defensive; AVAudioEngine should never deliver
    /// zero-length buffers but a converter hiccup could).
    func testComputeAudioLevelEmptyBufferIsZero() {
        let level = StreamingAudioEngine.computeAudioLevel(samples: [])
        XCTAssertEqual(level, 0.0)
    }

    /// Full-scale sine at the carrier produces a high normalized level.
    /// The exact value depends on `AudioMeter.normalize`'s -60 dB floor:
    /// RMS of a unit-amplitude sine is 1/sqrt(2) ≈ 0.707, which is
    /// ~-3 dBFS, which normalizes to ≈ (60 - 3) / 60 ≈ 0.95.
    /// Asserting > 0.85 keeps the test robust if the floor changes
    /// slightly in the future while still failing if the metering math
    /// regresses to a constant or near-zero output.
    func testComputeAudioLevelFullScaleSineIsHigh() {
        let frequency: Float = 440
        let sampleRate: Float = 16_000
        let count = 1024
        let samples = (0..<count).map { i -> Float in
            sin(2 * .pi * frequency * Float(i) / sampleRate)
        }
        let level = StreamingAudioEngine.computeAudioLevel(samples: samples)
        XCTAssertGreaterThan(level, 0.85, "Full-scale sine should drive level near 1; got \(level)")
        XCTAssertLessThanOrEqual(level, 1.0)
    }

    /// Half-scale sine sits between silence and full-scale: half amplitude
    /// drops RMS by 6 dB (20·log10(0.5)), so a -3 dBFS full-scale becomes
    /// ~-9 dBFS → normalized ≈ (60 - 9) / 60 ≈ 0.85. We assert in a wide
    /// band so the test is not brittle to small floor changes but DOES
    /// reject a stuck-at-zero or stuck-at-one regression.
    func testComputeAudioLevelHalfScaleSineIsMid() {
        let frequency: Float = 440
        let sampleRate: Float = 16_000
        let count = 1024
        let samples = (0..<count).map { i -> Float in
            0.5 * sin(2 * .pi * frequency * Float(i) / sampleRate)
        }
        let level = StreamingAudioEngine.computeAudioLevel(samples: samples)
        XCTAssertGreaterThan(level, 0.6)
        XCTAssertLessThan(level, 0.95)
    }

    /// Very quiet signal (below the -60 dB normalization floor) clamps
    /// to 0 — same behaviour as the async path so the orb floor is
    /// consistent across pipelines.
    func testComputeAudioLevelBelowFloorIsZero() {
        // RMS of constant `c` is `|c|`. For `1e-4` (≈ -80 dBFS), the
        // AudioMeter.normalize floor of -60 dB clamps the level to 0.
        let samples = Array(repeating: Float(1e-4), count: 1024)
        let level = StreamingAudioEngine.computeAudioLevel(samples: samples)
        XCTAssertEqual(level, 0.0, accuracy: 0.001)
    }

    /// Non-finite RMS inputs (would yield NaN/Inf if log10(0) reached the
    /// caller without guarding) must still produce a finite, in-range
    /// level. The same defensive `dB.isFinite` guard already exists in
    /// `AudioMeter.normalize`; this test pins the contract end-to-end so
    /// a future refactor that bypasses the helper can't reintroduce NaN
    /// into the orb's pull loop (NaN poisons the [0..1] state buffer
    /// SwiftUI animates on).
    func testComputeAudioLevelExtremelyQuietProducesFiniteResult() {
        let samples = Array(repeating: Float(0.0), count: 1)
        let level = StreamingAudioEngine.computeAudioLevel(samples: samples)
        XCTAssertTrue(level.isFinite)
        XCTAssertGreaterThanOrEqual(level, 0.0)
        XCTAssertLessThanOrEqual(level, 1.0)
    }

    /// Clipped input (samples beyond ±1.0 — shouldn't happen post-
    /// `AVAudioConverter` but cheap to guard against) saturates at the
    /// top of the [0..1] range rather than overshooting into > 1 or
    /// non-finite territory. RMS itself does NOT clamp magnitude, so
    /// values > 1.0 yield positive dB which `AudioMeter.normalize`
    /// clamps via `min(0, dB)` → normalized 1.0.
    func testComputeAudioLevelClippedInputSaturatesAtOne() {
        let samples = Array(repeating: Float(2.0), count: 1024)
        let level = StreamingAudioEngine.computeAudioLevel(samples: samples)
        XCTAssertEqual(level, 1.0, accuracy: 0.0001)
    }

    // MARK: - Level cache + publish cadence
    //
    // 1.1.3 splits the orb-publish path in two to match the async path
    // (`AudioRecorder.tickMeter`):
    //
    //   * The audio-thread tap callback only **caches** the latest level
    //     in `latestLevel` — no async hop, no `Task { @MainActor }`,
    //     bounded main-thread pressure regardless of tap frequency.
    //   * A `Timer` running at the same 30 Hz cadence the async path
    //     uses reads the cache on the main run loop and publishes it via
    //     `AppState.shared.pushAudioLevel`.
    //
    // Background: 1.1.2 had the tap callback push directly via a
    // `Task { @MainActor }` per buffer (~21 ms at 48 kHz tap rate ≈ 48 Hz).
    // Each Task incurred an actor-hop scheduling delay; user-perceived
    // result was an orb that pulsed *behind* the voice. Async path is
    // snappier because its 30 Hz `Timer` already fires on the main run
    // loop — no hop needed.
    //
    // These tests pin the split: cache vs publish are independently
    // observable so the cadence fix can't silently regress to "push from
    // the tap" without a test going red.

    /// Fresh engine starts with a zero level cached. Mirrors
    /// `AudioRecorder.peakEnergy` defaulting to 0 before `start()` — no
    /// orb-paint side effects until real audio flows.
    @MainActor
    func testLatestLevelDefaultsToZero() {
        let engine = StreamingAudioEngine()
        XCTAssertEqual(engine.latestLevel, 0.0)
    }

    /// Caching the level updates the in-memory store but does NOT push
    /// to `AppState`. This is the contract that lets the tap callback
    /// run lock-free on the audio thread: it writes, the timer reads.
    @MainActor
    func testCacheAudioLevelStoresWithoutPublishing() {
        let engine = StreamingAudioEngine()
        AppState.shared.clearAudioLevels()

        engine.cacheAudioLevel(0.42)

        XCTAssertEqual(engine.latestLevel, 0.42, accuracy: 0.0001)
        XCTAssertTrue(
            AppState.shared.audioLevels.isEmpty,
            "Caching must not touch AppState — the Timer does that"
        )
    }

    /// Multiple cache writes keep only the most recent value — this is
    /// intentional. At 30 Hz publish rate vs ~48 Hz tap rate, we drop
    /// intermediate samples on purpose; the orb only needs the latest
    /// for the current paint, not a history.
    @MainActor
    func testCacheAudioLevelOverwritesPreviousValue() {
        let engine = StreamingAudioEngine()

        engine.cacheAudioLevel(0.1)
        engine.cacheAudioLevel(0.7)
        engine.cacheAudioLevel(0.3)

        XCTAssertEqual(engine.latestLevel, 0.3, accuracy: 0.0001)
    }

    /// `publishLatestLevel()` is the Timer body: reads the cache, pushes
    /// to `AppState`. Decoupled from the tap callback so the audio thread
    /// never crosses the main actor — that's the latency fix.
    @MainActor
    func testPublishLatestLevelForwardsCachedValueToAppState() {
        let engine = StreamingAudioEngine()
        AppState.shared.clearAudioLevels()
        engine.cacheAudioLevel(0.55)

        engine.publishLatestLevel()

        XCTAssertEqual(AppState.shared.audioLevels.last ?? -1, Float(0.55), accuracy: 0.0001)
    }

    /// Publishing without any cache writes is safe — pushes the default
    /// (0) into `AppState`. Matches `AudioRecorder.tickMeter` calling
    /// `pushAudioLevel(0)` before any speech arrives.
    @MainActor
    func testPublishLatestLevelWithoutCacheIsZero() {
        let engine = StreamingAudioEngine()
        AppState.shared.clearAudioLevels()

        engine.publishLatestLevel()

        XCTAssertEqual(AppState.shared.audioLevels.last ?? -1, Float(0.0))
    }

    /// Meter cadence stays in lockstep with the async path (30 Hz). If
    /// either side drifts, the orb behaves differently across pipelines
    /// — a regression Maxim would notice. Pin the constant so a future
    /// "let's bump streaming to 60 Hz" requires touching both files.
    func testMeterIntervalMatchesAsyncPathThirtyHertz() {
        XCTAssertEqual(StreamingAudioEngine.meterInterval, 1.0 / 30.0, accuracy: 1e-9)
    }

    // MARK: - finish() protocol default

    /// `finish()` has a protocol default of `stop()` so cancel paths and
    /// existing test stubs keep working untouched. A stub that overrides
    /// nothing must observe `stop()` when `finish()` is called.
    /// `@MainActor` because the protocol's `stop()`/`finish()` are
    /// main-actor-isolated (single-actor engine-state contract).
    @MainActor
    func testProtocolFinishDefaultsToStop() {
        final class MinimalSource: StreamingAudioSourcing, @unchecked Sendable {
            let chunks: AsyncStream<Data> = AsyncStream { $0.finish() }
            private(set) var didStop = false
            func start() throws {}
            func stop() { didStop = true }
        }
        let source = MinimalSource()
        (source as any StreamingAudioSourcing).finish()
        XCTAssertTrue(source.didStop)
    }

    /// The wall-clock failsafe must outlast the gate's max tail (plus
    /// scheduling margin), or it would cut capture before the gate can
    /// finish the tail it was designed to capture. Pins the cross-file
    /// constant relationship so a future maxTailMs bump cannot silently
    /// re-introduce tail clipping.
    func testFinishFailsafeOutlastsGateMaxTail() {
        let gate = StreamingFinishGate()
        XCTAssertGreaterThan(
            StreamingAudioEngine.finishFailsafeSeconds * 1000,
            gate.maxTailMs
        )
    }

    // MARK: - Input format validation
    //
    // Task 7(a): `installTap` with `inputNode.outputFormat(forBus: 0)` on a
    // Mac with no input device yields a 0 Hz / 0 ch format, and AVAudioEngine
    // raises an *uncatchable* ObjC exception inside `installTap` — a hard
    // crash, not a Swift `throw`. We validate the format first and throw a
    // typed Swift error so the session resolves `.failed` instead of the
    // process dying. The math is pure (no engine), so it is testable on CI
    // without a mic, exactly like `computeAudioLevel`.

    /// A 0 Hz / 0 channel format (no input device) must be rejected so we
    /// never reach the crashing `installTap` call. AVFoundation will happily
    /// *build* such a degenerate format (it is `installTap`, not the format
    /// initialiser, that crashes on it), so the guard cannot rely on a nil
    /// format — it must inspect sampleRate / channelCount.
    func testValidateInputFormatRejectsZeroSampleRateAndChannels() throws {
        let zero = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 0, channels: 0))
        XCTAssertEqual(zero.sampleRate, 0)
        XCTAssertEqual(zero.channelCount, 0)
        XCTAssertThrowsError(try StreamingAudioEngine.validate(inputFormat: zero)) { error in
            XCTAssertEqual(error as? StreamingAudioEngineError, .invalidInputFormat)
        }
    }

    /// A nil format (target unbuildable) is also rejected — same typed error.
    func testValidateInputFormatRejectsNil() {
        XCTAssertThrowsError(try StreamingAudioEngine.validate(inputFormat: nil)) { error in
            XCTAssertEqual(error as? StreamingAudioEngineError, .invalidInputFormat)
        }
    }

    /// A format with a positive sample rate but zero channels is also
    /// invalid (a degenerate device state) and must throw.
    func testValidateInputFormatRejectsZeroChannels() {
        // Build a non-nil but degenerate format via a stream description so
        // we can exercise the channelCount == 0 branch independently of the
        // sampleRate == 0 branch.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 0,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        guard let degenerate = AVAudioFormat(streamDescription: &asbd) else {
            // Some OS versions refuse to build a 0-channel format at all,
            // which is an equally acceptable outcome (no crash path). Skip.
            return
        }
        XCTAssertThrowsError(try StreamingAudioEngine.validate(inputFormat: degenerate)) { error in
            XCTAssertEqual(error as? StreamingAudioEngineError, .invalidInputFormat)
        }
    }

    /// A healthy 48 kHz stereo format (typical Mac input) passes and is
    /// returned unchanged so `installTap` can use it.
    func testValidateInputFormatAcceptsHealthyFormat() throws {
        let healthy = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        let validated = try StreamingAudioEngine.validate(inputFormat: healthy)
        XCTAssertEqual(validated.sampleRate, 48_000)
        XCTAssertEqual(validated.channelCount, 2)
    }

    // MARK: - stop() before start() (slow-setup race)
    //
    // A drop can be released *during* session setup — before `start()` ever ran
    // the engine. The deferred stop then calls `stop()` with `isRunning == false`.
    // The chunk stream must STILL finish so the session's forward loop ends and
    // sends endInput()/EOF upstream; otherwise the provider keeps waiting, the
    // wing spins, and nothing is pasted until the stop watchdog fires — the
    // "вообще ничего не отдаётся" reports on slow / VPN setup windows where the
    // user releases Space before the session has started running.

    /// `stop()` before any `start()` must finish the chunk stream (so the
    /// forward loop ends and EOF is sent), instead of leaving it open to hang
    /// the session until the watchdog.
    @MainActor
    func testStopBeforeStartFinishesChunkStream() async {
        let engine = StreamingAudioEngine()
        // Never started → isRunning == false. This is the stop-before-run race.
        engine.stop()

        let finished = expectation(description: "chunk stream finishes after stop-before-start")
        let drain = Task {
            for await _ in engine.chunks {}
            finished.fulfill()
        }
        // A finished stream completes immediately; the bug leaves it open and
        // this fulfillment would time out.
        await fulfillment(of: [finished], timeout: 2.0)
        drain.cancel()
    }
}

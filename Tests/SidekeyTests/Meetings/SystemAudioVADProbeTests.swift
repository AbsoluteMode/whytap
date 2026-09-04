import AVFoundation
import CoreMedia
import XCTest
@testable import Sidekey

/// Stage 2 tests for `SystemAudioVADProbe`. The probe accepts 16 kHz mono
/// Float32 samples and feeds them through a Silero VAD (FluidAudio) to decide
/// per-chunk whether speech is present in the system audio mix.
///
/// We never call the real `VadManager` in these tests because:
/// 1. It downloads a CoreML model on first construction (network I/O in CI is
///    a flake source we do not want to inherit).
/// 2. Inference takes ANE time we do not need to spend just to verify the
///    glue between `CMSampleBuffer` → `[Float]` → VAD-protocol calls.
///
/// Instead we inject a `StubbedVAD` that maps a probability per call and
/// drive the probe through the public protocol seam.
@MainActor
final class SystemAudioVADProbeTests: XCTestCase {

    // MARK: - Helpers

    /// Collect up to `count` values within `seconds`, then return whatever
    /// was collected. Avoids races between the producer running on the
    /// VAD's actor and the consumer running on the test's MainActor.
    private func collect<T: Sendable>(
        _ stream: AsyncStream<T>,
        count: Int,
        within seconds: Double
    ) async -> [T] {
        await withTaskGroup(of: [T].self) { group in
            group.addTask {
                var collected: [T] = []
                for await value in stream {
                    collected.append(value)
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

    /// Build a CMSampleBuffer containing `sampleCount` 16 kHz mono Float32
    /// samples sourced from `samples`. The probe is supposed to extract
    /// these and pass them to the VAD; the test asserts on the resulting
    /// stream of `Bool` decisions.
    ///
    /// Marked `throws` rather than `try?` so a failure to construct the
    /// fixture surfaces as a test failure (not silently as an empty
    /// stream that we'd misinterpret as a behaviour bug).
    private func makeFloat32SampleBuffer(samples: [Float]) throws -> CMSampleBuffer {
        let sampleRate: Double = 16000
        let channels: UInt32 = 1

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var formatDesc: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard formatStatus == noErr, let format = formatDesc else {
            throw NSError(domain: "test", code: Int(formatStatus))
        }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
            throw NSError(domain: "test", code: Int(bbStatus))
        }

        try samples.withUnsafeBufferPointer { pointer in
            let copyStatus = CMBlockBufferReplaceDataBytes(
                with: pointer.baseAddress!,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
            guard copyStatus == kCMBlockBufferNoErr else {
                throw NSError(domain: "test", code: Int(copyStatus))
            }
        }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        let sampleSize: Int = 4
        let cmStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: [sampleSize],
            sampleBufferOut: &sampleBuffer
        )
        guard cmStatus == noErr, let sb = sampleBuffer else {
            throw NSError(domain: "test", code: Int(cmStatus))
        }
        return sb
    }

    // MARK: - Behaviour

    /// A buffer filled with synthetic 440 Hz sine "speech" should produce
    /// a `true` emission once the stub VAD reports a probability above
    /// the default threshold. We feed enough samples for the probe to
    /// drain one full FluidAudio chunk (4096 samples = 256 ms at 16 kHz)
    /// and assert the resulting Boolean lands on the stream.
    func test_speech_segment_emits_true() async throws {
        let chunkSize = SileroVADAdapter.chunkSize
        let samples = sineWave(frequency: 440, sampleCount: chunkSize)
        let sampleBuffer = try makeFloat32SampleBuffer(samples: samples)

        let stub = StubbedVAD(probabilities: [0.95])
        let probe = SystemAudioVADProbe(vad: stub)

        let stream = probe.subscribe()
        defer { Task { await probe.stop() } }

        probe.ingest(sampleBuffer)

        let values = await collect(stream, count: 1, within: 2.0)
        XCTAssertEqual(values, [true], "Speech-like signal must yield isVoiceActive=true")
    }

    /// Zero-filled samples must trigger a `false` emission once the stub
    /// VAD returns a sub-threshold probability. This is the silence path
    /// the detector uses to NOT trigger when the system audio is empty.
    func test_silence_emits_false() async throws {
        let chunkSize = SileroVADAdapter.chunkSize
        let samples = [Float](repeating: 0.0, count: chunkSize)
        let sampleBuffer = try makeFloat32SampleBuffer(samples: samples)

        let stub = StubbedVAD(probabilities: [0.0])
        let probe = SystemAudioVADProbe(vad: stub)

        let stream = probe.subscribe()
        defer { Task { await probe.stop() } }

        probe.ingest(sampleBuffer)

        let values = await collect(stream, count: 1, within: 2.0)
        XCTAssertEqual(values, [false], "Silence must yield isVoiceActive=false")
    }

    /// One sample buffer smaller than a single VAD chunk should be buffered
    /// internally and only flushed once a full chunk's worth of samples has
    /// arrived. Verifies the probe accumulates rather than dropping partial
    /// data on the floor — important because audio callbacks come in
    /// variable sizes that rarely match the 4096-sample chunk exactly.
    ///
    /// `AsyncStream` supports a single iteration; we therefore use one
    /// consumer task and assert that the first emission happens only after
    /// the second buffer (which completes the chunk) is ingested.
    func test_partial_buffer_does_not_emit_until_chunk_full() async throws {
        let chunkSize = SileroVADAdapter.chunkSize
        let halfChunk = chunkSize / 2
        let firstHalf = sineWave(frequency: 440, sampleCount: halfChunk)
        let secondHalf = sineWave(
            frequency: 440,
            sampleCount: chunkSize - halfChunk
        )

        let firstBuf = try makeFloat32SampleBuffer(samples: firstHalf)
        let secondBuf = try makeFloat32SampleBuffer(samples: secondHalf)

        let stub = StubbedVAD(probabilities: [0.95])
        let probe = SystemAudioVADProbe(vad: stub)

        let stream = probe.subscribe()
        defer { Task { await probe.stop() } }

        // Half a chunk: probe must wait, no emission within the inspection
        // window. We start the single consumer task BEFORE the second
        // ingest so the iterator is alive when the stream finally yields.
        probe.ingest(firstBuf)
        try await Task.sleep(nanoseconds: 200_000_000)

        let collected = Task<[Bool], Never> {
            await self.collect(stream, count: 1, within: 2.0)
        }

        // Give the consumer a moment to attach before the second ingest
        // so the test does not race with the stream yield.
        try await Task.sleep(nanoseconds: 100_000_000)
        probe.ingest(secondBuf)

        let values = await collected.value
        XCTAssertEqual(values, [true])
    }

    // MARK: - Local helpers

    private func sineWave(frequency: Double, sampleCount: Int) -> [Float] {
        let sampleRate: Double = 16000
        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            samples[i] = Float(sin(2 * .pi * frequency * t) * 0.5)
        }
        return samples
    }

    private func firstValue<T: Sendable>(
        from stream: AsyncStream<T>,
        within seconds: Double
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
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

// MARK: - audioBufferStream rebuild tests

extension SystemAudioVADProbeTests {

    /// First `audioBufferStream()` call on a probe whose audio source has not
    /// yet been started: the source must be started exactly once, never stopped.
    func test_audioBufferStream_firstCall_startsSourceOnce() async throws {
        let stub = StubbedVAD(probabilities: [0.0])
        let fake = FakeAudioSource()
        let probe = SystemAudioVADProbe(vad: stub, audioSource: fake)

        _ = probe.audioBufferStream()

        // Allow the async Task spawned by ensureAudioSourceStarted to run.
        for _ in 0..<20 {
            if fake.startCount >= 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(fake.startCount, 1, "Source must be started exactly once on first subscription")
        XCTAssertEqual(fake.stopCount, 0, "Source must not be stopped on the first subscription")

        await probe.stop()
    }

    func test_audioBufferStream_firstCall_refreshesTapAfterPermissionWindow() async throws {
        let stub = StubbedVAD(probabilities: [0.0])
        let fake = FakeAudioSource()
        let probe = SystemAudioVADProbe(
            vad: stub,
            audioSource: fake,
            initialTapRefreshDelaySeconds: 0.05
        )

        _ = probe.audioBufferStream()
        for _ in 0..<40 {
            if fake.stopCount >= 1 && fake.startCount >= 2 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(fake.stopCount, 1)
        XCTAssertEqual(fake.startCount, 2)
        XCTAssertEqual(probe.tapRebuildCount, 1)

        await probe.stop()
    }

    /// Second `audioBufferStream()` call (new meeting recorder) must trigger a
    /// full tap rebuild: stop then start again. The new subscription must also
    /// receive samples injected after the rebuild completes.
    func test_audioBufferStream_secondCall_rebuildsSourceAndDeliversSamples() async throws {
        let stub = StubbedVAD(probabilities: [0.0])
        let fake = FakeAudioSource()
        let probe = SystemAudioVADProbe(vad: stub, audioSource: fake)

        // First subscription — starts the source.
        _ = probe.audioBufferStream()
        for _ in 0..<20 {
            if fake.startCount >= 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(fake.startCount, 1, "precondition: source started after first call")

        // Second subscription — should trigger stop + start (rebuild).
        let stream2 = probe.audioBufferStream()

        for _ in 0..<40 {
            if fake.stopCount >= 1 && fake.startCount >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(fake.stopCount, 1, "Source must be stopped once for the rebuild")
        XCTAssertEqual(fake.startCount, 2, "Source must be restarted after the rebuild")

        // Samples delivered after the rebuild must reach the second stream.
        probe.ingest(samples: [0.25])
        let values = await collect(stream2, count: 1, within: 2.0)
        XCTAssertEqual(values.count, 1, "New subscription must receive samples after rebuild")
        XCTAssertEqual(values.first?.first, 0.25, "Sample value must be preserved through the rebuild path")

        await probe.stop()
    }

    /// `subscribe()` (the VAD Bool stream the detector consumes) must NOT
    /// start the CoreAudio process tap. The tap lights the macOS "System
    /// Audio Recording" indicator, so it may only run while a meeting is
    /// actually being recorded — and that path goes exclusively through
    /// `audioBufferStream()` (the recorder fan-out), verified above.
    ///
    /// The detector subscribes once at launch and lives for the whole app
    /// session (it is never stopped). If `subscribe()` started the tap, the
    /// privacy indicator would burn the entire session even when nothing is
    /// being recorded — the bug this guards against.
    /// See docs/decisions/2026-06-16-system-audio-tap-on-record-only.md.
    func test_subscribe_doesNotStartSource() async throws {
        let stub = StubbedVAD(probabilities: [0.0])
        let fake = FakeAudioSource()
        let probe = SystemAudioVADProbe(vad: stub, audioSource: fake)

        _ = probe.subscribe()

        // Wait long enough that an erroneous start Task would have run.
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(
            fake.startCount, 0,
            "subscribe() must not light the CoreAudio tap; only audioBufferStream() (recording) may"
        )
        XCTAssertEqual(fake.stopCount, 0, "subscribe() must not touch the source at all")

        await probe.stop()
    }
}

// MARK: - Stubs

/// Fake `SystemAudioSourceStreaming` that records start/stop call counts and
/// emits samples fed via `sendSamples(_:)`. Thread-safe via NSLock so the
/// audio-callback and MainActor paths can both read counts safely.
final class FakeAudioSource: SystemAudioSourceStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var startCount: Int = 0
    private(set) var stopCount: Int = 0

    private var currentContinuation: AsyncStream<[Float]>.Continuation?

    func audioBufferStream() -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        lock.lock()
        currentContinuation?.finish()
        currentContinuation = continuation
        lock.unlock()
        return stream
    }

    func start() async throws {
        lock.lock()
        startCount += 1
        lock.unlock()
    }

    func stop() async {
        lock.lock()
        stopCount += 1
        currentContinuation?.finish()
        currentContinuation = nil
        lock.unlock()
    }

    /// Push samples into the currently active stream (simulates CoreAudio callback).
    func sendSamples(_ samples: [Float]) {
        lock.lock()
        let cont = currentContinuation
        lock.unlock()
        cont?.yield(samples)
    }
}

/// Scripted VAD that replays a probability sequence. Each chunk submitted
/// pops one probability; once the script exhausts the last one repeats.
/// The boolean decision is "probability >= 0.5" so tests can use round
/// numbers without having to encode the production threshold here.
final class StubbedVAD: SileroVoiceActivityDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var probabilities: [Float]
    private var lastProb: Float

    init(probabilities: [Float]) {
        precondition(!probabilities.isEmpty, "StubbedVAD needs at least one probability")
        self.probabilities = probabilities
        self.lastProb = probabilities[0]
    }

    func detect(samples: [Float]) async -> Bool {
        lock.lock()
        let prob: Float
        if probabilities.isEmpty {
            prob = lastProb
        } else {
            prob = probabilities.removeFirst()
            lastProb = prob
        }
        lock.unlock()
        return prob >= 0.5
    }
}

import AVFoundation
import CoreMedia
import FluidAudio
import Foundation
import os.log

/// Voice-activity probe over the system audio mix. Production feeds it from
/// `CoreAudioSystemAudioSource`, an audio-only process tap, so Sidekey can
/// record meetings without touching Screen Recording APIs.
///
/// Privacy contract:
/// - The probe only **reads** the system mix while an explicit recording
///   stream is active. No microphone content is consumed here — the
///   mic-side signal lives in `MicInUseProbe`, which reads metadata only.
/// - The probe's outbound `AsyncStream<Bool>` carries decisions, never
///   audio. Sample buffers are dropped after VAD inference.
///
/// Streaming semantics:
/// - CoreAudio delivers audio in variable-length chunks that rarely match
///   FluidAudio's 4096-sample chunk size exactly.
/// - The probe buffers samples internally until a full chunk is available,
///   then emits one `Bool` per chunk on the output stream.
/// - Each subscription replaces the previous one (single-consumer producer:
///   the detector is the only caller).
@MainActor
final class SystemAudioVADProbe: SystemAudioVADProbing, SystemAudioBufferStreaming, @unchecked Sendable {

    /// os_log surface for the vad category. Spec / plan call out "vad" as
    /// one of the meetings log categories so Console.app can filter VAD
    /// diagnostics from the rest. Never logs audio content.
    nonisolated private static let log = OSLog(
        subsystem: "com.sidekey.meetings",
        category: "vad"
    )

    private let vad: SileroVoiceActivityDetecting
    private let audioSource: SystemAudioSourceStreaming?
    private let initialTapRefreshDelaySeconds: TimeInterval
    private var sourceTask: Task<Void, Never>?
    private var initialTapRefreshTask: Task<Void, Never>?
    private var didScheduleInitialTapRefresh = false

    /// Session counter for meeting-health telemetry (Task 7): every time
    /// `audioBufferStream()` schedules a full tap rebuild because a recorder
    /// subscribes while the source is already running. Monotonic within the
    /// process — `MeetingRecorder` snapshots start/stop deltas so rebuilds
    /// outside a meeting never leak in. MainActor-isolated like the rest of
    /// this type's mutable state. Privacy inv. #3: a count only, never a
    /// device name.
    private(set) var tapRebuildCount = 0

    /// Serialises ingest → VAD calls without blocking the CoreAudio callback
    /// queue. We never want backpressure to stall the process tap.
    private let processingQueue = DispatchQueue(
        label: "com.sidekey.meetings.vad.processing",
        qos: .utility
    )

    /// In-flight accumulator for partial chunks. Mutated only from
    /// `processingQueue` so it is safe to keep as a non-actor property.
    nonisolated(unsafe) private var pendingSamples: [Float] = []

    /// DEBUG (vad-debug worktree): counters used to throttle .debug-level
    /// diagnostic logging from the audio callback path. Touched only
    /// from `processingQueue`. Every Nth ingest / chunk emits one
    /// `os_log .debug` entry so Console can be filtered without flooding.
    nonisolated(unsafe) private var debugIngestCounter: Int = 0
    nonisolated(unsafe) private var debugChunkCounter: Int = 0
    /// Log every Nth sample buffer arrival. CoreAudio delivers ~30-50 buffers
    /// per second of audio depending on system load, so 50 ≈ once per
    /// 1-2 seconds. Adjustable if signal is too sparse / too noisy.
    nonisolated private static let debugIngestStride = 50
    /// Log every Nth chunk drain. With chunkSize=4096 @16kHz one chunk is
    /// 256ms, so 50 chunks ≈ 12.8 s of audio.
    nonisolated private static let debugChunkStride = 50

    /// Marked `nonisolated(unsafe)` because both the audio callback
    /// path (`nonisolated`) and the MainActor `subscribe()` need to read
    /// and replace it. Writes happen only on MainActor; reads from the
    /// audio path see a stable pointer (or `nil`). `AsyncStream
    /// .Continuation` itself is documented `Sendable` / thread-safe.
    nonisolated(unsafe) private var continuation: AsyncStream<Bool>.Continuation?

    /// Stage 4 fan-out: parallel continuation that emits the raw 16 kHz
    /// mono Float32 samples *as they arrive* — separate from the VAD Bool
    /// stream. `MeetingRecorder` subscribes to feed the mixer's system
    /// audio input; the VAD continues to consume from the chunked path
    /// independently. Lock-free single-writer / single-reader: the audio
    /// callback writes, `MeetingRecorder` reads. Marked `nonisolated(unsafe)`
    /// for the same reason as `continuation`: it crosses the MainActor /
    /// callback boundary, but Swift's `AsyncStream.Continuation` is
    /// documented thread-safe.
    nonisolated(unsafe) private var samplesContinuation: AsyncStream<[Float]>.Continuation?

    /// - Parameter vad: VAD seam. Production injects `SileroVADAdapter`
    ///   wrapping a real `VadManager`; tests inject `StubbedVAD`.
    init(
        vad: SileroVoiceActivityDetecting,
        audioSource: SystemAudioSourceStreaming? = nil,
        initialTapRefreshDelaySeconds: TimeInterval = 2
    ) {
        self.vad = vad
        self.audioSource = audioSource
        self.initialTapRefreshDelaySeconds = initialTapRefreshDelaySeconds
    }

    /// Replaces any previous subscription and starts a fresh `AsyncStream`.
    /// Callers receive one `Bool` per FluidAudio chunk processed; partial
    /// chunks are buffered until full.
    ///
    /// Intentionally does **NOT** start the CoreAudio process tap. The tap
    /// lights the macOS "System Audio Recording" privacy indicator, so it may
    /// run only while a meeting is actively recorded — that path is
    /// `audioBufferStream()` (the recorder fan-out). `MeetingDetector`
    /// subscribes here once at launch and is never stopped, so starting the
    /// tap from `subscribe()` would burn the indicator for the whole app
    /// session even when nothing is being recorded.
    ///
    /// Consequence: with no tap running, no samples flow, so the VAD `Bool`
    /// stream stays empty in production. That is acceptable today because the
    /// detector's trigger no longer relies on system-audio VAD — it fires off
    /// the frontmost-app + mic path (`MeetingDetector.tryFireFromFrontmost` /
    /// `scheduleMicOnlyTrigger`). The VAD `Bool` path is kept wired but dormant
    /// rather than ripped out, pending a decision on whether VAD detection
    /// returns. WHY: docs/decisions/2026-06-16-system-audio-tap-on-record-only.md
    func subscribe() -> AsyncStream<Bool> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        self.continuation = continuation
        processingQueue.sync {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        return stream
    }

    /// Stage 4 fan-out: subscribe to the raw 16 kHz mono Float32 sample
    /// chunks that arrive from the CoreAudio system-audio source. Each yielded
    /// `[Float]` is one callback's worth of samples,
    /// already mono-downmixed and normalised. The continuation is
    /// independent from `subscribe()`'s VAD Bool stream — `MeetingRecorder`
    /// can consume samples without affecting VAD decisions, and a missing
    /// MeetingRecorder subscription does not stall VAD ingest.
    ///
    /// Calling this a second time replaces the previous subscription;
    /// it is single-consumer by design (the recorder).
    ///
    /// If the audio source is already running when a new recorder subscribes
    /// (i.e. `sourceTask != nil`), we schedule a full tap rebuild: stop the
    /// source and restart it. This is required because:
    ///  1. A process tap created before the user grants "System Audio Recording"
    ///     delivers all-zero buffers forever; rebuild forces macOS to recheck
    ///     TCC and open a real stream.
    ///  2. A known macOS bug zero-fills long-lived taps on Bluetooth outputs;
    ///     teardown+rebuild is the documented workaround (mirrors
    ///     `reinstallAudioOutput()` used for sleep/wake).
    /// A brief capture gap at meeting start is acceptable per spec.
    func audioBufferStream() -> AsyncStream<[Float]> {
        samplesContinuation?.finish()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.samplesContinuation = continuation

        if sourceTask != nil {
            // Source is already running — rebuild the tap so the new
            // recorder subscription gets a fresh, uncorrupted stream.
            let audioSource = self.audioSource
            Task { [weak self] in
                guard let self, let audioSource else { return }
                self.tapRebuildCount += 1
                os_log(
                    "rebuilding system audio source on recorder subscribe",
                    log: Self.log, type: .info
                )
                self.sourceTask?.cancel()
                self.sourceTask = nil
                await audioSource.stop()
                self.ensureAudioSourceStarted()
            }
        } else {
            ensureAudioSourceStarted()
        }

        return stream
    }

    /// Tears down the current subscription. Idempotent. Called by the
    /// detector on shutdown so the producer task is not orphaned.
    func stop() async {
        initialTapRefreshTask?.cancel()
        initialTapRefreshTask = nil
        sourceTask?.cancel()
        sourceTask = nil
        await audioSource?.stop()
        continuation?.finish()
        continuation = nil
        samplesContinuation?.finish()
        samplesContinuation = nil
        processingQueue.sync {
            pendingSamples.removeAll(keepingCapacity: false)
        }
    }

    /// Stage 9: audio sessions can die after a system sleep, so a wake-side
    /// `MeetingsCoordinator.resumeRecordingIfPaused` asks the probe to
    /// gracefully tear down its existing fan-out and rebuild it.
    ///
    /// On success the probe's `audioBufferStream()` returns a fresh
    /// stream the recorder can subscribe to. On failure (currently
    /// only thrown if a downstream subsystem reports irrecoverable
    /// teardown — reserved hook; the in-process implementation is
    /// best-effort and does not surface errors today) the coordinator
    /// falls back to finalizing the recording with
    /// `interruptedBySleep: true`.
    func reinstallAudioOutput() async throws {
        // Drain any pending samples that crossed the sleep boundary;
        // they are likely truncated or stale and would confuse the VAD
        // chunker downstream.
        processingQueue.sync {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        // Drop the prior sample-fan-out continuation so a stale
        // recorder subscription is not left dangling. `audioBufferStream()`
        // is single-consumer by design — the next call (typically from
        // `MeetingRecorder.resume()` via the recorder's systemSource
        // reference) installs a fresh continuation.
        samplesContinuation?.finish()
        samplesContinuation = nil
        sourceTask?.cancel()
        sourceTask = nil
        await audioSource?.stop()
        try await audioSource?.start()
        ensureAudioSourceStarted()
    }

    private func ensureAudioSourceStarted() {
        guard sourceTask == nil, let audioSource else { return }
        let sourceStream = audioSource.audioBufferStream()
        sourceTask = Task { [weak self, audioSource] in
            do {
                try await audioSource.start()
                self?.scheduleInitialTapRefreshIfNeeded(audioSource: audioSource)
            } catch {
                os_log(
                    "system audio source start failed: %{public}@",
                    log: Self.log, type: .error,
                    String(describing: error)
                )
                return
            }
            for await samples in sourceStream {
                guard let self else { return }
                self.ingest(samples: samples)
            }
        }
    }

    /// The first CoreAudio process tap can be created while macOS is showing
    /// the System Audio Recording consent prompt. Even after Allow, that tap
    /// remains zero-filled until recreated, which made the first meeting
    /// mic-only while a second recording worked. Refresh it once per process
    /// shortly after the first successful start; subsequent recordings open a
    /// fresh tap normally and do not pay this gap.
    private func scheduleInitialTapRefreshIfNeeded(
        audioSource: SystemAudioSourceStreaming
    ) {
        guard !didScheduleInitialTapRefresh,
              initialTapRefreshDelaySeconds > 0 else { return }
        didScheduleInitialTapRefresh = true
        let delay = initialTapRefreshDelaySeconds
        initialTapRefreshTask = Task { [weak self, audioSource] in
            try? await Task.sleep(
                nanoseconds: UInt64(delay * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  self.sourceTask != nil else { return }
            self.tapRebuildCount += 1
            os_log(
                "refreshing first system audio tap after permission window",
                log: Self.log, type: .info
            )
            self.sourceTask?.cancel()
            self.sourceTask = nil
            await audioSource.stop()
            guard !Task.isCancelled, self.samplesContinuation != nil else {
                self.initialTapRefreshTask = nil
                return
            }
            self.ensureAudioSourceStarted()
            self.initialTapRefreshTask = nil
        }
    }

    /// Feeds one `CMSampleBuffer` fixture into the VAD pipeline. Tests use
    /// this path to exercise the decoder without starting CoreAudio.
    /// VAD pipeline. Synchronous from the caller's perspective: the heavy
    /// lifting (sample extraction, optional resampling, VAD inference)
    /// runs on the probe's serial queue.
    ///
    /// Marked `nonisolated` because fixture/audio callbacks come in away
    /// from the MainActor. We bounce through `processingQueue` for
    /// serialisation, then send onto the AsyncStream.
    nonisolated func ingest(_ sampleBuffer: CMSampleBuffer) {
        guard let samples = Self.extractMono16kFloat32(from: sampleBuffer) else {
            // DEBUG (vad-debug worktree): if extraction returns nil that is
            // a strong signal of an unexpected ASBD shape. Log enough to
            // identify the format mismatch on first occurrence.
            Self.logExtractionFailure(sampleBuffer)
            return
        }
        guard !samples.isEmpty else { return }
        ingest(samples: samples, sampleBufferForDebug: sampleBuffer)
    }

    /// Feeds a 16 kHz mono Float32 chunk from the CoreAudio process tap into
    /// the VAD pipeline and recorder fan-out.
    nonisolated func ingest(samples: [Float]) {
        guard !samples.isEmpty else { return }
        ingest(samples: samples, sampleBufferForDebug: nil)
    }

    nonisolated private func ingest(
        samples: [Float],
        sampleBufferForDebug sampleBuffer: CMSampleBuffer?
    ) {
        // DEBUG (vad-debug worktree): every Nth buffer log arrival shape so
        // Console shows that samples are actually flowing into the probe and
        // in the expected 16 kHz mono Float32 format.
        let counter = debugIngestCounter
        debugIngestCounter &+= 1
        if counter % Self.debugIngestStride == 0, let sampleBuffer {
            Self.logIngest(samples: samples, sampleBuffer: sampleBuffer, count: counter)
        }

        // Fan out to MeetingRecorder (Stage 4) before queuing for VAD.
        // The two paths are independent — recorder gets the raw samples
        // immediately; VAD batches them into 4096-sample chunks on its
        // serial queue. A missing recorder subscription is a no-op.
        samplesContinuation?.yield(samples)
        processingQueue.async { [weak self] in
            self?.processSamples(samples)
        }
    }

    // MARK: - Debug helpers (vad-debug worktree)

    /// Log one sample-buffer arrival: format, sample count, sample rate.
    /// Throttled to every Nth call by the ingest path.
    nonisolated private static func logIngest(
        samples: [Float],
        sampleBuffer: CMSampleBuffer,
        count: Int
    ) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            os_log(
                "ingest #%{public}d samples=%{public}d (no ASBD)",
                log: log, type: .debug,
                count, samples.count
            )
            return
        }
        let asbd = asbdPtr.pointee
        let peak = samples.lazy.map { abs($0) }.max() ?? 0
        let rms: Float = {
            guard !samples.isEmpty else { return 0 }
            let sumSq = samples.reduce(into: Float(0)) { $0 += $1 * $1 }
            return (sumSq / Float(samples.count)).squareRoot()
        }()
        os_log(
            "ingest #%{public}d samples=%{public}d sr=%{public}.0f ch=%{public}d bits=%{public}d float=%{public}d peak=%{public}.4f rms=%{public}.4f",
            log: log, type: .debug,
            count,
            samples.count,
            asbd.mSampleRate,
            Int(asbd.mChannelsPerFrame),
            Int(asbd.mBitsPerChannel),
            (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? 1 : 0,
            peak,
            rms
        )
    }

    /// One-shot diagnostic when `extractMono16kFloat32` returns nil — the
    /// probe silently drops these buffers in production, but in a debug
    /// build we want to see the offending ASBD shape exactly once per
    /// occurrence so format mismatches surface in Console.
    nonisolated private static func logExtractionFailure(_ sampleBuffer: CMSampleBuffer) {
        if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
            let asbd = asbdPtr.pointee
            os_log(
                "extract failed sr=%{public}.0f ch=%{public}d bits=%{public}d float=%{public}d interleaved=%{public}d",
                log: log, type: .debug,
                asbd.mSampleRate,
                Int(asbd.mChannelsPerFrame),
                Int(asbd.mBitsPerChannel),
                (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 ? 1 : 0,
                (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0 ? 1 : 0
            )
        } else {
            os_log(
                "extract failed (no format description)",
                log: log, type: .debug
            )
        }
    }

    // MARK: - Internal: chunking + VAD

    /// Drains accumulated samples into `SileroVADAdapter.chunkSize`-sized
    /// chunks, runs the VAD on each, and yields the resulting `Bool` onto
    /// the output stream. Any tail shorter than a full chunk is preserved
    /// for the next ingest.
    nonisolated private func processSamples(_ incoming: [Float]) {
        pendingSamples.append(contentsOf: incoming)

        let chunkSize = SileroVADAdapter.chunkSize
        var idx = 0
        while pendingSamples.count - idx >= chunkSize {
            let chunk = Array(pendingSamples[idx..<(idx + chunkSize)])
            idx += chunkSize
            // DEBUG (vad-debug worktree): throttled chunk-emission log so
            // we can confirm samples are actually being drained into 4096-
            // sample frames at the expected rate (~one every 256 ms).
            let counter = debugChunkCounter
            debugChunkCounter &+= 1
            if counter % Self.debugChunkStride == 0 {
                let pending = pendingSamples.count - idx
                os_log(
                    "chunk emit #%{public}d size=%{public}d pendingAfter=%{public}d",
                    log: Self.log, type: .debug,
                    counter, chunkSize, pending
                )
            }
            // VAD inference happens off the audio callback queue; awaiting via
            // a Task is fine here because the chunk is owned by this
            // closure and the continuation is documented thread-safe.
            let vad = self.vad
            let continuation = self.continuation
            let chunkIdx = counter
            Task.detached(priority: .utility) {
                let isActive = await vad.detect(samples: chunk)
                // DEBUG (vad-debug worktree): same throttle stride as chunk
                // emission so the post-VAD decision lines up with the
                // emission log for the same chunk index.
                if chunkIdx % Self.debugChunkStride == 0 {
                    os_log(
                        "vad decision #%{public}d isActive=%{public}d",
                        log: Self.log, type: .debug,
                        chunkIdx, isActive ? 1 : 0
                    )
                }
                continuation?.yield(isActive)
            }
        }
        if idx > 0 {
            pendingSamples.removeFirst(idx)
        }
    }

    // MARK: - CMSampleBuffer → [Float] (16 kHz mono Float32)

    /// Extracts samples in 16 kHz mono Float32 from test fixtures. The
    /// production CoreAudio path already emits this shape, but tests keep
    /// the decoder pinned. We still defend against:
    ///
    /// - Different float precision (Float32 vs Float64)
    /// - Multi-channel input (downmix to mono via straight average)
    /// - Non-interleaved layouts (CMSampleBuffer can be either)
    ///
    /// Returns `nil` if the buffer is invalid or unsupported.
    nonisolated static func extractMono16kFloat32(
        from sampleBuffer: CMSampleBuffer
    ) -> [Float]? {
        guard sampleBuffer.isValid,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        let asbd = asbdPtr.pointee
        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        // Audio buffers may live in a CMBlockBuffer (interleaved or single
        // channel) or in an AudioBufferList (non-interleaved). Try block
        // buffer first, then fall back to the AudioBufferList variant for
        // unexpected formats.
        if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
           isInterleaved {
            return decodeInterleaved(
                blockBuffer: blockBuffer,
                isFloat: isFloat,
                bitsPerChannel: bitsPerChannel,
                channels: channels
            )
        }

        // Fallback: non-interleaved or unusual layouts via AudioBufferList.
        return decodeViaAudioBufferList(
            sampleBuffer: sampleBuffer,
            isFloat: isFloat,
            bitsPerChannel: bitsPerChannel,
            channels: channels
        )
    }

    nonisolated private static func decodeInterleaved(
        blockBuffer: CMBlockBuffer,
        isFloat: Bool,
        bitsPerChannel: Int,
        channels: Int
    ) -> [Float]? {
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return [] }

        var rawData = [UInt8](repeating: 0, count: totalLength)
        let copyStatus = rawData.withUnsafeMutableBytes { ptr -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: base
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        return convertBytesToMonoFloats(
            rawData,
            isFloat: isFloat,
            bitsPerChannel: bitsPerChannel,
            channels: channels
        )
    }

    nonisolated private static func decodeViaAudioBufferList(
        sampleBuffer: CMSampleBuffer,
        isFloat: Bool,
        bitsPerChannel: Int,
        channels: Int
    ) -> [Float]? {
        var ablSizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, ablSizeNeeded > 0 else { return nil }

        let abl = AudioBufferList.allocate(maximumBuffers: max(channels, 1))
        defer { free(abl.unsafeMutablePointer) }
        var retainedBlock: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: abl.unsafeMutablePointer,
            bufferListSize: ablSizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr else { return nil }

        var channelStreams: [[Float]] = []
        for buffer in abl {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            let bytes = Array(UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: UInt8.self),
                count: byteCount
            ))
            if let stream = convertBytesToMonoFloats(
                bytes,
                isFloat: isFloat,
                bitsPerChannel: bitsPerChannel,
                channels: 1
            ) {
                channelStreams.append(stream)
            }
        }

        guard !channelStreams.isEmpty else { return [] }
        if channelStreams.count == 1 {
            return channelStreams[0]
        }
        // Down-mix non-interleaved channels by straight average.
        let frameCount = channelStreams.map(\.count).min() ?? 0
        var mono = [Float](repeating: 0, count: frameCount)
        for stream in channelStreams {
            for i in 0..<frameCount {
                mono[i] += stream[i]
            }
        }
        let invChannels = 1.0 / Float(channelStreams.count)
        for i in 0..<frameCount {
            mono[i] *= invChannels
        }
        return mono
    }

    nonisolated private static func convertBytesToMonoFloats(
        _ raw: [UInt8],
        isFloat: Bool,
        bitsPerChannel: Int,
        channels: Int
    ) -> [Float]? {
        guard channels >= 1 else { return nil }
        let bytesPerSample = bitsPerChannel / 8
        guard bytesPerSample > 0 else { return nil }
        let bytesPerFrame = bytesPerSample * channels
        guard bytesPerFrame > 0 else { return nil }
        let frameCount = raw.count / bytesPerFrame
        guard frameCount > 0 else { return [] }

        var out = [Float](repeating: 0, count: frameCount)
        raw.withUnsafeBytes { ptr in
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    let offset = frame * bytesPerFrame + ch * bytesPerSample
                    let sample = readSample(
                        ptr: ptr,
                        offset: offset,
                        isFloat: isFloat,
                        bitsPerChannel: bitsPerChannel
                    )
                    sum += sample
                }
                out[frame] = sum / Float(channels)
            }
        }
        return out
    }

    nonisolated private static func readSample(
        ptr: UnsafeRawBufferPointer,
        offset: Int,
        isFloat: Bool,
        bitsPerChannel: Int
    ) -> Float {
        if isFloat {
            switch bitsPerChannel {
            case 32:
                return ptr.load(fromByteOffset: offset, as: Float.self)
            case 64:
                let v = ptr.load(fromByteOffset: offset, as: Double.self)
                return Float(v)
            default:
                return 0
            }
        }
        switch bitsPerChannel {
        case 16:
            let v = ptr.load(fromByteOffset: offset, as: Int16.self)
            return Float(v) / Float(Int16.max)
        case 32:
            let v = ptr.load(fromByteOffset: offset, as: Int32.self)
            return Float(v) / Float(Int32.max)
        default:
            return 0
        }
    }
}

// MARK: - Protocols

/// Test seam over the VAD inference. Returning one `Bool` per chunk keeps
/// the surface narrow; the implementation chooses how to map FluidAudio's
/// probability to a decision (today: `probability >= config.defaultThreshold`,
/// which `VadManager` already does via `VadResult.isVoiceActive`).
protocol SileroVoiceActivityDetecting: Sendable {
    func detect(samples: [Float]) async -> Bool
}

/// Test seam over the probe itself, used by `MeetingDetector` so the
/// detector tests can drive a hand-rolled stream of speech / silence ticks.
@MainActor
protocol SystemAudioVADProbing: AnyObject {
    func subscribe() -> AsyncStream<Bool>
    func stop() async
}

/// Stage 4 narrower seam for `MeetingRecorder`: lets the recorder consume
/// the raw 16 kHz mono Float32 samples that arrive from an audio-only system
/// source, independent of the VAD Bool decisions. Kept separate from
/// `SystemAudioVADProbing` so `MeetingDetector` stubs (Stage 2) do not have
/// to grow this surface they never use.
@MainActor
protocol SystemAudioBufferStreaming: AnyObject {
    /// One `[Float]` per audio callback, 16 kHz mono Float32.
    /// Single-consumer — calling twice replaces the previous subscription.
    func audioBufferStream() -> AsyncStream<[Float]>
    func start() async throws
    func stop() async
}

extension SystemAudioBufferStreaming {
    func start() async throws {}
    func stop() async {}
}

/// Audio-only producer used by `SystemAudioVADProbe` to feed both VAD and the
/// recorder. This is intentionally not `@MainActor`: CoreAudio invokes process
/// tap callbacks on an audio queue, so the implementation owns its own
/// synchronization.
protocol SystemAudioSourceStreaming: AnyObject, Sendable {
    /// One `[Float]` per audio callback, 16 kHz mono Float32.
    func audioBufferStream() -> AsyncStream<[Float]>
    func start() async throws
    func stop() async
}

// MARK: - FluidAudio adapter

/// Production VAD seam wrapping FluidAudio's `VadManager` actor. The
/// adapter:
/// - Lazily initialises the manager on first inference call so app launch
///   is not blocked on CoreML model download / load.
/// - Falls back to "no speech" if the manager fails to come up (network
///   missing on first launch, model bundle corrupt, etc.). The detector
///   then never triggers — strictly safer than misfiring.
/// - Pins chunk size to FluidAudio's native 4096 samples (256 ms at
///   16 kHz). The plan's "32 ms frame" target predates the verified API;
///   the public stream contract ("one Bool per chunk") is unchanged.
actor SileroVADAdapter: SileroVoiceActivityDetecting {
    /// FluidAudio's native chunk size, surfaced publicly so the probe and
    /// its tests can size buffers without depending on the package directly.
    nonisolated static var chunkSize: Int { VadManager.chunkSize }

    private var manager: VadManager?
    private var state: VadStreamState = .initial()
    private var initFailed = false

    func detect(samples: [Float]) async -> Bool {
        guard let manager = await loadedManager() else {
            return false
        }
        do {
            let result = try await manager.processStreamingChunk(
                samples,
                state: state
            )
            state = result.state
            return result.state.triggered
        } catch {
            // Probability inference failed for this chunk — treat as
            // silence. We do not surface the error to the detector because
            // a transient ANE hiccup should not invalidate the stream.
            return false
        }
    }

    private func loadedManager() async -> VadManager? {
        if let manager { return manager }
        if initFailed { return nil }
        do {
            let manager = try await VadManager()
            self.manager = manager
            return manager
        } catch {
            initFailed = true
            return nil
        }
    }
}

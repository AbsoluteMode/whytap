import FluidAudio
import Foundation
import os.log

/// Decode seam over FluidAudio's Parakeet `AsrManager`, so the session and the
/// batch path can be driven (and tested) without the Core ML model.
///
/// `decode` is a self-contained pass over `samples` with a fresh decoder
/// state. The on-stop final (the whole take) and the live partials (a bounded
/// trailing window) both use it, so a partial can never corrupt the final.
protocol OnDeviceSpeechDecoding: Sendable {
    func decode(samples: [Float], language: String?) async throws -> String
    /// Starts loading the model (or joins the load in progress) without
    /// waiting for it.
    func prepareModel() async
    /// Whether a decode can start without loading the model first.
    func modelIsLoaded() async -> Bool
}

extension OnDeviceSpeechDecoding {
    func prepareModel() async {}
    func modelIsLoaded() async -> Bool { true }
}

/// Production decoder: one stateless full-buffer pass per call. An `actor`, so
/// Core ML inference is serialised off the main actor.
///
/// FluidAudio's public `transcribe` finalises the decoder state on every call
/// and its state-carrying entry point is internal, so true per-slice streaming
/// is not available without forking the package. A bounded-window fresh-state
/// re-decode gives correct, growing live text at constant cost instead.
actor ParakeetSpeechDecoder: OnDeviceSpeechDecoding {
    /// How long a take waits, after the key is released, for a model that is
    /// still loading. Past it the take ends with Retry and the load goes on.
    // WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
    static let takePreparationWait: Duration = .seconds(45)
    /// The batch rung and Retry: under `BatchRecoveryDeadline` (30 s), so
    /// the take ends with the model's own reason, not a generic timeout.
    static let batchPreparationWait: Duration = .seconds(20)

    private let store: any OnDeviceSpeechModelManaging
    private let preparationWait: Duration?

    init(
        store: any OnDeviceSpeechModelManaging = OnDeviceSpeechModelStore.shared,
        preparationWait: Duration? = ParakeetSpeechDecoder.takePreparationWait
    ) {
        self.store = store
        self.preparationWait = preparationWait
    }

    nonisolated func prepareModel() async {
        let store = self.store
        Task(priority: .userInitiated) { await store.prepare() }
    }

    nonisolated func modelIsLoaded() async -> Bool {
        await store.isLoaded()
    }

    func decode(samples: [Float], language: String?) async throws -> String {
        let manager = try await store.acquire(within: preparationWait)
        do {
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(
                samples, decoderState: &state, language: Self.scriptFilter(for: language)
            )
            await store.release()
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await store.release()
            throw error
        }
    }

    /// FluidAudio's `language` is a script filter, not a hint: it drops tokens
    /// of the other script. A Latin-script language keeps it (it stops a
    /// Polish or Czech take drifting into Cyrillic). A Cyrillic-script one
    /// passes nothing, so a Russian speaker's English terms can stay Latin.
    nonisolated static func scriptFilter(for code: String?) -> Language? {
        guard let primary = code?.split(separator: "-").first?.lowercased(),
              let language = Language(rawValue: primary), language.script == .latin
        else { return nil }
        return language
    }
}

@MainActor
final class OnDeviceTranscriptionSession: StreamingSessionRunning {
    var onTranscriptUpdate: ((String) -> Void)?
    /// The same partials, plus whether the decoded window no longer starts at
    /// the beginning of the take (audio past `partialWindowSamples`). For
    /// `drop_live`, which keeps the start of a long take in a client's field.
    // WHY: .project-docs/decisions/2026-11-24-drop-live-for-dictation-clients.md
    var onTranscriptWindow: ((String, Bool) -> Void)?
    /// The key was released and the model is still loading: the take waits
    /// for it (at most `ParakeetSpeechDecoder.takePreparationWait`). Lets the
    /// island say so instead of showing "listening…".
    // WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
    var onPreparingModel: (() -> Void)?

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "on-device-speech")

    /// New audio (in PCM16 bytes) accumulated before a partial decode runs.
    /// 16 kHz mono PCM16 = 32_000 bytes/s, so 25_600 bytes ≈ 800 ms cadence.
    /// Each partial is a bounded-window full re-decode (see
    /// `partialWindowSamples`), so the per-tick cost is roughly constant but
    /// non-trivial (a padded-to-15 s encoder pass); ~800 ms gives that decode
    /// comfortable headroom to finish before the next tick on Apple Silicon.
    /// Decodes are serialised (`await emitPartial`): one in flight at a time.
    private static let partialByteStride = 25_600  // ~800 ms @ 16 kHz PCM16

    /// Trailing window (in samples) re-decoded for each live partial. Kept
    /// strictly below FluidAudio's single-chunk threshold (`maxModelSamples`
    /// 240_000 / 15 s) so every partial stays on the constant-cost single-chunk
    /// encoder path and never falls into the O(buffer) `ChunkProcessor`
    /// multi-chunk path (the source of a ~6 s lag and a pegged core).
    /// 224_000 (~14 s) leaves margin for frame-alignment padding
    /// (`frameAlignedAudio` rounds up to the next 1280-sample frame). For
    /// dictations under this length the partial is the WHOLE growing transcript;
    /// for longer ones the island shows a correct, growing transcript of roughly
    /// the last ~14 s — fine for a display-only ticker. The on-stop final always
    /// re-decodes the entire captured buffer.
    /// Internal (not private) so the streaming regression test can assert the
    /// fed window is capped at this value.
    static let partialWindowSamples = 224_000  // ~14 s @ 16 kHz, < 240k

    /// Parakeet rejects audio shorter than 0.3 s (`ASRError.invalidAudioData`).
    /// Hold the first partial decode until we have a comfortable margin over
    /// that floor so an early tick never throws.
    private static let minPartialSampleCount = 8_000  // 0.5 s @ 16 kHz

    /// Characters at the end of a partial that must differ for it to count as
    /// new live text.
    private static let stableTailLength = 32

    private enum Signal {
        case stop
        case cancel
        case failure(StreamingSessionError)
    }

    private let audioEngine: any StreamingAudioSourcing
    private let decoder: any OnDeviceSpeechDecoding
    private let languageCode: String?

    private var drainTask: Task<Void, Never>?
    private var finalTask: Task<String, Error>?
    private var cancelRequested = false
    /// Whether the model was in memory when the take began. An empty result
    /// from a model that loaded during the take is not trusted as silence.
    private var modelLoadedAtStart = true
    private var failureWatchTask: Task<Void, Never>?
    private var signalContinuation: CheckedContinuation<Signal, Never>?
    private var pendingSignal: Signal?

    /// Latest partial transcript emitted, used to suppress duplicate emits: a
    /// partial is forwarded to the island only when its text DIFFERS from this
    /// (emit-on-change). Length is deliberately NOT compared — the trailing
    /// window scrolls once speech exceeds it, so newer text is often shorter,
    /// and a length-monotonic guard would freeze the ticker.
    private var lastEmittedPartial: String = ""

    /// Every chunk of the take, kept by the session itself: the engine's turn
    /// buffer stops at 20 MB (about 11 minutes), and the pasted text must
    /// cover a longer take too.
    private var streamed = Data()
    private var bytesSinceLastDecode = 0
    /// Set by `stop()`: chunks still in the stream are kept, but no further
    /// partial is decoded, so the final pass starts at once.
    private var stopping = false

    init(
        audioEngine: any StreamingAudioSourcing = StreamingAudioEngine(),
        decoder: any OnDeviceSpeechDecoding = ParakeetSpeechDecoder(),
        language: String?
    ) {
        self.audioEngine = audioEngine
        self.decoder = decoder
        self.languageCode = language
    }

    func run() async -> StreamingSessionResult {
        do {
            try audioEngine.start()
        } catch {
            os_log(
                "on-device speech: audio engine start failed: %{public}@",
                log: Self.log,
                type: .error,
                String(describing: error)
            )
            return .failed(.transportFailed)
        }

        // Load the model while the user speaks: after a launch, an idle
        // unload or a fresh download it is not in memory yet.
        let decoder = self.decoder
        modelLoadedAtStart = await decoder.modelIsLoaded()
        Task { await decoder.prepareModel() }

        // Keep every chunk and, about every 0.8 s, re-decode a bounded trailing
        // window (`partialWindowSamples`, under FluidAudio's 15 s single-chunk
        // threshold, so each pass costs the same however long the take is)
        // with a fresh decoder state. Partials are display-only; the final
        // pass on stop covers the whole take.
        //
        // This task runs on the main actor, so the work it does itself is kept
        // small: appending a chunk and converting at most 14 s of samples.
        // Core ML inference runs on the decoder's actor. `await emitPartial`
        // keeps one decode in flight; chunks that arrive meanwhile are kept
        // and the next decode covers them.
        drainTask = Task(priority: .utility) { [weak self, audioEngine] in
            for await chunk in audioEngine.chunks {
                guard let self else { return }
                guard let window = self.ingest(chunk) else { continue }
                await self.emitPartial(samples: window.samples, shifted: window.shifted)
            }
        }

        failureWatchTask = Task { [weak self, audioEngine] in
            for await _ in audioEngine.failures {
                await MainActor.run {
                    self?.signal(.failure(.audioEngineFailed))
                }
                break
            }
        }

        let signal = await nextSignal()
        switch signal {
        case .cancel:
            await teardown()
            return .cancelled
        case .failure(let error):
            await teardown()
            return .failed(error)
        case .stop:
            await drainTask?.value
            failureWatchTask?.cancel()
            let pcm = takeAudio()
            let final = Task { @MainActor [weak self] () async throws -> String in
                guard let self else { throw CancellationError() }
                return try await self.transcribe(pcm: pcm)
            }
            finalTask = final
            do {
                let text = try await final.value
                finalTask = nil
                guard !cancelRequested else {
                    await teardown()
                    return .cancelled
                }
                // WHY: .project-docs/decisions/2026-11-28-on-device-model-preparation.md
                if text.isEmpty, !modelLoadedAtStart, Self.hasSpeechLevelAudio(pcm) {
                    os_log("on-device take: no text from a model loaded during the take",
                           log: Self.log, type: .error)
                    await teardown()
                    return .failed(.localModelNoText)
                }
                onTranscriptUpdate?(text)
                await teardown()
                return .transcript(text)
            } catch {
                finalTask = nil
                await teardown()
                if cancelRequested { return .cancelled }
                os_log(
                    "on-device speech failed: %{public}@",
                    log: Self.log,
                    type: .error,
                    OnDeviceSpeechModelStore.describe(error)
                )
                return .failed(Self.sessionError(for: error))
            }
        }
    }

    /// A model that is still loading or did not load is named, so the take
    /// ends with that reason and Retry instead of a generic failure.
    /// Any 100 ms of the take louder than about -34 dBFS: speech, not a
    /// silent room or digital silence.
    nonisolated static func hasSpeechLevelAudio(_ pcm: Data, threshold: Float = 0.02) -> Bool {
        let window = 1_600
        let samples = floatSamples(fromPCM16LittleEndian: pcm)
        guard samples.count >= window else { return false }
        var start = 0
        while start + window <= samples.count {
            var sum: Float = 0
            for index in start..<(start + window) { sum += samples[index] * samples[index] }
            if (sum / Float(window)).squareRoot() > threshold { return true }
            start += window
        }
        return false
    }

    nonisolated static func sessionError(for error: Error) -> StreamingSessionError {
        switch error as? OnDeviceSpeechError {
        case .modelPreparing: return .localModelPreparing
        case .modelLoadFailed, .modelNotDownloaded: return .localModelFailed
        case .modelNoText: return .localModelNoText
        case .noAudio, .none: return .transportFailed
        }
    }

    func stop() async {
        stopping = true
        audioEngine.finish()
        signal(.stop)
    }

    func cancel() async {
        cancelRequested = true
        audioEngine.stop()
        finalTask?.cancel()
        signal(.cancel)
    }

    func capturedAudioPCM16() -> Data {
        takeAudio()
    }

    /// The whole take: the session's own copy of the stream, or the engine's
    /// turn buffer when that holds more (a source that tees without streaming).
    private func takeAudio() -> Data {
        let captured = audioEngine.capturedPCM16()
        return streamed.count >= captured.count ? streamed : captured
    }

    /// Keeps `chunk` and, once about 0.8 s of new audio has arrived, returns
    /// the trailing window to decode. `nil` between ticks, after `stop()` and
    /// while the take is shorter than Parakeet accepts.
    private func ingest(_ chunk: Data) -> (samples: [Float], shifted: Bool)? {
        streamed.append(chunk)
        bytesSinceLastDecode += chunk.count
        guard bytesSinceLastDecode >= Self.partialByteStride else { return nil }
        bytesSinceLastDecode = 0
        guard !stopping else { return nil }
        let audio = takeAudio()
        guard audio.count / 2 >= Self.minPartialSampleCount else { return nil }
        return (Self.floatSamples(fromPCM16LittleEndian: audio.suffix(Self.partialWindowSamples * 2)),
                audio.count > Self.partialWindowSamples * 2)
    }


    /// Run one partial decode over a bounded trailing window of the captured
    /// audio (fresh decoder state) and forward the transcript to the island.
    /// Display-only: a decode failure here is swallowed (the authoritative final
    /// decode on stop is what matters), and the text is forwarded on CHANGE
    /// (`lastEmittedPartial` guard) — the window scrolls once speech exceeds it,
    /// so the ticker must keep updating even when newer text is shorter. The
    /// decode runs on the decoder's actor (off the main actor); only the cheap
    /// guard + callback run here.
    private func emitPartial(samples: [Float], shifted: Bool) async {
        // A partial never waits for the model: the chunks are kept and the
        // final pass covers them.
        guard await decoder.modelIsLoaded() else { return }
        do {
            let text = try await decoder.decode(
                samples: samples,
                language: languageCode
            )
            let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            // Emit when the END of the text changes. Past 14 s the window
            // scrolls: older words fall off the front on every tick, also
            // while the speaker is silent. Comparing whole strings would keep
            // "changing" the live text through a pause, which erases the
            // ticker and holds Drop auto-stop (it waits for the transcript to
            // stop changing). New speech always changes the tail. Length is
            // not compared: a scrolled window is often shorter.
            guard !trimmed.isEmpty,
                  trimmed.suffix(Self.stableTailLength) != lastEmittedPartial.suffix(Self.stableTailLength)
            else { return }
            lastEmittedPartial = trimmed
            onTranscriptUpdate?(trimmed)
            onTranscriptWindow?(trimmed, shifted)
        } catch {
            // Partials are best-effort; the final decode on stop is the
            // authority. Never surface a partial failure to the user.
        }
    }

    private func transcribe(pcm: Data) async throws -> String {
        let samples = Self.floatSamples(fromPCM16LittleEndian: pcm)
        // Parakeet rejects takes under 0.3 s; that little audio holds no word,
        // so it is silence (nothing pasted), not a failure.
        guard samples.count >= 4_800 else { return "" }
        if !(await decoder.modelIsLoaded()) {
            os_log("on-device take: waiting for the model samples=%{public}d",
                   log: Self.log, type: .info, samples.count)
            onPreparingModel?()
        }
        return try await decoder.decode(
            samples: samples,
            language: languageCode
        )
    }

    private func nextSignal() async -> Signal {
        if let pendingSignal {
            self.pendingSignal = nil
            return pendingSignal
        }
        return await withCheckedContinuation { continuation in
            signalContinuation = continuation
        }
    }

    private func signal(_ signal: Signal) {
        if let continuation = signalContinuation {
            signalContinuation = nil
            continuation.resume(returning: signal)
        } else {
            pendingSignal = signal
        }
    }

    private func teardown() async {
        failureWatchTask?.cancel()
        drainTask?.cancel()
        audioEngine.stop()
        signalContinuation = nil
        pendingSignal = nil
    }

    nonisolated static func floatSamples(fromPCM16LittleEndian data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { bytes in
            (0..<count).map { index in
                let sample = Int16(bitPattern: UInt16(bytes[2 * index]) | (UInt16(bytes[2 * index + 1]) << 8))
                return Float(sample) / Float(Int16.max)
            }
        }
    }
}

extension StreamingSessionError {
    /// The on-device model's own reason, for the delivery ladder: retrying
    /// the same model at once cannot help, so the take ends with Retry.
    var onDeviceModelError: OnDeviceSpeechError? {
        switch self {
        case .localModelPreparing: return .modelPreparing
        case .localModelFailed: return .modelLoadFailed
        case .localModelNoText: return .modelNoText
        default: return nil
        }
    }
}

import Foundation
import FluidAudio
import os.log

/// Decode seam over FluidAudio's Parakeet `AsrManager`. Abstracted so
/// `LocalTranscriptionSession` can drive live partial decodes (and be
/// unit-tested) without the 2.3 GB Core ML model: tests inject a fake.
///
/// `decode` is a self-contained pass over `samples` with a FRESH decoder state.
/// Used for BOTH the authoritative on-stop final (full captured buffer) and the
/// live partials (a bounded trailing window of the buffer). Because every pass
/// is stateless, the pasted transcript is byte-identical to the previous
/// batch-only path (no decoder-state drift, no token dedup to get wrong), and a
/// partial decode can never corrupt the final.
protocol LocalASRDecoding: Sendable {
    func decode(samples: [Float], language: Language?) async throws -> String
}

/// Production decoder: loads the shared Parakeet manager and runs one stateless
/// full-buffer pass (fresh `TdtDecoderState`) per call — for both the live
/// partials (handed a bounded trailing window) and the on-stop final (handed
/// the whole captured buffer). An `actor` so Core ML inference is serialised off
/// the main actor.
///
/// WHY a stateless re-decode instead of a carried-state incremental pass:
/// FluidAudio's only public streaming-capable entry point, `manager.transcribe`,
/// routes single-chunk audio (≤ 15 s) through `transcribeWithState` with
/// `isLastChunk: true` hardcoded — it FINALISES the decoder state every call
/// (`TdtDecoderState.finalizeLastChunk` nulls the carried context). The internal
/// `transcribeChunk`/`transcribeWithState` (which take `isLastChunk: false`) are
/// `internal` to FluidAudio and not callable without forking the package. So
/// true per-slice streaming isn't available here; a bounded-window fresh-state
/// re-decode gives correct, growing text at constant cost instead (see
/// `LocalTranscriptionSession.partialWindowSamples`). The dedicated
/// `SlidingWindowAsrManager` is the proper long-term streaming route but is a
/// much larger refactor and unnecessary for a display-only ticker.
/// WHY: docs/decisions/2026-06-27-local-partials-bounded-window-redecode.md
actor ParakeetLocalASRDecoder: LocalASRDecoding {
    private let modelStore: any LocalTranscriptionModelManaging

    init(modelStore: any LocalTranscriptionModelManaging) {
        self.modelStore = modelStore
    }

    func decode(samples: [Float], language: Language?) async throws -> String {
        let manager = try await modelStore.loadManager()
        let decoderLayers = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState,
            language: language
        )
        return result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}

@MainActor
final class LocalTranscriptionSession: StreamingSessionRunning {
    var onTranscriptUpdate: ((String) -> Void)?

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "local-transcription")

    /// New audio (in PCM16 bytes) accumulated before a partial decode runs.
    /// 16 kHz mono PCM16 = 32_000 bytes/s, so 25_600 bytes ≈ 800 ms cadence.
    /// Each partial is a bounded-window full re-decode (see
    /// `partialWindowSamples`), so the per-tick cost is roughly constant but
    /// non-trivial (a padded-to-15 s encoder pass); ~800 ms gives that decode
    /// comfortable headroom to finish before the next tick on Apple Silicon.
    /// Decodes are serialised (`await emitPartial`), so if one ever overruns the
    /// cadence the loop simply drops ticks — work never piles up.
    private static let partialByteStride = 25_600  // ~800 ms @ 16 kHz PCM16

    /// Trailing window (in samples) re-decoded for each live partial. Kept
    /// strictly below FluidAudio's single-chunk threshold (`maxModelSamples`
    /// 240_000 / 15 s) so every partial stays on the constant-cost single-chunk
    /// encoder path and never falls into the O(buffer) `ChunkProcessor`
    /// multi-chunk path (the source of the ~6 s lag / CPU peg, ROO-257).
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

    private enum Signal {
        case stop
        case cancel
        case failure(StreamingSessionError)
    }

    private let audioEngine: any StreamingAudioSourcing
    private let decoder: any LocalASRDecoding
    private let languageCode: String?

    private var drainTask: Task<Void, Never>?
    private var failureWatchTask: Task<Void, Never>?
    private var signalContinuation: CheckedContinuation<Signal, Never>?
    private var pendingSignal: Signal?

    /// Latest partial transcript emitted, used to suppress duplicate emits: a
    /// partial is forwarded to the island only when its text DIFFERS from this
    /// (emit-on-change). Length is deliberately NOT compared — the trailing
    /// window scrolls once speech exceeds it, so newer text is often shorter,
    /// and a length-monotonic guard would freeze the ticker (ROO-257).
    private var lastEmittedPartial: String = ""

    convenience init(
        audioEngine: any StreamingAudioSourcing = StreamingAudioEngine(),
        modelStore: any LocalTranscriptionModelManaging = LocalTranscriptionModelStore.shared,
        language: String?
    ) {
        self.init(
            audioEngine: audioEngine,
            decoder: ParakeetLocalASRDecoder(modelStore: modelStore),
            language: language
        )
    }

    init(
        audioEngine: any StreamingAudioSourcing = StreamingAudioEngine(),
        decoder: any LocalASRDecoding,
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
                "local transcription: audio engine start failed: %{public}@",
                log: Self.log,
                type: .error,
                String(describing: error)
            )
            return .failed(.transportFailed)
        }

        // Drain the chunk stream AND run throttled partial decodes over a BOUNDED
        // TRAILING WINDOW of the audio captured so far. Each tick re-decodes the
        // last ~14 s (`partialWindowSamples`) with a FRESH decoder state — capped
        // below FluidAudio's single-chunk threshold (240k / 15 s) so it stays on
        // the constant-cost single-chunk encoder path and never falls into the
        // O(buffer) `ChunkProcessor` path that pegged a core and fell ~6 s behind
        // speech (ROO-257). The full PCM is teed inside the engine (`turnAudio`)
        // and read back via `capturedPCM16()` for both this windowed partial and
        // the authoritative final decode — the partials are display-only.
        //
        // WHY a windowed re-decode and not a carried-state incremental pass:
        // FluidAudio's public `transcribe` hardcodes `isLastChunk: true` (it
        // finalises decoder state every call), and the internal `transcribeChunk`
        // (which would carry state across slices) is not callable without forking
        // the package. A bounded fresh-state re-decode is the cleanest CORRECT
        // partial the public API allows, at constant cost. See
        // `ParakeetLocalASRDecoder` and the decision doc.
        //
        // `.utility` priority keeps the decode loop off the main thread's QoS so
        // the hover CGEventTap + UI stay responsive while a dictation runs. The
        // decoder is an `actor`, so the actual Core ML inference already runs off
        // the main actor; the priority hint keeps the surrounding slice work off
        // it too. `await emitPartial` suspends this loop until the decode
        // returns, so decodes stay serialized (one in flight at a time): if a
        // decode ever overruns the ~800 ms cadence the loop just drops ticks.
        drainTask = Task(priority: .utility) { [weak self, audioEngine] in
            var bytesSinceLastDecode = 0
            for await chunk in audioEngine.chunks {
                bytesSinceLastDecode += chunk.count
                guard bytesSinceLastDecode >= Self.partialByteStride else { continue }
                bytesSinceLastDecode = 0

                // Re-decode a bounded trailing window of the captured buffer
                // (the last ~14 s, < 15 s threshold → constant cost, not
                // O(buffer)). Reading the captured buffer (not disjoint slices)
                // gives the decoder full acoustic context for that window, so the
                // partial is a clean, growing transcript.
                let samples = Self.floatSamples(
                    fromPCM16LittleEndian: audioEngine.capturedPCM16()
                )
                guard samples.count >= Self.minPartialSampleCount else { continue }
                let window = samples.count > Self.partialWindowSamples
                    ? Array(samples.suffix(Self.partialWindowSamples))
                    : samples

                await self?.emitPartial(samples: window)
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
            let pcm = audioEngine.capturedPCM16()
            do {
                let text = try await transcribe(pcm: pcm)
                onTranscriptUpdate?(text)
                await teardown()
                return .transcript(text)
            } catch {
                os_log(
                    "local transcription failed: %{public}@",
                    log: Self.log,
                    type: .error,
                    String(describing: error)
                )
                await teardown()
                return .failed(.transportFailed)
            }
        }
    }

    func stop() async {
        audioEngine.finish()
        signal(.stop)
    }

    func cancel() async {
        audioEngine.stop()
        signal(.cancel)
    }

    func capturedAudioPCM16() -> Data {
        audioEngine.capturedPCM16()
    }

    /// Run one partial decode over a bounded trailing window of the captured
    /// audio (fresh decoder state) and forward the transcript to the island.
    /// Display-only: a decode failure here is swallowed (the authoritative final
    /// decode on stop is what matters), and the text is forwarded on CHANGE
    /// (`lastEmittedPartial` guard) — the window scrolls once speech exceeds it,
    /// so the ticker must keep updating even when newer text is shorter. The
    /// decode runs on the decoder's actor (off the main actor); only the cheap
    /// guard + callback run here.
    private func emitPartial(samples: [Float]) async {
        do {
            let text = try await decoder.decode(
                samples: samples,
                language: Self.fluidLanguage(from: languageCode)
            )
            let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            // Emit on CHANGE, not on growth. The island is a trailing-window
            // ticker: once speech exceeds `partialWindowSamples` (~14 s), the
            // windowed transcript SCROLLS (older audio falls off the front), so
            // a later partial is routinely shorter-or-equal in length than the
            // longest text seen. A length-monotonic guard (`count >= lastCount`)
            // would freeze the island at that longest frame ("after a certain
            // number of words it stops writing", ROO-257). Emitting whenever the
            // text differs keeps the ticker scrolling; the rare momentary
            // backtrack within the window is far cheaper than freezing.
            guard !trimmed.isEmpty, trimmed != lastEmittedPartial else { return }
            lastEmittedPartial = trimmed
            onTranscriptUpdate?(trimmed)
        } catch {
            // Partials are best-effort; the final decode on stop is the
            // authority. Never surface a partial failure to the user.
        }
    }

    private func transcribe(pcm: Data) async throws -> String {
        let samples = Self.floatSamples(fromPCM16LittleEndian: pcm)
        guard !samples.isEmpty else {
            throw LocalTranscriptionModelError.noAudio
        }
        return try await decoder.decode(
            samples: samples,
            language: Self.fluidLanguage(from: languageCode)
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
        guard data.count >= 2 else { return [] }

        var samples: [Float] = []
        samples.reserveCapacity(data.count / 2)
        var index = data.startIndex
        while index < data.endIndex {
            let next = data.index(after: index)
            guard next < data.endIndex else { break }
            let low = UInt16(data[index])
            let high = UInt16(data[next]) << 8
            let sample = Int16(bitPattern: high | low)
            samples.append(Float(sample) / Float(Int16.max))
            index = data.index(after: next)
        }
        return samples
    }

    nonisolated static func fluidLanguage(from code: String?) -> Language? {
        guard let code else { return nil }
        let normalized = code
            .split(separator: "-")
            .first
            .map(String.init)?
            .lowercased()
        guard let normalized else { return nil }
        return Language(rawValue: normalized)
    }
}

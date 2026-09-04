import Foundation
import FluidAudio
import os.log

// MARK: - ASR segment shape (Stage 5a)

/// One ASR span produced locally for a single audio track. Distinct from
/// `TranscriptSegment` (which carries a `speaker` and is the diarized,
/// aligned shape rendered in notes) on purpose: Stage 5a only knows
/// "this track said this text between these times" — speaker attribution
/// ("Me" vs "Speaker N") and cross-track alignment are Stage 5b.
struct MeetingASRSegment: Sendable, Equatable {
    let text: String
    /// Seconds from the start of the recording (track-local clock —
    /// both tracks share the same recording timeline because mic and
    /// system were captured concurrently).
    let start: Double
    let end: Double
}

/// One ASR token of a single track with its timing. Carries the finest
/// granularity the engine exposes (Parakeet emits a `TokenTiming` per decoded
/// sub-word piece). Stage 5b uses the SYSTEM track's tokens to RE-SEGMENT it by
/// diarizer turn — a single whole-track `MeetingASRSegment` cannot be split
/// across speakers, but the underlying tokens can. The mic track does not need
/// tokens: it is always one speaker ("Me").
///
/// `text` is the engine-normalized token piece: FluidAudio replaces the
/// SentencePiece word-boundary marker `▁` with a leading space, so concatenating
/// a run of tokens and trimming reconstructs readable text (the same way the
/// engine builds `ASRResult.text`).
struct MeetingASRToken: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
}

/// Result of transcribing a recorded meeting locally with the mic and
/// system tracks kept SEPARATE. Stage 5b consumes this: mic segments
/// become "Me", the system track's per-token timings get re-segmented by
/// diarizer turn into "Speaker N", then the two are aligned into a single
/// `[TranscriptSegment]`.
struct MeetingLocalTranscript: Sendable, Equatable {
    let mic: [MeetingASRSegment]
    /// Whole-track system span(s) — kept for logging / fallback. NOT used for
    /// speaker attribution: a single span cannot represent multiple remote
    /// speakers. `systemTokens` is the source of truth Stage 5b re-segments.
    let system: [MeetingASRSegment]
    /// Per-token timings of the SYSTEM track, in time order. Stage 5b assigns
    /// each token to the diarizer turn it overlaps and groups consecutive
    /// same-turn tokens into per-turn "Speaker N" segments. Empty when the
    /// system track had no speech or the engine returned no token timings.
    let systemTokens: [MeetingASRToken]

    init(
        mic: [MeetingASRSegment],
        system: [MeetingASRSegment],
        systemTokens: [MeetingASRToken] = []
    ) {
        self.mic = mic
        self.system = system
        self.systemTokens = systemTokens
    }
}

// MARK: - Engine seam

/// Batch ASR engine seam over FluidAudio's Parakeet `AsrManager`.
/// Injected so `MeetingLocalTranscriber` can be unit-tested against a
/// fake without the 2.3 GB Core ML model — the production adapter
/// (`ParakeetMeetingASREngine`) drives the same manager the streaming
/// local-STT session uses, just over recorded samples in one shot.
protocol MeetingASRTranscribing: Sendable {
    func transcribe(samples: [Float], language: Language?) async throws -> ASRResult
}

/// Production engine: loads the shared Parakeet manager from the local
/// transcription model store and runs a single batch pass per track with
/// a fresh decoder state (each track is an independent utterance stream,
/// so they must not share decoder state).
struct ParakeetMeetingASREngine: MeetingASRTranscribing {
    private let modelStore: any LocalTranscriptionModelManaging

    init(modelStore: any LocalTranscriptionModelManaging = LocalTranscriptionModelStore.shared) {
        self.modelStore = modelStore
    }

    func transcribe(samples: [Float], language: Language?) async throws -> ASRResult {
        let manager = try await modelStore.loadManager()
        let decoderLayers = await manager.decoderLayerCount
        var decoderState = TdtDecoderState.make(decoderLayers: decoderLayers)
        return try await manager.transcribe(
            samples,
            decoderState: &decoderState,
            language: language
        )
    }
}

// MARK: - MeetingLocalTranscriber

/// Seam the coordinator depends on so the local capture/transcribe path
/// can be wired (and unit-tested) without the real Parakeet model. The
/// production conformer is `MeetingLocalTranscriber`.
protocol MeetingLocalTranscribing: Sendable {
    func transcribe(tracks: MeetingRecorder.SeparateTrackURLs) async throws -> MeetingLocalTranscript
}

/// Stage 5a: batch-transcribe a recorded meeting's mic and system tracks
/// SEPARATELY with Parakeet, producing per-track ASR segments. The
/// separation is the whole point — it is the foundation Stage 5b builds
/// on to label mic audio as "Me" and diarize the system audio into
/// remote speakers. This type does NOT diarize, align, or summarize.
struct MeetingLocalTranscriber: MeetingLocalTranscribing {
    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "local-transcriber")

    private let engine: any MeetingASRTranscribing
    private let language: Language?

    init(engine: any MeetingASRTranscribing, language: Language?) {
        self.engine = engine
        self.language = language
    }

    /// Read the retained per-source WAVs from disk and transcribe each
    /// track separately. The mic/system WAVs are the raw un-mixed tracks
    /// written by `MeetingRecorder` when `retainSeparateTracks` is on.
    func transcribe(tracks: MeetingRecorder.SeparateTrackURLs) async throws -> MeetingLocalTranscript {
        let micSamples = Self.floatSamples(fromWAV: tracks.micURL)
        let systemSamples = Self.floatSamples(fromWAV: tracks.systemURL)
        return try await transcribe(micSamples: micSamples, systemSamples: systemSamples)
    }

    /// Decode a 16 kHz mono PCM16 WAV track to Float samples. Returns an
    /// empty array on a missing / header-only / unreadable file so a
    /// mic-only or system-only meeting transcribes the track that exists.
    static func floatSamples(fromWAV url: URL) -> [Float] {
        guard let pcm = try? MeetingPCM16WAVReader.readPCM16Data(from: url) else { return [] }
        return LocalTranscriptionSession.floatSamples(fromPCM16LittleEndian: pcm)
    }

    /// Transcribe both tracks. Each track is run through the engine on its
    /// own call (never mixed), so the returned mic/system segment lists are
    /// independently derived. An empty input track is skipped (no engine
    /// call, no segments) so a mic-only or system-only meeting still works.
    func transcribe(
        micSamples: [Float],
        systemSamples: [Float]
    ) async throws -> MeetingLocalTranscript {
        let mic = try await transcribeTrack(samples: micSamples, track: "mic")
        let system = try await transcribeTrack(samples: systemSamples, track: "system")

        os_log(
            "local meeting transcription done (mic_segments: %{public}d, system_segments: %{public}d, system_tokens: %{public}d)",
            log: Self.log, type: .info,
            mic.segments.count, system.segments.count, system.tokens.count
        )
        return MeetingLocalTranscript(
            mic: mic.segments,
            system: system.segments,
            systemTokens: system.tokens
        )
    }

    /// One track's ASR output: the whole-track segment(s) plus the per-token
    /// timings the system track is later re-segmented by. The mic ignores the
    /// tokens (always one "Me"); only the system track threads them through.
    private struct TrackTranscription {
        let segments: [MeetingASRSegment]
        let tokens: [MeetingASRToken]
    }

    private func transcribeTrack(samples: [Float], track: String) async throws -> TrackTranscription {
        guard !samples.isEmpty else { return TrackTranscription(segments: [], tokens: []) }

        let startedAt = Date()
        let result = try await engine.transcribe(samples: samples, language: language)
        let elapsed = Date().timeIntervalSince(startedAt)

        os_log(
            "local meeting track transcribed (track: %{public}@, samples: %{public}d, duration_s: %{public}.2f)",
            log: Self.log, type: .info,
            track, samples.count, elapsed
        )

        return TrackTranscription(
            segments: Self.makeSegments(from: result),
            tokens: Self.makeTokens(from: result)
        )
    }

    /// Derive the whole-track ASR segment from a single track's `ASRResult`:
    /// one segment spanning the whole track, with timecodes from the token
    /// timings when present (first token start → last token end) and a
    /// `0…duration` fallback otherwise. Whitespace-only transcripts produce no
    /// segment.
    ///
    /// For the SYSTEM track this whole-track segment is NOT used for speaker
    /// attribution (a single span cannot hold multiple speakers) — Stage 5b
    /// re-segments the track from `makeTokens` instead. It is retained for
    /// logging and as the mic track's representation (the mic is always "Me",
    /// so one span is exactly right there).
    static func makeSegments(from result: ASRResult) -> [MeetingASRSegment] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let span = timeSpan(from: result)
        return [MeetingASRSegment(text: text, start: span.start, end: span.end)]
    }

    /// Per-token timings of a track, in time order. Stage 5b uses the SYSTEM
    /// track's tokens to re-segment it by diarizer turn (one token cannot span
    /// two speakers, so token granularity is what makes multi-speaker
    /// attribution possible). Returns empty when the engine produced no token
    /// timings (then the whole-track segment is the only fallback). Tokens whose
    /// timing is degenerate (end < start) are clamped, never inverted.
    static func makeTokens(from result: ASRResult) -> [MeetingASRToken] {
        guard let timings = result.tokenTimings, !timings.isEmpty else { return [] }
        return timings
            .sorted { $0.startTime < $1.startTime }
            .map { timing in
                MeetingASRToken(
                    text: timing.token,
                    start: timing.startTime,
                    end: max(timing.startTime, timing.endTime)
                )
            }
    }

    private static func timeSpan(from result: ASRResult) -> (start: Double, end: Double) {
        if let timings = result.tokenTimings, !timings.isEmpty {
            let start = timings.map(\.startTime).min() ?? 0
            let end = timings.map(\.endTime).max() ?? result.duration
            // Guard against degenerate timings (end < start) by clamping
            // end up to start; never invert a segment.
            return (start, max(start, end))
        }
        return (0, max(0, result.duration))
    }
}

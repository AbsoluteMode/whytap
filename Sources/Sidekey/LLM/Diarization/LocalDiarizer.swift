import Foundation
import FluidAudio
import os.log

/// A contiguous span of speech attributed to one speaker.
///
/// Deliberately DISTINCT from `TranscriptSegment` (which carries `text`):
/// a `SpeakerTurn` answers only "who spoke when", never "what was said".
/// The two are unified downstream (Stage 5b alignment), not here.
struct SpeakerTurn: Sendable, Equatable {
    let speaker: String
    let start: Double
    let end: Double

    init(speaker: String, start: Double, end: Double) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Engine-agnostic view of one diarized segment, used as the seam between the
/// FluidAudio pipeline and `LocalDiarizer`'s mapping logic so the mapping is
/// unit-testable without downloading Core ML models.
struct DiarizedSegment: Sendable, Equatable {
    let speakerId: String
    let start: Double
    let end: Double
}

/// On-device speaker diarization over the FluidAudio pipeline. Loads the cached
/// `DiarizerManager` from the model store (mirroring how `LocalLLMSession` /
/// `LocalTranscriptionSession` cache their managers) and runs a single offline
/// batch pass over an audio buffer.
///
/// Audio and resulting labels are NEVER logged — only the speaker/turn counts
/// and timing (invariant #3).
actor LocalDiarizer {
    /// Injection seam: produce engine-neutral segments for a mono 16 kHz sample
    /// buffer. Defaults to the real FluidAudio `DiarizerManager` pipeline.
    typealias Diarize = @Sendable ([Float]) async throws -> [DiarizedSegment]

    private static let log = OSLog(subsystem: "com.rootwise.sidekey", category: "local-diarizer")

    /// Input sample rate the diarizer models expect (16 kHz mono).
    static let sampleRate = 16_000

    private let modelStore: any LocalDiarizerModelManaging
    private let diarizeOverride: Diarize?

    init(modelStore: any LocalDiarizerModelManaging = LocalDiarizerModelStore.shared) {
        self.modelStore = modelStore
        self.diarizeOverride = nil
    }

    /// Test seam: inject a deterministic segment producer (no model download).
    init(diarize: @escaping Diarize) {
        self.modelStore = LocalDiarizerModelStore.shared
        self.diarizeOverride = diarize
    }

    /// Diarize a mono 16 kHz audio buffer into speaker turns, ordered by start
    /// time. Segments FluidAudio could not attribute (empty speaker id) are
    /// dropped. Throws `LocalDiarizerError.modelNotDownloaded` if the models
    /// are absent.
    func diarize(samples: [Float]) async throws -> [SpeakerTurn] {
        let start = DispatchTime.now()
        os_log("local diarization: start", log: Self.log, type: .info)

        let segments: [DiarizedSegment]
        if let diarizeOverride {
            segments = try await diarizeOverride(samples)
        } else {
            segments = try await runFluidAudio(samples: samples)
        }

        let turns = segments
            .filter { !$0.speakerId.isEmpty }
            .map { SpeakerTurn(speaker: $0.speakerId, start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let speakerCount = Set(turns.map(\.speaker)).count
        os_log(
            "local diarization: done in %{public}.0f ms (%{public}d speakers, %{public}d turns)",
            log: Self.log, type: .info, elapsedMs, speakerCount, turns.count
        )

        return turns
    }

    private func runFluidAudio(samples: [Float]) async throws -> [DiarizedSegment] {
        guard !samples.isEmpty else { return [] }

        let manager = try await modelStore.loadManager()
        let result = try manager.performCompleteDiarization(samples, sampleRate: Self.sampleRate)
        return result.segments.map {
            DiarizedSegment(
                speakerId: $0.speakerId,
                start: Double($0.startTimeSeconds),
                end: Double($0.endTimeSeconds)
            )
        }
    }
}

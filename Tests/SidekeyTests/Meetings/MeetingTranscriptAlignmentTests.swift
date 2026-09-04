import XCTest
import FluidAudio
@testable import Sidekey

/// Stage 5b alignment: fold the per-track ASR segments (Stage 5a) plus the
/// diarization turns (Stage 4) into a single `[TranscriptSegment]`.
///
/// Contract under test:
/// - every mic segment becomes speaker `"Me"`,
/// - every system segment is labelled `"Speaker N"` by overlapping its time
///   range with the diarization turns (max-overlap wins; raw diarizer ids are
///   renumbered to stable `Speaker 1..N` in first-appearance order),
/// - the merged list is sorted by `start`.
final class MeetingTranscriptAlignmentTests: XCTestCase {

    private func mic(_ text: String, _ start: Double, _ end: Double) -> MeetingASRSegment {
        MeetingASRSegment(text: text, start: start, end: end)
    }

    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn {
        SpeakerTurn(speaker: speaker, start: start, end: end)
    }

    func test_micSegmentsAreLabelledMe() {
        let result = MeetingTranscriptAlignment.align(
            mic: [mic("hi there", 0, 1)],
            system: [],
            diarizationTurns: []
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.speaker, "Me")
        XCTAssertEqual(result.first?.text, "hi there")
        XCTAssertEqual(result.first?.start, 0)
        XCTAssertEqual(result.first?.end, 1)
    }

    func test_systemSegmentsGetSpeakerLabelFromOverlappingTurn() {
        // One system segment 2..4 overlaps a diarizer turn for raw id "spk_7".
        let result = MeetingTranscriptAlignment.align(
            mic: [],
            system: [mic("hello", 2, 4)],
            diarizationTurns: [turn("spk_7", 1.5, 4.5)]
        )

        XCTAssertEqual(result.count, 1)
        // Raw "spk_7" → first-appearance → "Speaker 1".
        XCTAssertEqual(result.first?.speaker, "Speaker 1")
        XCTAssertEqual(result.first?.text, "hello")
    }

    func test_twoSystemSpeakersRenumberedByFirstAppearance() {
        // Diarizer hands back arbitrary ids out of order; first to appear by
        // overlap (earliest system segment) must become Speaker 1.
        let result = MeetingTranscriptAlignment.align(
            mic: [],
            system: [
                mic("first remote", 0, 2),
                mic("second remote", 3, 5),
                mic("first again", 6, 8),
            ],
            diarizationTurns: [
                turn("zulu", 0, 2.5),    // segment 0
                turn("alpha", 2.8, 5.2), // segment 1
                turn("zulu", 5.8, 8.5),  // segment 2 (same raw id as seg 0)
            ]
        )

        XCTAssertEqual(result.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 1"])
        XCTAssertEqual(result.map(\.text), ["first remote", "second remote", "first again"])
    }

    func test_maxOverlapWinsWhenTurnsStraddleSegment() {
        // Segment 4..10 (6s). Turn A overlaps 4..5 (1s); turn B overlaps 5..10
        // (5s). Max-overlap → turn B's speaker.
        let result = MeetingTranscriptAlignment.align(
            mic: [],
            system: [mic("straddled", 4, 10)],
            diarizationTurns: [
                turn("A", 0, 5),
                turn("B", 5, 12),
            ]
        )

        // "A" appears first in the turns list but does NOT win the overlap, so
        // the assigned id is "B". First label assigned overall → "Speaker 1".
        XCTAssertEqual(result.first?.speaker, "Speaker 1")
    }

    func test_systemSegmentWithNoOverlapFallsBackToUnknownSpeaker() {
        // No diarizer turn overlaps this segment → it still must render with a
        // non-empty speaker so the transcript tab never shows "** [..]:**".
        let result = MeetingTranscriptAlignment.align(
            mic: [],
            system: [mic("orphan", 100, 102)],
            diarizationTurns: [turn("A", 0, 5)]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.speaker, "Speaker 1")
        XCTAssertEqual(result.first?.text, "orphan")
    }

    func test_micAndSystemMergedAndSortedByStart() {
        let result = MeetingTranscriptAlignment.align(
            mic: [
                mic("me at 1", 1, 2),
                mic("me at 5", 5, 6),
            ],
            system: [
                mic("remote at 0", 0, 0.9),
                mic("remote at 3", 3, 4),
            ],
            diarizationTurns: [
                turn("X", 0, 1),
                turn("X", 3, 4),
            ]
        )

        XCTAssertEqual(
            result.map(\.text),
            ["remote at 0", "me at 1", "remote at 3", "me at 5"]
        )
        XCTAssertEqual(
            result.map(\.speaker),
            ["Speaker 1", "Me", "Speaker 1", "Me"]
        )
        // Strictly non-decreasing starts.
        let starts = result.map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    func test_emptyInputsYieldEmptyTranscript() {
        XCTAssertTrue(
            MeetingTranscriptAlignment.align(mic: [], system: [], diarizationTurns: []).isEmpty
        )
    }

    // MARK: - Per-turn re-segmentation (FIX 1: real transcriber output shape)

    private func token(_ text: String, _ start: Double, _ end: Double) -> MeetingASRToken {
        MeetingASRToken(text: text, start: start, end: end)
    }

    /// The system track is RE-SEGMENTED by diarizer turn: a single whole-track
    /// ASR span carrying per-token timings, when two diarizer turns cover
    /// different time ranges, must split into one `Speaker N` segment per turn —
    /// not collapse into one speaker.
    func test_systemTokensReSegmentByTurn_multipleSpeakersFromOneTrack() {
        // One contiguous system utterance, four tokens. Tokens 0..1 fall in
        // turn "alpha" (0..2), tokens 2..3 fall in turn "bravo" (2..4).
        let systemTokens = [
            token(" hello", 0.1, 0.6),
            token(" there", 0.7, 1.4),
            token(" general", 2.1, 2.6),
            token(" kenobi", 2.7, 3.4),
        ]
        let result = MeetingTranscriptAlignment.align(
            mic: [],
            systemTokens: systemTokens,
            diarizationTurns: [
                SpeakerTurn(speaker: "alpha", start: 0, end: 2),
                SpeakerTurn(speaker: "bravo", start: 2, end: 4),
            ]
        )

        let distinctSpeakers = Set(result.compactMap(\.speaker))
        XCTAssertGreaterThan(
            distinctSpeakers.count, 1,
            "two diarizer turns over one system track must yield >1 Speaker N"
        )
        XCTAssertEqual(result.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(result.map(\.text), ["hello there", "general kenobi"])
        XCTAssertEqual(result.first?.start ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(result.last?.end ?? -1, 3.4, accuracy: 0.0001)
    }

    /// End-to-end through the REAL transcriber output shape: the system track's
    /// `ASRResult` produces ONE whole-track segment (what `makeSegments` really
    /// returns) PLUS the per-token timings, and that token stream — fed into
    /// alignment with three diarizer turns spanning distinct ranges — yields
    /// more than one distinct `Speaker N`. This is the gap the prior tests hid:
    /// they injected pre-split multi-segment system lists the transcriber never
    /// produces, so a single-speaker collapse passed unnoticed.
    func test_realTranscriberShape_systemTrackYieldsMultipleSpeakers() async throws {
        let systemTokens: [(String, Double, Double)] = [
            (" let", 0.2, 0.5), ("'s", 0.5, 0.7), (" begin", 0.8, 1.3),
            (" sounds", 3.1, 3.6), (" good", 3.7, 4.2),
            (" agreed", 6.1, 6.8),
        ]
        let timings = systemTokens.enumerated().map { i, t in
            TokenTiming(token: t.0, tokenId: i, startTime: t.1, endTime: t.2, confidence: 1)
        }
        let realResult = ASRResult(
            text: "let's begin sounds good agreed",
            confidence: 1,
            duration: 7.0,
            processingTime: 0.1,
            tokenTimings: timings
        )

        // Drive the REAL transcriber: one system segment + the token stream.
        let engine = ConstantASREngine(result: realResult)
        let transcriber = MeetingLocalTranscriber(engine: engine, language: nil)
        let transcript = try await transcriber.transcribe(
            micSamples: [],
            systemSamples: [0.5, 0.5, 0.5]
        )

        // The transcriber really returns ONE whole-track system segment …
        XCTAssertEqual(transcript.system.count, 1, "transcriber collapses to one whole-track span")
        // … but ALSO the per-token stream alignment uses to re-segment.
        XCTAssertEqual(transcript.systemTokens.count, timings.count)

        let merged = MeetingTranscriptAlignment.align(
            mic: transcript.mic,
            systemTokens: transcript.systemTokens,
            diarizationTurns: [
                SpeakerTurn(speaker: "spkA", start: 0, end: 2),
                SpeakerTurn(speaker: "spkB", start: 3, end: 5),
                SpeakerTurn(speaker: "spkC", start: 6, end: 8),
            ]
        )

        let distinct = Set(merged.compactMap(\.speaker))
        XCTAssertGreaterThan(distinct.count, 1, "one system track + 3 turns must produce >1 Speaker N")
        XCTAssertEqual(merged.map(\.speaker), ["Speaker 1", "Speaker 2", "Speaker 3"])
        XCTAssertEqual(merged.map(\.text), ["let's begin", "sounds good", "agreed"])
    }
}

/// Minimal ASR engine that returns a fixed result for any track (used to drive
/// the REAL `MeetingLocalTranscriber` over a synthetic `ASRResult`).
private actor ConstantASREngine: MeetingASRTranscribing {
    private let result: ASRResult
    init(result: ASRResult) { self.result = result }
    func transcribe(samples: [Float], language: Language?) async throws -> ASRResult {
        result
    }
}

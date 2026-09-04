import Foundation

/// Stage 5b: fold the mic ASR segments (Stage 5a) and the SYSTEM track's
/// per-token timings + diarization turns (Stage 4) into a single diarized
/// `[TranscriptSegment]` the notes window renders.
///
/// Speaker attribution rule:
/// - Mic-track segments are the local user → labelled `"Me"` unconditionally
///   (the mic track is captured from this device's microphone, so it is
///   always the same person; diarizing it would be wasted work).
/// - The system track is RE-SEGMENTED by diarizer turn into `"Speaker N"`.
///   The transcriber returns the system track as ONE whole-track span plus its
///   per-token timings; a single span cannot represent multiple remote
///   speakers, so we walk the tokens, assign each to the diarizer turn it
///   overlaps the MOST (max-overlap), and group consecutive same-turn tokens
///   into one segment per turn. Raw diarizer ids are renumbered into stable
///   `Speaker 1..N` in first-appearance order so the notes read "Speaker 1",
///   "Speaker 2", … rather than the diarizer's internal ids. This is what makes
///   a single system track yield multiple speakers.
///
/// Pure function — no I/O, no global state, fully unit-tested. Deliberately
/// kept out of `MeetingLocalProcessor` so the (subtle) overlap/renumber logic
/// can be exercised in isolation without the model pipeline.
enum MeetingTranscriptAlignment {

    /// Label used for the local microphone track.
    static let meSpeakerLabel = "Me"

    /// Fallback label for a system segment that no diarization turn overlaps
    /// (e.g. diarization produced no turn for that span). Renders as a normal
    /// remote speaker so the transcript never shows an empty `**  []:**`.
    private static let fallbackRemoteRawId = "__unattributed__"

    /// Merge mic segments + the system track's per-token timings into a single
    /// diarized, start-sorted transcript. The system track is re-segmented by
    /// diarizer turn (see the type doc). This is the production entry point used
    /// by `MeetingLocalProcessor`.
    static func align(
        mic: [MeetingASRSegment],
        systemTokens: [MeetingASRToken],
        diarizationTurns: [SpeakerTurn]
    ) -> [TranscriptSegment] {
        let meSegments = mic.map { segment in
            TranscriptSegment(
                speaker: meSpeakerLabel,
                start: segment.start,
                end: segment.end,
                text: segment.text
            )
        }

        let remoteSegments = reSegmentSystemByTurn(
            tokens: systemTokens,
            turns: diarizationTurns
        )

        // Mic + system are interleaved by start time. This assumes both tracks
        // share a common time origin (recorder captures mic and system
        // concurrently into the same recording timeline). Best-effort: if the
        // system WAV omits leading silence the two clocks can drift slightly, so
        // cross-track ordering near simultaneous speech is approximate. Speaker
        // ATTRIBUTION (Me vs Speaker N) is unaffected — it is intra-track.
        return (meSegments + remoteSegments).sorted { $0.start < $1.start }
    }

    /// Legacy/segment-based overload: merge mic + already-segmented system ASR
    /// segments by max-overlap turn. Retained for tests that inject pre-split
    /// system segments directly. The production path uses the token-based
    /// overload above so a single system track can split across speakers.
    static func align(
        mic: [MeetingASRSegment],
        system: [MeetingASRSegment],
        diarizationTurns: [SpeakerTurn]
    ) -> [TranscriptSegment] {
        let meSegments = mic.map { segment in
            TranscriptSegment(
                speaker: meSpeakerLabel,
                start: segment.start,
                end: segment.end,
                text: segment.text
            )
        }

        // First pass: resolve each system segment to a RAW diarizer id (or the
        // fallback) so the renumber pass below can assign stable labels in the
        // order the speakers first appear across the time-sorted system track.
        let systemByStart = system.sorted { $0.start < $1.start }
        let rawIds = systemByStart.map { segment in
            overlappingRawSpeakerId(
                start: segment.start, end: segment.end, turns: diarizationTurns
            )
        }
        let labels = renumber(rawIds)

        let remoteSegments = zip(systemByStart, labels).map { segment, label in
            TranscriptSegment(
                speaker: label,
                start: segment.start,
                end: segment.end,
                text: segment.text
            )
        }

        return (meSegments + remoteSegments).sorted { $0.start < $1.start }
    }

    // MARK: - System re-segmentation by diarizer turn

    /// Walk the system track's tokens in time order, tag each with the raw
    /// diarizer id of the turn it overlaps the most, then group RUNS of
    /// consecutive same-id tokens into one segment per run. Each run becomes a
    /// `TranscriptSegment` whose text is the tokens reconstructed (the engine
    /// already normalized `▁`→leading-space, so joining + trimming yields
    /// readable text) and whose span is [first token start, last token end].
    /// Raw ids are renumbered to stable `Speaker 1..N` by first appearance.
    ///
    /// Grouping by RUN (not by id) means a speaker who talks, yields, then
    /// talks again produces two segments under the same label — preserving
    /// conversational order — exactly like the diarized cloud transcript.
    private static func reSegmentSystemByTurn(
        tokens: [MeetingASRToken],
        turns: [SpeakerTurn]
    ) -> [TranscriptSegment] {
        guard !tokens.isEmpty else { return [] }
        let ordered = tokens.sorted { $0.start < $1.start }

        // Tag each token with its max-overlap raw id, then collapse consecutive
        // equal ids into runs.
        var runs: [(rawId: String, tokens: [MeetingASRToken])] = []
        for token in ordered {
            let rawId = overlappingRawSpeakerId(
                start: token.start, end: token.end, turns: turns
            )
            if var last = runs.last, last.rawId == rawId {
                last.tokens.append(token)
                runs[runs.count - 1] = last
            } else {
                runs.append((rawId: rawId, tokens: [token]))
            }
        }

        // Renumber raw ids → stable Speaker N in first-appearance order.
        let labels = renumber(runs.map(\.rawId))

        return zip(runs, labels).compactMap { run, label -> TranscriptSegment? in
            let text = reconstructText(from: run.tokens)
            guard !text.isEmpty else { return nil }
            let start = run.tokens.first?.start ?? 0
            let end = run.tokens.last?.end ?? start
            return TranscriptSegment(
                speaker: label,
                start: start,
                end: max(start, end),
                text: text
            )
        }
    }

    /// Reconstruct readable text from a run of tokens. The engine emits each
    /// token with a leading space at word boundaries (SentencePiece `▁`
    /// normalized to a space upstream), so concatenating the raw token strings
    /// reproduces the spacing; we then collapse any accidental double spaces and
    /// trim the edges.
    private static func reconstructText(from tokens: [MeetingASRToken]) -> String {
        let joined = tokens.map(\.text).joined()
        let collapsed = joined
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
    }

    // MARK: - Private

    /// The raw diarizer speaker id whose turn overlaps the interval
    /// `[start, end)` the most. When no turn overlaps at all, returns the shared
    /// fallback id so every system segment/token still renders with a speaker
    /// label.
    private static func overlappingRawSpeakerId(
        start: Double,
        end: Double,
        turns: [SpeakerTurn]
    ) -> String {
        var bestId: String?
        var bestOverlap = 0.0

        for turn in turns {
            let overlap = overlapSeconds(
                aStart: start, aEnd: end,
                bStart: turn.start, bEnd: turn.end
            )
            // Strictly-greater keeps the FIRST turn in list order when two
            // overlaps tie, which is deterministic and stable.
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestId = turn.speaker
            }
        }

        return bestId ?? fallbackRemoteRawId
    }

    /// Overlap (in seconds) of the two half-open intervals `[aStart, aEnd)` and
    /// `[bStart, bEnd)`. Zero when they do not intersect.
    private static func overlapSeconds(
        aStart: Double, aEnd: Double,
        bStart: Double, bEnd: Double
    ) -> Double {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    /// Map raw diarizer ids to stable `Speaker N` labels by first appearance.
    private static func renumber(_ rawIds: [String]) -> [String] {
        var mapping: [String: String] = [:]
        var next = 1
        return rawIds.map { rawId in
            if let existing = mapping[rawId] { return existing }
            let label = "Speaker \(next)"
            mapping[rawId] = label
            next += 1
            return label
        }
    }
}

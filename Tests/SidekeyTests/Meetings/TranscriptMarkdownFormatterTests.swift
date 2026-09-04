import XCTest
@testable import Sidekey

/// Pure-function tests for `TranscriptMarkdownFormatter` — turns a
/// Soniox diarized `[TranscriptSegment]` into the same markdown shape
/// the backend used to inline as a "## Transcript" section, so the
/// meeting Transcribe tab renders through the same BlockNote pipeline
/// as the Note tab.
final class TranscriptMarkdownFormatterTests: XCTestCase {

    func test_empty_returnsEmptyString() {
        XCTAssertEqual(
            TranscriptMarkdownFormatter.format([]),
            ""
        )
    }

    func test_singleSegment_rendersSpeakerBoldWithCompactTimestampRangeAndText() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 1", start: 2.0, end: 4.0, text: "Алло.")
        ]
        XCTAssertEqual(
            TranscriptMarkdownFormatter.format(segments),
            "**Speaker 1 [00:02-00:04]:** Алло."
        )
    }

    func test_twoSegments_separatedByBlankLine() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 1", start: 2.0, end: 4.0, text: "Алло."),
            TranscriptSegment(speaker: "Speaker 2", start: 3.0, end: 6.0,
                              text: "Доброе утро. Что случилось?")
        ]
        XCTAssertEqual(
            TranscriptMarkdownFormatter.format(segments),
            """
            **Speaker 1 [00:02-00:04]:** Алло.

            **Speaker 2 [00:03-00:06]:** Доброе утро. Что случилось?
            """
        )
    }

    func test_speakerNil_fallsBackToUnknownSpeakerLabel() {
        let segments = [
            TranscriptSegment(speaker: nil, start: 0.0, end: 1.0, text: "Hello.")
        ]
        XCTAssertEqual(
            TranscriptMarkdownFormatter.format(segments),
            "**Unknown [00:00-00:01]:** Hello."
        )
    }

    func test_timestamp_floorsToWholeSeconds() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 1", start: 119.9, end: 120.0,
                              text: "Done.")
        ]
        XCTAssertEqual(
            TranscriptMarkdownFormatter.format(segments),
            "**Speaker 1 [01:59-02:00]:** Done.",
            "01:59-02:00 — floor at the whole second to avoid a start-time jump from ms drift."
        )
    }

    func test_timestamp_minuteBoundary() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 1", start: 60.0, end: 61.0, text: "Tick.")
        ]
        XCTAssertEqual(
            TranscriptMarkdownFormatter.format(segments),
            "**Speaker 1 [01:00-01:01]:** Tick."
        )
    }

    func test_timestamp_overTenMinutes_keepsMMSSFormat() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 1", start: 723.0, end: 725.0,
                              text: "Twelve oh three.")
        ]
        XCTAssertEqual(
            TranscriptMarkdownFormatter.format(segments),
            "**Speaker 1 [12:03-12:05]:** Twelve oh three."
        )
    }

    /// Soniox can return labels like "Speaker 1 (Даша)" — backend's
    /// diarization decoration already lives in the speaker string. The
    /// formatter must pass it through verbatim.
    func test_speakerWithDecoratedName_preservedVerbatim() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 3 (Даша)", start: 12.0, end: 13.0,
                              text: "Стартую.")
        ]
        XCTAssertEqual(
            TranscriptMarkdownFormatter.format(segments),
            "**Speaker 3 (Даша) [00:12-00:13]:** Стартую."
        )
    }

    /// Free-form transcript text can legitimately contain `*` / `_` / `[`
    /// — characters BlockNote/CommonMark would otherwise interpret as
    /// emphasis or link syntax and silently consume. We don't reach for
    /// a full escaper here (BlockNote uses tryParseMarkdownToBlocks which
    /// is tolerant of stray markers); the smoke test below pins that the
    /// formatter does NOT crash and keeps the user's characters in the
    /// output verbatim.
    func test_textWithMarkdownChars_preservedInOutput() {
        let segments = [
            TranscriptSegment(speaker: "Speaker 1", start: 0.0, end: 1.0,
                              text: "Use *foo* and [bar] in the spec.")
        ]
        let out = TranscriptMarkdownFormatter.format(segments)
        XCTAssertTrue(out.contains("*foo*"))
        XCTAssertTrue(out.contains("[bar]"))
    }
}

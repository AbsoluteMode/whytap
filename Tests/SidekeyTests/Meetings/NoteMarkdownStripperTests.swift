import XCTest
@testable import Sidekey

/// Pure-function tests for `NoteMarkdownStripper`. The meeting backend
/// currently inlines a "## Transcript" section at the bottom of the
/// LLM summary markdown; the new Transcribe tab renders that same
/// content from the separate `transcriptJson` payload, so the Note
/// tab needs to strip the inlined section to avoid showing the
/// transcript twice.
final class NoteMarkdownStripperTests: XCTestCase {

    func test_emptyString_returnsEmpty() {
        XCTAssertEqual(NoteMarkdownStripper.stripTranscript(""), "")
    }

    func test_noTranscriptSection_returnedUnchanged() {
        let md = """
        # Title

        ## Summary

        - bullet

        ## Action items

        - [ ] do thing
        """
        XCTAssertEqual(NoteMarkdownStripper.stripTranscript(md), md)
    }

    func test_transcriptSectionAtEnd_isStripped() {
        let md = """
        # Title

        ## Summary

        - bullet

        ## Transcript

        **Speaker 1 [00:02]:** Алло.

        **Speaker 2 [00:03]:** Hi.
        """
        let expected = """
        # Title

        ## Summary

        - bullet
        """
        XCTAssertEqual(NoteMarkdownStripper.stripTranscript(md), expected)
    }

    func test_transcriptSectionInMiddle_isStrippedAlongWithEverythingAfter() {
        let md = """
        # Title

        ## Transcript

        ...words...

        ## Trailing section

        Should be dropped too.
        """
        let expected = """
        # Title
        """
        XCTAssertEqual(NoteMarkdownStripper.stripTranscript(md), expected)
    }

    /// `## Transcript` must only match a heading line. Inline text
    /// mentioning the word, or a heading like `### Transcript notes`,
    /// must NOT trigger the strip.
    func test_inlineMentionOfTranscript_doesNotStrip() {
        let md = """
        # Title

        The transcript will be available in the Transcribe tab.

        ## Summary

        - bullet
        """
        XCTAssertEqual(NoteMarkdownStripper.stripTranscript(md), md)
    }

    func test_thirdLevelTranscriptHeading_doesNotStrip() {
        let md = """
        ## Summary

        ### Transcript subsection

        - bullet
        """
        XCTAssertEqual(NoteMarkdownStripper.stripTranscript(md), md)
    }

    /// The stripper must tolerate trailing whitespace on the heading
    /// line (`## Transcript  `) — markdown editors sometimes add it.
    func test_trailingWhitespaceOnHeading_stillStrips() {
        let md = "# Title\n\n## Transcript   \n\nsome text"
        XCTAssertEqual(NoteMarkdownStripper.stripTranscript(md), "# Title")
    }

    /// Real backend output from production (94E8009C). The stripper
    /// should leave the summary, action items, etc. intact and drop
    /// the inlined transcript at the bottom.
    func test_productionNoteShape_stripsTranscriptKeepsBody() {
        let md = """
        # Создание подстраницы в Notion

        ## Резюме

        - точка 1
        - точка 2

        ## Решения

        - решение 1

        ## Action items

        - [ ] @Speaker 1 — сделать что-то

        ## Transcript

        **Speaker 1 [00:02]:** Алло.

        **Speaker 2 [00:03]:** Доброе утро.
        """
        let stripped = NoteMarkdownStripper.stripTranscript(md)
        XCTAssertFalse(stripped.contains("## Transcript"))
        XCTAssertFalse(stripped.contains("**Speaker 1"))
        XCTAssertTrue(stripped.contains("# Создание подстраницы в Notion"))
        XCTAssertTrue(stripped.contains("## Action items"))
        XCTAssertTrue(stripped.contains("@Speaker 1 — сделать что-то"))
    }
}

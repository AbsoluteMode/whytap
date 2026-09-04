import XCTest
@testable import Sidekey

/// Contract for the native protocol renderer's markdown → `[NoteBlock]`
/// parser. Covers exactly the shapes the backend LLM emits for summaries
/// plus the diarized transcript format.
final class MeetingNoteMarkdownParserTests: XCTestCase {

    private func plain(_ attr: AttributedString) -> String {
        String(attr.characters)
    }

    func test_headings_levels_one_to_three() {
        let blocks = MeetingNoteMarkdownParser.parse("# Title\n## Section\n### Sub")
        XCTAssertEqual(blocks.count, 3)
        guard case let .heading(l1, t1) = blocks[0] else { return XCTFail("h1") }
        XCTAssertEqual(l1, 1); XCTAssertEqual(plain(t1), "Title")
        guard case let .heading(l2, t2) = blocks[1] else { return XCTFail("h2") }
        XCTAssertEqual(l2, 2); XCTAssertEqual(plain(t2), "Section")
        guard case let .heading(l3, t3) = blocks[2] else { return XCTFail("h3") }
        XCTAssertEqual(l3, 3); XCTAssertEqual(plain(t3), "Sub")
    }

    func test_deep_headings_capped_at_level_three() {
        let blocks = MeetingNoteMarkdownParser.parse("##### Deep")
        guard case let .heading(level, text) = blocks.first else { return XCTFail("heading") }
        XCTAssertEqual(level, 3)
        XCTAssertEqual(plain(text), "Deep")
    }

    func test_bullets_with_dash_star_plus() {
        let blocks = MeetingNoteMarkdownParser.parse("- one\n* two\n+ three")
        XCTAssertEqual(blocks.count, 3)
        for (i, expected) in ["one", "two", "three"].enumerated() {
            guard case let .bullet(text) = blocks[i] else { return XCTFail("bullet \(i)") }
            XCTAssertEqual(plain(text), expected)
        }
    }

    func test_numbered_list() {
        let blocks = MeetingNoteMarkdownParser.parse("1. first\n2. second\n10. tenth")
        XCTAssertEqual(blocks.count, 3)
        guard case let .numbered(i0, t0) = blocks[0] else { return XCTFail("n0") }
        XCTAssertEqual(i0, 1); XCTAssertEqual(plain(t0), "first")
        guard case let .numbered(i2, t2) = blocks[2] else { return XCTFail("n2") }
        XCTAssertEqual(i2, 10); XCTAssertEqual(plain(t2), "tenth")
    }

    func test_checkboxes_checked_and_unchecked() {
        let blocks = MeetingNoteMarkdownParser.parse("- [ ] todo\n- [x] done\n- [X] also done")
        XCTAssertEqual(blocks.count, 3)
        guard case let .checkbox(c0, t0) = blocks[0] else { return XCTFail("cb0") }
        XCTAssertFalse(c0); XCTAssertEqual(plain(t0), "todo")
        guard case let .checkbox(c1, _) = blocks[1] else { return XCTFail("cb1") }
        XCTAssertTrue(c1)
        guard case let .checkbox(c2, _) = blocks[2] else { return XCTFail("cb2") }
        XCTAssertTrue(c2)
    }

    func test_paragraph_and_blank_line_separation() {
        let blocks = MeetingNoteMarkdownParser.parse("Hello world\n\nSecond para")
        XCTAssertEqual(blocks.count, 2)
        guard case let .paragraph(p0) = blocks[0] else { return XCTFail("p0") }
        XCTAssertEqual(plain(p0), "Hello world")
        guard case let .paragraph(p1) = blocks[1] else { return XCTFail("p1") }
        XCTAssertEqual(plain(p1), "Second para")
    }

    func test_consecutive_plain_lines_join_into_one_paragraph() {
        let blocks = MeetingNoteMarkdownParser.parse("line one\nline two")
        XCTAssertEqual(blocks.count, 1)
        guard case let .paragraph(p) = blocks[0] else { return XCTFail("paragraph") }
        XCTAssertEqual(plain(p), "line one line two")
    }

    func test_divider() {
        let blocks = MeetingNoteMarkdownParser.parse("a\n\n---\n\nb")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .divider)
    }

    func test_inline_bold_preserved_as_plain_text() {
        // Transcript shape: "**Speaker [00:02-00:04]:** Hi"
        let blocks = MeetingNoteMarkdownParser.parse("**Speaker 1 [00:02-00:04]:** Hi there")
        guard case let .paragraph(p) = blocks.first else { return XCTFail("paragraph") }
        // The bold markers are consumed; visible text remains intact.
        XCTAssertEqual(plain(p), "Speaker 1 [00:02-00:04]: Hi there")
        // And at least one run carries strong emphasis.
        let hasStrong = p.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        XCTAssertTrue(hasStrong, "Bold markers must produce a strongly-emphasized run.")
    }

    func test_numbered_falsePositive_periodInProse_staysParagraph() {
        let blocks = MeetingNoteMarkdownParser.parse("See item. More text.")
        guard case .paragraph = blocks.first else {
            return XCTFail("Prose with a period must not become a numbered item.")
        }
    }

    func test_empty_input_yields_no_blocks() {
        XCTAssertTrue(MeetingNoteMarkdownParser.parse("").isEmpty)
        XCTAssertTrue(MeetingNoteMarkdownParser.parse("\n\n  \n").isEmpty)
    }
}

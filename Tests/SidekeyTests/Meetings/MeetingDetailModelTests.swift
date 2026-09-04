import XCTest
@testable import Sidekey

/// Edit flow of the native protocol detail: commit re-renders locally and
/// persists with the base version; cancel discards without persisting.
@MainActor
final class MeetingDetailModelTests: XCTestCase {

    func test_load_populates_note_markdown_and_version() {
        let model = MeetingDetailModel()
        let id = UUID()
        model.load(
            id: id,
            noteMarkdown: "# Title",
            noteBlocks: MeetingNoteMarkdownParser.parse("# Title"),
            transcriptBlocks: [],
            hasTranscript: false,
            version: 4
        )
        XCTAssertEqual(model.currentMeetingId, id)
        XCTAssertEqual(model.version, 4)
        XCTAssertEqual(model.noteMarkdown, "# Title")
        XCTAssertFalse(model.isEditing)
        XCTAssertNil(model.unavailableMessage)
        XCTAssertFalse(model.unavailableIsLoading)
    }

    func test_loadUnavailable_replacesPreviousMeetingContentAndIdentity() {
        let model = MeetingDetailModel()
        let previous = UUID()
        let failed = UUID()
        model.load(
            id: previous,
            noteMarkdown: "# Previous meeting",
            noteBlocks: MeetingNoteMarkdownParser.parse("# Previous meeting"),
            transcriptBlocks: MeetingNoteMarkdownParser.parse("Old transcript"),
            hasTranscript: true,
            version: 9
        )
        model.isEditing = true

        model.loadUnavailable(id: failed, message: "Recording is safe")

        XCTAssertEqual(model.currentMeetingId, failed)
        XCTAssertEqual(model.unavailableMessage, "Recording is safe")
        XCTAssertEqual(model.noteMarkdown, "")
        XCTAssertTrue(model.noteBlocks.isEmpty)
        XCTAssertTrue(model.transcriptBlocks.isEmpty)
        XCTAssertFalse(model.hasTranscript)
        XCTAssertFalse(model.isEditing)
        XCTAssertFalse(model.unavailableIsLoading)
    }

    func test_loadUnavailable_marksTransientLoadingSeparatelyFromFailure() {
        let model = MeetingDetailModel()

        model.loadUnavailable(id: UUID(), message: "Loading", isLoading: true)

        XCTAssertTrue(model.unavailableIsLoading)
        model.loadUnavailable(id: UUID(), message: "Failed")
        XCTAssertFalse(model.unavailableIsLoading)
    }

    func test_commitEdit_reparses_blocks_and_persists_with_base_version() {
        let model = MeetingDetailModel()
        var saved: (markdown: String, version: Int)?
        model.onSave = { markdown, version in saved = (markdown, version) }
        model.load(
            id: UUID(),
            noteMarkdown: "old",
            noteBlocks: MeetingNoteMarkdownParser.parse("old"),
            transcriptBlocks: [],
            hasTranscript: false,
            version: 2
        )
        model.isEditing = true

        model.commitEdit("## New section\n- point")

        XCTAssertEqual(model.noteMarkdown, "## New section\n- point")
        XCTAssertFalse(model.isEditing)
        guard case let .heading(level, _) = model.noteBlocks.first else {
            return XCTFail("commit must re-render: first block should be the new heading")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(saved?.markdown, "## New section\n- point")
        XCTAssertEqual(saved?.version, 2, "Edit must persist against the loaded base version.")
    }

    func test_cancelEdit_keeps_markdown_and_does_not_persist() {
        let model = MeetingDetailModel()
        var saveCount = 0
        model.onSave = { _, _ in saveCount += 1 }
        model.load(
            id: UUID(),
            noteMarkdown: "keep me",
            noteBlocks: MeetingNoteMarkdownParser.parse("keep me"),
            transcriptBlocks: [],
            hasTranscript: false,
            version: 1
        )
        model.isEditing = true

        model.cancelEdit()

        XCTAssertFalse(model.isEditing)
        XCTAssertEqual(model.noteMarkdown, "keep me")
        XCTAssertEqual(saveCount, 0)
    }

    func test_shareCurrentNote_sends_formatted_markdown_attachment_payload_to_share_presenter() {
        var shared: [MeetingSharePayload] = []
        let model = MeetingDetailModel(
            meetingSharePresenter: { shared.append($0) }
        )
        model.load(
            id: UUID(),
            noteMarkdown: """
            <!-- protocol:v1 -->
            # Weekly sync

            Quick alignment.

            ## Tasks
            - Ship the onboarding PR — Maxim — Fri

            ## Decisions
            - Keep native share for V1

            ## Other
            """,
            noteBlocks: [],
            transcriptBlocks: [],
            hasTranscript: false,
            version: 1
        )

        model.shareCurrentNote()

        XCTAssertEqual(shared.map(\.markdown), [
            """
            # Weekly sync

            Quick alignment.

            ## Tasks
            - [ ] Ship the onboarding PR
              - Assignee: Maxim
              - Deadline: Fri

            ## Decisions
            - Keep native share for V1
            """
        ])
        XCTAssertEqual(shared.map(\.attachmentFileName), ["Weekly sync.md"])
    }
}

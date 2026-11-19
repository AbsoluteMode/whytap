import XCTest
@testable import Sidekey

/// The note pane of a meeting whose transcript exists but whose note does
/// not: the Transcript tab works, the Note tab says why and offers a retry,
/// and nothing of it can be edited or carried into the next meeting.
@MainActor
final class MeetingKeptTranscriptViewTests: XCTestCase {
    private let transcript = [
        TranscriptSegment(speaker: "Speaker 1", start: 0, end: 3, text: "We ship on Friday."),
    ]

    func test_failed_meeting_with_a_kept_transcript_opens_its_transcript_tab_and_offers_retry() {
        let view = MeetingsDetailView(bundleURL: nil, bundleAccessRoot: nil)
        var states: [(Int, Bool)] = []
        view.onTabState = { states.append(($0, $1)) }
        var retried = 0

        view.loadUnavailableMeeting(
            id: UUID(), message: "The Meeting notes provider is out of credit.",
            transcript: transcript, onRetryNotes: { retried += 1 }
        )

        XCTAssertEqual(view.currentTab, .note)
        XCTAssertEqual(states.last?.1, true, "the Transcript tab is enabled")
        view.showTab(.transcribe)
        XCTAssertEqual(view.currentTab, .transcribe)
        XCTAssertFalse(view.isEditing, "a missing note cannot be edited")
        _ = retried
    }

    func test_background_refresh_leaves_the_reader_on_the_transcript_tab() {
        let view = MeetingsDetailView(bundleURL: nil, bundleAccessRoot: nil)
        let id = UUID()
        view.loadUnavailableMeeting(id: id, message: "Out of credit.", transcript: transcript)
        view.showTab(.transcribe)

        view.loadUnavailableMeeting(id: id, message: "Out of credit.", transcript: transcript, preservingTab: true)
        XCTAssertEqual(view.currentTab, .transcribe)

        view.loadUnavailableMeeting(id: UUID(), message: "Out of credit.", transcript: transcript, preservingTab: true)
        XCTAssertEqual(view.currentTab, .note, "another meeting opens on its Note tab")
    }

    func test_meeting_without_a_kept_transcript_keeps_the_transcript_tab_disabled() {
        let view = MeetingsDetailView(bundleURL: nil, bundleAccessRoot: nil)
        var states: [(Int, Bool)] = []
        view.onTabState = { states.append(($0, $1)) }

        view.loadUnavailableMeeting(id: UUID(), message: "The recording is saved and is being transcribed.")

        XCTAssertEqual(states.last?.1, false)
        view.showTab(.transcribe)
        XCTAssertEqual(view.currentTab, .note)
    }

    func test_model_keeps_the_note_empty_and_drops_the_retry_when_another_meeting_loads() {
        let model = MeetingDetailModel()
        model.loadUnavailable(id: UUID(), message: "Out of credit.")
        model.attachKeptTranscript(blocks: MeetingNoteMarkdownParser.parse("Speaker 1: hello"), copyText: "Speaker 1: hello")
        model.onRetryNotes = {}

        XCTAssertTrue(model.hasTranscript)
        XCTAssertTrue(model.noteMarkdown.isEmpty)
        XCTAssertNotNil(model.unavailableMessage)
        let pasteboard = NSPasteboard.withUniqueName()
        model.copyTranscript(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Speaker 1: hello")

        model.load(id: UUID(), noteMarkdown: "# Note", noteBlocks: [], transcriptBlocks: [],
                   hasTranscript: false, version: 1)
        XCTAssertNil(model.onRetryNotes, "a stored note has nothing to retry")
        XCTAssertNil(model.unavailableMessage)

        model.loadUnavailable(id: UUID(), message: "Processing")
        XCTAssertFalse(model.hasTranscript, "the previous meeting's transcript is gone")
        XCTAssertNil(model.onRetryNotes)
    }
}

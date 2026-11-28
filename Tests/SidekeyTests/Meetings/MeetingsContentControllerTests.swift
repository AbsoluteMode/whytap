import AppKit
import XCTest
@testable import Sidekey

@MainActor
final class MeetingsContentControllerTests: XCTestCase {
    final class StubSource: MeetingsSidebarSource, @unchecked Sendable {
        private let meetings: [MeetingMetaWithLocalState]

        init(meetings: [MeetingMetaWithLocalState]) {
            self.meetings = meetings
        }

        func loadList() async throws -> [MeetingMetaWithLocalState] {
            meetings
        }
    }

    /// New behaviour: Notes opens on the list screen — `refreshOnShow()` must NOT
    /// auto-select a meeting into the editor.
    func test_refreshOnShow_opensListWithoutSelectingMeeting() async {
        let newest = UUID()
        let older = UUID()
        let meetings = [
            makeMeeting(id: newest, startedAt: Date(timeIntervalSince1970: 200)),
            makeMeeting(id: older, startedAt: Date(timeIntervalSince1970: 100)),
        ]
        let controller = MeetingsContentController(
            source: StubSource(meetings: meetings),
            markdownProvider: { id in "# Meeting \(id.uuidString)" },
            transcriptProvider: { _ in nil },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil
        )

        _ = controller.view
        controller.refreshOnShow()

        // Give any async work a moment; the editor must stay empty (list screen).
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(controller.currentMeetingId)
    }

    /// Selecting a meeting navigates into the editor and loads it.
    func test_selectMeeting_loadsIntoEditor() async {
        let target = UUID()
        let other = UUID()
        let meetings = [
            makeMeeting(id: target, startedAt: Date(timeIntervalSince1970: 200)),
            makeMeeting(id: other, startedAt: Date(timeIntervalSince1970: 100)),
        ]
        let controller = MeetingsContentController(
            source: StubSource(meetings: meetings),
            markdownProvider: { id in "# Meeting \(id.uuidString)" },
            transcriptProvider: { _ in nil },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil
        )

        _ = controller.view
        controller.selectMeeting(id: target)

        await waitUntil { controller.currentMeetingId == target }
        XCTAssertEqual(controller.currentMeetingId, target)
    }

    /// Regression: selecting a failed/in-flight row with no markdown used to
    /// leave the previous note model untouched, so the row opened old content.
    func test_selectMeetingWithMissingMarkdown_replacesPreviousMeetingIdentity() async {
        let previous = UUID()
        let failed = UUID()
        let now = Date(timeIntervalSince1970: 300)
        let meetings = [
            makeMeeting(
                id: failed,
                startedAt: now,
                progressStatus: .failed,
                failureReason: "Upload will retry when Whytap restarts"
            ),
            makeMeeting(id: previous, startedAt: now.addingTimeInterval(-100)),
        ]
        let controller = MeetingsContentController(
            source: StubSource(meetings: meetings),
            markdownProvider: { id in id == previous ? "# Previous" : nil },
            transcriptProvider: { _ in nil },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil
        )

        _ = controller.view
        controller.selectMeeting(id: previous)
        await waitUntil { controller.currentMeetingId == previous }

        controller.selectMeeting(id: failed)
        await waitUntil { controller.currentMeetingId == failed }

        XCTAssertEqual(controller.currentMeetingId, failed)
    }

    /// A slower provider completion for an older selection must not replace the
    /// meeting the user selected most recently.
    func test_staleMarkdownCompletion_doesNotOverrideNewerSelection() async {
        let slow = UUID()
        let newest = UUID()
        let meetings = [
            makeMeeting(id: newest, startedAt: Date(timeIntervalSince1970: 200)),
            makeMeeting(id: slow, startedAt: Date(timeIntervalSince1970: 100)),
        ]
        let controller = MeetingsContentController(
            source: StubSource(meetings: meetings),
            markdownProvider: { id in
                if id == slow { try? await Task.sleep(nanoseconds: 250_000_000) }
                return "# \(id.uuidString)"
            },
            transcriptProvider: { _ in nil },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil
        )

        _ = controller.view
        controller.selectMeeting(id: slow)
        try? await Task.sleep(nanoseconds: 20_000_000)
        controller.selectMeeting(id: newest)
        await waitUntil { controller.currentMeetingId == newest }
        try? await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(controller.currentMeetingId, newest)
    }

    /// A meeting stored without a Meeting notes model opens with a calm
    /// explanation and Make notes, never the fixed note in the editor, and its
    /// transcript is on the Transcript tab.
    // WHY: .project-docs/decisions/2026-11-28-meeting-transcript-without-notes-model.md
    func test_transcript_only_meeting_shows_its_transcript_and_make_notes() async {
        let id = UUID()
        let segments = [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "We ship on Friday.")]
        let source = MutableSource(meetings: [makeMeeting(id: id, startedAt: Date(timeIntervalSince1970: 200))])
        let controller = MeetingsContentController(
            source: source,
            markdownProvider: { _ in MeetingBYOKProcessor.transcriptOnlyMarkdown },
            transcriptProvider: { _ in segments },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil
        )
        var made: [UUID] = []
        controller.notesRecovery = MeetingNotesRecovery(
            keptTranscript: { _ in nil }, retryNotes: { made.append($0) })

        _ = controller.view
        controller.selectMeeting(id: id)
        let pane = controller.detailPane
        await waitUntil { pane.offeredNotesAction != nil }

        XCTAssertEqual(pane.unavailableMessage, MeetingsContentController.transcriptOnlyMessage)
        XCTAssertEqual(pane.offeredNotesAction, .makeNotes)
        XCTAssertEqual(pane.offeredNotesAction?.title, "Make notes")
        XCTAssertFalse(pane.isEditing)
        pane.showTab(.transcribe)
        XCTAssertEqual(pane.currentTab, .transcribe, "the transcript is readable")

        pane.performNotesAction()
        await waitUntil { made == [id] }
        XCTAssertEqual(made, [id])
    }

    /// Make notes failed with a configured model: the reason replaces the
    /// explanation, still with Make notes and no failure state.
    func test_transcript_only_meeting_shows_the_last_make_notes_failure_calmly() async {
        let id = UUID()
        let source = MutableSource(meetings: [makeMeeting(
            id: id, startedAt: Date(timeIntervalSince1970: 200),
            failureReason: "The Meeting notes provider is out of credit.")])
        let controller = MeetingsContentController(
            source: source,
            markdownProvider: { _ in MeetingBYOKProcessor.transcriptOnlyMarkdown },
            transcriptProvider: { _ in [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "Hello")] },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil
        )
        controller.notesRecovery = MeetingNotesRecovery(keptTranscript: { _ in nil }, retryNotes: { _ in })

        _ = controller.view
        controller.selectMeeting(id: id)
        let pane = controller.detailPane
        await waitUntil { pane.offeredNotesAction != nil }

        XCTAssertEqual(pane.unavailableMessage,
                       "The Meeting notes provider is out of credit. The transcript is in the Transcript tab.")
        XCTAssertEqual(pane.offeredNotesAction, .makeNotes)
    }

    final class MutableSource: MeetingsSidebarSource, @unchecked Sendable {
        var meetings: [MeetingMetaWithLocalState]
        init(meetings: [MeetingMetaWithLocalState]) { self.meetings = meetings }
        func loadList() async throws -> [MeetingMetaWithLocalState] { meetings }
    }

    private func makeMeeting(
        id: UUID,
        startedAt: Date,
        progressStatus: MeetingProgressStatus = .ready,
        failureReason: String? = nil
    ) -> MeetingMetaWithLocalState {
        MeetingMetaWithLocalState(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(900),
            durationSeconds: 900,
            title: "Meeting",
            syncStatus: .new,
            serverVersion: 1,
            createdAt: startedAt.addingTimeInterval(901),
            progressStatus: progressStatus,
            failureReason: failureReason
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

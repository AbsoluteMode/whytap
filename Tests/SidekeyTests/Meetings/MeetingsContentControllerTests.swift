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

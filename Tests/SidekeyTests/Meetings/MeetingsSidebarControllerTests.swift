import AppKit
import XCTest
@testable import Sidekey

/// Tests for `MeetingsSidebarController` — now a thin host around the native
/// SwiftUI `MeetingListView`/`MeetingListModel`. The list buckets meetings by
/// date (`Today` / `Yesterday` / `<Month Year>`) via `MeetingsDateGrouping`,
/// and a row tap forwards `sidebarDidSelectMeeting(id:)` to the delegate.
///
/// All tests inject a hand-built stub source instead of the production
/// `MeetingsStore` actor so the contract can be exercised without touching
/// SQLite / disk. A pinned `now` flows through to the grouping helper so the
/// bucketing is deterministic regardless of when CI runs.
@MainActor
final class MeetingsSidebarControllerTests: XCTestCase {

    // MARK: - Stubs

    final class StubSource: MeetingsSidebarSource, @unchecked Sendable {
        private let meetings: [MeetingMetaWithLocalState]
        init(meetings: [MeetingMetaWithLocalState]) { self.meetings = meetings }
        func loadList() async throws -> [MeetingMetaWithLocalState] { meetings }
    }

    final class CapturingDelegate: MeetingsSidebarDelegate {
        private(set) var selected: [UUID] = []
        func sidebarDidSelectMeeting(id: UUID) { selected.append(id) }
    }

    // MARK: - Fixtures

    /// Anchored "now" so Today / Yesterday / This Week buckets are stable
    /// across runs. Wednesday, 21 May 2026 14:00 UTC.
    private let pinnedNow = Date(timeIntervalSince1970: 1_779_716_400)

    private func makeMeeting(
        id: UUID = UUID(),
        startedAt: Date,
        title: String? = "Sample"
    ) -> MeetingMetaWithLocalState {
        MeetingMetaWithLocalState(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(900),
            durationSeconds: 900,
            title: title,
            syncStatus: .new,
            serverVersion: 1,
            createdAt: startedAt.addingTimeInterval(905)
        )
    }

    /// Build the controller pre-wired with a deterministic `now`.
    private func makeController(meetings: [MeetingMetaWithLocalState]) async throws
        -> (MeetingsSidebarController, CapturingDelegate)
    {
        let source = StubSource(meetings: meetings)
        let delegate = CapturingDelegate()
        let controller = MeetingsSidebarController(
            source: source,
            nowProvider: { self.pinnedNow }
        )
        controller.delegate = delegate
        _ = controller.view
        try await controller.awaitLoad()
        return (controller, delegate)
    }

    // MARK: - Test 1: list grouped into date sections

    func test_list_groupsMeetingsByDayWithSectionHeaders() async throws {
        // Three meetings, all on the same day → one section ("Today") with
        // three meeting rows.
        let today = pinnedNow
        let meetings = [
            makeMeeting(startedAt: today.addingTimeInterval(-3600), title: "Standup"),
            makeMeeting(startedAt: today.addingTimeInterval(-7200), title: "1×1"),
            makeMeeting(startedAt: today.addingTimeInterval(-10800), title: nil),
        ]

        let (controller, _) = try await makeController(meetings: meetings)

        XCTAssertEqual(controller.sections.count, 1, "Single day → one section.")
        XCTAssertEqual(controller.sections.first?.header, "Today")
        XCTAssertEqual(controller.sections.first?.rows.count, 3)
        // Title falls back to "Untitled" when nil.
        XCTAssertEqual(controller.sections.first?.rows.last?.title, "Untitled")
    }

    func test_list_groupsMeetingsAcrossBucketsWithDistinctHeaders() async throws {
        let cal = Calendar(identifier: .gregorian)

        let today = pinnedNow
        let yesterday = cal.date(byAdding: .day, value: -1, to: pinnedNow)!
        let oldMonth = cal.date(byAdding: .month, value: -2, to: pinnedNow)!

        let meetings = [
            makeMeeting(startedAt: today.addingTimeInterval(-3600), title: "T"),
            makeMeeting(startedAt: yesterday, title: "Y"),
            makeMeeting(startedAt: oldMonth, title: "Old"),
        ]

        let (controller, _) = try await makeController(meetings: meetings)

        XCTAssertEqual(
            controller.sections.count, 3,
            "Three meetings spanning three buckets → three sections."
        )
        let headers = controller.sections.map(\.header)
        XCTAssertTrue(headers.contains("Today"))
        XCTAssertTrue(headers.contains("Yesterday"))
    }

    // MARK: - Test 2: selection forwards meeting id

    func test_userSelection_emits_meeting_selected_event() async throws {
        let target = UUID()
        let meetings = [
            makeMeeting(id: UUID(), startedAt: pinnedNow, title: "Other"),
            makeMeeting(id: target, startedAt: pinnedNow.addingTimeInterval(-3600), title: "Target"),
        ]

        let (controller, delegate) = try await makeController(meetings: meetings)

        controller.handleUserSelection(id: target)

        XCTAssertEqual(
            delegate.selected, [target],
            "A user row tap must emit `sidebarDidSelectMeeting(id:)` with the matching id."
        )
    }

    /// Programmatic selection (used when the host opens a specific meeting)
    /// only highlights — it must NOT re-fire the delegate, or the content
    /// controller would load the note twice.
    func test_programmaticSelect_highlightsWithoutEmittingDelegate() async throws {
        let target = UUID()
        let meetings = [
            makeMeeting(id: target, startedAt: pinnedNow, title: "Target"),
            makeMeeting(id: UUID(), startedAt: pinnedNow.addingTimeInterval(-3600), title: "Other"),
        ]

        let (controller, delegate) = try await makeController(meetings: meetings)

        controller.selectMeeting(id: target)

        XCTAssertTrue(
            delegate.selected.isEmpty,
            "Programmatic selectMeeting(id:) must not notify the delegate."
        )
    }
}

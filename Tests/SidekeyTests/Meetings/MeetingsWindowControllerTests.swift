import AppKit
import XCTest
@testable import Sidekey

/// Stale-while-revalidate auto-refresh wiring on `MeetingsWindowController`.
///
/// The window does not own the refresh logic — that lives on the
/// coordinator as `refreshMeeting(id:)` and is unit-tested in
/// `MeetingsCoordinatorTests`. What the window IS responsible for is
/// firing that closure at the two UX-level trigger points the rework
/// pins:
///
/// 1. `showWindow(_:)` → batch refresh of every meeting currently in
///    the sidebar's source.
/// 2. `sidebarDidSelectMeeting(id:)` → background refresh of the
///    clicked row (the local copy still paints synchronously, so the
///    user does not wait for the network).
///
/// Both tests inject a recording handler closure that captures the ids
/// the window asked to refresh; the production wiring threads
/// `coordinator.refreshMeeting(id:)` through the same closure slot, so
/// asserting on the captured ids covers production behaviour.
@MainActor
final class MeetingsWindowControllerTests: XCTestCase {

    // MARK: - Fixtures

    /// In-memory `MeetingsSidebarSource` so the window can list rows
    /// without spinning up SQLite / Application Support.
    final class StubSource: MeetingsSidebarSource, @unchecked Sendable {
        private let meetings: [MeetingMetaWithLocalState]

        init(meetings: [MeetingMetaWithLocalState]) {
            self.meetings = meetings
        }

        func loadList() async throws -> [MeetingMetaWithLocalState] {
            meetings
        }
    }

    /// Captures every `refreshHandler` invocation so the auto-trigger
    /// tests can assert which meetings were asked to refresh and in
    /// what total count (dedupe is enforced by the coordinator, not
    /// the window, so the window may issue duplicates legitimately).
    private final class RefreshRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [UUID] = []
        var calls: [UUID] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func record(_ id: UUID) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(id)
        }
    }

    private func makeMeeting(id: UUID = UUID()) -> MeetingMetaWithLocalState {
        MeetingMetaWithLocalState(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            durationSeconds: 120,
            title: "Sample",
            syncStatus: .read,
            serverVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_130)
        )
    }

    private func makeWindow(
        meetings: [MeetingMetaWithLocalState],
        refreshHandler: @escaping @MainActor (UUID) async -> Void
    ) -> MeetingsWindowController {
        MeetingsWindowController(
            source: StubSource(meetings: meetings),
            markdownProvider: { _ in nil },
            transcriptProvider: { _ in nil },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: refreshHandler
        )
    }

    /// Polls `condition` every 10ms up to `timeout` so async work
    /// (refresh `Task` enqueues, source `loadList` await) can settle
    /// without a fixed sleep.
    private func waitFor(
        condition: @escaping () async -> Bool,
        timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - showWindow batch refresh

    /// `showWindow(_:)` must enumerate the sidebar source and ask the
    /// refresh handler for every meeting. Order does not matter
    /// (`TaskGroup` runs in parallel) — what matters is that every id
    /// shows up exactly once per `showWindow` call.
    func test_show_window_triggers_refresh_for_every_meeting() async throws {
        let ids = (0..<3).map { _ in UUID() }
        let metas = ids.map { makeMeeting(id: $0) }
        let recorder = RefreshRecorder()

        let window = makeWindow(meetings: metas) { id in
            recorder.record(id)
        }
        defer { window.close() }

        window.showWindow(nil)

        await waitFor(
            condition: { recorder.calls.count == ids.count },
            timeout: 2.0
        )

        XCTAssertEqual(
            Set(recorder.calls), Set(ids),
            "showWindow must ask the refresh handler for every meeting in the store, exactly once."
        )
    }

    /// When `refreshHandler` is nil (test paths that don't need
    /// refresh), `showWindow` must still bring the window up without
    /// crashing or enqueueing phantom work.
    func test_show_window_without_refresh_handler_is_noop() async {
        let window = MeetingsWindowController(
            source: StubSource(meetings: [makeMeeting()]),
            markdownProvider: { _ in nil },
            transcriptProvider: { _ in nil },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil
        )
        defer { window.close() }

        // No refresh handler ⇒ no recorder. The only assertion is that
        // showWindow completes synchronously without throwing.
        window.showWindow(nil)
        XCTAssertNotNil(window.window)
    }

    // MARK: - sidebar select auto-refresh

    /// Clicking a row fires `sidebarDidSelectMeeting(id:)`. The window
    /// must dispatch the refresh handler with the clicked id in
    /// addition to its normal `loadMarkdownIfNeeded` path.
    func test_sidebar_select_triggers_refresh_for_clicked_meeting() async {
        let clickedId = UUID()
        let recorder = RefreshRecorder()

        // Only meta we need for this test is the one we'll click.
        let window = makeWindow(meetings: [makeMeeting(id: clickedId)]) { id in
            recorder.record(id)
        }
        defer { window.close() }

        window.sidebarDidSelectMeeting(id: clickedId)

        await waitFor(
            condition: { recorder.calls.contains(clickedId) },
            timeout: 1.0
        )

        XCTAssertTrue(
            recorder.calls.contains(clickedId),
            "Selecting a row must enqueue a refresh for that meeting's id."
        )
    }

    /// Same path as above but without a refresh handler — the window
    /// must still drive `loadMarkdownIfNeeded` without crashing.
    func test_sidebar_select_without_refresh_handler_does_not_crash() async {
        let window = MeetingsWindowController(
            source: StubSource(meetings: []),
            markdownProvider: { _ in nil },
            transcriptProvider: { _ in nil },
            bundleURL: nil,
            bundleAccessRoot: nil,
            refreshHandler: nil
        )
        defer { window.close() }

        window.sidebarDidSelectMeeting(id: UUID())
        // No assertion beyond "did not crash" — the markdown provider
        // returning nil exercises the loadMarkdownIfNeeded miss path
        // and the absent refreshHandler exercises the early return.
    }
}

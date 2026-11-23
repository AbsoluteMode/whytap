import AppKit
import Combine
import XCTest
@testable import Sidekey

@MainActor
final class MeetingContinuationRefreshTests: XCTestCase {
    final class SnapshotSource: MeetingsSidebarSource, MeetingDetailSnapshotSource {
        let listSource: Source
        let snapshot: MeetingDetailSnapshot
        init(id: UUID) {
            listSource = Source(id)
            snapshot = .init(markdown: "# Updated meeting\n\nNew findings.",
                transcript: [.init(speaker: "Speaker 1", start: 0, end: 1, text: "New transcript")],
                version: 2, title: "Updated meeting")
        }
        func loadList() async throws -> [MeetingMetaWithLocalState] { try await listSource.loadList() }
        func loadDetail(id: UUID) async throws -> MeetingDetailSnapshot? { snapshot }
    }

    final class Backend: MeetingsSidebarSource {
        let id = UUID()
        var version = 1
        var loads = 0
        var markdownReads = 0
        var markdown = "# Meeting\n\nFirst part."
        var transcript = [TranscriptSegment(speaker: "Speaker 1", start: 0, end: 1, text: "First")]
        var suspendMarkdown = false
        var pendingMarkdown: CheckedContinuation<String?, Never>?

        func loadList() async throws -> [MeetingMetaWithLocalState] {
            loads += 1
            return [.init(id: id, startedAt: Date(timeIntervalSince1970: 1000),
                endedAt: Date(timeIntervalSince1970: 1042), durationSeconds: 42, title: "Meeting",
                syncStatus: .new, serverVersion: version, createdAt: Date(timeIntervalSince1970: 1000))]
        }

        func readMarkdown() async -> String? {
            markdownReads += 1
            if suspendMarkdown {
                return await withCheckedContinuation { pendingMarkdown = $0 }
            }
            return markdown
        }

        func complete() {
            version += 1
            markdown += "\n\nNew findings."
            transcript.append(.init(speaker: "Speaker 2", start: 1, end: 2, text: "Second"))
        }
    }

    private func detail(_ controller: MeetingsContentController) throws -> (MeetingsDetailView, MeetingDetailModel) {
        let view = try XCTUnwrap(Mirror(reflecting: controller).children.first {
            $0.label == "detailView"
        }?.value as? MeetingsDetailView)
        let model = try XCTUnwrap(Mirror(reflecting: view).children.first {
            $0.label == "model"
        }?.value as? MeetingDetailModel)
        return (view, model)
    }

    private func fixture(_ backend: Backend) async throws -> (MeetingsContentController, MeetingsDetailView, MeetingDetailModel) {
        let controller = MeetingsContentController(source: backend,
            markdownProvider: { _ in await backend.readMarkdown() },
            transcriptProvider: { _ in backend.transcript }, bundleURL: nil, bundleAccessRoot: nil)
        let (view, model) = try detail(controller)
        controller.selectMeeting(id: backend.id)
        try await waitUntil { model.noteMarkdown == backend.markdown }
        return (controller, view, model)
    }

    /// Returns as soon as the condition holds; the deadline only matters on a loaded Mac.
    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition())
    }

    private func settleRefresh(_ controller: MeetingsContentController, backend: Backend) async throws {
        let previous = backend.loads
        controller.refreshSidebar()
        try await waitUntil { backend.loads > previous }
        // Flush the asynchronous list-completion/reload tasks. Persistence in
        // the tests below is explicitly gated, not driven by this delay.
        try await Task.sleep(for: .milliseconds(30))
    }

    func testReaderUsesContentSnapshotVersionInsteadOfEarlierListVersion() async throws {
        let id = UUID()
        let source = SnapshotSource(id: id)
        let controller = MeetingsContentController(source: source,
            markdownProvider: { _ in XCTFail("Production snapshot must keep content and version together"); return nil },
            transcriptProvider: { _ in XCTFail("Transcript belongs to the same snapshot"); return nil },
            bundleURL: nil, bundleAccessRoot: nil)
        let (_, model) = try detail(controller)
        controller.selectMeeting(id: id)
        try await waitUntil { model.noteMarkdown == source.snapshot.markdown }
        XCTAssertEqual(model.version, 2)
        XCTAssertTrue(model.transcriptCopyText.contains("New transcript"))
        let list = try await source.loadList()
        XCTAssertEqual(list.first?.serverVersion, 1, "The earlier list fetch intentionally predates the body")
    }

    func testDraftSurvivesCompletionAndDoneWaitsForSuccessfulPersistenceAcknowledgment() async throws {
        let backend = Backend()
        let (controller, _, model) = try await fixture(backend)
        let bridge = MeetingsEditBridge(debounceMilliseconds: 0)
        controller.attachEditBridge(bridge)
        bridge.attachMeeting(id: backend.id)
        defer { bridge.finish() }
        var submitted: MeetingsEditBridge.EditEvent?
        let subscription = bridge.editEvents.sink { submitted = $0 }
        defer { subscription.cancel() }

        model.isEditing = true
        let first = model.noteMarkdown
        backend.complete()
        try await settleRefresh(controller, backend: backend)
        XCTAssertTrue(model.isEditing)
        XCTAssertEqual(model.noteMarkdown, first)

        let edited = "# My edited meeting\n\nMy draft."
        model.commitEdit(edited)
        try await waitUntil { submitted != nil }
        let event = try XCTUnwrap(submitted)
        try await settleRefresh(controller, backend: backend)
        XCTAssertEqual(model.noteMarkdown, edited, "Done must not reload storage before its save finishes")

        // Simulate a slow persistence operation that has now committed the
        // user's changes plus the continuation. A failed/old acknowledgment
        // must not unlock the edited content.
        backend.markdown = edited + "\n\nNew findings."
        backend.version = 3
        bridge.finishSave(event, succeeded: false)
        try await settleRefresh(controller, backend: backend)
        XCTAssertEqual(model.noteMarkdown, edited)
        bridge.finishSave(event, succeeded: true)
        controller.refreshSidebar()
        try await waitUntil { model.noteMarkdown == backend.markdown }
        XCTAssertEqual(model.version, 3)
        XCTAssertTrue(model.transcriptCopyText.contains("Second"))
    }

    func testCancelAppliesDeferredContinuationAndPreservesTranscriptTab() async throws {
        let backend = Backend()
        let (controller, view, model) = try await fixture(backend)
        model.isEditing = true
        backend.complete()
        try await settleRefresh(controller, backend: backend)
        XCTAssertTrue(model.isEditing)
        model.cancelEdit()
        try await waitUntil { model.noteMarkdown == backend.markdown }
        view.showTab(.transcribe)
        backend.complete()
        controller.refreshSidebar()
        try await waitUntil { model.version == backend.version }
        XCTAssertEqual(view.currentTab, .transcribe)
        XCTAssertEqual(model.activeTab, .transcribe)
    }

    func testEditingStartedDuringAsyncReloadPreventsTheLateResultFromReplacingDraft() async throws {
        let backend = Backend()
        let (controller, _, model) = try await fixture(backend)
        backend.complete()
        backend.suspendMarkdown = true
        controller.refreshSidebar()
        try await waitUntil { backend.pendingMarkdown != nil }
        model.isEditing = true
        backend.suspendMarkdown = false
        backend.pendingMarkdown?.resume(returning: backend.markdown)
        backend.pendingMarkdown = nil
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.isEditing)
        XCTAssertFalse(model.noteMarkdown.contains("New findings"))
        model.cancelEdit()
        try await waitUntil { model.noteMarkdown == backend.markdown }
    }

    func testProductionCoordinatorRefreshesBothHostsAfterContinuationAndDebouncedSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "meeting.refresh." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let store = try MeetingsStore(rootDirectory: root)
        let id = UUID(), second = UUID()
        let start = Date(timeIntervalSince1970: 1000)
        let original = "<!-- protocol:v1 -->\n# Meeting\n\nFirst.\n\n## Tasks\n- Original task\n\n## Decisions\n- None\n\n## Other\n- None"
        let extra = "<!-- protocol:v1 -->\n# Continuation\n\nSecond.\n\n## Tasks\n- New task\n\n## Decisions\n- Ship\n\n## Other\n- None"
        _ = try await store.storeProcessedRecording(recordingId: id, startedAt: start,
            endedAt: start.addingTimeInterval(42), duration: 42, title: "Meeting", markdown: original,
            transcript: [.init(speaker: "Speaker 1", start: 0, end: 42, text: "First")], continuation: nil)
        let coordinator = MeetingsCoordinator(config: MeetingsConfig(defaults: defaults),
            detector: StubbedMeetingDetector(), meetingsStore: store, meetingsEnabled: { true })
        let settings = try XCTUnwrap(coordinator.settingsMeetingsContentController)
        let window = try XCTUnwrap(coordinator.meetingsWindowController)
        defer { window.window?.close() }
        let (_, settingsModel) = try detail(settings)
        let (standaloneView, standaloneModel) = try detail(window.contentController)
        settings.selectMeeting(id: id)
        window.contentController.selectMeeting(id: id) // Never show/activate the test window.
        try await waitUntil { settingsModel.noteMarkdown == original && standaloneModel.noteMarkdown == original }
        XCTAssertFalse(window.window?.isVisible == true)
        settingsModel.isEditing = true
        standaloneView.showTab(.transcribe)

        _ = try await store.storeProcessedRecording(recordingId: second,
            startedAt: start.addingTimeInterval(102), endedAt: start.addingTimeInterval(112), duration: 10,
            title: "Continuation", markdown: extra,
            transcript: [.init(speaker: "Speaker 1", start: 0, end: 10, text: "Second")],
            continuation: .init(meetingId: id, precedingRecordingId: id,
                startedAt: start, audioOffsetSeconds: 42, gapSeconds: 60))
        coordinator.refreshOpenWindowIfNeeded()
        try await waitUntil { standaloneModel.noteMarkdown.contains("New task") }
        XCTAssertTrue(settingsModel.isEditing)
        XCTAssertEqual(settingsModel.noteMarkdown, original)
        XCTAssertTrue(standaloneModel.transcriptCopyText.contains("Second"))
        XCTAssertEqual(standaloneView.currentTab, .transcribe)

        settingsModel.commitEdit(original.replacingOccurrences(of: "Original task", with: "My edited task"))
        try await waitUntil {
            settingsModel.noteMarkdown.contains("My edited task") && settingsModel.noteMarkdown.contains("New task")
                && standaloneModel.noteMarkdown.contains("My edited task")
        }
        let saved = try await store.markdown(id: id)
        XCTAssertEqual(settingsModel.noteMarkdown, saved)
        XCTAssertEqual(standaloneModel.noteMarkdown, saved)
        XCTAssertEqual(settingsModel.version, 3)
        XCTAssertTrue(settingsModel.transcriptCopyText.contains("Second"))
        await store.close()
    }
    final class Source: MeetingsSidebarSource, @unchecked Sendable {
        let id: UUID
        let lock = NSLock()
        var version = 1
        var loadCount = 0
        init(_ id: UUID) { self.id = id }
        func loadList() async throws -> [MeetingMetaWithLocalState] {
            let current = lock.withLock { loadCount += 1; return version }
            return [MeetingMetaWithLocalState(id: id, startedAt: Date(timeIntervalSince1970: 1000),
                endedAt: Date(timeIntervalSince1970: 1042), durationSeconds: 42,
                title: "Synthetic meeting", syncStatus: .new, serverVersion: current,
                createdAt: Date(timeIntervalSince1970: 1000), progressStatus: .ready)]
        }
        func complete() { lock.withLock { version = 2 } }
        var loads: Int { lock.withLock { loadCount } }
    }

    func testReadyContinuationRefreshesAlreadyOpenNoteWithoutReselecting() async throws {
        let id = UUID()
        let source = Source(id)
        var markdown = "# Synthetic meeting\n\nFirst part."
        let controller = MeetingsContentController(source: source,
            markdownProvider: { _ in markdown }, transcriptProvider: { _ in [] },
            bundleURL: nil, bundleAccessRoot: nil)
        _ = controller.view
        let detail = try XCTUnwrap(Mirror(reflecting: controller).children.first { $0.label == "detailView" }?.value as? MeetingsDetailView)
        let model = try XCTUnwrap(Mirror(reflecting: detail).children.first { $0.label == "model" }?.value as? MeetingDetailModel)
        controller.selectMeeting(id: id)
        let deadline = Date().addingTimeInterval(2)
        while model.noteMarkdown != markdown && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.noteMarkdown, markdown)
        XCTAssertFalse(model.isEditing)
        let priorLoads = source.loads
        markdown += "\n\nNew continuation findings."
        source.complete()
        // This is exactly the production completion/update hook used by the
        // coordinator for both Notes hosts.
        controller.refreshSidebar()
        let completionDeadline = Date().addingTimeInterval(2)
        while source.loads <= priorLoads && Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(source.loads, priorLoads)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.noteMarkdown, markdown,
            "After continuation completion the open note should show its new findings without manual reselection")
    }
}

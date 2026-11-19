import AppKit
import Foundation
import os.log

/// Shared Meetings overview → history or editor. The list host preserves its
/// current page while a note is open, so Back returns to the caller's context.
/// The `NotesTopBar` + navigation live here, so the Settings > Notes tab and the
/// standalone Meetings window get the same experience. `onExit` is injected by
/// the host (Settings → leave Notes; standalone → close window).
@MainActor
final class MeetingsContentController: NSViewController {

    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "content")

    private static let minimumSidebarWidth: CGFloat = 200
    private static let minimumContentWidth: CGFloat = 600
    static let minimumContentSize = NSSize(width: 800, height: 600)

    private let sidebarController: MeetingsSidebarController
    private let detailView: MeetingsDetailView
    private let source: MeetingsSidebarSource
    private let markdownProvider: @MainActor (UUID) async throws -> String?
    private let transcriptProvider: @MainActor (UUID) async throws -> [TranscriptSegment]?
    /// Set by the coordinator: the transcript kept for a meeting whose note is
    /// missing, and the way to write that note again.
    var notesRecovery: MeetingNotesRecovery?
    private let refreshHandler: (@MainActor (UUID) async -> Void)?
    /// Deletes one meeting for good; `false` means it could not be deleted.
    /// `nil` hides the feature in surfaces that cannot delete.
    private let deleteHandler: (@MainActor (UUID) async -> Bool)?
    private let deletionPrompts: MeetingDeletionPrompts

    private let topBar: NotesTopBar
    private var topBarHeight: NSLayoutConstraint!
    private var dividerHeight: NSLayoutConstraint!
    private let listContainer = NSView()
    private let editorContainer = NSView()

    private enum Mode { case list, editor }
    private var mode: Mode = .list
    private var currentTitle = ""
    /// The last meeting the user explicitly selected. Async markdown/transcript
    /// completions must match this id before touching the detail model, otherwise
    /// a slower request can overwrite a newer selection with stale content.
    private var requestedMeetingId: UUID?
    private weak var editBridge: MeetingsEditBridge?
    private var pendingDetailRefreshId: UUID?
    private var detailLoadGeneration: UInt64 = 0
    private var sidebarRefreshGeneration: UInt64 = 0

    var currentMeetingId: UUID? { detailView.currentMeetingId }
    var listPage: MeetingListModel.Page { sidebarController.page }

    init(
        source: MeetingsSidebarSource,
        markdownProvider: @escaping @MainActor (UUID) async throws -> String?,
        transcriptProvider: @escaping @MainActor (UUID) async throws -> [TranscriptSegment]?,
        bundleURL: URL?,
        bundleAccessRoot: URL?,
        refreshHandler: (@MainActor (UUID) async -> Void)? = nil,
        deleteHandler: (@MainActor (UUID) async -> Bool)? = nil,
        deletionPrompts: MeetingDeletionPrompts = .system,
        topBarLeadingInset: CGFloat = 72
    ) {
        self.source = source
        self.markdownProvider = markdownProvider
        self.transcriptProvider = transcriptProvider
        self.refreshHandler = refreshHandler
        self.deleteHandler = deleteHandler
        self.deletionPrompts = deletionPrompts

        let sidebar = MeetingsSidebarController(source: source, canDelete: deleteHandler != nil)
        self.sidebarController = sidebar

        let detail = MeetingsDetailView(bundleURL: bundleURL, bundleAccessRoot: bundleAccessRoot)
        detail.translatesAutoresizingMaskIntoConstraints = false
        self.detailView = detail

        self.topBar = NotesTopBar(leadingInset: topBarLeadingInset)

        super.init(nibName: nil, bundle: nil)

        let rootView = NSView(frame: NSRect(origin: .zero, size: Self.minimumContentSize))
        topBar.translatesAutoresizingMaskIntoConstraints = false
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.translatesAutoresizingMaskIntoConstraints = false

        addChild(sidebar)
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(sidebar.view)
        editorContainer.addSubview(detail)

        rootView.addSubview(topBar)
        rootView.addSubview(listContainer)
        rootView.addSubview(editorContainer)

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        rootView.addSubview(divider)

        topBarHeight = topBar.heightAnchor.constraint(equalToConstant: 48)
        dividerHeight = divider.heightAnchor.constraint(equalToConstant: 0.5)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            topBarHeight,

            divider.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            dividerHeight,

            listContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            listContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            listContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            editorContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            sidebar.view.topAnchor.constraint(equalTo: listContainer.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            sidebar.view.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            sidebar.view.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),

            detail.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            detail.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
        ])
        view = rootView

        sidebar.delegate = self

        topBar.onBack = { [weak self] in
            self?.returnToMeetingList()
        }
        topBar.onSelectTab = { [weak self] index in
            self?.detailView.showTab(MeetingsDetailView.Tab(rawValue: index) ?? .note)
        }
        detail.onTabState = { [weak self] current, transcribeEnabled in
            guard let self, self.mode == .editor else { return }
            self.topBar.configure(
                mode: .editor,
                title: self.currentTitle,
                currentTab: current,
                transcribeEnabled: transcribeEnabled
            )
        }

        detail.onEditingFinished = { [weak self] in
            guard let self, let id = self.pendingDetailRefreshId else { return }
            self.reloadMeeting(id: id)
        }
        showList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MeetingsContentController only supports programmatic init.")
    }

    // MARK: - Navigation

    private func showList() {
        detailLoadGeneration &+= 1
        pendingDetailRefreshId = nil
        requestedMeetingId = nil
        mode = .list
        editorContainer.isHidden = true
        listContainer.isHidden = false
        // List is the root inside the Settings detail pane — no top bar, the note
        // list fills the pane like the other Settings panels.
        topBar.isHidden = true
        topBarHeight.constant = 0
        dividerHeight.constant = 0
    }

    func returnToMeetingList() {
        showList()
        sidebarController.restoreFocus()
    }

    func showHistoryScreen() {
        sidebarController.showHistory()
        returnToMeetingList()
    }

    private func showEditor(title: String) {
        currentTitle = title
        mode = .editor
        listContainer.isHidden = true
        editorContainer.isHidden = false
        topBar.isHidden = false
        topBarHeight.constant = 48
        dividerHeight.constant = 0.5
        topBar.configure(
            mode: .editor,
            title: title,
            currentTab: detailView.currentTab.rawValue,
            transcribeEnabled: false
        )
    }

    private func meetingTitle(for id: UUID) -> String {
        let title = sidebarController.meetings.first { $0.id == id }?.title
        return (title?.isEmpty == false) ? title! : "Note"
    }

    // MARK: - Public API

    /// Refresh the sidebar; Notes always opens on the list screen.
    func refreshOnShow() {
        refreshSidebar()
        if mode != .editor { showList() }
        refreshAllOnShow()
    }

    /// Force the meeting list, even from inside the editor. The sidebar
    /// **Notes** button is "Notes home" — clicking it always returns to the
    /// list of meetings, never re-opens the last note.
    func showListScreen() {
        sidebarController.refresh()
        sidebarController.showOverview()
        showList()
        refreshAllOnShow()
    }

    /// Open a specific meeting straight in the editor (Dynamic Island Notes tile,
    /// menu entries). Refreshes the list underneath so back lands on fresh data.
    func selectMeeting(id: UUID) {
        // Notifications and the island open a note directly, with Meetings as
        // their parent rather than an archive left open during an earlier visit.
        sidebarController.showOverview()
        let generation = prepareDetailForSelection(id: id)
        sidebarController.refresh()
        Task { [weak self] in
            guard let self else { return }
            try? await self.sidebarController.awaitLoad()
            guard self.requestedMeetingId == id, self.detailLoadGeneration == generation else { return }
            self.sidebarController.selectMeeting(id: id)
            self.showEditor(title: self.meetingTitle(for: id))
            await self.loadMarkdownIfNeeded(for: id, generation: generation)
        }
    }

    func refreshSidebar() {
        sidebarController.refresh()
        sidebarRefreshGeneration &+= 1
        let generation = sidebarRefreshGeneration
        guard let id = requestedMeetingId else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await self.sidebarController.awaitLoad()
            guard self.sidebarRefreshGeneration == generation, self.requestedMeetingId == id,
                  self.mode == .editor,
                  self.sidebarController.meetings.contains(where: { $0.id == id }) else { return }
            self.reloadSelectedDetail(id: id)
        }
    }

    func reloadMeeting(id: UUID) {
        guard requestedMeetingId == id, detailView.currentMeetingId == id else { return }
        pendingDetailRefreshId = id
        // Done only submits a debounced edit. Wait for the actual store
        // acknowledgment before replacing that local edited note.
        guard !detailView.isEditing, editBridge?.hasPendingSave(for: id) != true else { return }
        refreshSidebar()
    }

    private func reloadSelectedDetail(id: UUID) {
        detailLoadGeneration &+= 1
        let generation = detailLoadGeneration
        pendingDetailRefreshId = id
        guard mayApplyDetailLoad(id: id, generation: generation) else { return }
        Task { [weak self] in
            await self?.loadMarkdownIfNeeded(for: id, generation: generation, preservingTab: true)
        }
    }

    private func mayApplyDetailLoad(id: UUID, generation: UInt64) -> Bool {
        guard requestedMeetingId == id, detailLoadGeneration == generation else { return false }
        guard !detailView.isEditing, editBridge?.hasPendingSave(for: id) != true else {
            pendingDetailRefreshId = id
            return false
        }
        return true
    }

    func attachEditBridge(_ bridge: MeetingsEditBridge) {
        editBridge = bridge
        detailView.attachEditBridge(bridge)
    }

    // MARK: - Refresh

    private func refreshAllOnShow() {
        guard let refreshHandler else { return }
        let source = self.source
        Task { @MainActor in
            let metas: [MeetingMetaWithLocalState]
            do {
                metas = try await source.loadList()
            } catch {
                os_log(
                    "show refresh batch: source list failed (%{public}@)",
                    log: Self.log, type: .error,
                    String(describing: error)
                )
                return
            }
            os_log(
                "show refresh batch (count: %{public}d)",
                log: Self.log, type: .info,
                metas.count
            )
            await withTaskGroup(of: Void.self) { group in
                for meta in metas {
                    let id = meta.id
                    group.addTask { @MainActor in
                        await refreshHandler(id)
                    }
                }
            }
        }
    }

    // MARK: - Loading

    private func loadMarkdownIfNeeded(for id: UUID, generation: UInt64, preservingTab: Bool = false) async {
        guard mayApplyDetailLoad(id: id, generation: generation) else { return }
        do {
            if let snapshots = source as? MeetingDetailSnapshotSource {
                let snapshot = try await snapshots.loadDetail(id: id)
                guard mayApplyDetailLoad(id: id, generation: generation) else { return }
                if let snapshot {
                    await applyDetail(id: id, markdown: snapshot.markdown, transcript: snapshot.transcript,
                        version: snapshot.version, title: snapshot.title, preservingTab: preservingTab)
                } else {
                    await showUnavailable(id: id, generation: generation, preservingTab: preservingTab)
                }
                return
            }
            guard let rawMarkdown = try await markdownProvider(id) else {
                os_log(
                    "viewer markdown missing for meeting (id: %{public}@)",
                    log: Self.log, type: .error,
                    id.uuidString
                )
                await showUnavailable(id: id, generation: generation, preservingTab: preservingTab)
                return
            }
            guard mayApplyDetailLoad(id: id, generation: generation) else { return }
            await loadMeeting(id: id, rawMarkdown: rawMarkdown, generation: generation, preservingTab: preservingTab)
        } catch {
            os_log(
                "viewer markdown load failed (id: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                id.uuidString, String(describing: error)
            )
            guard mayApplyDetailLoad(id: id, generation: generation) else { return }
            detailView.loadUnavailableMeeting(
                id: id,
                message: "This meeting could not be loaded. Your previous meeting has not been substituted."
            )
        }
    }

    private func loadMeeting(id: UUID, rawMarkdown: String, generation: UInt64, preservingTab: Bool) async {
        guard mayApplyDetailLoad(id: id, generation: generation) else { return }
        let transcript: [TranscriptSegment]?
        do {
            transcript = try await transcriptProvider(id)
        } catch {
            os_log(
                "viewer transcript load failed (id: %{public}@, error: %{public}@) - falling back to placeholder",
                log: Self.log, type: .error,
                id.uuidString, String(describing: error)
            )
            transcript = nil
        }
        guard mayApplyDetailLoad(id: id, generation: generation) else { return }
        // The note's stored version, so an edit bumps the right base (falls
        // back to 1).
        let version = sidebarController.meetings.first { $0.id == id }?.serverVersion ?? 1
        await applyDetail(id: id, markdown: rawMarkdown, transcript: transcript,
            version: version, title: nil, preservingTab: preservingTab)
    }

    private func applyDetail(id: UUID, markdown: String, transcript: [TranscriptSegment]?,
                             version: Int, title: String?, preservingTab: Bool) async {
        currentTitle = title ?? meetingTitle(for: id)
        pendingDetailRefreshId = nil
        await detailView.loadMeeting(
            id: id,
            noteMarkdown: NoteMarkdownStripper.stripTranscript(markdown),
            transcript: transcript,
            version: version, preservingTab: preservingTab
        )
    }

    /// Clears the old note synchronously, before either provider can suspend.
    /// The selected row therefore always owns the visible detail state, even
    /// while its note is still processing or permanently unavailable.
    private func prepareDetailForSelection(id: UUID) -> UInt64 {
        detailLoadGeneration &+= 1
        pendingDetailRefreshId = nil
        requestedMeetingId = id
        currentTitle = meetingTitle(for: id)
        detailView.loadUnavailableMeeting(
            id: id,
            message: "Loading this meeting…",
            isLoading: true
        )
        return detailLoadGeneration
    }

    /// A meeting without a note: its status message, plus the kept transcript
    /// and Retry notes when a failed attempt left one.
    private func showUnavailable(id: UUID, generation: UInt64, preservingTab: Bool = false) async {
        let kept = (try? await notesRecovery?.keptTranscript(id)) ?? nil
        guard mayApplyDetailLoad(id: id, generation: generation) else { return }
        let meta = sidebarController.meetings.first { $0.id == id }
        let hasKept = kept?.isEmpty == false
        let canRetry = hasKept && meta?.progressStatus == .failed
        detailView.loadUnavailableMeeting(
            id: id,
            message: hasKept && meta?.progressStatus == .failed
                ? (meta?.failureReason?.nilIfBlank ?? MeetingNotesFailure.transcriptKept)
                : unavailableMessage(for: id),
            transcript: kept,
            onRetryNotes: canRetry ? { [weak self] in
                guard let self, let recovery = self.notesRecovery else { return }
                self.detailView.loadUnavailableMeeting(
                    id: id, message: "Writing the notes from the saved transcript…", isLoading: true, transcript: kept
                )
                Task { @MainActor in await recovery.retryNotes(id) }
            } : nil,
            preservingTab: preservingTab
        )
    }

    private func unavailableMessage(for id: UUID) -> String {
        guard let meta = sidebarController.meetings.first(where: { $0.id == id }) else {
            return "This meeting's note is not available yet."
        }
        switch meta.progressStatus {
        case .updating:
            return "This meeting is being updated with the continued call. The earlier note remains available."
        case .waitingToReconnect:
            return "Waiting briefly in case the meeting reconnects. The recording so far is saved."
        case .uploading:
            return "The recording is saved and waiting to upload. Notes will appear here automatically."
        case .transcribing:
            return "The recording is saved and is being transcribed."
        case .generatingProtocol:
            return "The transcript is ready and the meeting note is being prepared."
        case .failed:
            if let failureReason = meta.failureReason, !failureReason.isEmpty {
                return "The recording is saved on this Mac. \(failureReason)"
            }
            return "Processing failed, but this meeting will not open an older note."
        case .ready:
            return "The meeting is ready, but its local note is missing. Reopen Whytap to restore it."
        }
    }
}

// MARK: - MeetingsSidebarDelegate

extension MeetingsContentController: MeetingsSidebarDelegate {
    func sidebarDidSelectMeeting(id: UUID) {
        let generation = prepareDetailForSelection(id: id)
        showEditor(title: meetingTitle(for: id))
        Task { [weak self] in
            await self?.loadMarkdownIfNeeded(for: id, generation: generation)
        }
        guard let refreshHandler else { return }
        Task { @MainActor in
            await refreshHandler(id)
        }
    }

    /// Ask first; delete through the host's handler only after a yes; reload
    /// the list either way (the state may have changed); say so when the
    /// delete did not go through. The question names the meeting like the
    /// list does.
    func sidebarDidRequestDelete(id: UUID) {
        guard let deleteHandler else { return }
        let title = deletionTitle(for: id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.deletionPrompts.confirm(title, self.view.window) else { return }
            let deleted = await deleteHandler(id)
            self.sidebarController.refresh()
            if !deleted {
                await self.deletionPrompts.reportFailure(title, self.view.window)
            }
        }
    }

    private func deletionTitle(for id: UUID) -> String {
        let title = sidebarController.meetings.first { $0.id == id }?.title
        return (title?.isEmpty == false) ? title! : "Untitled"
    }
}

/// How a notes window reaches a transcript kept without a note.
struct MeetingNotesRecovery {
    let keptTranscript: @MainActor (UUID) async throws -> [TranscriptSegment]?
    let retryNotes: @MainActor (UUID) async -> Void
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

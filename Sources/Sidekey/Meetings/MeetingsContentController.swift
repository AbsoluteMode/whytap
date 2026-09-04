import AppKit
import Foundation
import os.log

/// Reusable Meeting Notes surface. Two screens, like the reference:
/// **list** (pick a meeting) → **editor** (full-window note with a back button).
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
    private let refreshHandler: (@MainActor (UUID) async -> Void)?

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

    var currentMeetingId: UUID? { detailView.currentMeetingId }

    init(
        source: MeetingsSidebarSource,
        markdownProvider: @escaping @MainActor (UUID) async throws -> String?,
        transcriptProvider: @escaping @MainActor (UUID) async throws -> [TranscriptSegment]?,
        bundleURL: URL?,
        bundleAccessRoot: URL?,
        refreshHandler: (@MainActor (UUID) async -> Void)? = nil,
        topBarLeadingInset: CGFloat = 72
    ) {
        self.source = source
        self.markdownProvider = markdownProvider
        self.transcriptProvider = transcriptProvider
        self.refreshHandler = refreshHandler

        let sidebar = MeetingsSidebarController(source: source)
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

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = MacSettingsTheme.NS.sep.cgColor
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
            self?.showList()
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

        showList()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MeetingsContentController only supports programmatic init.")
    }

    // MARK: - Navigation

    private func showList() {
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
        sidebarController.refresh()
        if mode != .editor { showList() }
        refreshAllOnShow()
    }

    /// Force the meeting list, even from inside the editor. The sidebar
    /// **Notes** button is "Notes home" — clicking it always returns to the
    /// list of meetings, never re-opens the last note.
    func showListScreen() {
        sidebarController.refresh()
        showList()
        refreshAllOnShow()
    }

    /// Open a specific meeting straight in the editor (Dynamic Island Notes tile,
    /// menu entries). Refreshes the list underneath so back lands on fresh data.
    func selectMeeting(id: UUID) {
        prepareDetailForSelection(id: id)
        sidebarController.refresh()
        Task { [weak self] in
            guard let self else { return }
            try? await self.sidebarController.awaitLoad()
            guard self.requestedMeetingId == id else { return }
            self.sidebarController.selectMeeting(id: id)
            self.showEditor(title: self.meetingTitle(for: id))
            await self.loadMarkdownIfNeeded(for: id)
        }
    }

    func refreshSidebar() {
        sidebarController.refresh()
    }

    func reloadMeeting(id: UUID) {
        guard detailView.currentMeetingId == id else { return }
        // Don't stomp an in-progress edit with a background refresh.
        guard !detailView.isEditing else { return }
        Task { [weak self] in
            await self?.loadMarkdownIfNeeded(for: id)
        }
    }

    func attachEditBridge(_ bridge: MeetingsEditBridge) {
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

    private func loadMarkdownIfNeeded(for id: UUID) async {
        guard requestedMeetingId == id else { return }
        do {
            guard let rawMarkdown = try await markdownProvider(id) else {
                os_log(
                    "viewer markdown missing for meeting (id: %{public}@)",
                    log: Self.log, type: .error,
                    id.uuidString
                )
                guard requestedMeetingId == id else { return }
                detailView.loadUnavailableMeeting(
                    id: id,
                    message: unavailableMessage(for: id)
                )
                return
            }
            guard requestedMeetingId == id else { return }
            await loadMeeting(id: id, rawMarkdown: rawMarkdown)
        } catch {
            os_log(
                "viewer markdown load failed (id: %{public}@, error: %{public}@)",
                log: Self.log, type: .error,
                id.uuidString, String(describing: error)
            )
            guard requestedMeetingId == id else { return }
            detailView.loadUnavailableMeeting(
                id: id,
                message: "This meeting could not be loaded. Your previous meeting has not been substituted."
            )
        }
    }

    private func loadMeeting(id: UUID, rawMarkdown: String) async {
        guard requestedMeetingId == id else { return }
        let noteMarkdown = NoteMarkdownStripper.stripTranscript(rawMarkdown)
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
        guard requestedMeetingId == id else { return }
        // The note's stored version, so an edit bumps the right base (falls
        // back to 1).
        let version = sidebarController.meetings.first { $0.id == id }?.serverVersion ?? 1
        await detailView.loadMeeting(
            id: id,
            noteMarkdown: noteMarkdown,
            transcript: transcript,
            version: version
        )
    }

    /// Clears the old note synchronously, before either provider can suspend.
    /// The selected row therefore always owns the visible detail state, even
    /// while its note is still processing or permanently unavailable.
    private func prepareDetailForSelection(id: UUID) {
        requestedMeetingId = id
        currentTitle = meetingTitle(for: id)
        detailView.loadUnavailableMeeting(
            id: id,
            message: "Loading this meeting…",
            isLoading: true
        )
    }

    private func unavailableMessage(for id: UUID) -> String {
        guard let meta = sidebarController.meetings.first(where: { $0.id == id }) else {
            return "This meeting's note is not available yet."
        }
        switch meta.progressStatus {
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
        prepareDetailForSelection(id: id)
        showEditor(title: meetingTitle(for: id))
        Task { [weak self] in
            await self?.loadMarkdownIfNeeded(for: id)
        }
        guard let refreshHandler else { return }
        Task { @MainActor in
            await refreshHandler(id)
        }
    }
}

import AppKit
import Foundation
import SwiftUI
import os.log

/// Detail pane of the Notes surface. Renders the meeting protocol **natively**
/// (SwiftUI `MeetingNoteView`) instead of a BlockNote WKWebView — styled like
/// the rest of Settings. Two tabs share one renderer:
///
/// - **Note** (default) — the LLM summary markdown stored in
///   `note.markdown` (transcript section stripped upstream). Editable via an
///   inline markdown editor (Edit -> type -> Done); Done persists through the
///   same `MeetingsEditBridge` -> `saveNoteEdit` path the webview used.
/// - **Transcribe** — the diarised transcript formatted via
///   `TranscriptMarkdownFormatter`. Read-only. Meetings recorded before
///   transcript persistence shipped have no local transcript, so the tab is
///   disabled and a placeholder shows.
///
/// The `[Note] [Transcribe]` control lives in the SwiftUI top bar; this view
/// exposes `showTab(_:)` and reports state via `onTabState`. The public API is
/// unchanged from the old WKWebView version so `MeetingsContentController`
/// (Settings + standalone) and the coordinator are untouched.
@MainActor
final class MeetingsDetailView: NSView {

    private static let log = OSLog(subsystem: "com.sidekey.meetings", category: "detail-view")

    enum Tab: Int {
        case note = 0
        case transcribe = 1
    }

    /// Notifies the host (SwiftUI top bar) when the active tab or transcript
    /// availability changes, so the segmented control stays in sync.
    var onTabState: ((_ current: Int, _ transcribeEnabled: Bool) -> Void)?

    private let model: MeetingDetailModel
    private weak var editBridge: MeetingsEditBridge?

    private(set) var currentTab: Tab = .note
    var currentMeetingId: UUID? { model.currentMeetingId }

    /// True while the Note tab's markdown editor is open — the host skips
    /// background reloads so an in-progress edit isn't stomped.
    var isEditing: Bool { model.isEditing }

    /// `bundleURL` / `bundleAccessRoot` are retained in the signature so the
    /// `MeetingsContentController` call site is untouched during the BlockNote
    /// retirement; the native renderer ignores them.
    init(
        bundleURL: URL?,
        bundleAccessRoot: URL?,
        meetingSharePresenter: @escaping @MainActor (MeetingSharePayload) -> Void = MeetingSharePresenter.present
    ) {
        self.model = MeetingDetailModel(
            meetingSharePresenter: meetingSharePresenter
        )
        super.init(frame: .zero)
        _ = bundleURL
        _ = bundleAccessRoot

        // Done in the editor forwards the new markdown to the edit bridge,
        // which debounces + persists through the coordinator (local store) —
        // the same path the old BlockNote webview used.
        model.onSave = { [weak self] markdown, version in
            self?.editBridge?.submitEdit(markdown: markdown, clientVersion: version)
        }

        let host = NSHostingView(rootView: MeetingDetailContentView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MeetingsDetailView only supports programmatic init.")
    }

    // MARK: - Public API

    /// Load both tabs for a meeting. The Note tab is selected by default on
    /// every fresh load. `transcript == nil` disables the Transcribe tab and
    /// primes the placeholder. `version` is the note's known stored version,
    /// sent with edits so `saveNoteEdit` PUTs against the right base.
    func loadMeeting(
        id: UUID,
        noteMarkdown: String,
        transcript: [TranscriptSegment]?,
        version: Int = 1
    ) async {
        let noteBlocks = MeetingNoteMarkdownParser.parse(noteMarkdown)

        let transcriptBlocks: [NoteBlock]
        let hasTranscript: Bool
        if let transcript, !transcript.isEmpty {
            let markdown = TranscriptMarkdownFormatter.format(transcript)
            transcriptBlocks = MeetingNoteMarkdownParser.parse(markdown)
            hasTranscript = true
        } else {
            transcriptBlocks = []
            hasTranscript = false
        }

        editBridge?.attachMeeting(id: id)
        model.load(
            id: id,
            noteMarkdown: noteMarkdown,
            noteBlocks: noteBlocks,
            transcriptBlocks: transcriptBlocks,
            hasTranscript: hasTranscript,
            version: version,
            transcriptCopyText: transcript.map(TranscriptMarkdownFormatter.plainText) ?? ""
        )
        switchTo(.note)
    }

    /// Selects a meeting whose note is not available yet (or failed to load).
    /// This is deliberately a real model transition, not just an overlay: the
    /// previous meeting id/content/edit target must be cleared immediately or a
    /// failed in-flight row appears to open the previously viewed meeting.
    func loadUnavailableMeeting(id: UUID, message: String, isLoading: Bool = false) {
        editBridge?.attachMeeting(id: id)
        model.loadUnavailable(id: id, message: message, isLoading: isLoading)
        switchTo(.note)
    }

    /// Wire the edit bridge so Done-in-editor persists. Stored weakly — the
    /// coordinator owns the bridge for the controller's lifetime.
    func attachEditBridge(_ bridge: MeetingsEditBridge) {
        editBridge = bridge
    }

    // MARK: - Tab switching

    /// Switch tabs from the top bar. Falls back to Note if Transcribe is
    /// requested but unavailable for the current meeting.
    func showTab(_ tab: Tab) {
        if tab == .transcribe && !model.hasTranscript {
            switchTo(.note)
            return
        }
        switchTo(tab)
    }

    private func switchTo(_ tab: Tab) {
        currentTab = tab
        model.activeTab = tab
        model.isEditing = false
        onTabState?(tab.rawValue, model.hasTranscript)
    }
}

// MARK: - Model

/// Holds the parsed blocks + raw markdown for both tabs, which tab is active,
/// and the edit state for the Note tab.
@MainActor
final class MeetingDetailModel: ObservableObject {
    @Published var noteBlocks: [NoteBlock] = []
    @Published var transcriptBlocks: [NoteBlock] = []
    @Published var hasTranscript = false
    @Published var activeTab: MeetingsDetailView.Tab = .note
    @Published var isEditing = false
    @Published private(set) var currentMeetingId: UUID?
    @Published private(set) var unavailableMessage: String?
    @Published private(set) var unavailableIsLoading = false

    /// Structured protocol when the note is in the canonical schema; nil for
    /// legacy / freely-edited notes (which fall back to the generic renderer).
    @Published private(set) var noteProtocol: MeetingProtocol?

    /// Full transcript as plain text, including speaker labels and timestamps.
    private(set) var transcriptCopyText = ""
    @Published private(set) var transcriptCopied = false
    /// Raw note markdown — the source the editor edits and the renderer parses.
    private(set) var noteMarkdown = ""
    private(set) var version = 1

    /// Called on Done with the edited markdown + base version. Wired by
    /// `MeetingsDetailView` to the edit bridge.
    var onSave: ((_ markdown: String, _ version: Int) -> Void)?

    private let meetingSharePresenter: @MainActor (MeetingSharePayload) -> Void

    init(
        meetingSharePresenter: @escaping @MainActor (MeetingSharePayload) -> Void = MeetingSharePresenter.present
    ) {
        self.meetingSharePresenter = meetingSharePresenter
    }

    func load(
        id: UUID,
        noteMarkdown: String,
        noteBlocks: [NoteBlock],
        transcriptBlocks: [NoteBlock],
        hasTranscript: Bool,
        version: Int,
        transcriptCopyText: String = ""
    ) {
        currentMeetingId = id
        unavailableMessage = nil
        unavailableIsLoading = false
        self.noteMarkdown = noteMarkdown
        self.noteBlocks = noteBlocks
        self.noteProtocol = MeetingProtocolParser.parse(noteMarkdown)
        self.transcriptCopyText = hasTranscript ? transcriptCopyText : ""
        transcriptCopied = false
        self.transcriptBlocks = transcriptBlocks
        self.hasTranscript = hasTranscript
        self.version = version
        activeTab = .note
        isEditing = false
    }

    /// Replaces every user-visible field when the selected meeting has no note.
    /// Keeping the old blocks around would make the new row render stale content
    /// and, worse, leave edits attached to the previous meeting id.
    func loadUnavailable(id: UUID, message: String, isLoading: Bool = false) {
        currentMeetingId = id
        unavailableMessage = message
        unavailableIsLoading = isLoading
        noteMarkdown = ""
        noteBlocks = []
        noteProtocol = nil
        transcriptBlocks = []
        transcriptCopyText = ""
        transcriptCopied = false
        hasTranscript = false
        version = 1
        activeTab = .note
        isEditing = false
    }

    /// Commit an edit: re-render locally for an instant update, then persist.
    func commitEdit(_ markdown: String) {
        noteMarkdown = markdown
        noteBlocks = MeetingNoteMarkdownParser.parse(markdown)
        noteProtocol = MeetingProtocolParser.parse(markdown)
        isEditing = false
        onSave?(markdown, version)
    }

    func cancelEdit() {
        isEditing = false
    }

    func copyTranscript(to pasteboard: NSPasteboard = .general) {
        guard hasTranscript, !transcriptCopyText.isEmpty else { return }
        pasteboard.clearContents()
        transcriptCopied = pasteboard.setString(transcriptCopyText, forType: .string)
    }

    func shareCurrentNote() {
        let markdown = MeetingShareMarkdownFormatter.format(noteMarkdown: noteMarkdown)
        guard let payload = MeetingSharePayload(markdown: markdown) else { return }
        meetingSharePresenter(payload)
    }
}

// MARK: - SwiftUI content

private struct MeetingDetailContentView: View {
    @ObservedObject var model: MeetingDetailModel
    @State private var draft = ""

    var body: some View {
        Group {
            if let message = model.unavailableMessage {
                unavailable(message)
            } else if model.activeTab == .transcribe && !model.hasTranscript {
                placeholder
            } else if model.activeTab == .note && model.isEditing {
                editor
            } else {
                reader
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func unavailable(_ message: String) -> some View {
        VStack(spacing: 10) {
            if model.unavailableIsLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(MacSettingsTheme.text2)
            }
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(MacSettingsTheme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var noteBody: some View {
        if model.activeTab == .note, let note = model.noteProtocol {
            // Canonical structured protocol -> rich structured render.
            MeetingProtocolView(
                note: note,
                onTaskTap: nil
            )
        } else {
            // Transcript, or legacy / freely-edited note -> generic markdown.
            MeetingNoteView(
                blocks: model.activeTab == .note ? model.noteBlocks : model.transcriptBlocks
            )
        }
    }

    private var reader: some View {
        VStack(spacing: 0) {
            if model.activeTab == .note {
                noteToolbar
            } else if model.hasTranscript {
                transcriptToolbar
            }
            noteBody
        }
    }

    private var transcriptToolbar: some View {
        HStack {
            Spacer(minLength: 0)
            Button { model.copyTranscript() } label: {
                Label(model.transcriptCopied ? "Copied" : "Copy transcript",
                      systemImage: model.transcriptCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(MacSettingsTheme.controlBg))
            }
            .buttonStyle(.plain)
            .disabled(model.transcriptCopyText.isEmpty)
            .help("Copy the full transcript with speakers and timestamps")
        }
        .padding(.top, 10)
        .padding(.trailing, 16)
        .padding(.bottom, 4)
    }

    private var noteToolbar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button {
                model.shareCurrentNote()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(MacSettingsTheme.controlBg))
            }
            .buttonStyle(.plain)

            Button {
                draft = model.noteMarkdown
                model.isEditing = true
            } label: {
                Label("Edit", systemImage: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MacSettingsTheme.text)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(MacSettingsTheme.controlBg))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 10)
        .padding(.trailing, 16)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.cancelEdit() } label: {
                    Text("Cancel")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MacSettingsTheme.text2)
                }
                .buttonStyle(.plain)

                Spacer()

                Button { model.commitEdit(draft) } label: {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(MacSettingsTheme.accent))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Rectangle().fill(MacSettingsTheme.sep).frame(height: 1)

            TextEditor(text: $draft)
                .font(.system(size: 13.5, design: .monospaced))
                .foregroundStyle(MacSettingsTheme.text)
                .scrollContentBackground(.hidden)
                .lineSpacing(3)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
    }

    private var placeholder: some View {
        Text("Transcript not available for meetings recorded before this update.")
            .font(.system(size: 13))
            .foregroundStyle(MacSettingsTheme.text2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum MeetingSharePresenter {
    @MainActor
    static func present(_ payload: MeetingSharePayload) {
        guard let anchor = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else {
            return
        }

        var items: [Any] = [payload.markdown as NSString]
        if let attachmentURL = try? MeetingShareAttachmentWriter.writeMarkdownAttachment(for: payload) {
            items.append(attachmentURL as NSURL)
        }

        let picker = NSSharingServicePicker(items: items)
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

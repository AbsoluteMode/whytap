import AppKit

/// What History says around deleting one clipboard copy: the question before
/// and the explanation when it did not work. A struct of closures so tests
/// answer without showing a window.
struct ClipboardEntryDeletionPrompts {
    var confirm: @MainActor (_ payload: ClipboardHistoryEntryPayload) async -> Bool
    var reportFailure: @MainActor () async -> Void

    static let system = ClipboardEntryDeletionPrompts(
        confirm: { payload in
            ClipboardEntryDeletionAlerts.confirm(payload)
        },
        reportFailure: {
            ClipboardEntryDeletionAlerts.reportFailure()
        }
    )
}

/// Deletes one clipboard history entry after the user confirms. Shared by
/// island History and Toolbox History, which reload when `removesEntry` is true.
/// WHY: .project-docs/decisions/2026-10-22-clipboard-entry-delete.md
@MainActor
struct ClipboardEntryDeletion {
    enum Outcome: Equatable {
        case notClipboard
        case cancelled
        case deleted
        /// The cap evicted it (or another surface deleted it) meanwhile.
        case alreadyGone
        case failed

        /// The entry is no longer stored, so lists should reload.
        var removesEntry: Bool { self == .deleted || self == .alreadyGone }
    }

    let store: SQLiteHistoryStore
    let assetsDirectory: URL
    var prompts: ClipboardEntryDeletionPrompts = .system

    func delete(_ card: HistoryStripCard) async -> Outcome {
        guard case .clipboard(let entry) = card else { return .notClipboard }
        guard await prompts.confirm(entry.payload) else { return .cancelled }
        let store = store
        let assets = assetsDirectory
        let id = entry.id
        // Off the main thread: the store serialises on its own queue and the
        // delete ends with a WAL checkpoint (disk I/O).
        let result = await Task.detached(priority: .userInitiated) {
            Result { try store.deleteClipboardEntry(id: id, assetsDirectory: assets) }
        }.value
        switch result {
        case .success(true):
            return .deleted
        case .success(false):
            return .alreadyGone
        case .failure:
            await prompts.reportFailure()
            return .failed
        }
    }
}

/// The real alerts, ordered like meeting delete: Cancel comes first and takes
/// Escape, Delete has no key equivalent, so a stray Return or Escape never
/// deletes. The alert never quotes the copied text, which may be the secret
/// being removed.
@MainActor
enum ClipboardEntryDeletionAlerts {
    static func confirm(_ payload: ClipboardHistoryEntryPayload) -> Bool {
        let alert = makeConfirmation(for: payload)
        // History lives in non-activating panels; activate so the alert
        // takes the keyboard (Escape cancels) instead of the user's app.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func reportFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t delete this clipboard entry"
        alert.informativeText = "It is still in your History. Try again in a moment."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Builds the dialog without displaying or activating it.
    static func makeConfirmation(for payload: ClipboardHistoryEntryPayload) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText(for: payload)
        alert.informativeText = informativeText(for: payload)
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        return alert
    }

    static func messageText(for payload: ClipboardHistoryEntryPayload) -> String {
        switch payload {
        case .text: return "Delete this copied text?"
        case .image: return "Delete this copied image?"
        case .fileURLs: return "Delete this copied file list?"
        }
    }

    static func informativeText(for payload: ClipboardHistoryEntryPayload) -> String {
        let removal = "It will be removed from Clipboard history on this Mac."
        let tail = "Backups already uploaded are not changed. This can’t be undone."
        if case .fileURLs = payload {
            return "\(removal) The files themselves are not touched. \(tail)"
        }
        return "\(removal) \(tail)"
    }
}

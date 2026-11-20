import AppKit

/// Native recovery is available even if the normal workspace cannot open.
/// Nothing here constructs AppDelegate or opens a live database.
@MainActor
enum ArtifactBackupStartup {
    static func finishPendingRestore() -> Bool {
        let transaction = ArtifactBackupEnvironment().transaction()
        guard transaction.isArmed || transaction.hasApplyJournal else {
            SettingsSyncService.resolveInterruptedRestore()
            return true
        }
        while true {
            let progress = progressPanel()
            do {
                try performAttempt(showing: progress)
                progress.close()
                return true
            } catch ArtifactBackupError.restoreInterrupted {
                progress.close()
                SettingsSyncService.restoreFinished(applied: false)
                // The durable rollback succeeded. Settings → Backup explains
                // the interruption without forcing a second app launch.
                return true
            } catch {
                progress.close()
                let alert = NSAlert()
                alert.messageText = "Restore needs attention"
                alert.informativeText = "Your backup and recovery files are kept. Unlock this Mac and check free disk space, then retry. If the restore key is missing, enter your saved recovery code."
                alert.alertStyle = .warning
                let code = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
                code.placeholderString = "Recovery code (only if needed)"
                code.setAccessibilityLabel("Saved backup recovery code")
                alert.accessoryView = code
                alert.addButton(withTitle: "Retry")
                alert.addButton(withTitle: "Quit")
                alert.buttons[1].keyEquivalent = "\u{1b}"
                alert.addButton(withTitle: "Show Recovery Files")
                let canCancel = !transaction.hasApplyJournal && transaction.isArmed
                if canCancel { alert.addButton(withTitle: "Cancel Restore") }
                let response = alert.runModal()
                if response == .alertSecondButtonReturn { return false }
                if response == .alertThirdButtonReturn {
                    NSWorkspace.shared.activateFileViewerSelecting([ArtifactBackupLocations.production.pendingRestoreRoot])
                    continue
                }
                if canCancel && response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3 {
                    do { _ = try transaction.cancelPlanned(); SettingsSyncService.restoreFinished(applied: false); return true }
                    catch { continue }
                }
                if !code.stringValue.isEmpty {
                    do {
                        let key = try ConfigBackupArchive.key(from: code.stringValue)
                        code.stringValue = ""
                        try transaction.unlockPending(with: key)
                    } catch {
                        code.stringValue = ""
                        let invalid = NSAlert()
                        invalid.messageText = "The restore could not be unlocked"
                        invalid.informativeText = "Check that this recovery code belongs to the selected backup and that the Mac is unlocked. Your saved files were kept."
                        invalid.addButton(withTitle: "OK")
                        invalid.runModal()
                    }
                }
            }
        }
    }

    /// The startup transaction owns no open runtime stores. Keep its disk and
    /// cryptography work off the UI thread while a native modal loop remains
    /// responsive; AppDelegate starts only after this attempt returns.
    private final class AttemptResult: @unchecked Sendable {
        // Accessed only on the main queue, including the completion closure.
        var value: Result<Void, Error>?
    }

    private static var attemptRunning = false

    private static func performAttempt(showing panel: NSPanel) throws {
        try runAttempt(operation: {
            let transaction = ArtifactBackupEnvironment().transaction()
            // Restored settings or keys are older than the synced ones: an
            // applied restore makes this Mac rejoin sync. A restore of other
            // sections, or one rolled back, keeps this Mac's agreement.
            // WHY: .project-docs/decisions/2026-11-20-settings-sync.md
            let touchesSync = transaction.plannedSections
                .map { !Set($0).isDisjoint(with: [.settings, .credentials]) } ?? true
            if touchesSync { SettingsSyncService.restoreWillStart() }
            let outcome = try transaction.applyIfPending()
            if touchesSync { SettingsSyncService.restoreFinished(applied: outcome?.state == .applied) }
        }, pump: { _ = NSApplication.shared.runModal(for: panel) },
           completed: { NSApplication.shared.stopModal() })
    }

    /// A modal panel can return early (for example on Escape). That is not a
    /// completed disk transaction. Keep pumping the same attempt until its
    /// worker actually finishes; never let Retry race a still-running apply.
    static func runAttempt(operation: @escaping @Sendable () throws -> Void,
                           pump: () -> Void,
                           completed: @escaping @MainActor @Sendable () -> Void = {}) throws {
        guard !attemptRunning else { throw ArtifactBackupError.applyInProgress }
        attemptRunning = true
        defer { attemptRunning = false }
        let result = AttemptResult()
        DispatchQueue.global(qos: .userInitiated).async {
            let attempt = Result<Void, Error>(catching: operation)
            DispatchQueue.main.async {
                result.value = attempt
                completed()
            }
        }
        while result.value == nil { pump() }
        guard let value = result.value else { throw ArtifactBackupError.restoreFailed }
        try value.get()
    }

    private static func progressPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 138),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Whytap · Restore"
        panel.isReleasedWhenClosed = false
        let title = NSTextField(labelWithString: "Restoring your workspace…")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.frame = NSRect(x: 64, y: 82, width: 350, height: 22)
        let detail = NSTextField(wrappingLabelWithString: "Your previous data is kept for recovery.\nKeep Whytap open until this finishes.")
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        detail.frame = NSRect(x: 64, y: 32, width: 350, height: 42)
        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 80, width: 24, height: 24))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.usesThreadedAnimation = true
        spinner.startAnimation(nil)
        panel.contentView?.addSubview(title)
        panel.contentView?.addSubview(detail)
        panel.contentView?.addSubview(spinner)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.displayIfNeeded()
        return panel
    }
}

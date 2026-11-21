import AppKit
import Darwin

/// IDs of custom dashboards the user deleted in Monitor, kept in
/// `Monitor/removed-dashboards.json`. Collectors are the user's own programs
/// that keep rewriting their snapshot, so deleting the file alone would bring
/// the board back on the next run: a listed ID stays hidden until the
/// dashboard is installed again (`customize.py install-dashboard`).
/// WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
struct MonitorRemovedDashboards: Equatable {
    static let fileName = "removed-dashboards.json"
    static let maxBytes = 64_000
    static let maxIDs = 512

    /// Whytap and `customize.py install-dashboard` both take an exclusive
    /// flock on this file around read-change-replace of the list, so neither
    /// loses the other's change.
    static let lockFileName = "removed-dashboards.lock"

    private(set) var ids: Set<String> = []

    init(ids: Set<String> = []) {
        self.ids = ids.filter(MonitorDashboard.validID)
    }

    private struct Document: Codable {
        var removed: [String]
    }

    static func url(root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    /// A missing file is an empty list. An unreadable or invalid one throws,
    /// so a broken list never silently brings deleted boards back as if the
    /// user had re-added them, and never gets overwritten by a delete.
    static func load(root: URL) throws -> Self {
        let file = url(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= maxBytes else {
            throw MonitorValidationError.invalidDashboard
        }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: file))
        guard document.removed.count <= maxIDs,
              document.removed.allSatisfy(MonitorDashboard.validID) else {
            throw MonitorValidationError.invalidDashboard
        }
        return Self(ids: Set(document.removed))
    }

    /// Runs `body` holding the list's lock; gives up with EBUSY after
    /// `timeout` so a stuck installer never freezes Monitor.
    static func withLock<T>(root: URL, timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(lockFileName, isDirectory: false).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else {
                throw POSIXError(.EBUSY)
            }
            usleep(20_000)
        }
        return try body()
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    mutating func insert(_ id: String) { ids.insert(id) }

    /// Atomic, mode 0600, like the dashboards next to it.
    func save(root: URL) throws {
        guard ids.count <= Self.maxIDs else { throw MonitorValidationError.invalidDashboard }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = Self.url(root: root)
        if let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw MonitorValidationError.invalidDashboard
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(removed: ids.sorted()))
        let temporary = root.appendingPathComponent(".removed-dashboards-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // rename(2) replaces atomically whether or not the list exists yet.
        guard rename(temporary.path, file.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }
}

/// What Monitor says around deleting one dashboard. A struct of closures so
/// tests answer without showing a window.
struct MonitorDashboardDeletionPrompts {
    var confirm: @MainActor (_ title: String) async -> Bool
    var reportFailure: @MainActor () async -> Void

    static let system = MonitorDashboardDeletionPrompts(
        confirm: { title in MonitorDashboardDeletionAlerts.confirm(title: title) },
        reportFailure: { MonitorDashboardDeletionAlerts.reportFailure() }
    )
}

/// Deletes one custom dashboard after the user confirms. Server status is
/// built in and is never offered.
/// WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
@MainActor
struct MonitorDashboardDeletion {
    enum Outcome: Equatable {
        case cancelled
        case deleted
        /// Another Monitor surface deleted it meanwhile.
        case alreadyGone
        case failed

        /// The dashboard is no longer listed, so an open view should leave it.
        var removesDashboard: Bool { self == .deleted || self == .alreadyGone }
    }

    let store: MonitorStore
    var prompts: MonitorDashboardDeletionPrompts = .system

    func delete(_ dashboard: MonitorDashboard) async -> Outcome {
        guard await prompts.confirm(dashboard.title) else { return .cancelled }
        do {
            return try store.deleteDashboard(id: dashboard.id) ? .deleted : .alreadyGone
        } catch {
            await prompts.reportFailure()
            return .failed
        }
    }
}

/// The real alerts, ordered like meeting and clipboard delete: Cancel comes
/// first and takes Escape, Delete has no key equivalent, so a stray Return or
/// Escape never deletes.
@MainActor
enum MonitorDashboardDeletionAlerts {
    static func confirm(title: String) -> Bool {
        let alert = makeConfirmation(title: title)
        // Monitor lives in a non-activating panel; activate so the alert
        // takes the keyboard (Escape cancels) instead of the user's app.
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func reportFailure() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t delete this dashboard"
        alert.informativeText = "It is still in Monitor. Try again in a moment."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Builds the dialog without displaying or activating it.
    static func makeConfirmation(title: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText(title: title)
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        return alert
    }

    static func messageText(title: String) -> String {
        "Delete the “\(title)” dashboard?"
    }

    static let informativeText =
        "It will be removed from Monitor on this Mac and stays removed even if its collector writes it again. "
        + "The collector and its scripts are not touched; turn the collector off separately. "
        + "Installing the dashboard again brings it back."
}

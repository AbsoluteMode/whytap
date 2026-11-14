import Foundation

/// To-do rules shared by the app's PlannerStore and `whytap todo`. While the
/// app runs it is the only writer (through the helper socket); the helper
/// edits the file itself only when that socket is unreachable. Both hold the
/// same advisory lock around read-modify-write, and the app adopts newer file
/// contents before every save, so neither side overwrites the other.
// WHY: .project-docs/decisions/2026-11-03-todo-helper.md
public enum PlannerTodoFile {
    public static let maxTitleLength = 500
    public static let maxTasks = 10_000
    public static let maxBatch = 100
    static let maxFileSize = 8 * 1024 * 1024

    /// The production archive. Beta and source builds share it, like PlannerStore.shared.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sidekey/Planner/planner-v1.json")
    }

    public struct Failure: Error, Equatable {
        public let code: String
        public let message: String
        public init(_ code: String, _ message: String) { self.code = code; self.message = message }
        public var response: AppControlResponse { .failure(code, message) }
    }

    public struct Planned: Equatable {
        public let id: UUID
        public let title: String
        /// False when an active sibling already has this title (a retry or a duplicate line).
        public let isNew: Bool
        public var parentID: UUID? = nil
    }

    /// One line per title: inner line breaks become spaces, outer whitespace is trimmed.
    public static func normalizedTitle(_ raw: String) -> String {
        raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validates the whole batch before anything is written: one bad title rejects all.
    public static func validatedTitles(_ raw: [String]) throws -> [String] {
        guard (1...maxBatch).contains(raw.count) else {
            throw Failure("invalid_arguments", "Provide 1–\(maxBatch) task titles.")
        }
        return try raw.enumerated().map { index, title in
            let title = normalizedTitle(title)
            guard !title.isEmpty else { throw Failure("empty_title", "Task \(index + 1) is empty.") }
            guard title.count <= maxTitleLength else {
                throw Failure("title_too_long", "Task \(index + 1) has \(title.count) characters; the limit is \(maxTitleLength). Nothing was added.")
            }
            return title
        }
    }

    public static func result(_ planned: [Planned], delivery: String, nodes: [TodoNode]) -> AppControlValue {
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return .object([
            "delivery": .string(delivery),
            "added": .int(planned.filter(\.isNew).count),
            "existing": .int(planned.filter { !$0.isNew }.count),
            "activeCount": .int(nodes.filter { !$0.completed }.count),
            "tasks": .array(planned.map { item in
                var row = byID[item.id].map(taskValue) ?? [:]
                row["result"] = .string(item.isNew ? "added" : "existing")
                row["status"] = byID[item.id]?.status.map(AppControlValue.string) ?? .null
                return .object(row)
            })
        ])
    }

    public static func updated(_ id: UUID, delivery: String, nodes: [TodoNode]) -> AppControlValue {
        var task = nodes.first { $0.id == id }.map(taskValue) ?? [:]
        task["status"] = nodes.first { $0.id == id }?.status.map(AppControlValue.string) ?? .null
        return .object([
            "delivery": .string(delivery),
            "activeCount": .int(nodes.filter { !$0.completed }.count),
            "task": .object(task),
            "affected": .int(1 + TodoTree.descendants(of: id, in: nodes).count)
        ])
    }

    /// Depth-first tree; completed tasks only with includeCompleted.
    public static func listing(_ nodes: [TodoNode], includeCompleted: Bool, delivery: String) -> AppControlValue {
        let shown = TodoTree.ordered(nodes) { includeCompleted || !$0.completed }
        return .object([
            "delivery": .string(delivery),
            "activeCount": .int(nodes.filter { !$0.completed }.count),
            "tasks": .array(shown.map { entry in
                var row = taskValue(entry.node)
                row["depth"] = .int(entry.depth)
                row["status"] = entry.node.status.map(AppControlValue.string) ?? .null
                row["children"] = .int(nodes.filter { $0.parentID == entry.node.id && (includeCompleted || !$0.completed) }.count)
                return .object(row)
            })
        ])
    }

    private static func taskValue(_ node: TodoNode) -> [String: AppControlValue] {
        [
            "id": .string(node.id.uuidString), "title": .string(node.title), "completed": .bool(node.completed),
            "createdAt": .string(ISO8601DateFormatter().string(from: node.createdAt)),
            "parentID": node.parentID.map { .string($0.uuidString) } ?? .null
        ]
    }

    /// Exclusive advisory lock on `<archive>.lock` beside the archive.
    public static func withLock<T>(for url: URL, timeout: TimeInterval, _ body: () throws -> T) throws -> T {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure("unavailable", "Couldn’t open the to-do lock file.") }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < deadline else { throw Failure("busy", "The to-do list is being saved. Retry in a moment.") }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: - Data protection

    /// Readable after the first unlock since startup, also while the screen is
    /// locked, so agents can use To-do on a locked Mac. This is the system
    /// default for new files; app builds up to 2.2.22 saved with CompleteUnlessOpen,
    /// which nobody can open while the screen is locked.
    // WHY: .project-docs/decisions/2026-11-04-todo-locked-screen.md
    public static let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]

    /// Moves an archive saved under a stricter class to the class above. Call it
    /// after a successful read: the file was readable, so the Mac is unlocked.
    public static func relaxProtection(at url: URL) {
        let manager = FileManager.default
        guard let current = (try? manager.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType,
              current == .complete || current == .completeUnlessOpen else { return }
        try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }

    // MARK: - Direct file access while Whytap is not running

    /// Applies a request straight to the archive while Whytap is closed. Fields
    /// the helper does not know are kept; the file is read back to confirm.
    public static func applyOffline(_ request: TodoRequest, at url: URL, now: Date = Date()) throws -> AppControlValue {
        try withLock(for: url, timeout: 2) {
            var archive = try readRaw(url)
            var rows = archive["tasks"] as! [[String: Any]]
            let before = nodes(rows)
            var after = before
            let reply = try request.apply(to: &after, now: now)
            guard after != before else { return reply("file") }
            let byID = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            rows = rows.compactMap { row in
                guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)), let node = byID[id] else { return nil }
                return merged(row, node)
            }
            let known = Set(before.map(\.id))
            rows += after.filter { !known.contains($0.id) }.map { merged([:], $0) }
            archive["tasks"] = rows
            let data = try JSONSerialization.data(withJSONObject: archive)
            guard data.count <= maxFileSize else {
                throw Failure("too_many_tasks", "The to-do file would exceed its size limit. Nothing was changed.")
            }
            // The edited bytes must still load in the app before they replace the file.
            guard isValidArchive(data) else { throw unreadable }
            try data.write(to: url, options: writeOptions)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            guard nodes(try readRaw(url)["tasks"] as! [[String: Any]]) == after else {
                throw Failure("unconfirmed", "The to-do file did not contain the change after saving.")
            }
            return reply("file")
        }
    }

    /// Flat batch while Whytap is closed (kept for scripts and tests).
    public static func addOffline(_ titles: [String], to url: URL, now: Date = Date()) throws -> AppControlValue {
        try applyOffline(TodoRequest("todo_add", ["titles": .array(titles.map(AppControlValue.string))]), at: url, now: now)
    }

    public static func listOffline(at url: URL, includeCompleted: Bool) throws -> AppControlValue {
        try applyOffline(.list(includeCompleted: includeCompleted), at: url)
    }

    static func nodes(_ rows: [[String: Any]]) -> [TodoNode] {
        rows.compactMap { row in
            guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)), let title = row["title"] as? String,
                  let completed = row["completed"] as? Bool, let created = row["createdAt"] as? Double else { return nil }
            return TodoNode(id: id, title: title, completed: completed, createdAt: Date(timeIntervalSinceReferenceDate: created),
                            completedAt: (row["completedAt"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)),
                            parentID: (row["parentID"] as? String).flatMap(UUID.init(uuidString:)),
                            status: row["status"] as? String)
        }
    }

    /// Writes the node's fields into its JSON object, leaving other keys as they were.
    private static func merged(_ row: [String: Any], _ node: TodoNode) -> [String: Any] {
        var row = row
        let previous = nodes([row]).first
        row["id"] = node.id.uuidString
        row["title"] = node.title
        row["completed"] = node.completed
        // Unchanged dates keep their exact stored number.
        if previous?.createdAt != node.createdAt { row["createdAt"] = node.createdAt.timeIntervalSinceReferenceDate }
        if node.completedAt == nil { row.removeValue(forKey: "completedAt") }
        else if previous?.completedAt != node.completedAt { row["completedAt"] = node.completedAt!.timeIntervalSinceReferenceDate }
        if let parent = node.parentID { row["parentID"] = parent.uuidString } else { row.removeValue(forKey: "parentID") }
        if let status = node.status { row["status"] = status } else { row.removeValue(forKey: "status") }
        return row
    }

    /// The archive as JSON objects, only after it passes the same validation
    /// PlannerStore.decodeArchive applies. A missing file is an empty archive;
    /// an invalid one is never written.
    static func readRaw(_ url: URL) throws -> [String: Any] {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ["version": 1, "tasks": [[String: Any]](), "events": [[String: Any]]()]
        } catch { throw unreadable }
        relaxProtection(at: url)
        guard isValidArchive(data),
              let archive = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              archive["tasks"] is [[String: Any]] else { throw unreadable }
        return archive
    }

    // MARK: - Archive validation shared with PlannerStore

    /// The archive shape PlannerStore loads, field for field: the same
    /// synthesized Codable decoding (required keys, Date as seconds since 2001,
    /// URL from string) and the same limits. PlannerStore.decodeArchive calls
    /// this, so the helper never edits a file the app would refuse.
    private struct ArchiveShape: Decodable {
        struct Task: Decodable {
            var id: UUID
            var title: String
            var completed: Bool
            var createdAt: Date
            var completedAt: Date?
            var parentID: UUID?
            var status: String?
        }
        struct Event: Decodable {
            var id: UUID
            var title: String
            var start: Date
            var end: Date
            var allDay: Bool
            var location: String
            var notes: String
            var meetingURL: URL?
            var timeZoneIdentifier: String
        }
        var version: Int
        var tasks: [Task]
        var events: [Event]
    }

    public static func isValidArchive(_ data: Data) -> Bool {
        guard data.count <= maxFileSize, let archive = try? JSONDecoder().decode(ArchiveShape.self, from: data),
              archive.version == 1, archive.tasks.count <= maxTasks, archive.events.count <= maxTasks,
              Set(archive.tasks.map(\.id)).count == archive.tasks.count,
              Set(archive.events.map(\.id)).count == archive.events.count else { return false }
        let nodes = archive.tasks.map {
            TodoNode(id: $0.id, title: $0.title, completed: $0.completed, createdAt: $0.createdAt,
                     completedAt: $0.completedAt, parentID: $0.parentID, status: $0.status)
        }
        guard TodoTree.isValid(nodes) else { return false }
        return archive.tasks.allSatisfy {
            isValidTitle($0.title) && $0.createdAt.timeIntervalSince1970.isFinite
                && ($0.completedAt?.timeIntervalSince1970.isFinite ?? true)
        } && archive.events.allSatisfy {
            isValidTitle($0.title) && $0.start.timeIntervalSince1970.isFinite && $0.end.timeIntervalSince1970.isFinite
                && $0.end > $0.start && $0.location.count <= 2000 && $0.notes.count <= 20_000
                && ($0.meetingURL == nil || safeMeetingURL($0.meetingURL?.absoluteString) != nil)
        }
    }

    public static func isValidTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= maxTitleLength
    }

    /// https with a host and no credentials.
    public static func safeMeetingURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static var unreadable: Failure {
        Failure("planner_unreadable", "The to-do file can’t be read safely, so it was left unchanged. Open To-do in Whytap and use Retry, or restore a backup.")
    }
}

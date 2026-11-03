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
        /// False when an active task already has this title (a retry or a duplicate line).
        public let isNew: Bool
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

    /// An active task with the same title is reused, so retrying a delivered
    /// batch adds nothing. Completed tasks never block adding the title again.
    public static func plan(_ titles: [String], active: [(id: UUID, title: String)]) -> [Planned] {
        var known = Dictionary(active.map { ($0.title, $0.id) }, uniquingKeysWith: { first, _ in first })
        return titles.map { title in
            if let id = known[title] { return Planned(id: id, title: title, isNew: false) }
            let id = UUID()
            known[title] = id
            return Planned(id: id, title: title, isNew: true)
        }
    }

    public static func result(_ planned: [Planned], delivery: String, activeCount: Int) -> AppControlValue {
        .object([
            "delivery": .string(delivery),
            "added": .int(planned.filter(\.isNew).count),
            "existing": .int(planned.filter { !$0.isNew }.count),
            "activeCount": .int(activeCount),
            "tasks": .array(planned.map {
                .object(["id": .string($0.id.uuidString), "title": .string($0.title),
                         "status": .string($0.isNew ? "added" : "existing")])
            })
        ])
    }

    public static func listing(_ tasks: [(id: UUID, title: String, completed: Bool, createdAt: Date)],
                               includeCompleted: Bool, delivery: String) -> AppControlValue {
        let formatter = ISO8601DateFormatter()
        let shown = tasks.filter { includeCompleted || !$0.completed }.sorted { $0.createdAt < $1.createdAt }
        return .object([
            "delivery": .string(delivery),
            "activeCount": .int(tasks.filter { !$0.completed }.count),
            "tasks": .array(shown.map {
                .object(["id": .string($0.id.uuidString), "title": .string($0.title),
                         "completed": .bool($0.completed), "createdAt": .string(formatter.string(from: $0.createdAt))])
            })
        ])
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

    // MARK: - Direct file access while Whytap is not running

    /// Adds tasks straight to the archive, keeping every other field byte-for-byte
    /// equivalent. Reads the file back to confirm the tasks are present.
    public static func addOffline(_ titles: [String], to url: URL, now: Date = Date()) throws -> AppControlValue {
        let titles = try validatedTitles(titles)
        return try withLock(for: url, timeout: 2) {
            var archive = try readRaw(url)
            var tasks = archive["tasks"] as! [[String: Any]]
            let planned = plan(titles, active: activeTasks(tasks))
            let new = planned.filter(\.isNew)
            guard tasks.count + new.count <= maxTasks else {
                throw Failure("too_many_tasks", "The to-do list is limited to \(maxTasks) tasks. Nothing was added.")
            }
            if !new.isEmpty {
                tasks += new.map { ["id": $0.id.uuidString, "title": $0.title, "completed": false,
                                    "createdAt": now.timeIntervalSinceReferenceDate] }
                archive["tasks"] = tasks
                let data = try JSONSerialization.data(withJSONObject: archive)
                guard data.count <= maxFileSize else {
                    throw Failure("too_many_tasks", "The to-do file would exceed its size limit. Nothing was added.")
                }
                // The edited bytes must still load in the app before they replace the file.
                guard isValidArchive(data) else { throw unreadable }
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let saved = activeTasks(try readRaw(url)["tasks"] as! [[String: Any]])
            let savedIDs = Set(saved.map(\.id))
            guard planned.allSatisfy({ savedIDs.contains($0.id) }) else {
                throw Failure("unconfirmed", "The to-do file did not contain the new tasks after saving.")
            }
            return result(planned, delivery: "file", activeCount: saved.count)
        }
    }

    public static func listOffline(at url: URL, includeCompleted: Bool) throws -> AppControlValue {
        let tasks = try withLock(for: url, timeout: 2) { try readRaw(url)["tasks"] as! [[String: Any]] }
        let rows = tasks.compactMap { task -> (UUID, String, Bool, Date)? in
            guard let id = (task["id"] as? String).flatMap(UUID.init(uuidString:)), let title = task["title"] as? String,
                  let completed = task["completed"] as? Bool, let created = task["createdAt"] as? Double else { return nil }
            return (id, title, completed, Date(timeIntervalSinceReferenceDate: created))
        }
        return listing(rows.map { (id: $0.0, title: $0.1, completed: $0.2, createdAt: $0.3) },
                       includeCompleted: includeCompleted, delivery: "file")
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

    private static func activeTasks(_ tasks: [[String: Any]]) -> [(id: UUID, title: String)] {
        tasks.compactMap { task in
            guard task["completed"] as? Bool == false, let title = task["title"] as? String,
                  let id = (task["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            return (id, title)
        }
    }

    private static var unreadable: Failure {
        Failure("planner_unreadable", "The to-do file can’t be read safely, so it was left unchanged. Open To-do in Whytap and use Retry, or restore a backup.")
    }
}

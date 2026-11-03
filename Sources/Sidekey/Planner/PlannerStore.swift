import Foundation
import WhytapCaseKit

struct PlannerTask: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var completed = false
    var createdAt = Date()
    // Optional for archives saved before completion history was introduced.
    var completedAt: Date?
}

struct PlannerEvent: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var allDay = false
    var location = ""
    var notes = ""
    var meetingURL: URL?
    var timeZoneIdentifier = TimeZone.current.identifier

    func displayBounds(calendar: Calendar = .current) -> DateInterval {
        guard allDay, let zone = TimeZone(identifier: timeZoneIdentifier) else { return DateInterval(start: start, end: end) }
        var original = calendar
        original.timeZone = zone
        let startDay = calendar.date(from: original.dateComponents([.year, .month, .day], from: start)) ?? start
        // Accept both exclusive midnight and an inclusive final-day time from
        // calendar adapters, without dropping the final civil day.
        let originalEndDay = original.startOfDay(for: end)
        let exclusiveEnd = end == originalEndDay ? end :
            (original.date(byAdding: .day, value: 1, to: originalEndDay) ?? end)
        let endDay = calendar.date(from: original.dateComponents([.year, .month, .day], from: exclusiveEnd)) ?? end
        return DateInterval(start: startDay, end: max(startDay, endDay))
    }

    func occurs(on day: Date, calendar: Calendar = .current) -> Bool {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return false }
        let bounds = displayBounds(calendar: calendar)
        return bounds.start < interval.end && bounds.end > interval.start
    }

    mutating func moveStart(to date: Date, calendar: Calendar = .current) {
        if allDay {
            let days = max(1, calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: end).day ?? 1)
            start = calendar.startOfDay(for: date)
            end = calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(86400)
        } else {
            let duration = max(1, end.timeIntervalSince(start))
            start = date
            end = date.addingTimeInterval(duration)
        }
    }

    /// Keep the selected civil dates while restoring the previous time of day.
    mutating func convertAllDay(_ enabled: Bool, timedRange: inout DateInterval?, calendar: Calendar = .current) {
        allDay = enabled
        if enabled {
            if end > start { timedRange = DateInterval(start: start, end: end) }
            let endDay = calendar.startOfDay(for: end)
            start = calendar.startOfDay(for: start)
            end = end == endDay && end > start ? endDay :
                (calendar.date(byAdding: .day, value: 1, to: max(start, endDay)) ?? start.addingTimeInterval(86400))
            timeZoneIdentifier = calendar.timeZone.identifier
        } else {
            let startTime = timedRange.map { calendar.dateComponents([.hour, .minute, .second], from: $0.start) }
                ?? DateComponents(hour: 10, minute: 0, second: 0)
            let endTime = timedRange.map { calendar.dateComponents([.hour, .minute, .second], from: $0.end) }
                ?? DateComponents(hour: 11, minute: 0, second: 0)
            let midnightEnd = endTime.hour == 0 && endTime.minute == 0 && endTime.second == 0
            let lastDay = midnightEnd ? end : (calendar.date(byAdding: .day, value: -1, to: end) ?? start)
            start = calendar.date(bySettingHour: startTime.hour ?? 10, minute: startTime.minute ?? 0,
                second: startTime.second ?? 0, of: start) ?? start
            end = calendar.date(bySettingHour: endTime.hour ?? 11, minute: endTime.minute ?? 0,
                second: endTime.second ?? 0, of: lastDay) ?? end
            if end <= start { end = start.addingTimeInterval(3600) }
        }
    }
}

/// Private local data. Failed loads block writes; failed writes never change the visible data.
/// Other writers (`whytap todo` while the app is closed, scripts) are adopted
/// before every save and, for the shared store, as soon as the folder changes.
// WHY: .project-docs/decisions/2026-11-03-todo-helper.md
@MainActor
final class PlannerStore: ObservableObject {
    static let shared = PlannerStore(url: PlannerTodoFile.defaultURL, observesExternalChanges: true)

    struct Archive: Codable, Equatable, Sendable {
        var version = 1
        var tasks: [PlannerTask] = []
        var events: [PlannerEvent] = []
    }

    @Published private(set) var archive = Archive()
    @Published private(set) var errorMessage: String?
    @Published private(set) var canWrite = false
    private let url: URL
    private let write: (Data, URL) throws -> Void
    /// The bytes last read from or written to `url`; nil while no file exists.
    private var diskSnapshot: Data?
    nonisolated(unsafe) private var watcher: DispatchSourceFileSystemObject?

    init(url: URL, observesExternalChanges: Bool = false, write: @escaping (Data, URL) throws -> Void = { data, url in
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        // The containing directory is private; a metadata failure after atomic save must not report lost data.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }) {
        self.url = url
        self.write = write
        reload()
        if observesExternalChanges { startWatching() }
    }

    deinit { watcher?.cancel() }

    func reload() {
        do {
            let data = try readDisk()
            archive = try data.map(Self.decodeArchive) ?? Archive()
            diskSnapshot = data
            canWrite = true
            errorMessage = nil
        } catch {
            canWrite = false
            errorMessage = Self.readFailureMessage
        }
    }

    /// Shows changes another writer saved. A broken file blocks writes and keeps
    /// the current view; Retry (or a later valid file) recovers.
    func refreshFromDisk() {
        if canWrite { adoptExternalChanges() } else { reload() }
    }

    /// Batch add for the helper and agents: one validated, atomic save. An active
    /// task with the same title is reported as existing, so a retry adds nothing.
    func addTasks(_ titles: [String], now: Date = Date()) throws -> [PlannerTodoFile.Planned] {
        let titles = try PlannerTodoFile.validatedTitles(titles)
        var planned: [PlannerTodoFile.Planned] = []
        var overflow = false
        let saved = commit { value in
            planned = PlannerTodoFile.plan(titles, active: value.tasks.filter { !$0.completed }.map { ($0.id, $0.title) })
            let new = planned.filter(\.isNew)
            guard value.tasks.count + new.count <= PlannerTodoFile.maxTasks else { overflow = true; return }
            value.tasks += new.map { PlannerTask(id: $0.id, title: $0.title, createdAt: now) }
        }
        if overflow {
            throw PlannerTodoFile.Failure("too_many_tasks", "The to-do list is limited to \(PlannerTodoFile.maxTasks) tasks. Nothing was added.")
        }
        guard saved else {
            throw canWrite ? PlannerTodoFile.Failure("save_failed", errorMessage ?? Self.saveFailureMessage)
                : PlannerTodoFile.Failure("planner_unreadable", Self.readFailureMessage)
        }
        return planned
    }

    @discardableResult
    func saveTask(_ task: PlannerTask, now: Date = Date()) -> Bool {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validationMessage(for: task) == nil else { return false }
        return commit { value in
            let previous = value.tasks.first { $0.id == task.id }
            if !task.completed { task.completedAt = nil }
            else if previous?.completed == false || previous == nil { task.completedAt = now }
            else { task.completedAt = previous?.completedAt }
            if let index = value.tasks.firstIndex(where: { $0.id == task.id }) { value.tasks[index] = task }
            else { value.tasks.append(task) }
        }
    }

    @discardableResult
    func deleteTask(_ id: UUID) -> Bool { commit { $0.tasks.removeAll { $0.id == id } } }

    @discardableResult
    func saveEvent(_ event: PlannerEvent) -> Bool {
        var event = event
        event.title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validationMessage(for: event) == nil else { return false }
        return commit { value in
            if let index = value.events.firstIndex(where: { $0.id == event.id }) { value.events[index] = event }
            else { value.events.append(event) }
        }
    }

    @discardableResult
    func deleteEvent(_ id: UUID) -> Bool { commit { $0.events.removeAll { $0.id == id } } }

    /// Applies `change` to the newest saved archive under the lock `whytap todo` also holds.
    private func commit(_ change: (inout Archive) -> Void) -> Bool {
        guard canWrite else { return false }
        do {
            return try PlannerTodoFile.withLock(for: url, timeout: 0.5) {
                guard adoptExternalChanges() else { return false }
                var candidate = archive
                change(&candidate)
                guard candidate != archive else { return true }
                let data = try JSONEncoder().encode(candidate)
                _ = try Self.decodeArchive(data)
                try write(data, url)
                archive = candidate
                diskSnapshot = data
                errorMessage = nil
                NotificationCenter.default.post(name: .exodiaBackupArtifactsChanged, object: nil)
                return true
            }
        } catch {
            errorMessage = Self.saveFailureMessage
            return false
        }
    }

    /// Adopts the file when another writer changed it since our last read/write.
    @discardableResult
    private func adoptExternalChanges() -> Bool {
        do {
            let data = try readDisk()
            guard data != diskSnapshot else { return true }
            archive = try data.map(Self.decodeArchive) ?? Archive()
            diskSnapshot = data
            return true
        } catch {
            canWrite = false
            errorMessage = Self.readFailureMessage
            return false
        }
    }

    private func readDisk() throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    /// Atomic saves replace the file, so the folder is watched rather than the file.
    /// In-place edits that do not touch the folder are still adopted on the next save.
    private func startWatching() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshFromDisk() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    private static let readFailureMessage = "Couldn’t read your planner. Your saved file has been kept. Restore access or a backup, then retry."
    private static let saveFailureMessage = "Couldn’t save your changes. Check available storage and folder access, then try again."

    nonisolated static func decodeArchive(_ data: Data) throws -> Archive {
        // One rule set with `whytap todo`, which edits the file while the app is closed.
        guard PlannerTodoFile.isValidArchive(data) else { throw StoreError.invalid }
        return try JSONDecoder().decode(Archive.self, from: data)
    }

    nonisolated private static func validTitle(_ title: String) -> Bool {
        PlannerTodoFile.isValidTitle(title)
    }

    nonisolated static func validationMessage(for task: PlannerTask) -> String? {
        validTitle(task.title) ? nil : "Enter a task between 1 and 500 characters."
    }

    nonisolated static func validationMessage(for event: PlannerEvent) -> String? {
        guard validTitle(event.title) else { return "Enter an event title between 1 and 500 characters." }
        guard event.start.timeIntervalSince1970.isFinite, event.end.timeIntervalSince1970.isFinite,
              event.end > event.start else { return "Choose an end time after the start." }
        guard event.location.count <= 2000 else { return "Keep the location within 2,000 characters." }
        guard event.notes.count <= 20_000 else { return "Keep notes within 20,000 characters." }
        guard event.meetingURL == nil || CalendarDateCodec.safeURL(event.meetingURL?.absoluteString) != nil else {
            return "Enter a valid https meeting link."
        }
        return nil
    }

    private enum StoreError: Error { case invalid }
}

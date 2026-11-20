import AppKit
import Combine
import Foundation

actor NotifyArchive {
    private let url: URL
    private var events: [LocalNotificationEvent]?
    private var revision = 0
    init(url: URL) { self.url = url }

    func load() throws -> (Int, [LocalNotificationEvent]) {
        if events == nil {
            if FileManager.default.fileExists(atPath: url.path) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 8 * 1024 * 1024 else { throw NotifyError.historyUnavailable }
                events = Array(try JSONDecoder().decode([LocalNotificationEvent].self, from: Data(contentsOf: url)).prefix(500))
            } else { events = [] }
        }
        return (revision, events!)
    }

    func insert(_ event: LocalNotificationEvent) throws -> (Int, [LocalNotificationEvent])? {
        var next = try load().1
        guard !next.contains(where: { $0.id == event.id }) else { return nil }
        next.insert(event, at: 0)
        return try save(Array(next.prefix(500)))
    }
    func markRead() throws -> (Int, [LocalNotificationEvent]) {
        try save(load().1.map { var item = $0; item.read = true; return item })
    }
    func clear() throws -> (Int, [LocalNotificationEvent]) {
        _ = try load() // Never overwrite an unreadable existing history.
        return try save([])
    }
    private func save(_ next: [LocalNotificationEvent]) throws -> (Int, [LocalNotificationEvent]) {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        events = next; revision += 1
        return (revision, next)
    }
}

/// One queue and durable events shared by the pill and Notify history.
@MainActor
final class LocalNotificationHub: ObservableObject {
    static let shared = LocalNotificationHub(directory: NotifyPaths.root, onArrival: {
        NotificationSoundPlayer.shared.play(NotificationSoundSettings.shared.sound(for: $0.source))
    })
    @Published private(set) var history: [LocalNotificationEvent] = []
    @Published private(set) var current: LocalNotificationEvent?
    @Published private(set) var deadline: Date?
    @Published private(set) var error: String?
    var unreadCount: Int { history.filter { !$0.read }.count }
    var openMeeting: ((UUID) -> Void)?
    var setInputLanguage: ((String) -> Void)?
    private let archive: NotifyArchive
    private let onArrival: (LocalNotificationEvent) -> Void
    private var historyRevision = -1
    private var queue: [LocalNotificationEvent] = []
    private var dismissTask: Task<Void, Never>?
    private var remaining: TimeInterval?
    private var suspended = false
    private var hovered = false
    private var timerGeneration = UUID()

    init(directory: URL, onArrival: @escaping (LocalNotificationEvent) -> Void = { _ in }) {
        archive = NotifyArchive(url: directory.appendingPathComponent("history.json"))
        self.onArrival = onArrival
    }
    func load() async {
        do { updateHistory(try await archive.load()) }
        catch { self.error = "Couldn’t read notification history. Its file has been preserved." }
    }
    @discardableResult
    func receive(_ event: LocalNotificationEvent) async -> Bool {
        do {
            guard let snapshot = try await archive.insert(event) else { return false }
            updateHistory(snapshot)
            // Clear All may have completed while this disk operation was in
            // flight. An older receipt must not replay an already-cleared item.
            guard history.contains(where: { $0.id == event.id }) else { return true }
            let presentedCount = current == nil ? 0 : 1
            if !suspended && presentedCount + queue.count < 33 {
                queue.append(event)
                if current == nil { advance() }
                onArrival(event)
            }
            return true
        } catch { self.error = "Couldn’t save notification history."; return false }
    }
    func markRead() async {
        do { updateHistory(try await archive.markRead()) }
        catch { self.error = "Couldn’t update notification history." }
    }
    func clear() async {
        do {
            updateHistory(try await archive.clear())
            // Keep genuinely newer arrivals if their archive receipt overtook
            // this continuation; clearing history must not swallow the next event.
            let retainedIDs = Set(history.map(\.id))
            queue.removeAll { !retainedIDs.contains($0.id) }
            if current.map({ !retainedIDs.contains($0.id) }) ?? true { advance() }
        }
        catch { self.error = "Couldn’t clear notification history." }
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value { queue.removeAll(); advance() }
    }
    func isPresented(_ id: String) -> Bool {
        current?.id == id
    }
    func activate(_ event: LocalNotificationEvent,
                  openLink: (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        if let id = event.meetingID { openMeeting?(id) }
        else if let code = event.inputLanguageCode { setInputLanguage?(code) }
        else if let link = event.link { openLink(link) }
    }
    func dismiss() {
        guard let id = current?.id else { return }
        dismiss(id: id)
    }
    func dismiss(id: String) {
        guard isPresented(id) else { return }
        advance()
    }
    func setHovered(_ value: Bool) {
        guard current != nil else { return }
        guard hovered != value else { return }
        hovered = value
        if value {
            remaining = max(0, deadline?.timeIntervalSinceNow ?? 0)
            dismissTask?.cancel()
        } else if let seconds = remaining {
            remaining = nil; schedule(after: seconds)
        }
    }
    private func updateHistory(_ snapshot: (Int, [LocalNotificationEvent])) {
        guard snapshot.0 >= historyRevision else { return }
        historyRevision = snapshot.0; history = snapshot.1; error = nil
    }
    private func advance() {
        dismissTask?.cancel(); remaining = nil; hovered = false
        timerGeneration = UUID()
        if queue.isEmpty { current = nil; deadline = nil; return }
        let event = queue.removeFirst()
        current = event
        schedule(after: event.resolvedDuration)
    }
    private func schedule(after seconds: TimeInterval) {
        dismissTask?.cancel()
        let generation = UUID()
        timerGeneration = generation
        deadline = Date().addingTimeInterval(seconds)
        if hovered { remaining = seconds; return }
        dismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
            catch { return }
            guard let self, self.timerGeneration == generation else { return }
            self.advance()
        }
    }
}

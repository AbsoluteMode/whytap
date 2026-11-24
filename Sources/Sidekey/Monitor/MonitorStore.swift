import Foundation
import Combine

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var dashboards: [MonitorDashboard] = []
    @Published private(set) var readings: [MonitorServerReading] = []
    @Published private(set) var dashboardError: String?
    @Published private(set) var serverError: String?
    @Published private(set) var refreshSeconds: Double = 15
    /// Server status was deleted like any other board: it is not listed and
    /// Whytap does not connect to the servers in servers.json.
    @Published private(set) var serverStatusRemoved = false
    /// Server status is a board only for a user who set servers up: it is
    /// listed while servers.json names at least one server (or cannot be
    /// read, so the mistake is visible) and the board was not deleted.
    /// WHY: .project-docs/decisions/2026-11-23-monitor-server-status-optional.md
    @Published private(set) var serverStatusListed = false

    /// Server status's ID in the deleted list; never a snapshot's ID.
    static let serverStatusID = "server-status"

    let root: URL
    private let collector: (MonitorServer) async throws -> MonitorServerMetrics
    /// The servers being polled. A poll belongs to the configuration it
    /// started with: once that is removed, emptied, unreadable or replaced,
    /// the poll in flight is cancelled before it can reach SSH.
    /// WHY: .project-docs/decisions/2026-11-23-monitor-server-status-optional.md
    private var configuration: MonitorServerConfiguration? {
        didSet { if configuration != oldValue { refreshTask?.cancel() } }
    }
    private var task: Task<Void, Never>?
    private var lastServerRefresh: Date?
    private var refreshRequested = false
    private var generation: UInt64 = 0
    /// Every dashboard file by the ID it decodes to, duplicates included, so
    /// Delete removes each copy of the board it lists.
    private var dashboardFiles: [String: [URL]] = [:]
    /// The server poll in flight; cancelled as soon as polling is no longer
    /// allowed, so a poll still preparing its connection never reaches SSH.
    private var refreshTask: Task<Void, Never>?
    /// Island and Toolbox each have a store; a Delete on one reaches the
    /// others at once through this notification (object: the Monitor root),
    /// so their polls in flight are cancelled too, not on their next loop.
    static let removedDashboardsChanged = Notification.Name("Whytap.Monitor.removedDashboardsChanged")
    private var removedListObserver: AnyCancellable?
    /// How long Delete waits for an installer holding the deleted list.
    var removedListLockTimeout: TimeInterval = 2

    init(root: URL = MonitorPaths.root,
         collector: @escaping (MonitorServer) async throws -> MonitorServerMetrics = {
             try await MonitorServerCollector().collect($0)
         }) {
        self.root = root
        self.collector = collector
        let ownRoot = root.standardizedFileURL
        // Posted synchronously on the main thread by deleteDashboard.
        removedListObserver = NotificationCenter.default.publisher(for: Self.removedDashboardsChanged)
            .filter { ($0.object as? URL)?.standardizedFileURL == ownRoot }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadFiles() }
            }
    }

    var dashboardsDirectory: URL { root.appendingPathComponent("dashboards", isDirectory: true) }

    func start() {
        guard task == nil else { return }
        try? FileManager.default.createDirectory(at: dashboardsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        generation &+= 1
        let runGeneration = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == runGeneration else { break }
                self.reloadFiles()
                let due = self.lastServerRefresh.map { Date().timeIntervalSince($0) >= self.refreshSeconds } ?? true
                if due || self.refreshRequested {
                    self.refreshRequested = false
                    let finished = await self.refreshServers(generation: runGeneration)
                    guard !Task.isCancelled, self.generation == runGeneration else { break }
                    // A poll cancelled for a replaced configuration leaves the
                    // new one due at once instead of a whole interval later.
                    if finished { self.lastServerRefresh = Date() }
                }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        lastServerRefresh = nil
        readings = readings.map { value in
            var reading = value
            reading.refreshing = false
            return reading
        }
    }

    func requestRefresh() {
        refreshRequested = true
    }

    func reloadFiles() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dashboardsDirectory,
                                                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var decoded: [MonitorDashboard] = []
        var rejected = 0
        var ids = Set<String>()
        var filesByID: [String: [URL]] = [:]
        // WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
        let removed = try? MonitorRemovedDashboards.load(root: root)
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "json" {
            do {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? Int.max) <= 2_000_000 else {
                    throw MonitorValidationError.invalidDashboard
                }
                let dashboard = try MonitorDashboard.decode(Data(contentsOf: file))
                filesByID[dashboard.id, default: []].append(file)
                // A deleted board stays hidden while its collector rewrites it.
                if removed?.contains(dashboard.id) == true { continue }
                guard ids.insert(dashboard.id).inserted else { throw MonitorValidationError.invalidDashboard }
                decoded.append(dashboard)
            } catch { rejected += 1 }
        }
        dashboardFiles = filesByID
        dashboards = decoded.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if removed == nil {
            dashboardError = "The list of deleted dashboards could not be read. Ask your agent to validate removed-dashboards.json."
        } else {
            dashboardError = rejected > 0 ? "\(rejected) dashboard file(s) could not be loaded. Ask your agent to validate them." : nil
        }

        // WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
        serverStatusRemoved = removed?.contains(Self.serverStatusID) == true
        // Servers are polled only while the list is readable and does not
        // hold server-status: an unreadable list may hide a deletion, so it
        // pauses polling instead of resuming it.
        let pollingAllowed = removed != nil && !serverStatusRemoved
        if !pollingAllowed { refreshTask?.cancel() }
        let configFile = root.appendingPathComponent("servers.json")
        // A deleted Server status reads no configuration, so refreshServers
        // has nothing to connect to; servers.json itself stays as it is.
        guard !serverStatusRemoved, fm.fileExists(atPath: configFile.path) else {
            serverStatusListed = false
            configuration = nil
            readings = []
            serverError = nil
            return
        }
        do {
            let values = try configFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 128_000 else {
                throw MonitorValidationError.invalidServers
            }
            let newConfiguration = try MonitorServerConfiguration.decode(Data(contentsOf: configFile))
            // No servers named: nothing was set up, so there is no board.
            guard !newConfiguration.servers.isEmpty else {
                serverStatusListed = false
                configuration = nil
                readings = []
                serverError = nil
                return
            }
            serverStatusListed = true
            guard pollingAllowed else {
                configuration = nil
                readings = []
                serverError = "Server status is paused until the list of deleted dashboards can be read. Ask your agent to validate removed-dashboards.json."
                return
            }
            if newConfiguration != configuration {
                let previous = Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0) })
                readings = newConfiguration.servers.map { server in
                    if let reading = previous[server.id], reading.server == server { return reading }
                    return MonitorServerReading(server: server)
                }
                configuration = newConfiguration
                refreshSeconds = newConfiguration.refreshSeconds
                lastServerRefresh = nil
            }
            serverError = nil
        } catch {
            // A file that is there but unreadable is a setup attempt: the
            // board stays listed and says what is wrong.
            serverStatusListed = true
            configuration = nil
            serverError = "Server configuration could not be loaded. Ask your agent to validate servers.json."
            readings = readings.map { reading in
                var stale = reading
                stale.refreshFailed = true
                return stale
            }
        }
    }

    /// Deletes one dashboard: records its ID as removed first (so a collector
    /// that rewrites the snapshot cannot bring it back), then removes every
    /// snapshot file with that ID. Server status is deleted the same way; it
    /// has no snapshot, and once listed Whytap stops polling its servers.
    /// Collectors, servers.json and other files in Monitor are never touched.
    /// Returns false when the board was no longer listed (another surface
    /// deleted it); its ID is still recorded.
    /// WHY: .project-docs/decisions/2026-11-21-monitor-dashboard-delete.md
    @discardableResult
    func deleteDashboard(id: String) throws -> Bool {
        guard MonitorDashboard.validID(id) else {
            throw MonitorValidationError.invalidDashboard
        }
        // The whole change runs under the list's lock, which install-dashboard
        // also takes, so a reinstall cannot land between hiding the ID and
        // removing the files (and lose its fresh snapshot).
        let wasListed = try MonitorRemovedDashboards.withLock(root: root, timeout: removedListLockTimeout) {
            reloadFiles()
            let wasListed = id == Self.serverStatusID
                ? serverStatusListed : dashboards.contains { $0.id == id }
            var removed = try MonitorRemovedDashboards.load(root: root)
            if !removed.contains(id) {
                removed.insert(id)
                try removed.save(root: root)
            }
            let fm = FileManager.default
            for file in dashboardFiles[id] ?? [] {
                // Only regular files inside dashboards/ that decoded to this ID.
                guard file.deletingLastPathComponent().standardizedFileURL
                        == dashboardsDirectory.standardizedFileURL else { continue }
                // The ID is already hidden; a file that cannot be removed is
                // simply rewritten or left by its collector.
                try? fm.removeItem(at: file)
            }
            return wasListed
        }
        reloadFiles()
        // Every other live Monitor surface over this folder reloads now.
        NotificationCenter.default.post(name: Self.removedDashboardsChanged, object: root.standardizedFileURL)
        return wasListed
    }

    /// Returns false when the poll was cancelled before it finished.
    @discardableResult
    func refreshServers(generation refreshGeneration: UInt64? = nil) async -> Bool {
        guard let configuration else { return true }
        readings = readings.map { reading in
            var pending = reading
            pending.refreshing = true
            return pending
        }
        // Its own task, so reloadFiles can cancel it the moment Server status
        // is deleted (here or on another surface), the list turns unreadable
        // or the configuration it started with is no longer the current one.
        let poll = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.collect(configuration, generation: refreshGeneration)
        }
        refreshTask = poll
        await withTaskCancellationHandler { await poll.value } onCancel: { poll.cancel() }
        if refreshTask == poll { refreshTask = nil }
        if poll.isCancelled {
            readings = readings.map { reading in
                var idle = reading
                idle.refreshing = false
                return idle
            }
        }
        return !poll.isCancelled
    }

    private func collect(_ configuration: MonitorServerConfiguration, generation refreshGeneration: UInt64?) async {
        let collector = self.collector
        await withTaskGroup(of: (MonitorServer, MonitorServerMetrics?).self) { group in
            for server in configuration.servers {
                group.addTask {
                    do { return (server, try await collector(server)) }
                    catch { return (server, nil) }
                }
            }
            for await (server, metrics) in group {
                guard !Task.isCancelled,
                      refreshGeneration == nil || refreshGeneration == generation,
                      self.configuration?.servers.contains(server) == true,
                      let index = readings.firstIndex(where: { $0.server == server }) else { continue }
                readings[index].refreshing = false
                readings[index].refreshFailed = metrics == nil
                if let metrics {
                    readings[index].metrics = metrics
                    readings[index].observedAt = Date()
                }
            }
        }
    }
}

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

    /// Server status's ID in the deleted list; never a snapshot's ID.
    static let serverStatusID = "server-status"

    let root: URL
    private let collector: (MonitorServer) async throws -> MonitorServerMetrics
    private var configuration: MonitorServerConfiguration?
    private var task: Task<Void, Never>?
    private var lastServerRefresh: Date?
    private var refreshRequested = false
    private var generation: UInt64 = 0
    /// Every dashboard file by the ID it decodes to, duplicates included, so
    /// Delete removes each copy of the board it lists.
    private var dashboardFiles: [String: [URL]] = [:]
    /// How long Delete waits for an installer holding the deleted list.
    var removedListLockTimeout: TimeInterval = 2

    init(root: URL = MonitorPaths.root,
         collector: @escaping (MonitorServer) async throws -> MonitorServerMetrics = {
             try await MonitorServerCollector().collect($0)
         }) {
        self.root = root
        self.collector = collector
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
                    await self.refreshServers(generation: runGeneration)
                    guard !Task.isCancelled, self.generation == runGeneration else { break }
                    self.lastServerRefresh = Date()
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
        let configFile = root.appendingPathComponent("servers.json")
        // A deleted Server status reads no configuration, so refreshServers
        // has nothing to connect to; servers.json itself stays as it is.
        guard !serverStatusRemoved, fm.fileExists(atPath: configFile.path) else {
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
                ? !serverStatusRemoved : dashboards.contains { $0.id == id }
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
        return wasListed
    }

    func refreshServers(generation refreshGeneration: UInt64? = nil) async {
        guard let configuration else { return }
        readings = readings.map { reading in
            var pending = reading
            pending.refreshing = true
            return pending
        }
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

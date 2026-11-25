import AppKit
import Combine

struct NotifySourceStatus: Identifiable, Equatable {
    let id: String
    var script: NotifyScript
    var message: String
}

enum NotifyRegistry {
    static func read(_ directory: URL) throws -> ([NotifyScript], [String]) {
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard files.count <= 16 else { throw NotifyError.invalidConfiguration }
        var scripts: [NotifyScript] = [], errors: [String] = []
        var ids = Set<String>()
        for url in files {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      (values.fileSize ?? 0) <= 65536 else { throw NotifyError.invalidConfiguration }
                let script = try JSONDecoder().decode(NotifyScript.self, from: Data(contentsOf: url))
                try script.validate()
                guard script.id == url.deletingPathExtension().lastPathComponent, ids.insert(script.id).inserted else {
                    throw NotifyError.invalidConfiguration
                }
                scripts.append(script)
            } catch { errors.append(url.lastPathComponent) }
        }
        return (scripts, errors)
    }
}

/// App-owned workers: no LaunchAgent, server, background service, or model calls.
// WHY: .project-docs/decisions/2026-10-19-script-notifications.md
@MainActor
final class NotifyScriptSupervisor: ObservableObject {
    static let shared = NotifyScriptSupervisor(directory: NotifyPaths.root, hub: .shared)
    @Published private(set) var sources: [NotifySourceStatus] = []
    @Published private(set) var error: String?
    private let directory: URL
    private let hub: LocalNotificationHub
    private var running = false
    private var generation = 0
    private var polling: Task<Void, Never>?
    private var processes: [String: NotifyProcess] = [:]
    private var tokens: [String: UUID] = [:]
    private var decoders: [String: NotifyLineDecoder] = [:]
    private var retries: [String: Task<Void, Never>] = [:]
    private var failures: [String: Int] = [:]
    private var rate: [String: (Date, Int)] = [:]
    private var sleepObservers: [NSObjectProtocol] = []

    init(directory: URL, hub: LocalNotificationHub) { self.directory = directory; self.hub = hub }
    func start() {
        guard !running else { return }
        running = true; generation += 1
        hub.setSuspended(false)
        let workspace = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspendWorkers() }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeWorkers() }
            }
        ]
        resumeWorkers()
        Task { await hub.load() }
    }
    func stop() {
        running = false; generation += 1
        suspendWorkers()
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; sleepObservers.removeAll()
    }
    private func suspendWorkers() {
        generation += 1; polling?.cancel(); polling = nil
        retries.values.forEach { $0.cancel() }; retries.removeAll()
        tokens.removeAll(); decoders.removeAll(); rate.removeAll()
        let children = Array(processes.values); processes.removeAll()
        children.forEach { $0.stop() }
        children.forEach { $0.waitUntilStopped() }
        hub.setSuspended(true)
    }
    private func resumeWorkers() {
        guard running else { return }
        generation += 1; let run = generation
        polling?.cancel(); hub.setSuspended(false)
        polling = Task { [weak self] in
            guard let self else { return }
            do {
                for folder in [directory, directory.appendingPathComponent("sources"), directory.appendingPathComponent("logos")] {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }
            } catch { self.error = "Couldn’t open notification sources."; return }
            do {
                let guide = directory.appendingPathComponent("README.md")
                try Data(NotifySetupGuide.contents(directory: directory).utf8).write(to: guide, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: guide.path)
            } catch { self.error = "Couldn’t write the source setup guide." }
            while !Task.isCancelled && self.running && self.generation == run {
                let sourceDirectory = directory.appendingPathComponent("sources")
                let snapshot = await Task.detached(priority: .utility) { Result { try NotifyRegistry.read(sourceDirectory) } }.value
                guard !Task.isCancelled, self.generation == run else { return }
                switch snapshot {
                case .success(let (scripts, invalid)):
                    self.publishError(invalid.isEmpty ? nil : "Invalid source configuration: " + invalid.joined(separator: ", "))
                    self.reconcile(scripts)
                case .failure:
                    self.publishError("Couldn’t read notification sources (maximum 16).")
                    self.reconcile([])
                }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }
    }
    /// The registry is reread every 2 s. Republishing an unchanged list or
    /// error redraws every observer, Settings among them, for nothing.
    // WHY: .project-docs/decisions/2026-11-25-settings-features-refresh.md
    func reconcile(_ scripts: [NotifyScript]) {
        for old in sources where !scripts.contains(where: { $0 == old.script }) { stopSource(old.id) }
        let next = scripts.map { script in
            sources.first(where: { $0.script == script }) ?? NotifySourceStatus(id: script.id, script: script, message: script.enabled ? "Starting…" : "Off")
        }
        if next != sources { sources = next }
        for script in scripts where script.enabled && processes[script.id] == nil && retries[script.id] == nil { launch(script) }
    }
    private func publishError(_ next: String?) {
        if error != next { error = next }
    }
    private func stopSource(_ id: String) {
        tokens[id] = nil; decoders[id] = nil; retries.removeValue(forKey: id)?.cancel()
        if let process = processes.removeValue(forKey: id) { process.stop(); process.waitUntilStopped() }
        failures[id] = nil; rate[id] = nil
    }
    private func launch(_ script: NotifyScript) {
        let token = UUID(); tokens[script.id] = token; decoders[script.id] = NotifyLineDecoder()
        do {
            let environment = Self.environment(inherited: ProcessInfo.processInfo.environment,
                                               source: script.id, directory: directory)
            processes[script.id] = try NotifyProcess(command: script.command, environment: environment,
                onData: { [weak self] data in
                    DispatchQueue.main.sync { self?.consume(data, script: script, token: token) }
                }, onExit: { [weak self] status in
                    DispatchQueue.main.async { self?.exited(script, status: status, token: token) }
                })
            status(script.id, "Running")
        } catch { status(script.id, "Couldn’t start. Check the executable and its permissions."); retry(script, failed: true) }
    }
    static func environment(inherited: [String: String], source: String, directory: URL) -> [String: String] {
        let allowed = Set(["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK"])
        var values = inherited.filter { allowed.contains($0.key) }
        values["WHYTAP_NOTIFY_SOURCE"] = source
        values["WHYTAP_NOTIFY_DIRECTORY"] = directory.path
        // Existing local sources may still read the original environment names.
        values["EXODIA_NOTIFY_SOURCE"] = source
        values["EXODIA_NOTIFY_DIRECTORY"] = directory.path
        values["PYTHONUNBUFFERED"] = "1"
        return values
    }
    private func consume(_ data: Data, script: NotifyScript, token: UUID) {
        guard running, tokens[script.id] == token else { return }
        let output = decoders[script.id]?.append(data) ?? []
        for result in output {
            do {
                let payload = try result.get()
                let now = Date()
                let previous = rate[script.id] ?? (now, 0)
                let sample = now.timeIntervalSince(previous.0) >= 1 ? (now, 0) : previous
                guard sample.1 < 10 else { status(script.id, "Rate limited (10 notifications/second)"); continue }
                rate[script.id] = (sample.0, sample.1 + 1)
                let event = try LocalNotificationEvent.make(payload, script: script)
                failures[script.id] = 0
                Task { await hub.receive(event) }
            } catch { status(script.id, "Invalid notification output. Expected one JSON object per line.") }
        }
    }
    private func exited(_ script: NotifyScript, status exitStatus: Int32, token: UUID) {
        guard running, tokens[script.id] == token else { return }
        // A final unterminated JSON object is accepted too.
        consume(Data([10]), script: script, token: token)
        processes[script.id] = nil
        status(script.id, exitStatus == 0 ? "Waiting" : "Script exited; retrying")
        retry(script, failed: exitStatus != 0)
    }
    private func retry(_ script: NotifyScript, failed: Bool) {
        let count = failed ? min(6, (failures[script.id] ?? 0) + 1) : 0
        failures[script.id] = count
        let delay = failed ? min(60, pow(2, Double(count))) : (script.intervalSeconds ?? 5)
        retries[script.id]?.cancel()
        retries[script.id] = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.running, self.sources.contains(where: { $0.script == script && $0.script.enabled }) else { return }
            self.retries[script.id] = nil; self.launch(script)
        }
    }
    private func status(_ id: String, _ message: String) {
        if let index = sources.firstIndex(where: { $0.id == id }), sources[index].message != message { sources[index].message = message }
    }
    func setEnabled(_ enabled: Bool, id: String) {
        guard var script = sources.first(where: { $0.id == id })?.script else { return }
        script.enabled = enabled
        save(script)
    }
    private func save(_ script: NotifyScript) {
        do {
            let url = directory.appendingPathComponent("sources/\(script.id).json")
            try JSONEncoder().encode(script).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            reconcile(sources.map { $0.id == script.id ? script : $0.script })
        } catch { self.error = "Couldn’t save the source setting." }
    }
    func remove(id: String) {
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("sources/\(id).json"))
            stopSource(id); sources.removeAll { $0.id == id }
        } catch { self.error = "Couldn’t remove the source." }
    }
}

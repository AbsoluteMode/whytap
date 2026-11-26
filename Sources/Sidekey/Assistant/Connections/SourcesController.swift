import AppKit
import Foundation

/// How a local server process gets its PATH and command. A GUI app inherits a
/// minimal PATH, so `npx`, `uvx` or `docker` are found through the login shell.
struct SourceProcessEnvironment: Sendable {
    var resolve: @Sendable (String) async -> String?
    var base: @Sendable () async -> [String: String]

    static let inheritedNames: Set<String> = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
                                              "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING"]

    static let live = SourceProcessEnvironment(
        resolve: { command in
            if command.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: command) ? command : nil }
            guard !command.contains("/") else { return nil }
            let path = await LoginPath.shared.value()
            for directory in path.split(separator: ":") {
                let candidate = String(directory) + "/" + command
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
            return nil
        },
        base: {
            // Model keys and other app secrets are never added: only these names.
            var values = ProcessInfo.processInfo.environment.filter { inheritedNames.contains($0.key) }
            values["PATH"] = await LoginPath.shared.value()
            return values
        })

    /// The login shell's PATH, read once per launch (bounded to 5 s).
    actor LoginPath {
        static let shared = LoginPath()
        private var cached: String?
        static let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        func value() async -> String {
            if let cached { return cached }
            let found = await Task.detached(priority: .utility) { () -> String? in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
                process.arguments = ["-lc", "printf '%s' \"$PATH\""]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return nil }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                let path = String(decoding: data.prefix(16_384), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? nil : path
            }.value
            var parts = (found ?? Self.fallback).split(separator: ":").map(String.init)
            for extra in Self.fallback.split(separator: ":").map(String.init) where !parts.contains(extra) { parts.append(extra) }
            let joined = parts.joined(separator: ":")
            cached = joined
            return joined
        }
    }
}

/// Sources the user connected for the Agent: the manifest (no secret values),
/// Keychain secrets, live MCP clients and each source's status.
///
/// Servers start lazily (on Check or the first Agent call), stop after
/// 10 idle minutes, on sleep, and with the app (parent-death guard). The
/// Agent may call only approved Read tools; this is checked here, again, at
/// every call. WHY: .project-docs/decisions/2026-11-26-agent-sources.md
@MainActor
final class SourcesController: ObservableObject {
    static let shared = SourcesController()

    static let readTimeout: TimeInterval = 10
    static let proofTimeout: TimeInterval = 15
    static let resultLimit = 24_000
    static let idleSeconds: TimeInterval = 600

    @Published private(set) var sources: [SourceRecord] = []
    @Published private(set) var statuses: [String: SourceStatus] = [:]
    @Published private(set) var error: String?

    let fileURL: URL
    private let keys: ProviderKeyStore
    private let classifier: SourceToolModelClassifier?
    private let session: URLSession
    private let environment: SourceProcessEnvironment
    private var clients: [String: MCPClient] = [:]
    private var connecting: [String: Task<MCPClient, Error>] = [:]
    private var lastUsed: [String: Date] = [:]
    private var exits: [String: [Date]] = [:]
    private var idle: Task<Void, Never>?
    private var sleepObserver: NSObjectProtocol?
    private var loaded = false

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("whytap", isDirectory: true)
            .appendingPathComponent("assistant", isDirectory: true)
    }

    init(directory: URL = SourcesController.defaultDirectory, keys: ProviderKeyStore = ProviderKeyStore(),
         classifier: SourceToolModelClassifier? = .agentModel, session: URLSession = .shared,
         environment: SourceProcessEnvironment = .live) {
        fileURL = directory.appendingPathComponent("sources.json")
        self.keys = keys; self.classifier = classifier; self.session = session; self.environment = environment
    }

    // MARK: - Manifest

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: fileURL) {
            do { sources = try JSONDecoder().decode([SourceRecord].self, from: data) }
            catch { self.error = "Couldn’t read the list of sources." }
        }
        for source in sources { statuses[source.id] = initialStatus(source) }
        if sleepObserver == nil {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in await self?.stopAll() }
                }
        }
    }

    private func save() {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sources).write(to: fileURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            if error != nil { error = nil }
        } catch { self.error = "Couldn’t save the list of sources." }
    }

    private func update(_ id: String, _ change: (inout SourceRecord) -> Void) {
        guard let index = sources.firstIndex(where: { $0.id == id }) else { return }
        change(&sources[index])
        save()
    }

    func record(_ id: String) -> SourceRecord? { sources.first { $0.id == id } }

    // MARK: - Settings actions

    /// Adds a source, stores its secrets in Keychain and checks it.
    @discardableResult
    func add(_ draft: SourceDraft) async -> String {
        loadIfNeeded()
        let id = Self.newID(name: draft.name, existing: Set(sources.map(\.id)))
        var record = SourceRecord(id: id, name: Self.uniqueName(draft.name, existing: sources.map(\.name)),
                                  kind: draft.kind, importedFrom: draft.importedFrom, transport: draft.transport,
                                  environment: draft.environment, headers: draft.headers)
        record.proof = draft.proof
        for (name, value) in draft.secrets where !value.isEmpty && record.secretNames.contains(name) {
            do { try keys.save(value, account: SourceRecord.keychainAccount(source: id, name: name)) }
            catch { self.error = "Couldn’t save a value in Keychain." }
        }
        if case .folder = draft.transport { record.tools = FolderSource.tools }
        sources.append(record)
        save()
        await check(id)
        return id
    }

    func setEnabled(_ enabled: Bool, id: String) async {
        update(id) { $0.enabled = enabled }
        if enabled { await check(id) }
        else { await stop(id); statuses[id] = .off }
    }

    func remove(_ id: String) async {
        guard let record = record(id) else { return }
        await stop(id)
        for name in record.secretNames { try? keys.delete(account: SourceRecord.keychainAccount(source: id, name: name)) }
        sources.removeAll { $0.id == id }
        statuses[id] = nil
        exits[id] = nil
        save()
    }

    func setSecret(_ value: String, name: String, id: String) async {
        guard let record = record(id), record.secretNames.contains(name) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty { try keys.delete(account: SourceRecord.keychainAccount(source: id, name: name)) }
            else { try keys.save(trimmed, account: SourceRecord.keychainAccount(source: id, name: name)) }
        } catch { self.error = "Couldn’t save a value in Keychain." }
        await stop(id)
        await check(id)
    }

    func hasSecret(_ name: String, id: String) -> Bool {
        keys.hasKey(account: SourceRecord.keychainAccount(source: id, name: name))
    }

    /// The user's own class for one tool. It is approved as the tool is now.
    func setClass(_ toolClass: SourceToolClass, tool: String, id: String) {
        guard let info = record(id)?.tools.first(where: { $0.name == tool }) else { return }
        update(id) { $0.decisions[tool] = SourceToolDecision(toolClass: toolClass, origin: .user, pinHash: info.pinHash) }
        refreshStatusAfterReview(id)
    }

    /// Accepts the current description of every changed tool.
    func approveChanges(id: String) {
        update(id) { record in
            for tool in record.tools {
                guard var decision = record.decisions[tool.name], decision.needsReview else { continue }
                decision.needsReview = false
                decision.pinHash = tool.pinHash
                record.decisions[tool.name] = decision
            }
        }
        refreshStatusAfterReview(id)
    }

    private func refreshStatusAfterReview(_ id: String) {
        guard let record = record(id), record.enabled else { return }
        switch statuses[id] {
        case .ready, .warning: statuses[id] = readyStatus(record, proof: nil)
        default: break
        }
    }

    // MARK: - Connect, classify, prove

    /// Connects, lists tools (pinning), classifies new ones and runs the proof call.
    func check(_ id: String) async {
        loadIfNeeded()
        guard let record = record(id) else { return }
        guard record.enabled else { statuses[id] = .off; return }
        let missing = missingSecrets(record)
        guard missing.isEmpty else { statuses[id] = .needsValue(missing.map(Self.displayName)); return }
        statuses[id] = .connecting
        exits[id] = nil
        if case .folder(let path) = record.transport {
            let folder = FolderSource(root: URL(fileURLWithPath: path))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                statuses[id] = .failed("The folder is missing. Remove this source or add the folder again."); return
            }
            let count = await Task.detached(priority: .utility) { folder.countFiles() }.value
            applyTools(FolderSource.tools, to: id, suggestion: nil, firstConnect: record.neverConnected)
            statuses[id] = .ready("Works · \(count >= FolderSource.maxFiles ? "\(FolderSource.maxFiles)+" : String(count)) text files")
            return
        }
        do {
            await stop(id)
            let client = try await client(for: id)
            let tools = try await client.listTools(timeout: 20)
            await classifyAndApply(tools, id: id)
            guard let current = self.record(id) else { return }
            let proof = await runProof(current, client: client)
            statuses[id] = readyStatus(current, proof: proof)
        } catch {
            statuses[id] = .failed((error as? MCPError)?.message ?? MCPError.notConnected.message)
            await stop(id)
        }
    }

    private func classifyAndApply(_ tools: [MCPToolInfo], id: String) async {
        guard let record = record(id) else { return }
        let fresh = tools.filter { tool in record.decisions[tool.name]?.pinHash != tool.pinHash }
        let undecided = SourceToolClassifier.undecided(fresh, presets: [:])
        var suggestion: SourceToolModelClassifier.Suggestion?
        let needsProof = record.proof == nil && record.neverConnected
        if let classifier, !undecided.isEmpty || (needsProof && !tools.isEmpty) {
            suggestion = await classifier.run(undecided.isEmpty ? tools : undecided)
        }
        applyTools(tools, to: id, suggestion: suggestion, firstConnect: record.neverConnected)
    }

    /// Pinning: unchanged tools keep their approved class; new or changed
    /// tools are classified again and, after the first connection, wait for review.
    private func applyTools(_ tools: [MCPToolInfo], to id: String, suggestion: SourceToolModelClassifier.Suggestion?,
                            firstConnect: Bool) {
        update(id) { record in
            var decisions: [String: SourceToolDecision] = [:]
            for tool in tools {
                if let old = record.decisions[tool.name], old.pinHash == tool.pinHash, !old.needsReview {
                    decisions[tool.name] = old
                    continue
                }
                if let old = record.decisions[tool.name], old.needsReview, old.origin == .user {
                    decisions[tool.name] = old
                    continue
                }
                let (toolClass, origin) = SourceToolClassifier.classify(tool, preset: nil, model: suggestion?.classes[tool.name])
                let changed = record.decisions[tool.name] != nil
                decisions[tool.name] = SourceToolDecision(
                    toolClass: toolClass, origin: origin,
                    pinHash: changed ? (record.decisions[tool.name]?.pinHash ?? "") : tool.pinHash,
                    needsReview: !firstConnect && (changed || toolClass == .read))
            }
            record.tools = tools
            record.decisions = decisions
            record.neverConnected = false
            if record.proof == nil, let proof = suggestion?.proof { record.proof = proof }
        }
    }

    private enum ProofOutcome { case worked(String), failed(String), none }

    private func runProof(_ record: SourceRecord, client: MCPClient) async -> ProofOutcome {
        let readable = record.readTools
        var call = record.proof.flatMap { proof in readable.contains { $0.name == proof.tool } ? proof : nil }
        if call == nil, let simple = readable.first(where: { ($0.inputSchema["required"]?.array ?? []).isEmpty }) {
            call = SourceProofCall(tool: simple.name, arguments: .object([:]))
        }
        guard let call else { return .none }
        do {
            let result = try await client.callTool(call.tool, arguments: call.arguments, timeout: Self.proofTimeout,
                                                   maxCharacters: 200_000)
            if result.isError { return .failed(String(result.text.prefix(120))) }
            return .worked(Self.proofSummary(result.text))
        } catch {
            return .failed((error as? MCPError)?.message ?? "No answer.")
        }
    }

    private func readyStatus(_ record: SourceRecord, proof: ProofOutcome?) -> SourceStatus {
        let reads = record.readTools.count
        if record.changedToolCount > 0 {
            return .warning("\(record.changedToolCount) tool\(record.changedToolCount == 1 ? "" : "s") changed · Review in Tools")
        }
        guard reads > 0 else { return .warning("Connected, but no read-only tools. Mark tools as Read in Tools.") }
        let count = "\(reads) read tool\(reads == 1 ? "" : "s")"
        switch proof {
        case .worked(let summary): return .ready(summary + " · " + count)
        case .failed(let reason): return .warning("Connected, but the test call failed: " + reason)
        case .some(.none), nil: return .ready("Connected · " + count)
        }
    }

    /// One short line from the proof call's answer (untrusted text, bounded).
    static func proofSummary(_ text: String) -> String {
        func clean(_ value: String) -> String {
            String(value.replacingOccurrences(of: "\n", with: " ").prefix(40))
        }
        if let value = try? MCPValue.decode(Data(text.utf8)) {
            if let login = value["login"]?.string { return "Works · signed in as @" + clean(login) }
            for key in ["displayName", "name", "email", "emailAddress"] {
                if let name = value[key]?.string, value.object?.count ?? 0 < 60 { return "Works · signed in as " + clean(name) }
            }
            if let array = value.array { return "Works · found \(array.count) item\(array.count == 1 ? "" : "s")" }
            if let total = value["total_count"]?.int ?? value["total"]?.int { return "Works · found \(total) item\(total == 1 ? "" : "s")" }
            for key in ["items", "issues", "results", "values", "data", "nodes", "pull_requests", "repositories"] {
                if let array = value[key]?.array { return "Works · found \(array.count) item\(array.count == 1 ? "" : "s")" }
            }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Works · nothing recent" }
        return "Works"
    }

    private func initialStatus(_ record: SourceRecord) -> SourceStatus {
        guard record.enabled else { return .off }
        let missing = missingSecrets(record)
        if !missing.isEmpty { return .needsValue(missing.map(Self.displayName)) }
        if record.neverConnected { return .warning("Not checked yet. Press Check again.") }
        return readyStatus(record, proof: nil)
    }

    func missingSecrets(_ record: SourceRecord) -> [String] {
        record.secretNames.filter { !keys.hasKey(account: SourceRecord.keychainAccount(source: record.id, name: $0)) }
    }

    /// "header.Authorization" → "the Authorization header"; "arg.1" → "argument 1".
    static func displayName(_ name: String) -> String {
        if name.hasPrefix("header.") { return "the " + name.dropFirst(7) + " header" }
        if name.hasPrefix("arg.") { return "argument " + name.dropFirst(4) }
        return name
    }

    // MARK: - Clients

    private func client(for id: String) async throws -> MCPClient {
        if let existing = clients[id] {
            if await existing.isOpen { return existing }
            clients[id] = nil
            await existing.close()
            var recent = (exits[id] ?? []).filter { Date().timeIntervalSince($0) < 300 }
            recent.append(Date())
            exits[id] = recent
            if recent.count > 3 {
                throw MCPError.exited(status: 1, detail: "It keeps exiting; press Check again after fixing it.")
            }
        }
        if let pending = connecting[id] { return try await pending.value }
        guard let record = record(id) else { throw MCPError.notConnected }
        let task = Task { @MainActor in try await self.makeClient(record) }
        connecting[id] = task
        defer { connecting[id] = nil }
        let client = try await task.value
        clients[id] = client
        lastUsed[id] = Date()
        scheduleIdleStop()
        return client
    }

    private func makeClient(_ record: SourceRecord) async throws -> MCPClient {
        let secret = { (name: String) -> String? in
            self.keys.read(account: SourceRecord.keychainAccount(source: record.id, name: name))
        }
        let transport: MCPTransport
        let timeout: TimeInterval
        switch record.transport {
        case .folder: throw MCPError.notConnected
        case .stdio(let command, let arguments):
            guard let executable = await environment.resolve(command) else { throw MCPError.commandNotFound(command) }
            var values = await environment.base()
            var secrets: [String] = []
            for item in record.environment {
                if item.secret {
                    guard let value = secret(item.name) else { throw MCPError.missingSecret(item.name) }
                    values[item.name] = value
                    secrets.append(value)
                } else if let value = item.value { values[item.name] = value }
            }
            var argv: [String] = []
            for argument in arguments {
                switch argument {
                case .plain(let value): argv.append(value)
                case .secret(let name):
                    guard let value = secret(name) else { throw MCPError.missingSecret(Self.displayName(name)) }
                    argv.append(value)
                    secrets.append(value)
                }
            }
            transport = MCPStdioTransport(launch: MCPStdioLaunch(executable: executable, arguments: argv, environment: values,
                                                                 directory: FileManager.default.homeDirectoryForCurrentUser,
                                                                 secrets: secrets))
            // A first `npx -y` or `uvx` run downloads the server.
            timeout = 90
        case .http(let address):
            guard let url = URL(string: address), MCPHTTPTransport.isAllowed(url) else { throw MCPError.insecureURL }
            var headers: [String: String] = [:]
            for item in record.headers {
                if item.secret {
                    guard let value = secret("header." + item.name) else { throw MCPError.missingSecret(Self.displayName("header." + item.name)) }
                    headers[item.name] = value
                } else if let value = item.value { headers[item.name] = value }
            }
            transport = MCPHTTPTransport(url: url, headers: headers, session: session)
            timeout = 20
        }
        let client = MCPClient(transport: transport)
        do { try await client.connect(timeout: timeout) }
        catch { await client.close(); throw error }
        return client
    }

    func stop(_ id: String) async {
        connecting[id]?.cancel()
        connecting[id] = nil
        guard let client = clients.removeValue(forKey: id) else { return }
        await client.close()
    }

    func stopAll() async {
        for id in Array(clients.keys) { await stop(id) }
    }

    private func scheduleIdleStop() {
        guard idle == nil else { return }
        idle = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                let now = Date()
                for (id, used) in self.lastUsed where now.timeIntervalSince(used) > Self.idleSeconds {
                    self.lastUsed[id] = nil
                    await self.stop(id)
                }
                if self.clients.isEmpty { self.idle = nil; return }
            }
        }
    }

    // MARK: - The Agent

    /// Approved Read tools of enabled sources, or nil without any. No server
    /// is started for this: the tool lists come from the last check.
    func agentCatalog() -> AgentSourceCatalog? {
        loadIfNeeded()
        var tools: [AgentSourceCatalog.Tool] = []
        var used = Set<String>()
        for record in sources where record.enabled {
            if case .needsValue = statuses[record.id] { continue }
            if case .failed = statuses[record.id], clients[record.id] == nil, record.neverConnected { continue }
            let prefix = Self.slug(record.name)
            for tool in record.readTools {
                var id = String((prefix + "__" + Self.slug(tool.name, limit: 48)).prefix(64))
                var suffix = 2
                while used.contains(id) { id = String(id.prefix(60)) + "_\(suffix)"; suffix += 1 }
                used.insert(id)
                tools.append(.init(id: id, sourceID: record.id, sourceName: record.name, tool: tool.name,
                                   signature: tool.signature, description: tool.description))
            }
        }
        guard !tools.isEmpty else { return nil }
        return AgentSourceCatalog(tools: tools) { [weak self] tool, arguments in
            guard let self else { throw MCPError.notConnected }
            return try await self.callRead(sourceID: tool.sourceID, tool: tool.tool, arguments: arguments)
        }
    }

    /// The only way the Agent reaches a source. Rechecks enablement and the
    /// tool's approved Read class (pinning included) at the moment of the call.
    func callRead(sourceID: String, tool: String, arguments: MCPValue) async throws -> MCPToolResult {
        guard let record = record(sourceID), record.enabled, record.readTools.contains(where: { $0.name == tool }) else {
            throw MCPError.notAllowed
        }
        guard arguments.object != nil else { throw MCPError.server(code: -32602, message: "arguments must be a JSON object") }
        if case .folder(let path) = record.transport {
            let folder = FolderSource(root: URL(fileURLWithPath: path))
            let work = Task.detached(priority: .userInitiated) {
                try folder.call(tool, arguments: arguments, maxCharacters: Self.resultLimit)
            }
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
        var attempt = 0
        while true {
            attempt += 1
            do {
                let client = try await client(for: sourceID)
                lastUsed[sourceID] = Date()
                if await client.toolsChanged {
                    // The server says its tools changed: re-pin before calling.
                    let tools = try await client.listTools(timeout: Self.readTimeout)
                    await classifyAndApply(tools, id: sourceID)
                    guard self.record(sourceID)?.readTools.contains(where: { $0.name == tool }) == true else {
                        statuses[sourceID] = self.record(sourceID).map { readyStatus($0, proof: nil) }
                        throw MCPError.notAllowed
                    }
                }
                let result = try await client.callTool(tool, arguments: arguments, timeout: Self.readTimeout,
                                                       maxCharacters: Self.resultLimit)
                lastUsed[sourceID] = Date()
                return result
            } catch MCPError.sessionExpired where attempt == 1 {
                await stop(sourceID)
            } catch let error as MCPError {
                switch error {
                case .exited, .commandNotFound, .unauthorized, .network, .tooLarge, .unsupportedProtocol, .insecureURL:
                    statuses[sourceID] = .failed(error.message)
                default: break
                }
                throw error
            }
        }
    }

    // MARK: - Names

    static func slug(_ text: String, limit: Int = 16) -> String {
        let allowed = text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" }
        let collapsed = String(allowed).split(separator: "_").joined(separator: "_")
        return String((collapsed.isEmpty ? "source" : collapsed).prefix(limit))
    }

    static func newID(name: String, existing: Set<String>) -> String {
        var id: String
        repeat { id = slug(name, limit: 12) + "-" + UUID().uuidString.prefix(6).lowercased() } while existing.contains(id)
        return id
    }

    static func uniqueName(_ name: String, existing: [String]) -> String {
        guard existing.contains(name) else { return name }
        var index = 2
        while existing.contains("\(name) \(index)") { index += 1 }
        return "\(name) \(index)"
    }
}

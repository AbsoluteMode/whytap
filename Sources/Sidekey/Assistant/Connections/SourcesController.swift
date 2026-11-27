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
/// 10 idle minutes, on sleep, and with the app (parent-death guard).
///
/// Approval is checked at the current generation: every connection re-lists
/// the tools (pinning) before any call, a list_changed notice holds them until
/// a newer list is applied, and enablement, the live client and the tool's
/// approved pin are checked again right before each proof or Agent call.
/// Removing or turning off a source revokes it at once and discards answers
/// still in flight. Tools of imported and custom servers wait for the user's
/// approval before Whytap calls any of them.
/// WHY: .project-docs/decisions/2026-11-26-agent-sources.md
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
    private let keyStore: ProviderKeyStore
    /// Every Keychain access (read, write, delete, presence) goes through
    /// this: nil while the feature is gated off, so an off controller never
    /// reaches the store. WHY: .project-docs/decisions/2026-11-27-agent-sources-gated.md
    private var keys: ProviderKeyStore? { isEnabled ? keyStore : nil }
    private let classifier: SourceToolModelClassifier?
    private let session: URLSession
    private let environment: SourceProcessEnvironment
    private var clients: [String: MCPClient] = [:]
    private var connecting: [String: Task<MCPClient, Error>] = [:]
    /// The client and list epoch whose tools were applied (pinning, classes).
    /// A call is sent only on that client while it still has that epoch.
    private struct Validation: Equatable { let client: ObjectIdentifier; let epoch: Int }
    private var validated: [String: Validation] = [:]
    /// Bumped by stop, disable, remove, new values and every class change or
    /// approval: work started under an older generation must not publish,
    /// apply or call anything, and its lease is revoked at once.
    private var generations: [String: Int] = [:]
    private var leases: [String: SourceLease] = [:]
    /// Runs a folder call (tests may hold it to revoke during a read).
    var folderReader: @Sendable (FolderSource, String, MCPValue) async throws -> MCPToolResult = { folder, tool, arguments in
        try await SourcesController.folderCall(folder, tool: tool, arguments: arguments)
    }
    private var masks: [String: SourceSecretMask] = [:]
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

    /// False while the feature is gated off: nothing is loaded, saved, stored
    /// in Keychain, connected or offered to the Agent.
    /// WHY: .project-docs/decisions/2026-11-27-agent-sources-gated.md
    let isEnabled: Bool

    init(enabled: Bool = AgentSourcesGate.isEnabled,
         directory: URL = SourcesController.defaultDirectory, keys: ProviderKeyStore = ProviderKeyStore(),
         classifier: SourceToolModelClassifier? = .agentModel, session: URLSession = .shared,
         environment: SourceProcessEnvironment = .live) {
        isEnabled = enabled
        fileURL = directory.appendingPathComponent("sources.json")
        self.keyStore = keys; self.classifier = classifier; self.session = session; self.environment = environment
    }

    // MARK: - Manifest

    func loadIfNeeded() {
        guard isEnabled, !loaded else { return }
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
        guard isEnabled else { return }
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

    // MARK: - Generations

    private func generation(_ id: String) -> Int { generations[id] ?? 0 }

    /// Revokes everything started under the current generation, synchronously:
    /// the lease a client checks when it dispatches a call is revoked here.
    private func bump(_ id: String) {
        leases[id]?.revoke()
        leases[id] = SourceLease()
        generations[id] = generation(id) + 1
    }

    private func lease(_ id: String) -> SourceLease {
        if let lease = leases[id] { return lease }
        let lease = SourceLease()
        leases[id] = lease
        return lease
    }

    // MARK: - Known values

    /// This source's secret values, masked out of every server text before it
    /// reaches Settings, the manifest or a model.
    func mask(_ id: String) -> SourceSecretMask {
        if let mask = masks[id] { return mask }
        guard let record = record(id) else { return SourceSecretMask([]) }
        let mask = SourceSecretMask(record.secretNames.compactMap {
            keys?.read(account: SourceRecord.keychainAccount(source: id, name: $0))
        })
        masks[id] = mask
        return mask
    }

    /// The one way an error reaches a status line: known values masked.
    private func message(_ error: Error, id: String) -> String {
        mask(id).error(error as? MCPError ?? .notConnected).message
    }

    /// The source still exists, is on, and nothing revoked it since `generation`.
    private func isCurrent(_ id: String, _ generation: Int) -> Bool {
        record(id)?.enabled == true && self.generation(id) == generation
    }

    // MARK: - Settings actions

    /// Adds a source, stores its secrets in Keychain and checks it. A draft
    /// that breaks the credential policy is refused here too.
    @discardableResult
    func add(_ draft: SourceDraft) async -> String? {
        guard isEnabled else { return nil }
        loadIfNeeded()
        if let problem = draft.credentialProblem { error = problem; return nil }
        let id = Self.newID(name: draft.name, existing: Set(sources.map(\.id)))
        var record = SourceRecord(id: id, name: Self.uniqueName(draft.name, existing: sources.map(\.name)),
                                  kind: draft.kind, importedFrom: draft.importedFrom, transport: draft.transport,
                                  environment: draft.environment, headers: draft.headers)
        record.proof = draft.proof
        for (name, value) in draft.secrets where !value.isEmpty && record.secretNames.contains(name) {
            do { try keys?.save(value, account: SourceRecord.keychainAccount(source: id, name: name)) }
            catch { self.error = "Couldn’t save a value in Keychain." }
        }
        if case .folder(let path) = draft.transport {
            // The folder as selected: its real path and identity, checked at every open.
            guard let identity = FolderSource.identify(path) else { error = "That folder can’t be read."; return nil }
            record.transport = .folder(path: identity.path)
            record.folder = identity
            record.tools = FolderSource.tools
        }
        sources.append(record)
        save()
        await check(id)
        return id
    }

    func setEnabled(_ enabled: Bool, id: String) async {
        update(id) { $0.enabled = enabled }
        bump(id)
        masks[id] = nil
        if enabled { await check(id) }
        else { statuses[id] = .off; await stop(id) }
    }

    /// Revokes first (the record, its generation, the Agent's access), then
    /// stops the server and deletes its Keychain values.
    func remove(_ id: String) async {
        guard let record = record(id) else { return }
        bump(id)
        sources.removeAll { $0.id == id }
        statuses[id] = nil
        validated[id] = nil
        masks[id] = nil
        exits[id] = nil
        save()
        await stop(id)
        for name in record.secretNames { try? keys?.delete(account: SourceRecord.keychainAccount(source: id, name: name)) }
    }

    func setSecret(_ value: String, name: String, id: String) async {
        guard isEnabled, let record = record(id), record.secretNames.contains(name) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty { try keys?.delete(account: SourceRecord.keychainAccount(source: id, name: name)) }
            else { try keys?.save(trimmed, account: SourceRecord.keychainAccount(source: id, name: name)) }
        } catch { self.error = "Couldn’t save a value in Keychain." }
        masks[id] = nil
        await stop(id)
        await check(id)
    }

    func hasSecret(_ name: String, id: String) -> Bool {
        keys?.hasKey(account: SourceRecord.keychainAccount(source: id, name: name)) ?? false
    }

    /// The user's own class for one tool, approved as the tool is now.
    func setClass(_ toolClass: SourceToolClass, tool: String, id: String) {
        guard let info = record(id)?.tools.first(where: { $0.name == tool }) else { return }
        update(id) { $0.decisions[tool] = SourceToolDecision(toolClass: toolClass, origin: .user, pinHash: info.pinHash) }
        // A class change revokes calls in flight; the next call re-checks.
        bump(id)
        refreshStatusAfterReview(id)
    }

    /// The user approves every tool waiting for review, as described now,
    /// then the proof call runs.
    func approveChanges(id: String) async {
        update(id) { record in
            for tool in record.tools {
                guard var decision = record.decisions[tool.name], decision.needsReview else { continue }
                decision.needsReview = false
                decision.pinHash = tool.pinHash
                record.decisions[tool.name] = decision
            }
        }
        bump(id)
        refreshStatusAfterReview(id)
        await prove(id)
    }

    private func refreshStatusAfterReview(_ id: String) {
        guard let record = record(id), record.enabled else { return }
        switch statuses[id] {
        case .ready, .warning: statuses[id] = readyStatus(record, proof: nil)
        // The change revoked a check in progress: check again.
        case .connecting: Task { await self.check(id) }
        default: break
        }
    }

    // MARK: - Connect, classify, prove

    /// Connects, lists tools (pinning), classifies new ones and runs the proof call.
    func check(_ id: String) async {
        guard isEnabled else { return }
        loadIfNeeded()
        guard let record = record(id) else { return }
        guard record.enabled else { statuses[id] = .off; return }
        let missing = missingSecrets(record)
        guard missing.isEmpty else { statuses[id] = .needsValue(missing.map(Self.displayName)); return }
        statuses[id] = .connecting
        exits[id] = nil
        await stop(id)
        let generation = generation(id)
        if case .folder = record.transport {
            guard let folder = FolderSource(record: record), folder.openRoot() != nil else {
                statuses[id] = .failed(FolderSource.missingReason); return
            }
            let count = try? await MCPDeadline.run(until: Date().addingTimeInterval(Self.proofTimeout),
                                                   timeout: .timedOut(seconds: Int(Self.proofTimeout))) { try folder.countFiles() }
            guard isCurrent(id, generation) else { return }
            guard let count else { statuses[id] = .failed(MCPError.timedOut(seconds: Int(Self.proofTimeout)).message); return }
            applyTools(FolderSource.tools, to: id, suggestion: nil)
            statuses[id] = .ready("Works · \(count >= FolderSource.maxFiles ? "\(FolderSource.maxFiles)+" : String(count)) text files")
            return
        }
        do {
            let client = try await client(for: id, generation: generation)
            try await validate(id, client: client, generation: generation)
            let proof = await runProof(id, client: client, generation: generation)
            guard isCurrent(id, generation), let current = self.record(id) else { return }
            statuses[id] = readyStatus(current, proof: proof)
        } catch {
            // A disable, removal or new check while connecting wins.
            guard isCurrent(id, generation) else { return }
            statuses[id] = .failed(message(error, id: id))
            await stop(id)
        }
    }

    /// After approval: the proof call on the live (or a new) connection.
    private func prove(_ id: String) async {
        guard let record = record(id), record.enabled, !record.readTools.isEmpty else { return }
        if case .folder = record.transport { return }
        let generation = generation(id)
        do {
            let client = try await client(for: id, generation: generation)
            if !(await isValidated(id, client)) {
                try await validate(id, client: client, generation: generation)
            }
            let proof = await runProof(id, client: client, generation: generation)
            guard isCurrent(id, generation), let current = self.record(id) else { return }
            statuses[id] = readyStatus(current, proof: proof)
        } catch {
            guard isCurrent(id, generation) else { return }
            statuses[id] = .failed(message(error, id: id))
        }
    }

    /// Lists the client's tools and applies them (pinning, classes). Until it
    /// succeeds on this client and generation, its tools cannot be called.
    private func validate(_ id: String, client: MCPClient, generation: Int) async throws {
        validated[id] = nil
        // Known values are masked from tool metadata before it is pinned,
        // stored, classified or shown; a tool whose name carries one is dropped.
        // A list is applied only if it is still the client's current list
        // after every await (the list itself and the classification); a list
        // overtaken by a change notice is read again, at most three times.
        let mask = mask(id)
        for _ in 0..<3 {
            let (tools, epoch) = try await client.listTools(timeout: 20, transform: { mask.tool($0) })
            guard isCurrent(id, generation), clients[id] === client else { throw MCPError.cancelled }
            guard await client.currentEpoch == epoch else { continue }
            guard let suggestion = try await classify(id, tools, client: client, generation: generation) else { continue }
            guard await client.currentEpoch == epoch, isCurrent(id, generation), clients[id] === client else { continue }
            // No await between this check and applying: the list applied is the current one.
            applyTools(tools, to: id, suggestion: suggestion.value)
            validated[id] = Validation(client: ObjectIdentifier(client), epoch: epoch)
            return
        }
        throw MCPError.cancelled
    }

    private struct Classified { let value: SourceToolModelClassifier.Suggestion? }

    /// The model suggestion for the tools nothing else settles, or nil when
    /// the source was revoked meanwhile (the caller then reads the list again
    /// or stops).
    private func classify(_ id: String, _ tools: [MCPToolInfo], client: MCPClient, generation: Int) async throws -> Classified? {
        guard let record = record(id) else { throw MCPError.cancelled }
        let fresh = tools.filter { tool in record.decisions[tool.name]?.pinHash != tool.pinHash }
        let undecided = SourceToolClassifier.undecided(fresh, presets: [:])
        var suggestion: SourceToolModelClassifier.Suggestion?
        let needsProof = record.proof == nil && record.neverConnected
        if let classifier, !undecided.isEmpty || (needsProof && !tools.isEmpty) {
            suggestion = await classifier.run(undecided.isEmpty ? tools : undecided)
            guard isCurrent(id, generation), clients[id] === client else { throw MCPError.cancelled }
        }
        return Classified(value: suggestion)
    }

    /// The live client's current list is the one applied.
    private func isValidated(_ id: String, _ client: MCPClient) async -> Bool {
        guard let epoch = await client.currentEpoch else { return false }
        return validated[id] == Validation(client: ObjectIdentifier(client), epoch: epoch)
    }

    /// Pinning: unchanged approved tools keep their class. New or changed
    /// tools are classified again; a changed tool, a Read tool added after
    /// the first connection, and every Read tool of a server that is not
    /// trusted on connect wait for the user's approval.
    private func applyTools(_ tools: [MCPToolInfo], to id: String, suggestion: SourceToolModelClassifier.Suggestion?) {
        update(id) { record in
            let firstConnect = record.neverConnected
            let trusted = record.kind.trustedOnConnect
            var decisions: [String: SourceToolDecision] = [:]
            for tool in tools {
                if let old = record.decisions[tool.name], old.pinHash == tool.pinHash {
                    decisions[tool.name] = old
                    continue
                }
                let (toolClass, origin) = SourceToolClassifier.classify(tool, preset: nil, model: suggestion?.classes[tool.name])
                let old = record.decisions[tool.name]
                decisions[tool.name] = SourceToolDecision(
                    toolClass: toolClass, origin: origin,
                    pinHash: old?.pinHash ?? tool.pinHash,
                    needsReview: old != nil || (toolClass == .read && (!trusted || !firstConnect)))
            }
            record.tools = tools
            record.decisions = decisions
            record.neverConnected = false
            if record.proof == nil, let proof = suggestion?.proof { record.proof = proof }
        }
    }

    private enum ProofOutcome { case worked(String), failed(String), none }

    private func runProof(_ id: String, client: MCPClient, generation: Int) async -> ProofOutcome {
        guard let record = record(id) else { return .none }
        let readable = record.readTools
        var call = record.proof.flatMap { proof in readable.contains { $0.name == proof.tool } ? proof : nil }
        if call == nil, let simple = readable.first(where: { ($0.inputSchema["required"]?.array ?? []).isEmpty }) {
            call = SourceProofCall(tool: simple.name, arguments: .object([:]))
        }
        guard let call else { return .none }
        do {
            let result = try await invoke(id, tool: call.tool, arguments: call.arguments, client: client,
                                          generation: generation, timeout: Self.proofTimeout, limit: 200_000)
            if result.isError { return .failed(Self.oneLine(result.text, limit: 120)) }
            return .worked(Self.proofSummary(result.text))
        } catch {
            return .failed(message(error, id: id))
        }
    }

    /// The last gate before a server runs a tool: the source is current, the
    /// client is the live validated one, and the tool is an approved Read
    /// tool at its current pin. An answer that arrives after a revocation is
    /// discarded.
    ///
    /// The client re-checks the lease, list epoch and pin in the same step
    /// that sends, so a revocation on this actor after this check still wins.
    /// The result is masked before anyone sees it.
    private func invoke(_ id: String, tool: String, arguments: MCPValue, client: MCPClient, generation: Int,
                        timeout: TimeInterval, limit: Int) async throws -> MCPToolResult {
        guard isCurrent(id, generation), clients[id] === client, let validation = validated[id],
              validation.client == ObjectIdentifier(client), let pin = approvedPin(id, tool: tool) else { throw MCPError.notAllowed }
        let lease = lease(id)
        let mask = mask(id)
        lastUsed[id] = Date()
        let result: MCPToolResult
        do {
            result = try await client.callTool(tool, arguments: arguments, timeout: timeout, maxCharacters: limit,
                                               lease: lease, epoch: validation.epoch, expectedPin: pin)
        } catch let error as MCPError { throw mask.error(error) }
        // Revoked or reclassified while the server answered: discard it.
        // The client returned it only under the approved list; the controller
        // checks its own side again: same lease, generation, validation and pin.
        guard lease.isValid, isCurrent(id, generation), validated[id] == validation,
              approvedPin(id, tool: tool) == pin else { throw MCPError.notAllowed }
        lastUsed[id] = Date()
        return mask.result(result)
    }

    /// The pin of an approved Read tool, as the user approved it now.
    private func approvedPin(_ id: String, tool: String) -> String? {
        record(id)?.readTools.first { $0.name == tool }?.pinHash
    }

    private func readyStatus(_ record: SourceRecord, proof: ProofOutcome?) -> SourceStatus {
        let reads = record.readTools.count
        let pending = record.pendingReviewCount
        if pending > 0 {
            return .warning(reads == 0 && !record.kind.trustedOnConnect
                ? "Connected · approve its tools in Details before the Agent uses them"
                : "\(pending) tool\(pending == 1 ? "" : "s") changed · Review in Details")
        }
        guard reads > 0 else { return .warning("Connected, but no read-only tools. Mark tools as Read in Details.") }
        let count = "\(reads) read tool\(reads == 1 ? "" : "s")"
        switch proof {
        case .worked(let summary): return .ready(summary + " · " + count)
        case .failed(let reason): return .warning("Connected, but the test call failed: " + reason)
        case .some(.none), nil: return .ready("Connected · " + count)
        }
    }

    static func oneLine(_ text: String, limit: Int) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(limit))
    }

    /// One short line from the proof call's answer (untrusted text, bounded).
    static func proofSummary(_ text: String) -> String {
        func clean(_ value: String) -> String { oneLine(value, limit: 40) }
        if let value = try? MCPValue.decode(Data(text.utf8)) {
            if let login = value["login"]?.string { return "Works · signed in as @" + clean(login) }
            for key in ["displayName", "name", "email", "emailAddress"] {
                if let name = value[key]?.string, value.object?.count ?? 0 < 60 { return "Works · signed in as " + clean(name) }
            }
            if let array = value.array { return "Works · found \(array.count) item\(array.count == 1 ? "" : "s")" }
            if let total = value["total_count"]?.int ?? value["total"]?.int, total >= 0 {
                return "Works · found \(total) item\(total == 1 ? "" : "s")"
            }
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
        record.secretNames.filter { !(keys?.hasKey(account: SourceRecord.keychainAccount(source: record.id, name: $0)) ?? false) }
    }

    /// "header.Authorization" → "the Authorization header".
    nonisolated static func displayName(_ name: String) -> String {
        if name.hasPrefix("header.") { return "the " + name.dropFirst(7) + " header" }
        return name
    }

    // MARK: - Clients

    /// The live client for this generation, connecting when needed. A new
    /// client is not validated: its tools are re-listed before any call.
    private func client(for id: String, generation: Int) async throws -> MCPClient {
        guard isEnabled, isCurrent(id, generation) else { throw MCPError.notAllowed }
        if let existing = clients[id] {
            if await existing.isOpen, clients[id] === existing { return existing }
            if clients[id] === existing { clients[id] = nil; validated[id] = nil }
            await existing.close()
            var recent = (exits[id] ?? []).filter { Date().timeIntervalSince($0) < 300 }
            recent.append(Date())
            exits[id] = recent
            if recent.count > 3 {
                throw MCPError.exited(status: 1, detail: "It keeps exiting; press Check again after fixing it.")
            }
        }
        guard isCurrent(id, generation) else { throw MCPError.notAllowed }
        let task: Task<MCPClient, Error>
        if let pending = connecting[id] { task = pending }
        else {
            guard let record = record(id) else { throw MCPError.notConnected }
            task = Task { @MainActor in try await self.makeClient(record, generation: generation) }
            connecting[id] = task
        }
        let client: MCPClient
        do { client = try await task.value }
        catch {
            if connecting[id] == task { connecting[id] = nil }
            throw error
        }
        if connecting[id] == task { connecting[id] = nil }
        if let live = clients[id] {
            // Another caller of the same connection stored it first.
            if live !== client { Task.detached { await client.close() } }
            guard isCurrent(id, generation) else { throw MCPError.notAllowed }
            return live
        }
        // Revoked while connecting: never keep it.
        // Revoked while connecting: answered at once, closed on its own.
        guard isCurrent(id, generation) else { Task.detached { await client.close() }; throw MCPError.notAllowed }
        clients[id] = client
        validated[id] = nil
        lastUsed[id] = Date()
        scheduleIdleStop()
        return client
    }

    /// Every await here can resume after a revocation; nothing is launched
    /// unless the source is still current right before the process or session starts.
    private func makeClient(_ record: SourceRecord, generation: Int) async throws -> MCPClient {
        func stillCurrent() throws {
            guard !Task.isCancelled, isCurrent(record.id, generation) else { throw MCPError.cancelled }
        }
        let secret = { (name: String) -> String? in
            self.keys?.read(account: SourceRecord.keychainAccount(source: record.id, name: name))
        }
        let transport: MCPTransport
        let timeout: TimeInterval
        switch record.transport {
        case .folder: throw MCPError.notConnected
        case .stdio(let command, let arguments, let directory):
            // The same policy as at setup: no secret on the command line.
            guard SourceCredentialPolicy.problem(record.transport, sendsSecrets: false) == nil else { throw MCPError.notAllowed }
            guard let executable = await environment.resolve(command) else { throw MCPError.commandNotFound(command) }
            try stillCurrent()
            var workingDirectory = FileManager.default.homeDirectoryForCurrentUser
            if let directory {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw MCPError.commandNotFound((directory as NSString).lastPathComponent + " (its working folder)")
                }
                workingDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            }
            var values = await environment.base()
            try stillCurrent()
            var secrets: [String] = []
            for item in record.environment {
                if item.secret {
                    guard let value = secret(item.name) else { throw MCPError.missingSecret(item.name) }
                    values[item.name] = value
                    secrets.append(value)
                } else if let value = item.value { values[item.name] = value }
            }
            transport = MCPStdioTransport(launch: MCPStdioLaunch(executable: executable, arguments: arguments,
                                                                 environment: values, directory: workingDirectory,
                                                                 secrets: secrets))
            // A first `npx -y` or `uvx` run downloads the server.
            timeout = 90
        case .http(let address):
            let sendsSecrets = record.headers.contains(where: \.secret)
            guard SourceCredentialPolicy.problem(record.transport, sendsSecrets: sendsSecrets) == nil,
                  let url = URL(string: address) else { throw MCPError.insecureURL }
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
        try stillCurrent()
        // Server text is masked with this source's values when decoded.
        let client = MCPClient(transport: transport, mask: mask(record.id))
        // A failed connect retires its own transport; nobody waits for it to close.
        try await client.connect(timeout: timeout)
        return client
    }

    /// Stops this source's server and in-flight connection; earlier work of
    /// this source can no longer publish or call.
    func stop(_ id: String) async {
        bump(id)
        validated[id] = nil
        connecting.removeValue(forKey: id)?.cancel()
        guard let client = clients.removeValue(forKey: id) else { return }
        await client.close()
    }

    /// Closes a client that ended (an expired session) without revoking the source.
    private func drop(_ id: String, _ client: MCPClient) async {
        guard clients[id] === client else { return }
        clients[id] = nil
        validated[id] = nil
        await client.close()
    }

    nonisolated static func summaryOf(_ record: SourceRecord) -> String { record.summary }

    /// Live and connecting servers (tests and diagnostics).
    var liveClientCount: Int { clients.count + connecting.count }

    /// Revokes every source first, synchronously, then closes them together.
    func stopAll() async {
        var closing: [MCPClient] = []
        // Every source, including folders and ones loaded from disk that never
        // connected: their leases are revoked before anything is awaited.
        for id in Set(sources.map(\.id)).union(leases.keys).union(clients.keys).union(connecting.keys).union(generations.keys) {
            bump(id)
            validated[id] = nil
            connecting.removeValue(forKey: id)?.cancel()
            if let client = clients.removeValue(forKey: id) { closing.append(client) }
        }
        await withTaskGroup(of: Void.self) { group in
            for client in closing { group.addTask { await client.close() } }
        }
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
        guard isEnabled else { return nil }
        loadIfNeeded()
        var tools: [AgentSourceCatalog.Tool] = []
        var used = Set<String>()
        for record in sources where record.enabled {
            if case .needsValue = statuses[record.id] { continue }
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

    /// The only way the Agent reaches a source.
    func callRead(sourceID: String, tool: String, arguments: MCPValue) async throws -> MCPToolResult {
        guard isEnabled, let record = record(sourceID), record.enabled, record.readTools.contains(where: { $0.name == tool }) else {
            throw MCPError.notAllowed
        }
        guard arguments.object != nil else { throw MCPError.server(code: -32602, message: "arguments must be a JSON object") }
        let generation = generation(sourceID)
        if case .folder = record.transport {
            guard let folder = FolderSource(record: record), let pin = approvedPin(sourceID, tool: tool) else { throw MCPError.notAllowed }
            let lease = lease(sourceID)
            lastUsed[sourceID] = Date()
            let result = try await folderReader(folder, tool, arguments)
            // The same result-time revocation check as a server call.
            guard lease.isValid, isCurrent(sourceID, generation), approvedPin(sourceID, tool: tool) == pin else {
                throw MCPError.notAllowed
            }
            return result
        }
        var attempt = 0
        while true {
            attempt += 1
            let client = try await client(for: sourceID, generation: generation)
            do {
                if !(await isValidated(sourceID, client)) {
                    // A new connection, or the server said its tools changed: re-pin first.
                    do { try await validate(sourceID, client: client, generation: generation) }
                    catch {
                        if let current = self.record(sourceID), isCurrent(sourceID, generation) {
                            statuses[sourceID] = readyStatus(current, proof: nil)
                        }
                        if let failure = error as? MCPError, failure == .cancelled { throw MCPError.notAllowed }
                        throw error
                    }
                    if let current = self.record(sourceID), current.pendingReviewCount > 0 {
                        statuses[sourceID] = readyStatus(current, proof: nil)
                    }
                }
                return try await invoke(sourceID, tool: tool, arguments: arguments, client: client, generation: generation,
                                        timeout: Self.readTimeout, limit: Self.resultLimit)
            } catch MCPError.sessionExpired where attempt == 1 {
                await drop(sourceID, client)
            } catch let error as MCPError {
                switch error {
                case .exited, .commandNotFound, .unauthorized, .network, .tooLarge, .unsupportedProtocol, .insecureURL:
                    if isCurrent(sourceID, generation) { statuses[sourceID] = .failed(message(error, id: sourceID)) }
                default: break
                }
                throw error
            }
        }
    }

    /// A folder search or read with the same deadline as a server call. The
    /// deadline returns at once; the reader stops at its next cancellation check.
    nonisolated static func folderCall(_ folder: FolderSource, tool: String, arguments: MCPValue) async throws -> MCPToolResult {
        try await MCPDeadline.run(until: Date().addingTimeInterval(readTimeout), timeout: .timedOut(seconds: Int(readTimeout))) {
            try folder.call(tool, arguments: arguments, maxCharacters: resultLimit)
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

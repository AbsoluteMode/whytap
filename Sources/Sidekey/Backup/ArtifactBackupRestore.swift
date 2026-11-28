import CryptoKit
import Foundation

// MARK: - Seams

/// Vault key access, split so a test (and a clean-profile recovery check) can
/// run the whole restore without touching the real Keychain.
protocol ArtifactCaseKeyProviding {
    /// The existing key, or nil. Never creates one.
    func existingVaultKey() throws -> SymmetricKey?
    /// This Mac's own vault key, created on a fresh profile. A restored vault
    /// is always re-encrypted with the target's local key; the source Mac's
    /// key is never installed here.
    func vaultKeyForRestore() throws -> SymmetricKey
}

extension ArtifactCaseKeyProviding {
    /// Undoes a key this restore minted on a profile that had none. Default
    /// no-op so a provider that cannot delete keys stays valid; the real
    /// store overrides it.
    func discardVaultKeyCreatedDuringRestore() throws {}
}

extension CaseVaultKeyStore: ArtifactCaseKeyProviding {
    func existingVaultKey() throws -> SymmetricKey? { try readExistingKey() }
    func vaultKeyForRestore() throws -> SymmetricKey { try readOrCreateKey() }
    func discardVaultKeyCreatedDuringRestore() throws { try deleteKey() }
}

/// Test-only interruption points. Nil in production, so the apply path has no
/// behavior that only exists for tests.
struct ArtifactBackupFaults {
    var beforeFileEntry: ((String) throws -> Void)?
    var beforeCommit: (() throws -> Void)?
    /// Simulates power loss: the apply stops where a crash would, leaving the
    /// journal, the moved-aside originals and the encrypted before-state on
    /// disk for the next launch to recover.
    var interruptAfter: ((ArtifactRestoreStage) -> Bool)?
}

enum ArtifactRestoreStage: String, Equatable, Sendable {
    case beforeState, checkpoint, files, metadata, committed, recovery
}

/// Thrown for a simulated interruption. Deliberately not an
/// `ArtifactBackupError`: the apply path must not treat it as a failure it can
/// clean up after, because a real crash gets no chance to.
struct ArtifactRestoreInterruption: Error {
    let stage: ArtifactRestoreStage
}

// MARK: - Durable transaction records

struct ArtifactRestorePlan: Codable, Equatable {
    static let currentSchema = 1
    var schema: Int = ArtifactRestorePlan.currentSchema
    var id: UUID
    var createdAt: Date
    var sections: [ArtifactBackupSection]
    var archiveSHA256: String
    var archiveBytes: Int64
    var manifestID: UUID
    var manifestCreatedAt: Date
    var attempts: Int = 0
    var restoreWarnings: [String]?
}

/// What the UI can tell the user after the app restarts. Durable, because the
/// restore happens before any window exists.
struct ArtifactRestoreOutcome: Codable, Equatable {
    enum State: String, Codable { case applied, rolledBack, failed }
    var id: UUID
    var finishedAt: Date
    var state: State
    var sections: [ArtifactBackupSection]
    var message: String
    var warnings: [String]
    /// Where the data this restore replaced (or could not put back) is kept.
    var recoveryDirectory: String?
    var recoveredFileCount: Int?
    /// True when Whytap could not prove it put everything back and preserved
    /// the evidence instead.
    var needsRecovery: Bool?
}

/// Enough for a "Show recovered files" affordance without the user having to
/// know about hidden names.
struct ArtifactRecoveryCheckpoint: Codable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var sections: [ArtifactBackupSection]
    var fileCount: Int
    var bytes: Int64
    var includesProviderKeys: Bool
    var directoryPath: String
    var directory: URL { URL(fileURLWithPath: directoryPath) }
}

/// A restored file that is deliberately not live until the user says so.
struct ArtifactParkedItem: Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case monitorServers, stagedRecording }
    var id: String
    var kind: Kind
    var title: String
    var parkedPath: String
    var activePath: String
    var parkedURL: URL { URL(fileURLWithPath: parkedPath) }
    var activeURL: URL { URL(fileURLWithPath: activePath) }
}

/// The before-state of everything a restore changes outside the filesystem.
/// Written encrypted BEFORE the first mutation, so a crash after provider keys
/// or preferences were committed can still be undone on the next launch.
struct ArtifactRestoreBeforeState: Codable, Equatable {
    static let currentSchema = 1
    var schema: Int = ArtifactRestoreBeforeState.currentSchema
    var transactionID: UUID
    var createdAt: Date
    var sections: [ArtifactBackupSection]
    /// Binary property list of the allowlisted preference keys that existed,
    /// with their exact values and types.
    var preferences: Data
    /// Every allowlisted key considered, so rollback also removes keys the
    /// restore added.
    var preferenceKeys: [String]
    var credentials: [String: String]
    /// Accounts that held nothing before the restore; rollback deletes them.
    var absentCredentials: [String]
    var caseVaultKeyMintedByRestore: Bool
}

/// Authenticated container for the before-state. The key is the parked
/// transaction's key, so the file is useless on its own.
enum ArtifactBeforeStateBox {
    static func seal(_ state: ArtifactRestoreBeforeState, key: Data) throws -> Data {
        guard key.count == 32 else { throw ArtifactBackupError.keyUnavailable }
        let data = try JSONEncoder.artifactBackup.encode(state)
        do {
            let box = try AES.GCM.seal(data, using: derive(key, state.transactionID),
                                       authenticating: associated(state.transactionID))
            guard let combined = box.combined else { throw ArtifactBackupError.writeFailed }
            return combined
        } catch { throw ArtifactBackupError.writeFailed }
    }

    static func open(_ data: Data, key: Data, transactionID: UUID) throws -> ArtifactRestoreBeforeState {
        guard key.count == 32 else { throw ArtifactBackupError.keyUnavailable }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(try AES.GCM.SealedBox(combined: data),
                                         using: derive(key, transactionID),
                                         authenticating: associated(transactionID))
        } catch { throw ArtifactBackupError.cannotUnlock }
        let state: ArtifactRestoreBeforeState
        do { state = try JSONDecoder.artifactBackup.decode(ArtifactRestoreBeforeState.self, from: plaintext) }
        catch { throw ArtifactBackupError.damaged }
        guard state.schema <= ArtifactRestoreBeforeState.currentSchema,
              state.transactionID == transactionID else { throw ArtifactBackupError.damaged }
        return state
    }

    private static func derive(_ key: Data, _ id: UUID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
                               salt: Data(id.uuidString.utf8),
                               info: Data("exodia.artifact-backup.v1.before-state".utf8),
                               outputByteCount: 32)
    }

    private static func associated(_ id: UUID) -> Data {
        Data("exodia.artifact-backup.v1.before-state:\(id.uuidString)".utf8)
    }
}

private struct ArtifactRestoreJournal: Codable {
    struct Step: Codable {
        var target: String
        var backup: String
        /// Intent flag only. Recovery trusts what is on disk: a crash between
        /// the rename and this flag's update must still put the file back.
        var movedAside: Bool
        /// Absent in a journal written before this field existed: then the
        /// target's prior existence is unknown and nothing is deleted.
        var existedBefore: Bool?
        var originalDevice: UInt64?
        var originalInode: UInt64?
    }
    var id: UUID
    var startedAt: Date
    var steps: [Step]
    var committedPlan: ArtifactRestorePlan?
    var commitProof: Data?
}

// MARK: - Destinations

enum ArtifactRestoreDestination: Hashable {
    case file(URL)
    case inline(Inline)

    enum Inline: Hashable {
        case settings
        case credentials
        case caseVault
        case caseKey
        case notifySource(String)
    }

    var isInline: Bool {
        if case .inline = self { return true }
        return false
    }

    /// Classifies a path without needing any locations, so the archive writer
    /// can place every inline entry at the head of the archive.
    static func isInlinePath(_ path: String) -> Bool {
        (try? resolve(path, in: .production))?.isInline ?? false
    }

    static func resolvedEntries(_ entries: [ArtifactBackupManifest.Entry], archiveID: UUID,
                                sections: Set<ArtifactBackupSection>,
                                locations: ArtifactBackupLocations) throws -> [String: Self] {
        func targets(_ destination: Self) -> [URL] {
            switch destination {
            case .file(let url): return [url]
            case .inline(.notifySource(let name)):
                let directory = locations.notifyRoot.appendingPathComponent("sources")
                return [directory.appendingPathComponent(name), directory.appendingPathComponent(name + invalidSuffix)]
            case .inline: return []
            }
        }
        let wanted = entries.filter { sections.contains($0.section) }
        let paths = Set(wanted.map { $0.path.lowercased() })
        var resolved: [String: Self] = [:]
        var occupied = Set<String>()
        for entry in wanted {
            let destination = try resolve(entry.path, in: locations)
            resolved[entry.path] = destination
            for target in targets(destination) { occupied.insert(target.standardizedFileURL.path.lowercased()) }
        }
        // Older complete archives may carry both an active configuration and
        // its previous inactive copy. Preserve that old copy in a separate
        // inert location instead of overwriting either one or rejecting a
        // recoverable archive. New writers already separate these generations.
        for entry in wanted {
            let parts = entry.path.split(separator: "/").map(String.init)
            let lower = parts.map { $0.lowercased() }
            guard let destination = resolved[entry.path], case .file(let original) = destination else { continue }
            var root: URL?
            var recording = false
            if lower == ["workspace", "monitor", "servers.json" + parkedSuffix],
               paths.contains("workspace/monitor/servers.json") { root = locations.monitorRoot }
            else if lower.count == 4, lower[0] == "workspace", lower[1] == "notify", lower[2] == "sources",
                    lower[3].hasSuffix(invalidSuffix), paths.contains(String(entry.path.dropLast(invalidSuffix.count)).lowercased()) {
                root = locations.notifyRoot
            } else if lower.count == 4, lower[0] == "meetings", lower[1] == "staged",
                      lower[3] == MeetingFinalizeManifest.fileName + parkedSuffix,
                      paths.contains("meetings/staged/" + lower[2] + "/" + MeetingFinalizeManifest.fileName) {
                root = original.deletingLastPathComponent(); recording = true
            }
            guard let root else { continue }
            var selected: URL?
            for counter in 0...wanted.count {
                let suffix = counter == 0 ? "" : "-\(counter)"
                let target = recording
                    ? root.appendingPathComponent("manifest-\(archiveID.uuidString)\(suffix).json" + parkedSuffix)
                    : root.appendingPathComponent("restored-files-\(archiveID.uuidString)\(suffix)")
                        .appendingPathComponent(parts.last!)
                if occupied.insert(target.standardizedFileURL.path.lowercased()).inserted { selected = target; break }
            }
            guard let selected else { throw ArtifactBackupError.invalidContent(entry.path) }
            resolved[entry.path] = .file(selected)
        }
        var seen = Set<String>()
        for entry in wanted {
            for target in targets(resolved[entry.path]!) {
                guard seen.insert(target.standardizedFileURL.path.lowercased()).inserted else {
                    throw ArtifactBackupError.invalidContent(entry.path)
                }
            }
        }
        return resolved
    }

    /// The only paths a restore is allowed to act on. Anything else — an
    /// unknown root, a traversal attempt, or executable provider job state
    /// refuses the whole archive instead of writing a file
    /// somewhere unexpected.
    static func resolve(_ path: String, in locations: ArtifactBackupLocations) throws -> Self {
        try ArtifactBackupPath.validate(path)
        let parts = path.split(separator: "/").map(String.init)
        func inside(_ parent: URL, _ names: [String]) throws -> URL {
            var url = parent
            for name in names {
                guard ArtifactBackupStager.isUsableName(name) else { throw ArtifactBackupError.unsafeContent }
                url.appendPathComponent(name)
            }
            guard url.standardizedFileURL.path.hasPrefix(parent.standardizedFileURL.path + "/") else {
                throw ArtifactBackupError.unsafeContent
            }
            return url
        }
        switch (parts[0], parts.count) {
        case ("settings", 2) where parts[1] == "preferences.json":
            return .inline(.settings)
        case ("credentials", 2) where parts[1] == "providers.json":
            return .inline(.credentials)
        case ("case", 2) where parts[1] == "vault.enc":
            return .inline(.caseVault)
        case ("case", 2) where parts[1] == "vault.key":
            return .inline(.caseKey)
        case ("meetings", 3) where parts[1] == "db" && parts[2] == "meetings.sqlite":
            return .file(try inside(locations.meetingsCatalog, [parts[2]]))
        case ("meetings", 3) where parts[1] == "notes":
            guard isMeetingSidecar(parts[2]) else { throw ArtifactBackupError.unsafeContent }
            return .file(try inside(locations.meetingsCatalog, [parts[2]]))
        case ("meetings", _) where parts[1] == "staged" && parts.count >= 4:
            guard UUID(uuidString: parts[2]) != nil,
                  !ArtifactBackupStager.isRecordingRuntimeFile(parts.dropFirst(3).joined(separator: "/")) else {
                throw ArtifactBackupError.unsafeContent
            }
            // The audio travels, the finalize record arrives parked. Launch
            // recovery only picks up `manifest.json`, so a restored Mac does
            // not start processing another Mac's unfinished recordings by
            // itself — and the bytes are still there to recover from.
            let name = parts.count == 4 && parts.last!.lowercased() == MeetingFinalizeManifest.fileName
                ? MeetingFinalizeManifest.fileName + parkedSuffix
                : parts.last!
            return .file(try inside(locations.meetingsStaging, Array(parts[2..<(parts.count - 1)]) + [name]))
        case ("history", 3) where parts[1] == "db" && parts[2] == "history.sqlite":
            return .file(locations.historyDatabase)
        case ("history", 3) where parts[1] == "db" && parts[2] == ArtifactUsageBackup.fileName:
            return .file(locations.usageDatabase)
        case ("history", 3) where parts[1] == "assets":
            guard isAssetName(parts[2]) else { throw ArtifactBackupError.unsafeContent }
            return .file(try inside(locations.historyAssets, [parts[2]]))
        case ("workspace", 3) where parts[1] == "monitor" && parts[2].lowercased() == "servers.json":
            // Server monitoring runs ssh / credential-tool processes. A
            // restored configuration is parked under a name MonitorStore does
            // not read, so nothing reconnects to another Mac's servers until
            // the user puts it back deliberately.
            return .file(try inside(locations.monitorRoot, ["servers.json" + parkedSuffix]))
        case ("workspace", _) where parts[1] == "monitor" && parts.count >= 3:
            return .file(try inside(locations.monitorRoot, Array(parts.dropFirst(2))))
        case ("workspace", 4) where parts[1] == "notify" && parts[2].lowercased() == "sources" && isJSONName(parts[3]):
            return .inline(.notifySource(parts[3]))
        case ("workspace", _) where parts[1] == "notify" && parts.count >= 3:
            return .file(try inside(locations.notifyRoot, Array(parts.dropFirst(2))))
        case ("workspace", 3) where parts[1] == "agent" && parts[2] == "AGENTS.md":
            return .file(try inside(locations.agentWorkspace, ["AGENTS.md"]))
        case ("planner", 2) where parts[1] == "planner-v1.json":
            return .file(locations.plannerArchive)
        default:
            throw ArtifactBackupError.unsafeContent
        }
    }

    /// Suffix for restored-but-inactive configuration. The runtime never reads
    /// these names; `ArtifactBackupEngine.parkedRestoredItems` lists them so a
    /// UI can activate one without the user renaming a hidden file.
    static let parkedSuffix = ".restored-inactive"
    /// Suffix for a configuration file this build cannot parse. Its bytes are
    /// kept rather than dropped.
    static let invalidSuffix = ".restored-invalid"

    private static func isMeetingSidecar(_ name: String) -> Bool {
        if name.hasSuffix(".md") { return UUID(uuidString: String(name.dropLast(3))) != nil }
        if name.hasSuffix("-transcript.json") { return UUID(uuidString: String(name.dropLast(16))) != nil }
        return false
    }

    private static func isAssetName(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count == 2, let ext = parts.last, ext.count <= 8,
              ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return UUID(uuidString: String(parts[0])) != nil
    }

    private static func isJSONName(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".json") && ArtifactBackupStager.isUsableName(name) && name.count > 5
    }
}

// MARK: - Transaction

/// A restore is a two-phase operation: `arm` validates the archive and parks
/// an encrypted copy plus a plan; `applyIfPending` runs at launch, before any
/// store opens its database, and installs it with a durable checkpoint of the
/// previous data, an encrypted before-state for everything outside the
/// filesystem, and a journal that survives a crash.
///
/// Nothing that could be the only copy of the user's data is deleted until a
/// rollback or an apply has been proven complete.
/// WHY: .project-docs/decisions/2026-10-19-config-backup.md
struct ArtifactRestoreTransaction {
    let locations: ArtifactBackupLocations
    let defaults: UserDefaults
    let credentialStore: (String) -> TokenStore
    let caseKeys: ArtifactCaseKeyProviding
    let pendingKeyStore: TokenStore
    let recoveryKeyStore: TokenStore
    var faults = ArtifactBackupFaults()

    static let maxAttempts = 3
    private static let archiveName = "pending.exodiabackup"

    private var root: URL { locations.pendingRestoreRoot }
    private var planURL: URL { root.appendingPathComponent("plan.json") }
    private var journalURL: URL { root.appendingPathComponent("journal.json") }
    private var archiveURL: URL { root.appendingPathComponent(Self.archiveName) }
    private var beforeStateURL: URL { root.appendingPathComponent("before-state.enc") }
    private var rollbackRoot: URL { root.appendingPathComponent("previous", isDirectory: true) }
    private var outcomeURL: URL { root.appendingPathComponent("outcome.json") }
    private var recoveryRoot: URL { locations.recoveryRoot }

    var isArmed: Bool { FileManager.default.fileExists(atPath: planURL.path) }
    var hasApplyJournal: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    /// The sections an armed restore will replace, when its plan is readable.
    var plannedSections: [ArtifactBackupSection]? { try? readPlan().sections }

    func readOutcome() -> ArtifactRestoreOutcome? {
        guard let data = try? Data(contentsOf: outcomeURL) else { return nil }
        return try? JSONDecoder.artifactBackup.decode(ArtifactRestoreOutcome.self, from: data)
    }

    func plannedRestore() -> ArtifactRestorePlan? { try? readPlan() }

    /// Retained checkpoint of the data the last completed restore replaced.
    func recoveryCheckpoint() -> ArtifactRecoveryCheckpoint? {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: recoveryRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        let checkpoints = directories.compactMap { directory -> ArtifactRecoveryCheckpoint? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("info.json")) else { return nil }
            return try? JSONDecoder.artifactBackup.decode(ArtifactRecoveryCheckpoint.self, from: data)
        }
        return checkpoints.sorted { $0.createdAt > $1.createdAt }.first
    }


    // MARK: Arming

    /// Where the armed copy lives. The copy is what gets applied, so a
    /// restore survives the original file being moved, unmounted or deleted.
    var pendingArchiveURL: URL { archiveURL }

    /// Clears any previous, not-yet-applied transaction and refuses to touch
    /// an unfinished apply: that journal owns the only copy of the user's
    /// previous data, and the next launch rolls it back. Retained recovery
    /// checkpoints from earlier completed restores are never touched here.
    func prepareForArming() throws {
        guard !hasApplyJournal else { throw ArtifactBackupError.restoreInterrupted }
        try createPrivateDirectory(root)
        try? FileManager.default.removeItem(at: planURL)
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: beforeStateURL)
        try? FileManager.default.removeItem(at: rollbackRoot)
    }

    /// Publishes the transaction. The plan file is written last: its presence
    /// is what arms the restore, so an interrupted copy leaves nothing armed.
    func arm(archiveDigest: String, archiveBytes: Int64, key: Data,
             manifest: ArtifactBackupManifest, sections: Set<ArtifactBackupSection>) throws {
        guard !sections.isEmpty else { throw ArtifactBackupError.nothingSelected }
        guard sections.isSubset(of: Set(manifest.sections)) else { throw ArtifactBackupError.missingSection }
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ArtifactBackupError.writeFailed
        }
        do { try pendingKeyStore.save(key.base64EncodedString()) }
        catch { throw ArtifactBackupError.keyUnavailable }
        let plan = ArtifactRestorePlan(
            id: UUID(), createdAt: Date(), sections: sections.sorted { $0.rawValue < $1.rawValue },
            archiveSHA256: archiveDigest, archiveBytes: archiveBytes,
            manifestID: manifest.id, manifestCreatedAt: manifest.createdAt)
        try writePrivate(try JSONEncoder.artifactBackup.encode(plan), to: planURL)
    }

    /// Cancels a parked restore that has not started applying. Refuses while
    /// an apply journal exists: that transaction owns the user's originals.
    @discardableResult
    func cancelPlanned() throws -> Bool {
        guard !hasApplyJournal else { throw ArtifactBackupError.applyInProgress }
        guard isArmed else { return false }
        disarm()
        return true
    }

    func disarm() {
        try? FileManager.default.removeItem(at: planURL)
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: journalURL)
        try? FileManager.default.removeItem(at: beforeStateURL)
        try? FileManager.default.removeItem(at: rollbackRoot)
        try? pendingKeyStore.delete()
    }

    /// Copies the archive into the transaction and verifies the copy in
    /// place, so what gets applied is proven readable where it now lives.
    static func stageArchiveCopy(from source: URL, to destination: URL, key: Data,
                                 manifestID: UUID) throws -> (digest: String, bytes: Int64) {
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        do { try FileManager.default.copyItem(at: source, to: destination) }
        catch { throw ArtifactBackupError.writeFailed }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        do {
            let handle = try FileHandle(forWritingTo: destination)
            try handle.synchronize(); try handle.close()
            try ConfigBackupFiles.synchronizeDirectory(destination.deletingLastPathComponent())
            let digest = try ArtifactBackupDigest.ofFile(destination)
            try validateArchive(at: destination, key: key, expecting: manifestID)
            return digest
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: Parked items

    func parkedItems() -> [ArtifactParkedItem] {
        var items: [ArtifactParkedItem] = []
        let servers = locations.monitorRoot
            .appendingPathComponent("servers.json" + ArtifactRestoreDestination.parkedSuffix)
        if FileManager.default.fileExists(atPath: servers.path) {
            items.append(ArtifactParkedItem(
                id: "monitor.servers", kind: .monitorServers, title: "Restored server monitoring",
                parkedPath: servers.path,
                activePath: locations.monitorRoot.appendingPathComponent("servers.json").path))
        }
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: locations.meetingsStaging, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let parked = directory.appendingPathComponent(
                MeetingFinalizeManifest.fileName + ArtifactRestoreDestination.parkedSuffix)
            guard FileManager.default.fileExists(atPath: parked.path) else { continue }
            items.append(ArtifactParkedItem(
                id: "recording." + directory.lastPathComponent, kind: .stagedRecording,
                title: "Restored unprocessed recording", parkedPath: parked.path,
                activePath: directory.appendingPathComponent(MeetingFinalizeManifest.fileName).path))
        }
        return items
    }

    func activate(_ item: ArtifactParkedItem) throws {
        let parked = item.parkedURL
        let active = item.activeURL
        guard FileManager.default.fileExists(atPath: parked.path) else {
            throw ArtifactBackupError.requiredFileMissing(parked.lastPathComponent)
        }
        guard !FileManager.default.fileExists(atPath: active.path) else {
            throw ArtifactBackupError.unsafeContent
        }
        // Only our own parked names, inside our own roots.
        guard parked.path.hasSuffix(ArtifactRestoreDestination.parkedSuffix),
              parked.path.hasPrefix(locations.bundleRoot.standardizedFileURL.path + "/")
                || parked.path.hasPrefix(locations.meetingsStaging.standardizedFileURL.path + "/")
        else { throw ArtifactBackupError.unsafeContent }
        do { try FileManager.default.moveItem(at: parked, to: active) }
        catch { throw ArtifactBackupError.writeFailed }
    }

    /// Accept an independently saved code only after it authenticates this
    /// exact pending transaction. No archive contents are applied here.
    func unlockPending(with key: Data) throws {
        guard key.count == 32 else { throw ArtifactBackupError.keyUnavailable }
        let journal = (try? Data(contentsOf: journalURL)).flatMap {
            try? JSONDecoder.artifactBackup.decode(ArtifactRestoreJournal.self, from: $0)
        }
        let plan = try journal?.committedPlan ?? readPlan()
        if let journal, journal.committedPlan != nil {
            guard let proof = journal.commitProof, proof == (try commitProof(for: plan, key: key)) else {
                throw ArtifactBackupError.keyUnavailable
            }
        } else if FileManager.default.fileExists(atPath: beforeStateURL.path) {
            _ = try ArtifactBeforeStateBox.open(Data(contentsOf: beforeStateURL), key: key, transactionID: plan.id)
        } else {
            _ = try Self.validateArchive(at: archiveURL, key: key, expecting: plan.manifestID)
        }
        try pendingKeyStore.save(key.base64EncodedString())
    }

    // MARK: Applying

    @discardableResult
    func applyIfPending() throws -> ArtifactRestoreOutcome? {
        if hasApplyJournal { return try recoverInterruptedApply() }
        guard isArmed else { return nil }
        let plan = try readPlan()
        let key: Data
        do {
            guard let encoded = try pendingKeyStore.read(), let data = Data(base64Encoded: encoded),
                  data.count == 32 else { throw ArtifactBackupError.keyUnavailable }
            key = data
        } catch {
            // A retry is not consent to discard a planned restore. Keep the
            // verified copy until the user explicitly cancels or supplies the
            // saved recovery code, regardless of how often Keychain is locked.
            write(ArtifactRestoreOutcome(
                id: plan.id, finishedAt: Date(), state: .failed, sections: plan.sections,
                message: "The restore key is unavailable. Your planned restore is kept; unlock this Mac or use your saved recovery code, then retry.",
                warnings: []))
            throw ArtifactBackupError.keyUnavailable
        }
        do {
            let outcome = try apply(plan: plan, key: key)
            write(outcome)
            return outcome
        } catch let interruption as ArtifactRestoreInterruption {
            // Simulated power loss: leave every durable record exactly as it
            // is, with no outcome, like a real crash.
            throw interruption
        } catch let error as ArtifactBackupError {
            if case .restoreNeedsRecovery = error { throw error }
            throw error
        }
    }

    private func apply(plan: ArtifactRestorePlan, key: Data) throws -> ArtifactRestoreOutcome {
        let digest = try ArtifactBackupDigest.ofFile(archiveURL)
        guard digest.digest == plan.archiveSHA256, digest.bytes == plan.archiveBytes else {
            throw ArtifactBackupError.damaged
        }
        let sections = Set(plan.sections)

        // 1. Everything that is applied through memory is decoded and
        //    semantically validated BEFORE a single target is touched. Inline
        //    entries form the head of the archive, so this reads only its
        //    first frames.
        let head = try readInlinePayloads(key: key, plan: plan, sections: sections)
        let manifest = head.manifest
        let destinations = try ArtifactRestoreDestination.resolvedEntries(manifest.entries, archiveID: manifest.id,
            sections: sections, locations: locations)

        // 2. The Case vault this Mac already has is read BEFORE its file moves
        //    aside: the merge must keep every unrelated secret that lives here.
        var targetCase: CaseVaultPayload?
        var targetCaseKey: SymmetricKey?
        if sections.contains(.caseVault) {
            (targetCase, targetCaseKey) = try readTargetCase()
        }

        // 3. Durable, encrypted before-state. A crash after the keys or
        //    preferences are committed is recoverable only because this file
        //    exists before any of it happens.
        let beforeState = try captureBeforeState(
            plan: plan, sections: sections,
            incomingCredentials: head.verification.inline[.credentials],
            mintsVaultKey: sections.contains(.caseVault) && targetCaseKey == nil)
        try writePrivate(try ArtifactBeforeStateBox.seal(beforeState, key: key), to: beforeStateURL)
        if faults.interruptAfter?(.beforeState) == true {
            throw ArtifactRestoreInterruption(stage: .beforeState)
        }

        var journal = ArtifactRestoreJournal(id: plan.id, startedAt: Date(), steps: [])
        try write(journal: journal)
        var warnings = head.verification.warnings
        do {
            try createPrivateDirectory(rollbackRoot)
            let includesUsage = sections.contains(.history) && manifest.entries.contains { $0.path == ArtifactUsageBackup.archivePath }
            for target in Self.checkpointTargets(for: sections, locations: locations, includesUsage: includesUsage,
                                                 carried: Self.carriedStores(in: manifest)) {
                let existed = FileManager.default.fileExists(atPath: target.path)
                guard existed else {
                    // Recorded anyway: a failure must also remove what the
                    // restore created where the user had nothing before.
                    journal.steps.append(.init(target: target.path, backup: "", movedAside: false,
                                               existedBefore: false))
                    try write(journal: journal)
                    continue
                }
                let backup = rollbackRoot.appendingPathComponent(
                    "\(journal.steps.count)-" + target.lastPathComponent, isDirectory: false)
                let identity = try Self.identity(target)
                journal.steps.append(.init(target: target.path, backup: backup.path, movedAside: false,
                                           existedBefore: true, originalDevice: identity.device, originalInode: identity.inode))
                try write(journal: journal)
                do { try durableMove(from: target, to: backup) }
                catch { throw ArtifactBackupError.restoreFailed }
                journal.steps[journal.steps.count - 1].movedAside = true
                try write(journal: journal)
            }
            if faults.interruptAfter?(.checkpoint) == true {
                throw ArtifactRestoreInterruption(stage: .checkpoint)
            }

            // 4. Stream the archive into place, verifying every entry's digest
            //    as it is written.
            let reader = try ArtifactArchiveReader(url: archiveURL, archiveKey: key)
            defer { reader.close() }
            guard try Self.readManifest(reader).id == manifest.id else {
                throw ArtifactBackupError.damaged
            }
            for entry in manifest.entries {
                guard sections.contains(entry.section), let destination = destinations[entry.path],
                      case .file(let url) = destination else {
                    try reader.forward(entry.bytes) { _ in }
                    continue
                }
                try faults.beforeFileEntry?(entry.path)
                try createPrivateDirectory(url.deletingLastPathComponent())
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else {
                    throw ArtifactBackupError.writeFailed
                }
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    throw ArtifactBackupError.writeFailed
                }
                var hasher = SHA256()
                do {
                    try reader.forward(entry.bytes) { block in
                        try handle.write(contentsOf: block)
                        hasher.update(data: block)
                    }
                    try handle.synchronize()
                    try handle.close()
                    try ConfigBackupFiles.synchronizeDirectory(url.deletingLastPathComponent())
                } catch {
                    try? handle.close()
                    throw (error as? ArtifactBackupError) ?? ArtifactBackupError.writeFailed
                }
                guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
                    throw ArtifactBackupError.damaged
                }
            }
            try reader.verifyEnd()
            if includesUsage {
                func prior(_ target: URL) -> URL? {
                    guard let step = journal.steps.first(where: { $0.target == target.path }), step.movedAside else { return nil }
                    return URL(fileURLWithPath: step.backup)
                }
                let priorJournal = locations.usageDatabase.deletingLastPathComponent()
                    .appendingPathComponent(ArtifactUsageBackup.fileName + "-journal")
                let priorWAL = locations.usageDatabase.deletingLastPathComponent()
                    .appendingPathComponent(ArtifactUsageBackup.fileName + "-wal")
                if let warning = try ArtifactUsageBackup.mergePrior(database: prior(locations.usageDatabase), rollbackJournal: prior(priorJournal),
                    writeAheadLog: prior(priorWAL), into: locations.usageDatabase, scratch: rollbackRoot) { warnings.append(warning) }
            }
            if faults.interruptAfter?(.files) == true {
                throw ArtifactRestoreInterruption(stage: .files)
            }
            try faults.beforeCommit?()

            // 5. Metadata last, in a fixed order, each with its before-state
            //    already on disk.
            if sections.contains(.settings) { try applySettings(head.verification.inline[.settings]) }
            if sections.contains(.credentials) { try applyCredentials(head.verification.inline[.credentials]) }
            if faults.interruptAfter?(.metadata) == true {
                throw ArtifactRestoreInterruption(stage: .metadata)
            }
            if sections.contains(.caseVault) {
                try applyCase(vault: head.verification.inline[.caseVault],
                              key: head.verification.inline[.caseKey],
                              targetPayload: targetCase, targetKey: targetCaseKey)
            }
            if sections.contains(.workspace) {
                warnings.append(contentsOf: try applyNotifySources(
                    head.verification.inline,
                    unreadable: Set(head.verification.unreadableNotifySources)))
            }
        } catch let interruption as ArtifactRestoreInterruption {
            throw interruption
        } catch {
            let fileFailures = rollback(journal)
            let metadataFailures = rollbackMetadata(beforeState)
            guard fileFailures.isEmpty, metadataFailures.isEmpty else {
                let outcome = preservedOutcome(plan: plan, reason: error,
                                               failures: fileFailures + metadataFailures)
                write(outcome)
                throw ArtifactBackupError.restoreNeedsRecovery(root.path)
            }
            try? FileManager.default.removeItem(at: journalURL)
            disarm()
            write(ArtifactRestoreOutcome(
                id: plan.id, finishedAt: Date(), state: .failed, sections: plan.sections,
                message: (error as? LocalizedError)?.errorDescription
                    ?? ArtifactBackupError.restoreFailed.errorDescription!,
                warnings: [], recoveryDirectory: nil, recoveredFileCount: nil, needsRecovery: false))
            throw error
        }

        var committed = plan
        committed.restoreWarnings = warnings
        journal.committedPlan = committed
        journal.commitProof = try commitProof(for: committed, key: key)
        try write(journal: journal)
        if faults.interruptAfter?(.committed) == true { throw ArtifactRestoreInterruption(stage: .committed) }
        return try finalizeCommitted(plan: committed, key: key)
    }

    private func commitProof(for plan: ArtifactRestorePlan, key: Data) throws -> Data {
        let secret = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
            salt: Data(plan.id.uuidString.utf8), info: Data("exodia.restore.commit.v1".utf8), outputByteCount: 32)
        return Data(HMAC<SHA256>.authenticationCode(for: try JSONEncoder.artifactBackup.encode(plan), using: secret))
    }

    private func finalizeCommitted(plan: ArtifactRestorePlan, key: Data) throws -> ArtifactRestoreOutcome {
        let checkpoint = try retainRecoveryCheckpoint(plan: plan, key: key)
        if faults.interruptAfter?(.recovery) == true { throw ArtifactRestoreInterruption(stage: .recovery) }
        let outcome = ArtifactRestoreOutcome(id: plan.id, finishedAt: Date(), state: .applied, sections: plan.sections,
            message: "Your backup was restored. The data it replaced is kept on this Mac so you can recover it.",
            warnings: plan.restoreWarnings ?? [], recoveryDirectory: checkpoint.directoryPath, recoveredFileCount: checkpoint.fileCount, needsRecovery: false)
        try writePrivate(try JSONEncoder.artifactBackup.encode(outcome), to: outcomeURL)
        // The journal carries its plan and commit proof until active cleanup
        // is durable. An interruption resumes finalization, never re-applies.
        for file in [archiveURL, planURL] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        try ConfigBackupFiles.synchronizeDirectory(root)
        try FileManager.default.removeItem(at: journalURL)
        try ConfigBackupFiles.synchronizeDirectory(root)
        try? pendingKeyStore.delete()
        return outcome
    }

    // MARK: Interrupted apply

    /// Runs at launch when a journal is present. Everything here is
    /// idempotent: the same pass can run again after any interruption, and no
    /// evidence is deleted until the rollback is proven complete.
    private func recoverInterruptedApply() throws -> ArtifactRestoreOutcome? {
        let journal = (try? Data(contentsOf: journalURL)).flatMap {
            try? JSONDecoder.artifactBackup.decode(ArtifactRestoreJournal.self, from: $0)
        }
        let plan = journal?.committedPlan ?? (try? readPlan())
        guard let plan, let journal, Self.validate(journal, plan: plan, locations: locations,
                                                   rollbackRoot: rollbackRoot) else {
            // The record cannot be read or does not describe this transaction.
            // Whatever is under `previous/` may be the only copy of the user's
            // data: keep everything and refuse to open the runtime on a state
            // nobody can prove.
            write(ArtifactRestoreOutcome(
                id: plan?.id ?? UUID(), finishedAt: Date(), state: .failed,
                sections: plan?.sections ?? [],
                message: "Whytap could not read its restore record, so it changed nothing and kept every file. Your previous data and the backup copy are preserved at \(root.path).",
                warnings: [], recoveryDirectory: root.path, recoveredFileCount: nil, needsRecovery: true))
            throw ArtifactBackupError.restoreNeedsRecovery(root.path)
        }

        if journal.committedPlan != nil {
            guard let encoded = try? pendingKeyStore.read(), let key = Data(base64Encoded: encoded),
                  let proof = journal.commitProof, proof == (try commitProof(for: plan, key: key)) else {
                write(preservedOutcome(plan: plan, reason: ArtifactBackupError.keyUnavailable, failures: ["Committed restore key is unavailable."]))
                throw ArtifactBackupError.restoreNeedsRecovery(root.path)
            }
            return try finalizeCommitted(plan: plan, key: key)
        }

        var beforeState: ArtifactRestoreBeforeState?
        if FileManager.default.fileExists(atPath: beforeStateURL.path) {
            if let encoded = try? pendingKeyStore.read(), let key = Data(base64Encoded: encoded),
               let data = try? Data(contentsOf: beforeStateURL),
               let state = try? ArtifactBeforeStateBox.open(data, key: key, transactionID: plan.id) {
                beforeState = state
            } else {
                // Settings and provider keys may already be changed and only
                // this file can put them back. A locked Keychain is temporary,
                // so retry on the next launches rather than give up at once.
                var retried = plan
                retried.attempts += 1
                if retried.attempts < Self.maxAttempts {
                    try? writePrivate(try JSONEncoder.artifactBackup.encode(retried), to: planURL)
                    write(ArtifactRestoreOutcome(
                        id: plan.id, finishedAt: Date(), state: .failed, sections: plan.sections,
                        message: "Whytap could not reach the key for its restore record. Nothing was deleted; unlock this Mac and open Whytap again. Your files are preserved at \(root.path).",
                        warnings: [], recoveryDirectory: root.path, recoveredFileCount: nil,
                        needsRecovery: true))
                    throw ArtifactBackupError.keyUnavailable
                }
                try? writePrivate(try JSONEncoder.artifactBackup.encode(retried), to: planURL)
                write(preservedOutcome(plan: plan, reason: ArtifactBackupError.keyUnavailable,
                                       failures: ["Recovery key is unavailable. No restore records were removed."]))
                throw ArtifactBackupError.restoreNeedsRecovery(root.path)
            }
        }

        if beforeState == nil && !Set(plan.sections).isDisjoint(with: [.settings, .credentials, .caseVault]) {
            write(preservedOutcome(plan: plan, reason: ArtifactBackupError.damaged,
                                   failures: ["The encrypted before-state is missing. No recovery records were removed."]))
            throw ArtifactBackupError.restoreNeedsRecovery(root.path)
        }
        let fileFailures = rollback(journal)
        let metadataFailures = beforeState.map { rollbackMetadata($0) } ?? []
        guard fileFailures.isEmpty, metadataFailures.isEmpty else {
            write(preservedOutcome(plan: plan, reason: ArtifactBackupError.restoreFailed,
                                   failures: fileFailures + metadataFailures))
            throw ArtifactBackupError.restoreNeedsRecovery(root.path)
        }
        try? FileManager.default.removeItem(at: journalURL)
        disarm()
        let outcome = ArtifactRestoreOutcome(
            id: plan.id, finishedAt: Date(), state: .rolledBack, sections: plan.sections,
            message: "The last restore was interrupted. Your previous data was put back; nothing was changed.",
            warnings: [], recoveryDirectory: nil, recoveredFileCount: nil, needsRecovery: false)
        write(outcome)
        throw ArtifactBackupError.restoreInterrupted
    }

    private func preservedOutcome(plan: ArtifactRestorePlan, reason: Error,
                                  failures: [String]) -> ArtifactRestoreOutcome {
        ArtifactRestoreOutcome(
            id: plan.id, finishedAt: Date(), state: .failed, sections: plan.sections,
            message: "Whytap could not put everything back after a failed restore, so it preserved every original file, the backup copy and the restore record at \(root.path). Nothing was deleted.",
            warnings: Array(failures.prefix(16)), recoveryDirectory: root.path,
            recoveredFileCount: nil, needsRecovery: true)
    }

    // MARK: Checkpoints and rollback

    /// Stores only older archives carry. Newer ones leave meeting audio and the
    /// history database out, and restoring them must not replace what this Mac
    /// has there with nothing.
    /// WHY: .project-docs/decisions/2026-10-21-backup-essentials-only.md
    struct CarriedStores: Equatable {
        var recordings = true
        var historyDatabase = true
    }

    static func carriedStores(in manifest: ArtifactBackupManifest) -> CarriedStores {
        CarriedStores(
            recordings: manifest.entries.contains { $0.path.lowercased().hasPrefix("meetings/staged/") },
            historyDatabase: manifest.entries.contains { $0.path == "history/db/history.sqlite" })
    }

    /// Everything a section replaces. The history WAL files matter: a restored
    /// database next to the previous `-wal` would be a corrupt pair.
    static func checkpointTargets(for sections: Set<ArtifactBackupSection>,
                                  locations: ArtifactBackupLocations, includesUsage: Bool = false,
                                  carried: CarriedStores = CarriedStores()) -> [URL] {
        var targets: [URL] = []
        if sections.contains(.caseVault) { targets.append(locations.caseVault) }
        if sections.contains(.meetings) {
            targets.append(locations.meetingsCatalog)
            if carried.recordings { targets.append(locations.meetingsStaging) }
        }
        if sections.contains(.history) {
            if carried.historyDatabase {
                targets.append(locations.historyDatabase)
                for suffix in ["-wal", "-shm"] {
                    targets.append(locations.historyDatabase.deletingLastPathComponent()
                        .appendingPathComponent(locations.historyDatabase.lastPathComponent + suffix))
                }
                targets.append(locations.historyAssets)
            }
            if includesUsage { targets.append(contentsOf: ArtifactUsageBackup.checkpointTargets(locations: locations)) }
        }
        if sections.contains(.workspace) {
            targets.append(locations.monitorRoot)
            targets.append(locations.notifyRoot)
            targets.append(locations.agentMemory)
        }
        if sections.contains(.planner) { targets.append(locations.plannerArchive) }
        return targets
    }

    /// A journal is only acted on when every path in it belongs to this
    /// transaction: allowlisted checkpoint targets, and backups inside this
    /// transaction's own checkpoint directory.
    private static func validate(_ journal: ArtifactRestoreJournal, plan: ArtifactRestorePlan,
                                 locations: ArtifactBackupLocations, rollbackRoot: URL) -> Bool {
        let allowed = Set(checkpointTargets(for: Set(plan.sections), locations: locations, includesUsage: true)
            .map { $0.standardizedFileURL.path })
        let prefix = rollbackRoot.standardizedFileURL.path + "/"
        guard journal.id == plan.id, journal.steps.count <= 64 else { return false }
        for step in journal.steps {
            guard allowed.contains(URL(fileURLWithPath: step.target).standardizedFileURL.path) else {
                return false
            }
            if !step.backup.isEmpty {
                guard URL(fileURLWithPath: step.backup).standardizedFileURL.path.hasPrefix(prefix) else {
                    return false
                }
            }
        }
        return true
    }

    /// Recovery is driven by what is on disk, not by the flag the apply path
    /// managed to write: a crash between the rename and the flag update must
    /// still put the file back. Returns the targets it could NOT restore; the
    /// caller must preserve every record when that list is not empty.
    private func rollback(_ journal: ArtifactRestoreJournal) -> [String] {
        var failures: [String] = []
        for step in journal.steps.reversed() {
            let target = URL(fileURLWithPath: step.target)
            if !step.backup.isEmpty, FileManager.default.fileExists(atPath: step.backup) {
                let backup = URL(fileURLWithPath: step.backup)
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    try durableMove(from: backup, to: target)
                } catch {
                    failures.append(target.lastPathComponent)
                }
            } else if step.existedBefore == false, FileManager.default.fileExists(atPath: target.path) {
                // Nothing was here before the restore, so nothing imported may
                // stay behind — an abandoned instruction file or dashboard
                // would otherwise become live configuration.
                do {
                    try FileManager.default.removeItem(at: target)
                    try ConfigBackupFiles.synchronizeDirectory(target.deletingLastPathComponent())
                }
                catch { failures.append(target.lastPathComponent) }
            } else if step.existedBefore != false {
                // A previous rollback may already have moved this original
                // back. Only its recorded filesystem identity proves that.
                let current = try? Self.identity(target)
                if current?.device != step.originalDevice || current?.inode != step.originalInode
                    || step.originalInode == nil { failures.append(target.lastPathComponent) }
            }
        }
        return failures
    }

    private func rollbackMetadata(_ state: ArtifactRestoreBeforeState) -> [String] {
        var failures: [String] = []
        if state.sections.contains(.settings) {
            if let plist = try? PropertyListSerialization.propertyList(
                from: state.preferences, options: [], format: nil) as? [String: Any] {
                for key in state.preferenceKeys {
                    if let value = plist[key] { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
                if !defaults.synchronize() { failures.append("settings") }
            } else {
                failures.append("settings")
            }
        }
        if state.sections.contains(.credentials) {
            for (account, secret) in state.credentials.sorted(by: { $0.key < $1.key }) {
                do { try credentialStore(account).save(secret) }
                catch { failures.append(account) }
            }
            for account in state.absentCredentials.sorted() {
                do { try credentialStore(account).delete() }
                catch { failures.append(account) }
            }
        }
        if state.caseVaultKeyMintedByRestore,
           !FileManager.default.fileExists(atPath: locations.caseVault.path) {
            // The key was created only for this restore and no vault uses it.
            do { try caseKeys.discardVaultKeyCreatedDuringRestore() }
            catch { failures.append("case key") }
        }
        return failures
    }

    /// Keeps the replaced workspace and the encrypted before-state under a
    /// generation-specific path, with its own key, so "recover what the
    /// restore replaced" is a real affordance and not a promise.
    private func retainRecoveryCheckpoint(plan: ArtifactRestorePlan, key: Data) throws -> ArtifactRecoveryCheckpoint {
        try createPrivateDirectory(recoveryRoot)
        var keys: [String: String] = [:]
        if let stored = try recoveryKeyStore.read() {
            if let decoded = try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8)) { keys = decoded }
            else if let data = Data(base64Encoded: stored), data.count == 32 {
                // Keep an unmapped legacy key even if its old info.json cannot
                // be read. It may still unlock an older retained before-state.
                keys[recoveryCheckpoint()?.id.uuidString ?? "preserved-legacy-key"] = stored
            } else {
                // Preserve the exact unreadable bytes inside Keychain instead
                // of deleting old recovery material or blocking this commit.
                keys["preserved-unreadable-state"] = stored
            }
        }
        keys[plan.id.uuidString] = key.base64EncodedString()
        let ring = try JSONEncoder().encode(keys)
        guard let encoded = String(data: ring, encoding: .utf8) else { throw ArtifactBackupError.restoreFailed }
        try recoveryKeyStore.save(encoded)
        let directory = recoveryRoot.appendingPathComponent(plan.id.uuidString, isDirectory: true)
        try createPrivateDirectory(directory)
        let previous = directory.appendingPathComponent("previous", isDirectory: true)
        if FileManager.default.fileExists(atPath: rollbackRoot.path) {
            guard !FileManager.default.fileExists(atPath: previous.path) else { throw ArtifactBackupError.restoreFailed }
            try FileManager.default.moveItem(at: rollbackRoot, to: previous)
            try ConfigBackupFiles.synchronizeDirectory(root)
            try ConfigBackupFiles.synchronizeDirectory(directory)
        }
        let state = directory.appendingPathComponent("before-state.enc")
        if FileManager.default.fileExists(atPath: beforeStateURL.path) {
            guard !FileManager.default.fileExists(atPath: state.path) else { throw ArtifactBackupError.restoreFailed }
            try FileManager.default.moveItem(at: beforeStateURL, to: state)
            try ConfigBackupFiles.synchronizeDirectory(root)
            try ConfigBackupFiles.synchronizeDirectory(directory)
        }
        guard FileManager.default.fileExists(atPath: state.path) else { throw ArtifactBackupError.restoreFailed }
        let before = try ArtifactBeforeStateBox.open(Data(contentsOf: state), key: key, transactionID: plan.id)
        guard before.transactionID == plan.id else { throw ArtifactBackupError.restoreFailed }
        let (count, bytes) = Self.measure(previous)
        let checkpoint = ArtifactRecoveryCheckpoint(id: plan.id, createdAt: plan.createdAt, sections: plan.sections,
            fileCount: count, bytes: bytes, includesProviderKeys: plan.sections.contains(.credentials), directoryPath: directory.path)
        try writePrivate(try JSONEncoder.artifactBackup.encode(checkpoint), to: directory.appendingPathComponent("info.json"))
        return checkpoint
    }

    private static func measure(_ directory: URL) -> (Int, Int64) {
        var files = 0
        var bytes: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
            if files > 200_000 { break }
        }
        return (files, bytes)
    }

    // MARK: Inline payloads and metadata

    private struct InlineHead {
        let manifest: ArtifactBackupManifest
        let verification: ArtifactArchiveVerification
    }

    /// Reads and fully validates the archive's inline head: the settings,
    /// provider keys, Case material and Notify configurations. Digests and
    /// frame authentication say the bytes are intact; this says they are
    /// usable, before anything on this Mac changes.
    private func readInlinePayloads(key: Data, plan: ArtifactRestorePlan,
                                    sections: Set<ArtifactBackupSection>) throws -> InlineHead {
        let reader = try ArtifactArchiveReader(url: archiveURL, archiveKey: key)
        defer { reader.close() }
        let manifest = try Self.readManifest(reader)
        guard manifest.id == plan.manifestID else { throw ArtifactBackupError.damaged }
        guard sections.isSubset(of: Set(manifest.sections)) else { throw ArtifactBackupError.missingSection }
        for section in sections.sorted(by: { $0.rawValue < $1.rawValue }) {
            for required in ArtifactArchiveVerifier.requiredPaths(for: section)
            where !manifest.entries.contains(where: { $0.path == required }) {
                throw ArtifactBackupError.incompleteArchive(required)
            }
        }
        var inline: [ArtifactRestoreDestination.Inline: Data] = [:]
        var unreadableNotify: [String] = []
        for entry in manifest.entries {
            guard ArtifactRestoreDestination.isInlinePath(entry.path) else { break }
            guard entry.bytes <= ArtifactBackupManifest.maxInlineBytes else {
                throw ArtifactBackupError.tooLarge
            }
            guard sections.contains(entry.section) else {
                try reader.forward(entry.bytes) { _ in }
                continue
            }
            guard case .inline(let kind) = try ArtifactRestoreDestination.resolve(entry.path, in: locations) else {
                throw ArtifactBackupError.damaged
            }
            var buffer = Data()
            var hasher = SHA256()
            try reader.forward(entry.bytes) { buffer.append($0); hasher.update(data: $0) }
            guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
                throw ArtifactBackupError.damaged
            }
            inline[kind] = buffer
        }
        if sections.contains(.settings) { try ArtifactArchiveVerifier.validateSettings(inline[.settings]) }
        if sections.contains(.credentials) {
            try ArtifactArchiveVerifier.validateCredentials(inline[.credentials])
        }
        if sections.contains(.caseVault) {
            try ArtifactArchiveVerifier.validateCase(inline[.caseVault], key: inline[.caseKey])
        }
        if sections.contains(.workspace) {
            for (kind, data) in inline {
                guard case .notifySource(let name) = kind else { continue }
                if !ArtifactArchiveVerifier.isReadableNotifySource(data, named: name) {
                    unreadableNotify.append(name)
                }
            }
        }
        var warnings = manifest.warnings
        if !unreadableNotify.isEmpty {
            warnings.append("\(unreadableNotify.count) notification source file(s) could not be read and were restored as an inactive copy.")
        }
        return InlineHead(manifest: manifest, verification: ArtifactArchiveVerification(
            manifest: manifest, warnings: warnings, inline: inline,
            unreadableNotifySources: unreadableNotify))
    }

    /// Captures the exact previous state of everything applied through memory.
    /// Credential reads are strict: a Keychain error aborts the restore before
    /// anything is written, because a key read as "absent" would be rolled
    /// back into deletion.
    private func captureBeforeState(plan: ArtifactRestorePlan, sections: Set<ArtifactBackupSection>,
                                    incomingCredentials: Data?,
                                    mintsVaultKey: Bool) throws -> ArtifactRestoreBeforeState {
        var preferences = Data()
        var keys: [String] = []
        if sections.contains(.settings) {
            keys = ConfigBackupRegistry.entries.keys.sorted()
            var values: [String: Any] = [:]
            for key in keys {
                if let value = defaults.object(forKey: key) { values[key] = value }
            }
            do {
                preferences = try PropertyListSerialization.data(fromPropertyList: values,
                                                                 format: .binary, options: 0)
            } catch { throw ArtifactBackupError.restoreFailed }
        }
        var credentials: [String: String] = [:]
        var absent: [String] = []
        if sections.contains(.credentials) {
            guard let incomingCredentials else { throw ArtifactBackupError.damaged }
            let payload = try JSONDecoder.artifactBackup.decode(ArtifactCredentialsPayload.self, from: incomingCredentials)
            // Capture every account about to be written, including server IDs
            // absent from this Mac. A crash must remove newly imported keys
            // and restore existing ones without reading unrelated credentials.
            for account in payload.accounts.keys.sorted() {
                let value: String?
                do { value = try credentialStore(account).read() }
                catch { throw ArtifactBackupError.keyUnavailable }
                if let value, !value.isEmpty { credentials[account] = value } else { absent.append(account) }
            }
        }
        return ArtifactRestoreBeforeState(
            transactionID: plan.id, createdAt: Date(),
            sections: sections.sorted { $0.rawValue < $1.rawValue },
            preferences: preferences, preferenceKeys: keys, credentials: credentials,
            absentCredentials: absent, caseVaultKeyMintedByRestore: mintsVaultKey)
    }

    private func applySettings(_ data: Data?) throws {
        guard let data else { throw ArtifactBackupError.damaged }
        let payload: ArtifactSettingsPayload
        do { payload = try JSONDecoder.artifactBackup.decode(ArtifactSettingsPayload.self, from: data) }
        catch { throw ArtifactBackupError.damaged }
        try payload.validate()
        // Only the blocks this payload restores are rewritten; everything else
        // the user changed meanwhile stays as it is.
        var preserve: Set<String> = payload.schema < 3 ? [ConfigBackupRegistry.aiRoutingKey, ConfigBackupRegistry.aiRoutingPreservedKey] : []
        if payload.schema < 4 { preserve.formUnion(CalendarAccountSettings.keys) }
        preserve.formUnion(payload.keysUnknownToWriter)
        try ConfigBackupRegistry.apply(payload.values, sections: payload.appliedSections,
                                       preservingMissingKeys: preserve, to: defaults)
    }

    private func applyCredentials(_ data: Data?) throws {
        guard let data else { throw ArtifactBackupError.damaged }
        let payload: ArtifactCredentialsPayload
        do { payload = try JSONDecoder.artifactBackup.decode(ArtifactCredentialsPayload.self, from: data) }
        catch { throw ArtifactBackupError.damaged }
        for (account, secret) in payload.accounts.sorted(by: { $0.key < $1.key }) {
            do { try credentialStore(account).save(secret) }
            catch { throw ArtifactBackupError.restoreFailed }
        }
    }

    private func readTargetCase() throws -> (CaseVaultPayload?, SymmetricKey?) {
        guard FileManager.default.fileExists(atPath: locations.caseVault.path) else {
            return (nil, try caseKeys.existingVaultKey())
        }
        // A vault file with no key is not an empty vault. Refuse rather than
        // overwrite secrets that a recovered key could still open.
        let existing: SymmetricKey?
        do { existing = try caseKeys.existingVaultKey() }
        catch { throw ArtifactBackupError.caseUnreadable }
        guard let key = existing else { throw ArtifactBackupError.caseUnreadable }
        do {
            let payload = try CaseVaultStore(fileURL: locations.caseVault).load(using: key)
            return (payload, key)
        } catch CaseVaultStoreError.missingFile {
            return (nil, key)
        } catch {
            throw ArtifactBackupError.caseUnreadable
        }
    }

    private func applyCase(vault: Data?, key: Data?, targetPayload: CaseVaultPayload?,
                           targetKey: SymmetricKey?) throws {
        guard let vault, let key, key.count == 32 else { throw ArtifactBackupError.damaged }
        let sourcePayload: CaseVaultPayload
        do { sourcePayload = try CaseVaultStore.decode(envelope: vault, using: SymmetricKey(data: key)) }
        catch CaseVaultStoreError.needsNewerApp { throw ArtifactBackupError.needsNewerApp }
        catch { throw ArtifactBackupError.damaged }
        guard sourcePayload.schemaVersion <= CaseVaultPayload.currentSchemaVersion else {
            throw ArtifactBackupError.needsNewerApp
        }
        let localKey: SymmetricKey
        if let targetKey { localKey = targetKey } else {
            guard let created = try? caseKeys.vaultKeyForRestore() else {
                throw ArtifactBackupError.keyUnavailable
            }
            localKey = created
        }
        let merged = ArtifactCaseMerge.merge(source: sourcePayload, into: targetPayload)
        do {
            try CaseVaultStore(fileURL: locations.caseVault).save(merged, using: localKey)
            let file = try FileHandle(forWritingTo: locations.caseVault)
            do { try file.synchronize(); try file.close() }
            catch { try? file.close(); throw error }
            try ConfigBackupFiles.synchronizeDirectory(locations.caseVault.deletingLastPathComponent())
        }
        catch { throw ArtifactBackupError.restoreFailed }
    }

    /// Notification sources run local commands. They come back switched off,
    /// so a restored Mac never starts another Mac's workers by itself. A
    /// configuration this build cannot read keeps its bytes under an inactive
    /// name rather than disappearing.
    private func applyNotifySources(_ inline: [ArtifactRestoreDestination.Inline: Data],
                                    unreadable: Set<String>) throws -> [String] {
        var warnings: [String] = []
        var written = 0
        let directory = locations.notifyRoot.appendingPathComponent("sources", isDirectory: true)
        for (kind, data) in inline.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
            guard case .notifySource(let name) = kind else { continue }
            try createPrivateDirectory(directory)
            if unreadable.contains(name) {
                try writePrivate(data, to: directory.appendingPathComponent(
                    name + ArtifactRestoreDestination.invalidSuffix, isDirectory: false))
                continue
            }
            // Rewrite only `enabled`, preserving every other field this build
            // may not know about.
            guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                try writePrivate(data, to: directory.appendingPathComponent(
                    name + ArtifactRestoreDestination.invalidSuffix, isDirectory: false))
                warnings.append("A notification source file could not be read and was kept as an inactive copy.")
                continue
            }
            object["enabled"] = false
            guard let encoded = try? JSONSerialization.data(withJSONObject: object,
                                                            options: [.sortedKeys]) else {
                throw ArtifactBackupError.restoreFailed
            }
            try writePrivate(encoded, to: directory.appendingPathComponent(name, isDirectory: false))
            written += 1
        }
        if written > 0 {
            warnings.append("\(written) notification source(s) were restored switched off. Enable the ones you want in Settings → Features → Notify.")
        }
        if !unreadable.isEmpty {
            warnings.append("\(unreadable.count) notification source file(s) were kept as an inactive copy because this version cannot read them.")
        }
        return warnings
    }

    // MARK: Shared helpers

    static func readManifest(_ reader: ArtifactArchiveReader) throws -> ArtifactBackupManifest {
        let header = try reader.read(exactly: 4)
        let length = [UInt8](header).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard Int(length) <= ArtifactBackupManifest.maxBytes, length > 0 else {
            throw ArtifactBackupError.damaged
        }
        return try ArtifactBackupManifest.decode(try reader.read(exactly: Int(length)))
    }

    /// Streams the whole archive and checks every digest, so a damaged,
    /// truncated or reordered file is refused before anything is staged.
    @discardableResult
    static func validateArchive(at url: URL, key: Data, expecting id: UUID? = nil) throws -> ArtifactBackupManifest {
        let reader = try ArtifactArchiveReader(url: url, archiveKey: key)
        defer { reader.close() }
        let manifest = try readManifest(reader)
        if let id, manifest.id != id { throw ArtifactBackupError.damaged }
        for entry in manifest.entries {
            var hasher = SHA256()
            try reader.forward(entry.bytes) { hasher.update(data: $0) }
            guard ArtifactBackupDigest.hex(hasher.finalize()) == entry.sha256 else {
                throw ArtifactBackupError.damaged
            }
        }
        try reader.verifyEnd()
        return manifest
    }

    private func readPlan() throws -> ArtifactRestorePlan {
        guard let data = try? Data(contentsOf: planURL),
              let plan = try? JSONDecoder.artifactBackup.decode(ArtifactRestorePlan.self, from: data),
              plan.schema == ArtifactRestorePlan.currentSchema, !plan.sections.isEmpty
        else { throw ArtifactBackupError.damaged }
        return plan
    }

    private func write(journal: ArtifactRestoreJournal) throws {
        try writePrivate(try JSONEncoder.artifactBackup.encode(journal), to: journalURL)
    }

    private func write(_ outcome: ArtifactRestoreOutcome) {
        try? createPrivateDirectory(root)
        try? writePrivate(try JSONEncoder.artifactBackup.encode(outcome), to: outcomeURL)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".restore-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ArtifactBackupError.writeFailed
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            // Atomic replacement leaves the old journal valid until the new
            // bytes and directory entry are durable, including on power loss.
            guard rename(temporary.path, url.path) == 0 else { throw ArtifactBackupError.writeFailed }
            try ConfigBackupFiles.synchronizeDirectory(url.deletingLastPathComponent())
        } catch { throw ArtifactBackupError.writeFailed }
    }

    private static func identity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
            throw ArtifactBackupError.unsafeContent
        }
        return (UInt64(info.st_dev), UInt64(info.st_ino))
    }

    private func durableMove(from source: URL, to target: URL) throws {
        try FileManager.default.moveItem(at: source, to: target)
        try ConfigBackupFiles.synchronizeDirectory(source.deletingLastPathComponent())
        try ConfigBackupFiles.synchronizeDirectory(target.deletingLastPathComponent())
    }

    private func createPrivateDirectory(_ directory: URL) throws {
        do { try ConfigBackupFiles.ensurePrivateDirectory(directory) }
        catch ConfigBackupError.unsafePath { throw ArtifactBackupError.unsafeContent }
        catch { throw ArtifactBackupError.writeFailed }
    }

}

// MARK: - Inline payloads

/// Schema 1 restores every allowlisted preference. Schema 2 adds
/// `selectedSections`, which the local block/key history uses to put one
/// Settings block back (or reset it to source defaults) without touching the
/// blocks the user edited meanwhile. A missing list still means "all blocks".
/// Schema 3 includes Keys & models' binary routing document. Older snapshots
/// cannot clear current routes simply because their format predated that key.
///
/// `knownKeys` lists every preference the writing app could back up. A key
/// missing from `values` is reset only when the writer knew it; a key added
/// in a later app keeps its current value. Optional, so archives without it
/// (written up to 2.2.27) and apps that ignore it (2.2.27 itself) keep working.
/// WHY: .project-docs/decisions/2026-11-28-backup-keys-unknown-to-the-writer.md
struct ArtifactSettingsPayload: Codable, Equatable {
    static let currentSchema = 4
    var schema: Int = ArtifactSettingsPayload.currentSchema
    var values: [String: ConfigBackupValue]
    var selectedSections: [ConfigBackupSection]?
    var knownKeys: [String]?

    /// Registry keys the writer of this payload could not have contained:
    /// keys missing from its `knownKeys`, or, for a payload without that list,
    /// the keys added after the last release that wrote none.
    var keysUnknownToWriter: Set<String> {
        guard let knownKeys else { return ConfigBackupRegistry.keysAddedAfterUnlistedArchives }
        return Set(ConfigBackupRegistry.entries.keys).subtracting(knownKeys)
    }

    var appliedSections: Set<ConfigBackupSection> {
        guard let selectedSections, !selectedSections.isEmpty else {
            return Set(ConfigBackupSection.allCases)
        }
        return Set(selectedSections)
    }

    /// Every value must belong to a block this payload claims to restore,
    /// otherwise applying it would silently drop or misplace a preference.
    func validate() throws {
        guard schema <= Self.currentSchema else { throw ArtifactBackupError.needsNewerApp }
        do { try ConfigBackupRegistry.validate(values) }
        catch { throw ArtifactBackupError.invalidContent("settings") }
        let sections = appliedSections
        for key in values.keys {
            guard let entry = ConfigBackupRegistry.entries[key], sections.contains(entry.section) else {
                throw ArtifactBackupError.invalidContent("settings")
            }
        }
    }
}

struct ArtifactCredentialsPayload: Codable, Equatable {
    static let currentSchema = 1
    var schema: Int = ArtifactCredentialsPayload.currentSchema
    var accounts: [String: String]
}

// MARK: - Case merge

/// Restoring Case into an existing vault adds what the backup has and keeps
/// everything this Mac already holds. Same id on both sides: the newer
/// `updatedAt` wins, so a restore cannot silently revert a local edit.
enum ArtifactCaseMerge {
    static func merge(source: CaseVaultPayload, into target: CaseVaultPayload?) -> CaseVaultPayload {
        guard let target else { return source }
        var secrets: [UUID: CaseSecret] = [:]
        for secret in target.secrets { secrets[secret.id] = secret }
        var values: [UUID: String] = [:]
        for value in target.values { values[value.secretID] = value.value }
        for secret in source.secrets {
            let incomingValue = source.value(for: secret.id)
            if let existing = secrets[secret.id] {
                guard secret.updatedAt > existing.updatedAt else { continue }
                secrets[secret.id] = secret
                if let incomingValue { values[secret.id] = incomingValue }
            } else {
                secrets[secret.id] = secret
                if let incomingValue { values[secret.id] = incomingValue }
            }
        }
        var projects: [UUID: CaseProject] = [:]
        for project in target.projects { projects[project.id] = project }
        for project in source.projects {
            if let existing = projects[project.id], project.updatedAt <= existing.updatedAt { continue }
            projects[project.id] = project
        }
        if projects[CaseProject.generalID] == nil {
            projects[CaseProject.generalID] = .general(now: secrets.values.map(\.createdAt).min() ?? Date())
        }
        // A secret must always point at an existing project.
        for (id, secret) in secrets where projects[secret.projectID] == nil {
            var moved = secret
            moved.projectID = CaseProject.generalID
            secrets[id] = moved
        }
        renameClashingProjects(&projects, target: target)
        renameClashingSecrets(&secrets, target: target)
        // Broker matching uses the first registration for an identity/path.
        // Keep local registrations first, and never import another registration
        // for the same app just because the other Mac minted a different UUID.
        var appIDs = Set(target.apps.map(\.id))
        var appIdentities = Set(target.apps.map(\.identity))
        var apps = target.apps
        for app in source.apps.sorted(by: { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }) {
            guard !appIDs.contains(app.id), !appIdentities.contains(app.identity) else { continue }
            apps.append(app); appIDs.insert(app.id); appIdentities.insert(app.identity)
        }
        let known = Set(secrets.keys)
        return CaseVaultPayload(
            schemaVersion: CaseVaultPayload.currentSchemaVersion,
            projects: projects.values.sorted { lhs, rhs in
                if lhs.id == CaseProject.generalID { return true }
                if rhs.id == CaseProject.generalID { return false }
                return lhs.createdAt < rhs.createdAt
            },
            secrets: secrets.values.sorted { $0.createdAt < $1.createdAt },
            values: known.compactMap { id in
                values[id].map { CaseSecretValue(secretID: id, value: $0) }
            }.sorted { $0.secretID.uuidString < $1.secretID.uuidString },
            apps: apps,
            timedApprovalMinutes: target.timedApprovalMinutes)
    }

    // The broker finds projects and keys by name, so names must stay unique
    // after a merge (projects case-insensitively, keys per project). What this
    // Mac already had keeps its name; a clashing name that came from the
    // backup gets the same suffix migration uses: ` (2)` for projects, `_2`
    // for keys. Ties are broken by creation date, then id, so a merge is
    // deterministic.

    /// 0: unchanged local name, 1: local item renamed by the backup, 2: new from the backup.
    private static func origin(id: UUID, name: String, localNames: [UUID: String]) -> Int {
        guard let local = localNames[id] else { return 2 }
        return local == name ? 0 : 1
    }

    private static func renameClashingProjects(_ projects: inout [UUID: CaseProject], target: CaseVaultPayload) {
        var local: [UUID: String] = [:]
        for project in target.projects { local[project.id] = project.name }
        local[CaseProject.generalID] = projects[CaseProject.generalID]?.name
        let ordered = projects.values.sorted { lhs, rhs in
            let l = origin(id: lhs.id, name: lhs.name, localNames: local)
            let r = origin(id: rhs.id, name: rhs.name, localNames: local)
            if l != r { return l < r }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        // Every name that stays is reserved first, so a renamed item never takes it.
        var taken = Set<String>()
        var clashing: [CaseProject] = []
        for project in ordered {
            if taken.insert(project.name.lowercased()).inserted { continue }
            clashing.append(project)
        }
        for var project in clashing {
            project.name = CaseProject.uniqueName(project.name, taken: taken)
            taken.insert(project.name.lowercased())
            projects[project.id] = project
        }
    }

    private static func renameClashingSecrets(_ secrets: inout [UUID: CaseSecret], target: CaseVaultPayload) {
        var local: [UUID: String] = [:]
        for secret in target.secrets { local[secret.id] = secret.name }
        let ordered = secrets.values.sorted { lhs, rhs in
            let l = origin(id: lhs.id, name: lhs.name, localNames: local)
            let r = origin(id: rhs.id, name: rhs.name, localNames: local)
            if l != r { return l < r }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var taken: [UUID: Set<String>] = [:]
        var clashing: [CaseSecret] = []
        for secret in ordered {
            if taken[secret.projectID, default: []].insert(secret.name.uppercased()).inserted { continue }
            clashing.append(secret)
        }
        for var secret in clashing {
            secret.name = CaseNameNormalizer.uniqueName(secret.name, taken: taken[secret.projectID, default: []])
            taken[secret.projectID, default: []].insert(secret.name.uppercased())
            secrets[secret.id] = secret
        }
    }
}

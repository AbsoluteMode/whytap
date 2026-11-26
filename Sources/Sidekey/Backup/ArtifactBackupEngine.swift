import CryptoKit
import Foundation

enum ArtifactBackupKeychain {
    /// Separate from the backup key itself: this one only unlocks the parked
    /// restore transaction and is deleted when the restore finishes.
    static let pendingRestoreAccount = "backup.pending_restore_key"
    /// Stores generation-specific keys for retained encrypted before-states.
    static let recoveryStateAccount = "backup.recovery_state_key"
}

/// Everything the engine touches, injectable so the whole backup and restore
/// path can be exercised against a temporary profile with no real Keychain,
/// no live stores and no user data.
struct ArtifactBackupEnvironment {
    var locations: ArtifactBackupLocations = .production
    var defaults: UserDefaults = .standard
    var credentialStore: (String) -> TokenStore = { KeychainStore(account: $0) }
    var caseVaultKeys: ArtifactCaseKeyProviding = CaseVaultKeyStore()
    var pendingKeyStore: TokenStore = KeychainStore(account: ArtifactBackupKeychain.pendingRestoreAccount)
    var recoveryKeyStore: TokenStore = KeychainStore(account: ArtifactBackupKeychain.recoveryStateAccount)
    /// Live stores, registered by the app. A second connection on the same
    /// files cannot serialise against the owning actor/queue, so the app
    /// registers the instances it owns (AppDelegate does this at startup).
    var meetings: ArtifactMeetingsExporting?
    var usage: ArtifactUsageExporting?
    var faults = ArtifactBackupFaults()
    var now: () -> Date = Date.init
    /// The preferences domain behind `defaults` (a test suite's name in tests).
    var defaultsDomain: String = BuildConfig.bundleID

    func transaction() -> ArtifactRestoreTransaction {
        ArtifactRestoreTransaction(locations: locations, defaults: defaults,
                                   credentialStore: credentialStore, caseKeys: caseVaultKeys,
                                   pendingKeyStore: pendingKeyStore, recoveryKeyStore: recoveryKeyStore,
                                   faults: faults, defaultsDomain: defaultsDomain)
    }
}

/// Complete user-artifact backup and restore.
///
/// Create, inspect and verification run entirely off the main thread; the only
/// work on the main actor is reading the small secret payloads (preferences,
/// provider keys and the Case vault key) that must never be written to a
/// plaintext temporary file. A restore is never applied while the runtime is
/// open: it is parked as a durable, encrypted transaction and installed by
/// `applyPendingRestore()` before the app delegate exists.
/// WHY: .project-docs/decisions/2026-10-19-config-backup.md
@MainActor
final class ArtifactBackupEngine {
    static let shared = ArtifactBackupEngine()

    private var environment: ArtifactBackupEnvironment
    private let stager = ArtifactBackupStager()
    private var isWorking = false

    init(environment: ArtifactBackupEnvironment = ArtifactBackupEnvironment()) {
        self.environment = environment
    }

    /// The app hands over the stores it already has open, so an export is a
    /// barrier against their own writers rather than a second connection.
    func register(meetings: ArtifactMeetingsExporting?, usage: ArtifactUsageExporting? = nil) {
        if let meetings { environment.meetings = meetings }
        if let usage { environment.usage = usage }
    }

    // MARK: - Create

    func createArchive(at url: URL, key: Data) async throws -> ArtifactBackupSummary {
        try await createArchive(at: url, key: key, sections: Set(ArtifactBackupSection.allCases))
    }

    func createArchive(at url: URL, key: Data,
                       sections: Set<ArtifactBackupSection>) async throws -> ArtifactBackupSummary {
        guard let summary = try await createGeneration(at: url, key: key, sections: sections, previousFingerprint: nil) else {
            throw ArtifactBackupError.writeFailed
        }
        return summary
    }

    func createArchiveIfChanged(at url: URL, key: Data,
                                previousFingerprint: String?) async throws -> ArtifactBackupSummary? {
        try await createGeneration(at: url, key: key, sections: Set(ArtifactBackupSection.allCases),
                                   previousFingerprint: previousFingerprint)
    }

    private func createGeneration(at url: URL, key: Data, sections: Set<ArtifactBackupSection>,
                                  previousFingerprint: String?) async throws -> ArtifactBackupSummary? {
        guard key.count == 32 else { throw ArtifactBackupError.keyUnavailable }
        guard !sections.isEmpty else { throw ArtifactBackupError.nothingSelected }
        guard !isWorking else { throw ArtifactBackupError.busy }
        isWorking = true
        defer { isWorking = false }

        var warnings: [String] = []
        let secrets = try captureInlinePayloads(sections: sections, warnings: &warnings)
        let request = ArtifactBackupStageRequest(
            sections: sections, locations: environment.locations, inline: secrets.payloads,
            includeCaseVaultFile: secrets.caseVaultKey != nil, caseVaultKey: secrets.caseVaultKey,
            meetings: sections.contains(.meetings) ? try meetingsExporter() : nil,
            usage: sections.contains(.history) ? environment.usage ?? AIUsageStore(url: environment.locations.usageDatabase) : nil)

        let generation = try await stager.stage(request)
        do {
            // Only sections that actually carry data are published, so a
            // preview cannot promise a block the archive does not hold.
            let present = Set(generation.entries.map(\.section))
            guard !present.isEmpty else { throw ArtifactBackupError.nothingSelected }
            let manifest = ArtifactBackupManifest(
                id: UUID(), createdAt: environment.now(), flavor: BuildConfig.flavor.rawValue,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                sections: present.sorted { $0.rawValue < $1.rawValue },
                entries: generation.entries.map {
                    ArtifactBackupManifest.Entry(path: $0.path, section: $0.section,
                                                 bytes: $0.bytes, sha256: $0.sha256)
                },
                contentBytes: generation.contentBytes,
                warnings: Array((warnings + generation.warnings).prefix(64)))
            let fingerprint = try Self.contentFingerprint(of: manifest,
                credentials: secrets.payloads.first { $0.path == "credentials/providers.json" }?.data)
            if fingerprint == previousFingerprint {
                await stager.discard(generation.directory)
                return nil
            }
            let archiveBytes = try await stager.writeArchive(to: url, archiveKey: key, manifest: manifest,
                                                             entries: generation.entries)
            await stager.discard(generation.directory)
            return ArtifactBackupSummary(id: manifest.id, createdAt: manifest.createdAt,
                                         totalBytes: archiveBytes, fileCount: manifest.entries.count,
                                         sections: present, contentFingerprint: fingerprint)
        } catch {
            await stager.discard(generation.directory)
            throw error
        }
    }

    // MARK: - Inspect

    /// Full verification: frame authentication, every digest, the inline
    /// schemas, the databases' integrity and the sidecars their rows refer to.
    func inspectArchive(at url: URL, key: Data) async throws -> ArtifactBackupPreview {
        guard key.count == 32 else { throw ArtifactBackupError.cannotUnlock }
        try ensureWorkRoot()
        let verification = try await stager.verifyArchive(at: url, archiveKey: key,
                                                          scratchRoot: environment.locations.stagingWorkRoot)
        var warnings = verification.warnings
        if let data = verification.inline[.settings],
           let payload = try? JSONDecoder.artifactBackup.decode(ArtifactSettingsPayload.self, from: data),
           payload.schema < 3, payload.values[ConfigBackupRegistry.aiRoutingKey] == nil {
            warnings.append("This backup predates Keys & models. Routes already configured on this Mac are kept; a fresh Mac can migrate the saved legacy provider choices.")
        }
        if verification.manifest.flavor != BuildConfig.flavor.rawValue {
            warnings.append("This backup was made by the \(verification.manifest.flavor) build of Whytap.")
        }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let summary = ArtifactBackupSummary(id: verification.manifest.id,
                                            createdAt: verification.manifest.createdAt,
                                            totalBytes: size,
                                            fileCount: verification.manifest.entries.count,
                                            sections: Set(verification.manifest.sections),
                                            contentFingerprint: try Self.contentFingerprint(of: verification.manifest,
                                                credentials: verification.inline[.credentials]))
        return ArtifactBackupPreview(summary: summary, warnings: Array(warnings.prefix(64)))
    }

    // MARK: - Restore

    /// Validates the whole archive — contents included — and parks it as a
    /// durable transaction. The user's current data is left untouched:
    /// nothing is replaced while this process holds its databases open.
    func stageRestore(from url: URL, key: Data, sections: Set<ArtifactBackupSection>) async throws {
        guard key.count == 32 else { throw ArtifactBackupError.cannotUnlock }
        guard !sections.isEmpty else { throw ArtifactBackupError.nothingSelected }
        guard !isWorking else { throw ArtifactBackupError.busy }
        isWorking = true
        defer { isWorking = false }

        try ensureWorkRoot()
        let verification = try await stager.verifyArchive(at: url, archiveKey: key, sections: sections,
                                                          scratchRoot: environment.locations.stagingWorkRoot)
        let manifest = verification.manifest
        guard sections.isSubset(of: Set(manifest.sections)) else { throw ArtifactBackupError.missingSection }
        let transaction = environment.transaction()
        try transaction.prepareForArming()
        let copy = try await stager.stageArchiveCopy(from: url, to: transaction.pendingArchiveURL,
                                                     archiveKey: key, manifestID: manifest.id)
        do {
            try transaction.arm(archiveDigest: copy.digest, archiveBytes: copy.bytes, key: key,
                                manifest: manifest, sections: sections)
        } catch {
            transaction.disarm()
            throw error
        }
    }

    /// Runs before the app delegate is constructed, so no store has its
    /// database open. Throwing leaves the user's previous data in place and
    /// lets the entry point show an alert instead of starting the runtime.
    static func applyPendingRestore() throws {
        try applyPendingRestore(environment: ArtifactBackupEnvironment())
    }

    @discardableResult
    static func applyPendingRestore(environment: ArtifactBackupEnvironment) throws -> ArtifactRestoreOutcome? {
        try environment.transaction().applyIfPending()
    }

    /// The durable record of the last restore, for the UI after a restart.
    /// Nonisolated: it only reads one small file, so a view model can ask for
    /// it from any context, including a default argument.
    nonisolated static func lastRestoreOutcome(
        locations: ArtifactBackupLocations = .production) -> ArtifactRestoreOutcome? {
        ArtifactBackupEnvironment(locations: locations).transaction().readOutcome()
    }

    var hasPendingRestore: Bool { environment.transaction().isArmed }

    /// What a parked restore would do, for a "Cancel planned restore" button.
    func plannedRestore() -> ArtifactPlannedRestore? {
        guard let plan = environment.transaction().plannedRestore() else { return nil }
        return ArtifactPlannedRestore(id: plan.id, createdAt: plan.createdAt,
                                      sections: Set(plan.sections), archiveBytes: plan.archiveBytes,
                                      backupCreatedAt: plan.manifestCreatedAt)
    }

    /// Cancels a parked restore. Returns false when nothing was planned and
    /// throws `.applyInProgress` when a restore has already started applying
    /// (its journal owns the user's only copy until the next launch finishes
    /// or rolls it back).
    @discardableResult
    func cancelPlannedRestore() throws -> Bool {
        try environment.transaction().cancelPlanned()
    }

    /// The data the last completed restore replaced, retained on this Mac.
    nonisolated static func recoveryCheckpoint(
        locations: ArtifactBackupLocations = .production) -> ArtifactRecoveryCheckpoint? {
        ArtifactBackupEnvironment(locations: locations).transaction().recoveryCheckpoint()
    }

    func recoveryCheckpoint() -> ArtifactRecoveryCheckpoint? {
        environment.transaction().recoveryCheckpoint()
    }

    /// Restored configuration that is deliberately inactive: another Mac's
    /// server monitoring and its unprocessed recordings. Activating one is an
    /// explicit user action, not a hidden rename.
    func parkedRestoredItems() -> [ArtifactParkedItem] {
        environment.transaction().parkedItems()
    }

    func activateParkedItem(_ item: ArtifactParkedItem) throws {
        try environment.transaction().activate(item)
    }

    // MARK: - Secrets and stores

    private struct CapturedSecrets {
        var payloads: [ArtifactInlinePayload]
        var caseVaultKey: Data?
    }

    /// Secrets and small configurations are read here, on the main actor, and
    /// handed to the archive writer in memory. They never become a plaintext
    /// file on disk — not in a staging directory and not in a temp file.
    private func captureInlinePayloads(sections: Set<ArtifactBackupSection>,
                                       warnings: inout [String]) throws -> CapturedSecrets {
        var payloads: [ArtifactInlinePayload] = []
        if sections.contains(.settings) {
            let values = try ConfigBackupRegistry.capture(environment.defaults, warnings: &warnings)
            let payload = ArtifactSettingsPayload(values: values)
            payloads.append(ArtifactInlinePayload(path: "settings/preferences.json", section: .settings,
                                                 data: try JSONEncoder.artifactBackup.encode(payload)))
        }
        if sections.contains(.credentials) {
            var accounts: [String: String] = [:]
            for account in try ConfigBackupRegistry.credentialAccounts(in: environment.defaults).sorted() {
                // A Keychain read that fails is not an absent key: failing
                // closed keeps a backup from quietly dropping a provider key.
                let value: String?
                do { value = try environment.credentialStore(account).read() }
                catch { throw ArtifactBackupError.keyUnavailable }
                if let value, !value.isEmpty { accounts[account] = value }
            }
            if accounts.isEmpty {
                warnings.append("No provider keys were stored on this Mac, so none are in this backup.")
            } else {
                try ConfigBackupRegistry.validate([:], credentials: accounts)
                let payload = ArtifactCredentialsPayload(accounts: accounts)
                payloads.append(ArtifactInlinePayload(path: "credentials/providers.json", section: .credentials,
                                                      data: try JSONEncoder.artifactBackup.encode(payload)))
            }
        }
        var caseKey: Data?
        if sections.contains(.caseVault) {
            if let keyData = try captureCaseVaultKey(warnings: &warnings) {
                payloads.append(ArtifactInlinePayload(path: "case/vault.key", section: .caseVault,
                                                      data: keyData))
                caseKey = keyData
            }
        }
        return CapturedSecrets(payloads: payloads, caseVaultKey: caseKey)
    }

    /// Case is only recoverable with its key, so the backup carries the
    /// vault's ciphertext and its key together — and the stager proves the
    /// staged ciphertext opens with that exact key. An existing vault this Mac
    /// cannot read fails the backup instead of being left out.
    private func captureCaseVaultKey(warnings: inout [String]) throws -> Data? {
        let vault = environment.locations.caseVault
        guard FileManager.default.fileExists(atPath: vault.path) else {
            warnings.append("There are no Case secrets on this Mac yet, so Case is not in this backup.")
            return nil
        }
        let key: SymmetricKey?
        do { key = try environment.caseVaultKeys.existingVaultKey() }
        catch { throw ArtifactBackupError.caseUnreadable }
        guard let key else { throw ArtifactBackupError.caseUnreadable }
        do { _ = try CaseVaultStore(fileURL: vault).load(using: key) }
        catch CaseVaultStoreError.missingFile {
            warnings.append("There are no Case secrets on this Mac yet, so Case is not in this backup.")
            return nil
        } catch { throw ArtifactBackupError.caseUnreadable }
        return key.withUnsafeBytes { Data($0) }
    }

    private func ensureWorkRoot() throws {
        let root = environment.locations.stagingWorkRoot
        guard !FileManager.default.fileExists(atPath: root.path) else { return }
        try ArtifactBackupStager.validateAncestors(of: root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw ArtifactBackupError.writeFailed }
    }

    private static func contentFingerprint(of manifest: ArtifactBackupManifest, credentials: Data?) throws -> String {
        guard let credentials else { return manifest.contentFingerprint }
        var payload = try JSONDecoder.artifactBackup.decode(ArtifactCredentialsPayload.self, from: credentials)
        payload.accounts = try ConfigBackupRegistry.credentialsForChangeDetection(payload.accounts)
        let normalized = try JSONEncoder.artifactBackup.encode(payload)
        var comparable = manifest
        if let index = comparable.entries.firstIndex(where: { $0.path == "credentials/providers.json" }) {
            comparable.contentBytes += Int64(normalized.count) - comparable.entries[index].bytes
            comparable.entries[index].bytes = Int64(normalized.count)
            comparable.entries[index].sha256 = ArtifactBackupDigest.of(normalized)
        }
        return comparable.contentFingerprint
    }

    /// Called once before runtime backup work starts; only app-owned scratch
    /// generations are disposable. Pending restore / recovery roots are separate.
    func cleanupAbandonedWork() async throws {
        guard !isWorking else { throw ArtifactBackupError.busy }
        try await stager.cleanupAbandonedWork(at: environment.locations.stagingWorkRoot)
    }

    private func meetingsExporter() throws -> ArtifactMeetingsExporting {
        if let registered = environment.meetings { return registered }
        do { return try MeetingsStore(rootDirectory: environment.locations.meetingsCatalog) }
        catch { throw ArtifactBackupError.readFailed }
    }
}

/// Summary of a parked restore for the cancellation affordance.
struct ArtifactPlannedRestore: Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var sections: Set<ArtifactBackupSection>
    var archiveBytes: Int64
    var backupCreatedAt: Date
}

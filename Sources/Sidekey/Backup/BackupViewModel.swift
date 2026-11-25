import AppKit
import Combine
import CryptoKit
import Foundation
import LocalAuthentication

@MainActor
final class BackupViewModel: ObservableObject {
    static let shared = BackupViewModel(cleanupWork: { try await ArtifactBackupEngine.shared.cleanupAbandonedWork() })
    nonisolated static let keyAccount = "backup.archive-key.v1"
    enum GitHubConnectionState { case disconnected, checking, connected, needsAttention }
    @Published var githubConnectionState: GitHubConnectionState = .disconnected
    @Published var githubConnectionError: String?
    @Published var isBusy = false
    @Published var isEnabled = false
    @Published var destinationName = "Not connected"
    @Published var lastBackupAt: Date?
    @Published var lastRemoteBackupAt: Date?
    @Published var statusText = "Your data stays on this Mac. Keep a backup to recover it on another Mac."
    @Published var errorMessage: String?
    @Published var recoveryCode = ""
    @Published var recoverySaved = false
    @Published private(set) var hasPresentedRecoveryCode = false
    @Published private(set) var isRevealingRecoveryCode = false
    @Published var versions: [BackupVersion] = []
    @Published var restorePreview: ArtifactBackupPreview?
    @Published var needsRestart = false
    @Published var localSettingsVersions: [ConfigBackupSnapshot] = []
    @Published var restoreNotice: ArtifactRestoreOutcome?
    @Published var recoveryCheckpoint: ArtifactRecoveryCheckpoint?
    @Published var parkedItems: [ArtifactParkedItem] = []
    @Published var canCancelOperation = false
    @Published var hasPendingMaintenance = false
    @Published var isReplacingCode = false
    @Published var managementWarning: String?

    var calendarConnectionBlockReason: String? {
        if needsRestart { return "Finish the pending backup restore before changing calendar connections." }
        if hasPendingMaintenance { return "Finish backup maintenance before changing calendar connections." }
        if isBusy { return "Wait for the backup operation to finish before changing calendar connections." }
        return nil
    }

    private let defaults: UserDefaults
    private let keyStore: TokenStore
    private let githubTokenStore: TokenStore
    private let local: BackupLocalStore
    private let settingsFiles: ConfigBackupFiles
    private let engine: BackupEngineActions
    private let changeProbe: @Sendable () -> String
    private let idle: @MainActor () -> Bool
    private let providerStore: (String) -> TokenStore
    private let previousRestoreOutcome: @MainActor () -> ArtifactRestoreOutcome?
    private let archivedKeyStore: (String) -> TokenStore
    private let pendingKeyStore: TokenStore
    private let recoveryAuthentication: @MainActor () async throws -> Bool
    private let cleanupWork: @MainActor () async throws -> Void
    private var github: GitHubBackupTransport?
    private let githubSession: URLSession
    private let delta = BackupDeltaArchive()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Timer?
    private var initializationTask: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var codePresentationID = UUID()
    private var keyCache: Data?
    @Published private(set) var needsFullBackup = true
    private var lastAttempt = Date.distantPast
    private let now: @MainActor () -> Date
    private var sourceStamp: String?
    private var restoreFile: URL?
    private var restoreKey: Data?
    private var clipboardTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var operationID = UUID()
    private enum Operation { case backup, preview, restore, connection, refresh, maintenance }
    private var operationKind: Operation?
    private var temporaryPreviewFiles = Set<URL>()
    private var changeRevision = 0
    private var destinationRevision = 0
    private var captureTask: Task<Void, Never>?
    private var replacementKey: Data?
    private var maintenanceRetryAttempted = false
    private var transferFailureCount = 0
    private var nextAutomaticAttempt = Date.distantPast
    private var stalledSourceStamp: String?
    private var githubRequiresReconnect = false
    @Published private(set) var lastContentCheck = Date.distantPast
    private var automaticOperationRunning = false
    private let availableCapacity: @Sendable (URL) -> Int64?
    /// One automatic full capture per hour at most, changed or not. Sources
    /// such as a Notify script's status file change every few seconds, and
    /// every capture is a complete snapshot.
    /// This is also the required hourly content check. Back up is immediate.
    /// WHY: .project-docs/decisions/2026-10-21-backup-capture-pacing.md
    static let automaticCaptureInterval: TimeInterval = 3600
    /// Free space a capture must leave on this Mac's volume after its archive.
    static let automaticFreeSpaceReserve: Int64 = 10_000_000_000
    static let manualFreeSpaceReserve: Int64 = 2_000_000_000

    init(defaults: UserDefaults = .standard,
         keyStore: TokenStore = KeychainStore(account: BackupViewModel.keyAccount),
         githubTokenStore: TokenStore = KeychainStore(account: "backup.github-token.v1"),
         local: BackupLocalStore = BackupLocalStore(),
         settingsFiles: ConfigBackupFiles = ConfigBackupFiles(root: ConfigBackupFiles.defaultRoot),
         engine: BackupEngineActions = .live,
         changeProbe: @escaping @Sendable () -> String = { BackupChangeProbe.stamp() },
         idle: @escaping @MainActor () -> Bool = { BackupViewModel.isIdle },
         providerStore: @escaping (String) -> TokenStore = { KeychainStore(account: $0) },
         previousRestoreOutcome: @escaping @MainActor () -> ArtifactRestoreOutcome? = { ArtifactBackupEngine.lastRestoreOutcome() },
         archivedKeyStore: @escaping (String) -> TokenStore = { KeychainStore(account: "backup.archived-key." + $0) },
         pendingKeyStore: TokenStore = KeychainStore(account: "backup.pending-key.v1"),
         githubSession: URLSession = GitHubBackupNetwork.session,
         now: @escaping @MainActor () -> Date = { Date() },
         availableCapacity: @escaping @Sendable (URL) -> Int64? = { BackupViewModel.availableCapacity(at: $0) },
         recoveryAuthentication: @escaping @MainActor () async throws -> Bool = {
             let context = LAContext()
             return try await context.evaluatePolicy(.deviceOwnerAuthentication,
                 localizedReason: "Show your Whytap backup recovery code")
         },
         cleanupWork: @escaping @MainActor () async throws -> Void = {}) {
        self.defaults = defaults; self.keyStore = keyStore
        self.githubTokenStore = githubTokenStore; self.local = local; self.settingsFiles = settingsFiles
        self.engine = engine; self.changeProbe = changeProbe; self.idle = idle; self.providerStore = providerStore; self.previousRestoreOutcome = previousRestoreOutcome; self.archivedKeyStore = archivedKeyStore
        self.pendingKeyStore = pendingKeyStore
        self.githubSession = githubSession
        self.now = now
        self.availableCapacity = availableCapacity
        self.recoveryAuthentication = recoveryAuthentication
        self.cleanupWork = cleanupWork
        hasPresentedRecoveryCode = defaults.bool(forKey: "backup.recovery-code-presented.v1")
    }

    /// Runtime wiring is explicit. Merely opening a settings preview or
    /// constructing a fixture never touches credentials, disk or the network.
    func stop() {
        stopped = true
        timer?.invalidate(); timer = nil; subscriptions.removeAll()
        initializationTask?.cancel(); operationTask?.cancel(); captureTask?.cancel(); clipboardTask?.cancel()
        started = false
    }

    /// Cancel owned work and wait before disposing injected stores or networking.
    /// The stopped gate also rejects SwiftUI tasks delivered after view teardown.
    func stopAndWait() async {
        stop()
        await initializationTask?.value
        await operationTask?.value
        await captureTask?.value
        await clipboardTask?.value
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        guard !started else { return initializationTask }; started = true; stopped = false
        // Resolve a durable management request before exposing backup actions.
        isBusy = true
        managementWarning = defaults.string(forKey: "backup.management-warning.v1")
        recoverySaved = defaults.bool(forKey: "backup.recovery-verified.v1")
        isEnabled = defaults.bool(forKey: "backup.enabled.v1")
        destinationName = defaults.string(forKey: "backup.destination-name.v1") ?? "Not connected"
        lastBackupAt = defaults.object(forKey: "backup.last-local.v1") as? Date
        lastRemoteBackupAt = defaults.object(forKey: "backup.last-copied.v1") as? Date
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] _ in Task { @MainActor in await self?.captureSettings() } }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .exodiaBackupArtifactsChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.markDirty()
                Task { @MainActor in await self?.captureSettings() }
            }
            .store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        let task = Task { await initialize() }
        initializationTask = task
        return task
    }

    private func initialize() async {
        guard !stopped, !Task.isCancelled else { isBusy = false; return }
        do {
            hasPendingMaintenance = try await local.maintenance() != nil
        } catch {
            hasPendingMaintenance = true
            errorMessage = "Backup management could not resume. Its recovery records are kept. Automatic backups remain paused."
        }
        if hasPendingMaintenance {
            isEnabled = false; defaults.set(false, forKey: "backup.enabled.v1")
            statusText = "Backup management is unfinished. Resume it to finish removing old copies."
        }
        if let outcome = previousRestoreOutcome(),
           defaults.string(forKey: "backup.last-outcome.v1") != outcome.id.uuidString {
            restoreNotice = outcome
        }
        recoveryCheckpoint = engine.checkpoint(); parkedItems = engine.parked()
        sourceStamp = defaults.string(forKey: "backup.source-stamp.v1")
        lastContentCheck = defaults.object(forKey: "backup.last-content-check.v1") as? Date ?? .distantPast
        needsFullBackup = lastBackupAt == nil || sourceStamp == nil
        // Resolve maintenance / restore protection before optional housekeeping.
        // A cleanup failure must never bypass a paused key-revocation request
        // or skip the rest of startup (including connection and recovery UI).
        do {
            try await cleanupWork()
            if !hasPendingMaintenance {
                try await local.cleanupOrphans()
                // Paused or not, already copied archives beyond the delta parent
                // are released at launch. A vanished unsent snapshot is captured again.
                let retention = try await local.applyRetention(destinationID: defaults.string(forKey: "backup.destination-id.v1"))
                if retention.forgottenPending > 0 { markDirty() }
            }
        } catch {
            if !hasPendingMaintenance { fail(error) }
        }
        await captureSettings()
        if defaults.string(forKey: "backup.destination-kind.v1") == "github" {
            do {
                guard let token = try githubTokenStore.read(), let owner = defaults.string(forKey: "backup.github-owner.v1") else {
                    throw GitHubBackupTransport.Failure.authentication
                }
                github = try GitHubBackupTransport(token: token, owner: owner,
                                                   repository: GitHubBackupTransport.savedRepository(defaults), session: githubSession)
                await updateGitHubConnection()
            } catch {
                githubRequiresReconnect = (error as? GitHubBackupTransport.Failure)?.requiresReconnect == true
                githubConnectionState = .needsAttention; githubConnectionError = error.localizedDescription
                recordBackupFailure(error, sourceStamp: nil)
            }
        }
        do { versions = try await local.versions(destinationID: defaults.string(forKey: "backup.destination-id.v1")) }
        catch { fail(error) }
        // Existing manually created GitHub copies adopt sync once. Later
        // cancellation, disconnection and maintenance still keep their pause.
        // WHY: .project-docs/decisions/2026-10-20-backup-auto-sync.md
        if !stopped, !Task.isCancelled, destinationKind == "github", recoverySaved, lastRemoteBackupAt != nil,
           !hasPendingMaintenance, !defaults.bool(forKey: "backup.github-auto-sync.v1") {
            enableCreatedBackupSync()
        }
        isBusy = false
        await poll()
    }

    private func key(create: Bool = true) throws -> Data {
        if let keyCache { return keyCache }
        if let encoded = try keyStore.read() {
            guard let key = Data(base64Encoded: encoded), key.count == 32 else { throw ConfigBackupError.keyUnavailable }
            keyCache = key; return key
        }
        guard create else { throw ConfigBackupError.keyUnavailable }
        // An absent key must never silently make existing archives unreadable.
        let roots = [local.root, settingsFiles.root]
        let existing = roots.contains { url in
            ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
                .contains { $0.hasSuffix(".exodiabackup") || $0 == "catalog.json" }
        }
        guard !existing, !recoverySaved else { throw ConfigBackupError.keyUnavailable }
        let key = ConfigBackupArchive.makeKey()
        try keyStore.save(key.base64EncodedString()); keyCache = key
        return key
    }

    func hideRecoveryCode() { codePresentationID = UUID(); recoveryCode = "" }

    func beginSetup() {
        guard !isBusy, !needsRestart, !hasPendingMaintenance else { return }
        // An already configured user reveals the credential only through the
        // authenticated Show action, never through Pause/Resume or Retry.
        if recoverySaved { recoveryCode = ""; errorMessage = nil; return }
        do { recoveryCode = try ConfigBackupArchive.recoveryCode(for: key()); errorMessage = nil }
        catch { fail(error) }
    }

    func confirmRecoveryCode(_ code: String) throws {
        let entered = try ConfigBackupArchive.key(from: code)
        guard entered == (try key()) else { throw ConfigBackupError.cannotUnlock }
        // Verify an actual independent decrypt, not a checkbox or cached-key read.
        let proof = ConfigBackupSnapshot(reason: "Recovery verification", preferences: [:])
        guard try ConfigBackupArchive.open(ConfigBackupArchive.seal(proof, key: entered), key: entered) == proof else {
            throw ConfigBackupError.cannotUnlock
        }
        recoverySaved = true; recoveryCode = ""
        defaults.set(true, forKey: "backup.recovery-verified.v1")
        rememberRecoveryCodePresented()
        errorMessage = nil
    }

    func copyRecoveryCode(pasteboard suppliedBoard: NSPasteboard? = nil,
                          suppression suppliedSuppression: ClipboardSuppression? = nil,
                          clearAfterNanoseconds: UInt64 = 120_000_000_000) {
        guard !recoveryCode.isEmpty else { return }
        let board = suppliedBoard ?? NSPasteboard.general
        let suppression = suppliedSuppression ?? ClipboardSuppression.shared
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(recoveryCode, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.writeObjects([item])
        // Privacy flags alone do not suppress Whytap's own polling watcher.
        suppression.suppressThrough(changeCount: board.changeCount)
        let copiedCount = board.changeCount
        clipboardTask?.cancel()
        clipboardTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: clearAfterNanoseconds)
            guard !Task.isCancelled, board.changeCount == copiedCount else { return }
            board.clearContents()
            suppression.suppressThrough(changeCount: board.changeCount)
        }
    }

    func showRecoveryCode() async {
        guard !isBusy, !isRevealingRecoveryCode else { return }
        isRevealingRecoveryCode = true
        defer { isRevealingRecoveryCode = false }
        let presentationID = codePresentationID
        do {
            guard try await recoveryAuthentication(), codePresentationID == presentationID else { return }
            recoveryCode = try ConfigBackupArchive.recoveryCode(for: key(create: false))
            rememberRecoveryCodePresented()
        } catch {
            let code = (error as NSError).code
            if (error as NSError).domain == LAError.errorDomain && [LAError.userCancel.rawValue, LAError.appCancel.rawValue, LAError.systemCancel.rawValue].contains(code) { return }
            errorMessage = "Your recovery code was not shown. Authenticate with your Mac password or Touch ID to try again."
        }
    }

    private func rememberRecoveryCodePresented() {
        hasPresentedRecoveryCode = true
        defaults.set(true, forKey: "backup.recovery-code-presented.v1")
    }

    func requireRecoveryCodePresentation() {
        hasPresentedRecoveryCode = false
        defaults.removeObject(forKey: "backup.recovery-code-presented.v1")
    }

    func beginReplacingCode() {
        guard !isBusy, !needsRestart, !hasPendingMaintenance else { return }
        replacementKey = ConfigBackupArchive.makeKey()
        do {
            recoveryCode = try ConfigBackupArchive.recoveryCode(for: replacementKey!)
            isReplacingCode = true; errorMessage = nil
        } catch { fail(error) }
    }

    func cancelReplacingCode() {
        replacementKey = nil; isReplacingCode = false; hideRecoveryCode()
    }

    func replaceRecoveryCode(verifiedCode: String) async {
        guard let replacementKey, !isBusy, !needsRestart, !hasPendingMaintenance else { return }
        do {
            guard try ConfigBackupArchive.key(from: verifiedCode) == replacementKey else { throw ConfigBackupError.cannotUnlock }
            guard destinationKind != nil else { throw ConfigBackupError.saveFailed }
            try await beginMaintenance(kind: .replaceCode, newKey: replacementKey)
        } catch { fail(error) }
    }

    func deleteBackups() async {
        guard !isBusy, !needsRestart, !hasPendingMaintenance else { return }
        do { try await beginMaintenance(kind: .deleteBackups, newKey: ConfigBackupArchive.makeKey()) }
        catch { fail(error) }
    }

    private func beginMaintenance(kind: BackupMaintenancePlan.Kind, newKey: Data) async throws {
        guard idle() else { throw ConfigBackupError.busy }
        isBusy = true
        defer { isBusy = false }
        let resumeAutomatic = isEnabled
        isEnabled = false; defaults.set(false, forKey: "backup.enabled.v1")
        // Preflight old-key retention before any destructive operation. Local
        // settings history stays recoverable even after the cloud code changes.
        try retainHistoryKey()
        try pendingKeyStore.save(newKey.base64EncodedString())
        let plan = BackupMaintenancePlan(kind: kind,
            destinationID: defaults.string(forKey: "backup.destination-id.v1"),
            newKeyID: ConfigBackupArchive.keyID(newKey), resumeAutomatic: resumeAutomatic)
        try await local.saveMaintenance(plan)
        hasPendingMaintenance = true
        isEnabled = false; defaults.set(false, forKey: "backup.enabled.v1")
        cancelReplacingCode(); clearPreview()
        if let captureTask { await captureTask.value }
        isBusy = false
        await resumeBackupManagement()
    }

    private func retainHistoryKey() throws {
        let oldKey = try key(create: false), id = ConfigBackupArchive.keyID(oldKey)
        var ids = defaults.stringArray(forKey: "backup.archived-key-ids.v1") ?? []
        guard ids.contains(id) || ids.count < 32 else { throw BackupManagementError.historyKeyLimit }
        try archivedKeyStore(id).save(oldKey.base64EncodedString())
        if !ids.contains(id) {
            ids.append(id); defaults.set(ids, forKey: "backup.archived-key-ids.v1")
        }
    }

    func resumeBackupManagement() async {
        await retainOperation(.maintenance) {
            self.maintenanceRetryAttempted = true
            await self.performBackupManagement()
        }
    }

    func stopBackupManagement() async {
        guard hasPendingMaintenance, !isBusy, !needsRestart else { return }
        isBusy = true; defer { isBusy = false }
        do {
            // Keep both the active history key and any staged replacement.
            // Retiring the active code prevents future setup reusing exposure.
            try retainHistoryKey()
            if let encoded = try pendingKeyStore.read(), let pending = Data(base64Encoded: encoded), pending.count == 32 {
                try archivedKeyStore(ConfigBackupArchive.keyID(pending)).save(encoded)
            }
            let fresh = ConfigBackupArchive.makeKey()
            try keyStore.save(fresh.base64EncodedString()); keyCache = fresh
            recoverySaved = false; defaults.removeObject(forKey: "backup.recovery-verified.v1")
            requireRecoveryCodePresentation()
            isEnabled = false; defaults.set(false, forKey: "backup.enabled.v1")
            let warning = "Old copies may remain at \(destinationName). Remove them there separately. Kept local copies may need their previous recovery codes."
            managementWarning = warning; defaults.set(warning, forKey: "backup.management-warning.v1")
            try await local.abandonMaintenance()
            hasPendingMaintenance = false; errorMessage = nil
            try? pendingKeyStore.delete()
            versions = (try? await local.versions(destinationID: defaults.string(forKey: "backup.destination-id.v1"))) ?? []
            statusText = "Backup management stopped. Automatic backup stays off. Save a new recovery code before starting again."
        } catch { fail(error) }
    }

    func dismissManagementWarning() {
        managementWarning = nil; defaults.removeObject(forKey: "backup.management-warning.v1")
    }

    func showRetainedBackups() { NSWorkspace.shared.activateFileViewerSelecting([local.root]) }

    private func performBackupManagement() async {
        guard !isBusy, !needsRestart, hasPendingMaintenance else { return }
        guard idle() else { fail(ConfigBackupError.busy); return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            guard var plan = try await local.maintenance(),
                  (plan.phase == .finalizing || plan.destinationID == defaults.string(forKey: "backup.destination-id.v1")),
                  let encoded = try pendingKeyStore.read(), let newKey = Data(base64Encoded: encoded),
                  newKey.count == 32, ConfigBackupArchive.keyID(newKey) == plan.newKeyID else { throw ConfigBackupError.keyUnavailable }
            if plan.phase != .finalizing {
                if plan.kind == .replaceCode {
                    statusText = "Saving and checking a full backup with your new code…"
                    if plan.replacement == nil {
                        let file = try await local.archiveURL()
                        defer { try? FileManager.default.removeItem(at: file) }
                        let summary = try await engine.create(file, newKey)
                        guard try await engine.inspect(file, newKey).summary.matchesArchive(summary) else { throw ConfigBackupError.invalidArchive }
                        _ = try await local.record(summary, from: file)
                        plan.replacement = summary
                        try await local.saveMaintenance(plan)
                    }
                    guard let summary = plan.replacement else { throw ConfigBackupError.invalidArchive }
                    let file = await local.fileURL(summary.id)
                    guard try await engine.inspect(file, newKey).summary.matchesArchive(summary) else { throw ConfigBackupError.invalidArchive }
                    if destinationKind == "github" {
                        guard let github else { throw GitHubBackupTransport.Failure.authentication }
                        // Always standalone: no dependency encrypted with the old code.
                        let store = local, destination = plan.destinationID!
                        let record = try await local.records().first { $0.summary.id == summary.id }
                        if record?.preparation == nil {
                            try await local.recordPreparation(id: summary.id, preparation: .init(destinationID: destination, depth: 0))
                        }
                        let remoteID = try await github.upload(file: file, summary: summary, key: newKey,
                            resumeReleaseID: record?.preparation?.draftID,
                            onDraft: { try await store.recordDraft(id: summary.id, destinationID: destination, draftID: $0) })
                        try await local.markCopied(id: summary.id, destinationID: destination, remoteID: remoteID)
                    } else if destinationKind == "folder" {
                        let folder = try backupFolder()
                        let access = folder.startAccessingSecurityScopedResource()
                        defer { if access { folder.stopAccessingSecurityScopedResource() } }
                        let copy = Task.detached(priority: .utility) {
                            try BackupLocalStore.copyArchive(file, to: folder.appendingPathComponent(summary.id.uuidString.lowercased() + ".exodiabackup"), replaceDamagedCopy: true)
                        }
                        try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
                        try await local.markCopied(id: summary.id, destinationID: plan.destinationID!)
                    } else { throw ConfigBackupError.saveFailed }
                    try Task.checkCancellation()
                    plan.phase = .cleanup
                    try await local.saveMaintenance(plan)
                }
                // The journal is durable before the active key changes. Repeating
                // this save after interruption is safe and preserves the new code.
                if plan.kind == .replaceCode {
                    if try key(create: false) != newKey { try retainHistoryKey() }
                    try keyStore.save(newKey.base64EncodedString()); keyCache = newKey
                    recoverySaved = true; defaults.set(true, forKey: "backup.recovery-verified.v1")
                }
                statusText = "Removing old backup copies…"
                let keep = plan.replacement?.id
                if destinationKind == "github" {
                    guard let github else { throw GitHubBackupTransport.Failure.authentication }
                    try await github.deleteBackups(except: keep)
                } else if destinationKind == "folder" {
                    let folder = try backupFolder()
                    let access = folder.startAccessingSecurityScopedResource()
                    defer { if access { folder.stopAccessingSecurityScopedResource() } }
                    let cleanup = Task.detached(priority: .utility) { try BackupLocalStore.deleteArchiveFiles(in: folder, except: keep) }
                    try await withTaskCancellationHandler(operation: { try await cleanup.value }, onCancel: { cleanup.cancel() })
                }
                try Task.checkCancellation()
                try await local.deleteFullBackups(except: keep)
                if plan.kind == .deleteBackups {
                    // Retire the exposed code for future setup too. The old key is
                    // retained only on this Mac for its automatic settings history.
                    if try key(create: false) != newKey { try retainHistoryKey() }
                    try keyStore.save(newKey.base64EncodedString()); keyCache = newKey
                    recoverySaved = false; defaults.removeObject(forKey: "backup.recovery-verified.v1")
                    requireRecoveryCodePresentation()
                } else {
                    lastBackupAt = plan.replacement?.createdAt; lastRemoteBackupAt = Date()
                    defaults.set(lastBackupAt, forKey: "backup.last-local.v1")
                    defaults.set(lastRemoteBackupAt, forKey: "backup.last-copied.v1")
                }
                plan.phase = .finalizing
                try await local.saveMaintenance(plan)
            }
            if plan.kind == .deleteBackups {
                try githubTokenStore.delete(); github = nil; githubConnectionState = .disconnected
                for field in ["destination-kind", "destination-id", "destination-name", "github-owner", "github-repository", "folder-bookmark", "last-local", "last-copied", "source-stamp"] {
                    defaults.removeObject(forKey: "backup.\(field).v1")
                }
                destinationName = "Not connected"; lastBackupAt = nil; lastRemoteBackupAt = nil
            }
            try await local.finishMaintenance()
            hasPendingMaintenance = false; needsFullBackup = true
            try? pendingKeyStore.delete()
            if plan.kind == .replaceCode { setEnabled(plan.resumeAutomatic) }
            statusText = plan.kind == .replaceCode
                ? "New code is active. Old backup copies were removed from this Mac and the connected destination."
                : "Backups were deleted and automatic backup is off. Your working data and local settings history are kept."
            await refreshVersionsQuietly()
        } catch {
            if error is CancellationError || Task.isCancelled { return }
            fail(error)
            let detail = errorMessage ?? "The operation could not finish."
            errorMessage = detail + " Some old copies may still exist. Automatic backup is paused. Reconnect if needed, then choose Finish backup management."
        }
    }


    func connectExistingGitHub() async {
        await retainOperation(.connection) { await self.performConnectExistingGitHub() }
    }

    private func performConnectExistingGitHub() async {
        guard !isBusy, !needsRestart else { return }
        isBusy = true; errorMessage = nil; githubConnectionState = .checking; githubConnectionError = nil
        statusText = "Checking your GitHub CLI login…"
        do {
            let token = try await BackupGitHubLogin.existingToken()
            isBusy = false
            await performConnectGitHub(token: token)
        } catch {
            isBusy = false; githubConnectionState = .needsAttention
            githubConnectionError = error.localizedDescription; fail(error)
        }
    }

    func connectGitHub(token: String) async {
        await retainOperation(.connection) { await self.performConnectGitHub(token: token) }
    }

    private func performConnectGitHub(token: String) async {
        guard !isBusy, !needsRestart else { return }
        isBusy = true; errorMessage = nil; githubConnectionState = .checking; githubConnectionError = nil
        statusText = "Connecting your private backup repository…"
        do {
            if hasPendingMaintenance {
                guard destinationKind == "github", let owner = defaults.string(forKey: "backup.github-owner.v1") else {
                    isBusy = false; githubConnectionState = .disconnected
                    errorMessage = "Reconnect the same backup folder to continue this request."
                    return
                }
                let transport = try GitHubBackupTransport(token: token.trimmingCharacters(in: .whitespacesAndNewlines), owner: owner,
                                                          repository: GitHubBackupTransport.savedRepository(defaults), session: githubSession)
                _ = try await transport.versions()
                try githubTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
                github = transport; githubConnectionState = .connected; githubConnectionError = nil; isBusy = false
                githubRequiresReconnect = false
                transferFailureCount = 0; nextAutomaticAttempt = .distantPast
                statusText = "Reconnected. Choose Finish backup management to continue."
                return
            }
            let saved = destinationKind == "github"
                ? defaults.string(forKey: "backup.github-owner.v1").map { (owner: $0, repository: GitHubBackupTransport.savedRepository(defaults)) }
                : nil
            let transport = try await GitHubBackupTransport.connect(token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                                                                    saved: saved, session: githubSession)
            try Task.checkCancellation()
            let name = await transport.destinationName
            try githubTokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            github = transport; githubConnectionState = .connected; githubConnectionError = nil
            githubRequiresReconnect = false
            transferFailureCount = 0; nextAutomaticAttempt = .distantPast
            lastAttempt = .distantPast
            destinationName = "GitHub · " + name
            selectDestination(id: "github:" + name.lowercased())
            defaults.set("github", forKey: "backup.destination-kind.v1")
            defaults.set(name.components(separatedBy: "/").first, forKey: "backup.github-owner.v1")
            defaults.set(await transport.repositoryName, forKey: GitHubBackupTransport.repositoryDefaultsKey)
            defaults.set(destinationName, forKey: "backup.destination-name.v1")
            await refreshVersionsQuietly()
            statusText = "GitHub connected."
            isBusy = false
        } catch {
            isBusy = false; githubConnectionState = .needsAttention
            githubConnectionError = error.localizedDescription; fail(error)
        }
    }

    var canUseGitHubBackup: Bool { githubConnectionState == .connected && github != nil && destinationKind == "github" }

    var githubBackupURL: URL? {
        guard destinationKind == "github", let owner = defaults.string(forKey: "backup.github-owner.v1") else { return nil }
        return GitHubBackupTransport.backupURL(owner: owner, repository: GitHubBackupTransport.savedRepository(defaults))
    }

    var syncState: BackupSyncState {
        if needsRestart { return .restoreReady }
        if hasPendingMaintenance || errorMessage != nil || githubConnectionState == .needsAttention { return .needsAttention }
        if githubConnectionState == .checking { return .checking }
        guard canUseGitHubBackup else { return .disconnected }
        if isBusy { return operationKind == .restore || operationKind == .preview ? .restoring : .syncing }
        guard lastRemoteBackupAt != nil else { return .notCreated }
        guard isEnabled else { return .paused }
        if needsFullBackup || versions.contains(where: \.pendingCopy) { return .waiting }
        if !hasPresentedRecoveryCode { return .recoveryCodeNeeded }
        return .synced
    }

    private func enableCreatedBackupSync() {
        isEnabled = true
        defaults.set(true, forKey: "backup.enabled.v1")
        defaults.set(true, forKey: "backup.github-auto-sync.v1")
    }

    /// The Automatic backup switch exists once a copy reached the destination,
    /// and stays usable while that destination is unreachable: local captures
    /// continue offline, so pausing them must too.
    var showsAutomaticBackup: Bool { lastRemoteBackupAt != nil && destinationKind != nil }

    /// Settings sync needs the recovery-code key and the GitHub repository,
    /// not an upload from this Mac: a second Mac that restored the backup
    /// qualifies before it ever backs up itself.
    // WHY: .project-docs/decisions/2026-11-20-settings-sync.md
    var showsSettingsSync: Bool { showsAutomaticBackup || (canUseGitHubBackup && recoverySaved) }

    var canChangeAutomaticBackup: Bool {
        showsAutomaticBackup && recoverySaved && !needsRestart && !hasPendingMaintenance
    }

    /// When the next automatic capture may start; nil while paused or already due.
    var nextAutomaticCapture: Date? {
        guard isEnabled else { return nil }
        let next = lastContentCheck.addingTimeInterval(Self.automaticCaptureInterval)
        return next > now() ? next : nil
    }

    /// Pause keeps every local and GitHub copy, survives restart and stops
    /// automatic captures and uploads until resumed. A running automatic
    /// backup is cancelled; one the user started with Back up continues.
    func setAutomaticBackup(_ enabled: Bool) {
        if !enabled, operationKind == .backup, automaticOperationRunning {
            cancelCurrentOperation(); return
        }
        guard !enabled || (recoverySaved && destinationKind != nil) else { return }
        setEnabled(enabled)
        if isEnabled == enabled { defaults.set(true, forKey: "backup.github-auto-sync.v1") }
    }

    func checkGitHubConnection() async {
        guard !Task.isCancelled else { return }
        await retainOperation(.connection, cancelWithCaller: true) {
            guard !Task.isCancelled else { return }
            self.isBusy = true
            await self.updateGitHubConnection()
            self.isBusy = false
        }
    }

    private func updateGitHubConnection() async {
        guard !stopped, !Task.isCancelled else { return }
        guard let github, destinationKind == "github" else {
            githubConnectionState = .disconnected; githubConnectionError = nil; return
        }
        let previousState = githubConnectionState
        githubConnectionState = .checking; githubConnectionError = nil
        do {
            try await github.checkConnection()
            try Task.checkCancellation()
            githubConnectionState = .connected
            githubRequiresReconnect = false
            transferFailureCount = 0; nextAutomaticAttempt = .distantPast
        } catch {
            if error is CancellationError || Task.isCancelled {
                githubConnectionState = previousState
                return
            }
            githubConnectionState = .needsAttention
            githubConnectionError = error.localizedDescription
            githubRequiresReconnect = (error as? GitHubBackupTransport.Failure)?.requiresReconnect == true
            recordBackupFailure(error, sourceStamp: nil)
        }
    }

    func disconnectGitHub() {
        guard !isBusy, !needsRestart, !hasPendingMaintenance else { return }
        do {
            try githubTokenStore.delete()
            github = nil; githubConnectionState = .disconnected; githubConnectionError = nil
            if destinationKind == "github" {
                setEnabled(false)
                for field in ["destination-kind", "destination-id", "destination-name", "github-owner", "github-repository"] {
                    defaults.removeObject(forKey: "backup.\(field).v1")
                }
                destinationRevision += 1; destinationName = "Not connected"
            }
            errorMessage = nil
        } catch { githubConnectionError = "GitHub could not be disconnected. Try again." }
    }

    /// One action covers the entire workspace, including every stored provider key.
    /// WHY: .project-docs/decisions/2026-10-20-simple-github-backup.md
    func backupEverything() async {
        await retainOperation(.backup) {
            guard self.canUseGitHubBackup, !self.needsRestart, !self.hasPendingMaintenance else { return }
            guard self.idle() else { self.fail(ConfigBackupError.busy); return }
            self.hideRecoveryCode()
            let presentationID = self.codePresentationID
            let firstBackup = self.lastRemoteBackupAt == nil && !self.hasPresentedRecoveryCode
            do {
                if self.lastBackupAt == nil, self.lastRemoteBackupAt == nil, !self.recoverySaved,
                   let github = self.github {
                    self.isBusy = true
                    let existing = try await github.versions()
                    self.isBusy = false
                    guard existing.isEmpty else {
                        self.errorMessage = "A backup already exists in GitHub. Use Restore backup with your saved recovery code to connect this Mac to it."
                        return
                    }
                }
                let code = try ConfigBackupArchive.recoveryCode(for: self.key())
                // The user receives the code as the result; no paste-back ceremony.
                self.recoverySaved = true
                self.defaults.set(true, forKey: "backup.recovery-verified.v1")
                if await self.performBackupNow(), !Task.isCancelled {
                    // Only the first created backup turns sync on. An explicit
                    // pause stays until the Automatic backup switch resumes it.
                    if !self.defaults.bool(forKey: "backup.github-auto-sync.v1") {
                        self.enableCreatedBackupSync()
                    } else if !self.isEnabled {
                        self.statusText = "Encrypted backup uploaded to GitHub and checked. Automatic backup stays paused."
                    }
                    if firstBackup, self.codePresentationID == presentationID {
                        self.recoveryCode = code
                        self.rememberRecoveryCodePresented()
                    }
                }
            } catch { self.isBusy = false; self.fail(error) }
        }
    }

    func restoreEverything(code: String) async {
        await retainOperation(.restore) {
            guard self.canUseGitHubBackup, let github = self.github,
                  !self.needsRestart, !self.hasPendingMaintenance else { return }
            guard self.canStartRestore() else { return }
            self.hideRecoveryCode(); self.clearPreview(); self.errorMessage = nil
            self.isBusy = true
            do {
                let key = try ConfigBackupArchive.key(from: code)
                guard let version = try await github.versions(key: key).first else {
                    if try await github.versions().isEmpty {
                        self.errorMessage = "No backups found in GitHub."; self.isBusy = false; return
                    }
                    throw ConfigBackupError.cannotUnlock
                }
                self.isBusy = false
                await self.performPrepareRestore(version: version, code: code)
                if let preview = self.restorePreview {
                    await self.performRestore(sections: preview.summary.sections)
                }
            } catch { self.isBusy = false; self.fail(error) }
        }
    }

    func chooseFolder() async {
        await retainOperation(.connection) { await self.performChooseFolder() }
    }

    private func performChooseFolder() async {
        guard !isBusy, !needsRestart else { return }
        guard !hasPendingMaintenance || destinationKind == "folder" else {
            errorMessage = "Reconnect your existing GitHub destination to continue this request."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose a backup folder"
        panel.message = "Choose iCloud Drive, another synced folder, or an external drive. Whytap verifies the saved file; your sync service handles cloud upload."
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "Use this folder"
        guard await panel.begin() == .OK, let selected = panel.url else { return }
        do {
            try Task.checkCancellation()
            let access = selected.startAccessingSecurityScopedResource()
            defer { if access { selected.stopAccessingSecurityScopedResource() } }
            let folder = ["Whytap Backups", "Exodia Backups"].contains(selected.lastPathComponent) ? selected : selected.appendingPathComponent("Whytap Backups", isDirectory: true)
            let folderID = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            guard !hasPendingMaintenance || defaults.string(forKey: "backup.destination-id.v1") == "folder:" + folderID else {
                errorMessage = "Choose the same backup folder to finish removing its old copies."
                return
            }
            try ConfigBackupFiles.ensurePrivateDirectory(folder)
            let bookmark = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if hasPendingMaintenance {
                defaults.set(bookmark, forKey: "backup.folder-bookmark.v1")
                statusText = "Folder reconnected. Choose Finish backup management to continue."
                return
            }
            selectDestination(id: "folder:" + folderID)
            defaults.set(bookmark, forKey: "backup.folder-bookmark.v1")
            defaults.set("folder", forKey: "backup.destination-kind.v1")
            destinationName = "Folder · " + selected.lastPathComponent
            defaults.set(destinationName, forKey: "backup.destination-name.v1")
            setEnabled(recoverySaved)
            await refreshVersionsQuietly()
            if isEnabled { await performBackupNow() }
            else { statusText = "Folder connected. Choose a backup to restore, or save a recovery code to start new backups." }
        } catch { fail(error) }
    }

    func setEnabled(_ enabled: Bool) {
        guard !needsRestart, !enabled || !hasPendingMaintenance else { return }
        guard !enabled || (recoverySaved && defaults.string(forKey: "backup.destination-kind.v1") != nil) else {
            beginSetup(); return
        }
        isEnabled = enabled; defaults.set(enabled, forKey: "backup.enabled.v1")
        if enabled { needsFullBackup = true; statusText = "Automatic encrypted backups are on." }
        else { statusText = "Automatic backup is paused. Your local settings history and existing backups are kept." }
    }

    func backupNow() async {
        await retainOperation(.backup) { await self.performBackupNow() }
    }

    @discardableResult
    private func performBackupNow(automatic: Bool = false) async -> Bool {
        guard !isBusy, !needsRestart, !hasPendingMaintenance else { return false }
        guard recoverySaved, destinationKind != nil else { beginSetup(); return false }
        guard idle() else { errorMessage = ConfigBackupError.busy.localizedDescription; return false }
        guard !automatic || isEnabled else { return false }
        // Set before the first suspension so the switch can cancel this run.
        automaticOperationRunning = automatic
        defer { automaticOperationRunning = false }
        if let shortage = await diskShortage(automatic: automatic) {
            // Checked before any export: a full disk never gets a partial archive.
            lastAttempt = now(); statusText = "Backup needs attention."; errorMessage = shortage
            return false
        }
        // A pause during the disk check stops an automatic run before it exports.
        guard !Task.isCancelled, !isBusy, !automatic || isEnabled else { return false }
        isBusy = true; errorMessage = nil; lastAttempt = now()
        statusText = "Saving an encrypted copy on this Mac…"
        var unfinished: URL?
        var attemptedStamp: String?
        do {
            let key = try key(), revision = changeRevision, probe = changeProbe
            let capturedStamp = await Task.detached(priority: .utility) { probe() }.value
            attemptedStamp = capturedStamp
            try Task.checkCancellation()
            let file = try await local.archiveURL(); unfinished = file
            let keyID = ConfigBackupArchive.keyID(key)
            let previous = try await local.records().first { $0.recoveryOnly != true && $0.archiveKeyID == keyID
                && FileManager.default.fileExists(atPath: local.root.appendingPathComponent($0.summary.id.uuidString.lowercased() + ".exodiabackup").path) }
            let summary: ArtifactBackupSummary?
            if let create = engine.createIfChanged {
                summary = try await create(file, key, previous?.summary.contentFingerprint)
            } else { summary = try await engine.create(file, key) }
            var current: (UUID, URL)?
            if let summary {
                guard try await engine.inspect(file, key).summary.matchesArchive(summary) else { throw ConfigBackupError.invalidArchive }
                let stored = try await local.record(summary, from: file, automatic: true, archiveKeyID: keyID)
                unfinished = nil
                current = (summary.id, stored)
                lastBackupAt = summary.createdAt; defaults.set(lastBackupAt, forKey: "backup.last-local.v1")
            }
            if let id = summary?.id ?? previous?.summary.id { try await local.coalescePending(keeping: id) }
            lastContentCheck = now(); defaults.set(lastContentCheck, forKey: "backup.last-content-check.v1")
            needsFullBackup = changeRevision != revision
            sourceStamp = capturedStamp
            defaults.set(capturedStamp, forKey: "backup.source-stamp.v1")
            await refreshVersionsQuietly(includeDestination: false)
            // A disconnected destination never prevents a fresh local snapshot.
            // Network backoff applies to transfer, not artifact capture.
            if (!automatic || now() >= nextAutomaticAttempt) && !githubRequiresReconnect {
                try await copyPending(current: current, key: key)
            }
            await refreshVersionsQuietly(includeDestination: false)
            let finishedStamp = await Task.detached(priority: .utility) { probe() }.value
            if finishedStamp != capturedStamp || changeRevision != revision { needsFullBackup = true }
            let pending = try await local.pendingCopies(destinationID: defaults.string(forKey: "backup.destination-id.v1") ?? "")
            if pending.isEmpty && (destinationKind != "github" || githubConnectionState == .connected) {
                errorMessage = nil
                transferFailureCount = 0; nextAutomaticAttempt = .distantPast
                statusText = destinationKind == "github" ? "Encrypted backup uploaded to GitHub and checked." : "Encrypted backup saved and checked in your folder. Cloud sync is managed by your sync service."
            } else { statusText = "Fresh encrypted snapshot saved on this Mac. Upload is pending." }
            stalledSourceStamp = nil
            isBusy = false
            return pending.isEmpty && (destinationKind != "github" || githubConnectionState == .connected)
        } catch {
            if let unfinished { try? FileManager.default.removeItem(at: unfinished) }
            // Bound unchanged source failures by the hourly content schedule.
            // A changed metadata hint or an explicit action can retry sooner.
            lastContentCheck = now(); defaults.set(lastContentCheck, forKey: "backup.last-content-check.v1")
            isBusy = false; recordBackupFailure(error, sourceStamp: attemptedStamp); fail(error)
            return false
        }
    }

    /// Space for one more archive (staging clones unchanged files on APFS),
    /// plus a reserve that keeps this Mac usable. Unknown capacity proceeds;
    /// a write that still runs out of space fails without keeping a partial file.
    private func diskShortage(automatic: Bool) async -> String? {
        guard let available = availableCapacity(local.root) else { return nil }
        let localSizes = ((try? await local.records()) ?? []).filter { $0.recoveryOnly != true }.map(\.summary.totalBytes)
        let estimate = (localSizes + versions.map(\.size)).max() ?? 0
        let required = max(0, estimate) + (automatic ? Self.automaticFreeSpaceReserve : Self.manualFreeSpaceReserve)
        guard available < required else { return nil }
        let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
        return automatic
            ? "Automatic backup is waiting for disk space: it needs about \(format(required)) free on this Mac and \(format(available)) is available. Free some space or pause automatic backup."
            : "There is not enough disk space for a backup: it needs about \(format(required)) free on this Mac and \(format(available)) is available. Free some space, then try again."
    }

    nonisolated static func availableCapacity(at url: URL) -> Int64? {
        var candidate = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        return (try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    @discardableResult
    private func copyPending(current: (UUID, URL)? = nil, key: Data) async throws -> Int {
        guard let destinationID = defaults.string(forKey: "backup.destination-id.v1") else { throw ConfigBackupError.saveFailed }
        // An unsent archive removed outside Whytap cannot be uploaded; its
        // content is captured again instead of failing every retry.
        if try await local.applyRetention(destinationID: destinationID).forgottenPending > 0 { markDirty() }
        let pending = try await local.pendingCopies(destinationID: destinationID)
        // Finish a resumable transfer before preparing the latest generation.
        // Offline edits can then replace the one unprepared pending snapshot.
        let ordered = pending.filter { $0.preparation != nil } + pending.filter { $0.preparation == nil }
        for record in ordered.prefix(3) {
            try Task.checkCancellation()
            let file = await local.fileURL(record.summary.id)
            if current?.0 != record.summary.id {
                let verified = try await engine.inspect(file, key)
                guard verified.summary.id == record.summary.id else { throw ConfigBackupError.invalidArchive }
            }
            if destinationKind == "github" {
                guard let github else { throw GitHubBackupTransport.Failure.authentication }
                statusText = "Uploading and checking changed backup files…"
                let transfer = try await prepareTransfer(record, file: file, destinationID: destinationID, key: key)
                let store = local, snapshotID = record.summary.id
                let id = try await github.upload(file: transfer.file, summary: record.summary, key: key, resumeReleaseID: transfer.draftID,
                    onDraft: { id in try await store.recordDraft(id: snapshotID, destinationID: destinationID, draftID: id) },
                    onProgress: { [weak self] part, total in
                        await MainActor.run { self?.statusText = "Uploading backup part \(part) of \(total)…" }
                    })
                try await local.markCopied(id: record.summary.id, destinationID: destinationID, remoteID: id, depth: transfer.depth)
                if transfer.file.pathExtension == "upload" { try? FileManager.default.removeItem(at: transfer.file) }
            } else if destinationKind == "folder" {
                let folder = try backupFolder()
                let access = folder.startAccessingSecurityScopedResource()
                defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let target = folder.appendingPathComponent(record.summary.id.uuidString.lowercased() + ".exodiabackup")
                let copy = Task.detached(priority: .utility) { try BackupLocalStore.copyArchive(file, to: target) }
                try await withTaskCancellationHandler(operation: { try await copy.value }, onCancel: { copy.cancel() })
                try await local.markCopied(id: record.summary.id, destinationID: destinationID)
            } else { throw ConfigBackupError.saveFailed }
            lastRemoteBackupAt = Date(); defaults.set(lastRemoteBackupAt, forKey: "backup.last-copied.v1")
        }
        return min(pending.count, 3)
    }

    private func prepareTransfer(_ record: BackupLocalStore.Record, file: URL, destinationID: String, key: Data) async throws -> (file: URL, depth: Int, draftID: Int?) {
        let output = await local.uploadFileURL(id: record.summary.id, destinationID: destinationID)
        if let prepared = record.preparation, prepared.destinationID == destinationID {
            guard (0...32).contains(prepared.depth), prepared.baseID != record.summary.id else { throw ConfigBackupError.invalidArchive }
            guard let baseID = prepared.baseID else { return (file, 0, prepared.draftID) }
            if FileManager.default.fileExists(atPath: output.path) {
                guard try await delta.baseID(in: output, key: key) == baseID else { throw ConfigBackupError.invalidArchive }
                return (output, prepared.depth, prepared.draftID)
            }
            // The prepared delta vanished before GitHub had a draft for it, so
            // nothing remote depends on it: prepare again from local archives.
            guard prepared.draftID == nil else { throw ConfigBackupError.invalidArchive }
        }
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        let records = try await local.records()
        // A parent archive removed from this Mac cannot serve as a delta base;
        // fall back to the newest one still present instead of a full upload.
        let base = records.first { $0.summary.id != record.summary.id && $0.destinationID == destinationID
            && $0.recoveryOnly != true && $0.remoteID != nil && ($0.uploadedDepth ?? 0) < 32
            && FileManager.default.fileExists(atPath: local.root.appendingPathComponent($0.summary.id.uuidString.lowercased() + ".exodiabackup").path) }
        let baseFile = base.map { record in local.root.appendingPathComponent(record.summary.id.uuidString.lowercased() + ".exodiabackup") }
        let prepared = try await delta.prepare(full: file, base: baseFile, output: output, key: key)
        let depth = prepared.baseID == nil ? 0 : (base?.uploadedDepth ?? 0) + 1
        try await local.recordPreparation(id: record.summary.id,
            preparation: .init(destinationID: destinationID, baseID: prepared.baseID, depth: depth))
        return (prepared.file, depth, nil)
    }

    func refreshVersions() async {
        await retainOperation(.refresh) { await self.performRefreshVersions() }
    }

    private func performRefreshVersions() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        errorMessage = nil
        await refreshVersionsQuietly()
    }
    private func refreshVersionsQuietly(includeDestination: Bool = true) async {
        do {
            let revision = destinationRevision
            var all = try await local.versions(destinationID: defaults.string(forKey: "backup.destination-id.v1"))
            if includeDestination, destinationKind == "github", let github {
                for version in try await github.versions() where !all.contains(where: { $0.id == version.id }) { all.append(version) }
            } else if includeDestination, destinationKind == "folder" {
                let folder = try backupFolder()
                let access = folder.startAccessingSecurityScopedResource(); defer { if access { folder.stopAccessingSecurityScopedResource() } }
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey], options: [.skipsHiddenFiles])
                for file in urls where file.pathExtension == "exodiabackup" {
                    guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !all.contains(where: { $0.id == id.uuidString }) else { continue }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    all.append(BackupVersion(id: id.uuidString, createdAt: values.creationDate ?? .distantPast,
                                             size: Int64(values.fileSize ?? 0), localURL: file, remoteID: nil, location: .folder))
                }
            }
            guard revision == destinationRevision else { return }
            versions = all.sorted { $0.createdAt > $1.createdAt }
        } catch { fail(error) }
    }

    func prepareRestore(version: BackupVersion, code: String) async {
        await retainOperation(.preview) { await self.performPrepareRestore(version: version, code: code) }
    }

    private func performPrepareRestore(version: BackupVersion, code: String) async {
        guard !isBusy, !needsRestart, !hasPendingMaintenance else { return }
        isBusy = true; errorMessage = nil; statusText = "Opening and checking the backup…"
        do {
            clearPreview()
            let key = try ConfigBackupArchive.key(from: code)
            let file: URL
            if let localURL = version.localURL { file = localURL }
            else {
                guard let github else { throw GitHubBackupTransport.Failure.authentication }
                file = try previewURL()
                do { try await github.download(version: version, to: file, key: key) }
                catch { try? FileManager.default.removeItem(at: file); throw error }
            }
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let expanded = try await expandedArchive(file: file, key: key)
            try await preview(file: expanded, key: key)
            guard restorePreview?.summary.id.uuidString == version.id else {
                cancelRestore(); throw ConfigBackupError.invalidArchive
            }
        } catch { clearPreview(); fail(error) }
        isBusy = false
    }

    func chooseArchive(code: String) async {
        await retainOperation(.preview) { await self.performChooseArchive(code: code) }
    }

    private func performChooseArchive(code: String) async {
        guard !isBusy, !needsRestart, !hasPendingMaintenance else { return }
        let panel = NSOpenPanel(); panel.title = "Open a Whytap backup"; panel.canChooseDirectories = false
        panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard await panel.begin() == .OK, let file = panel.url else { return }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let key = try ConfigBackupArchive.key(from: code)
            let access = file.startAccessingSecurityScopedResource()
            defer { if access { file.stopAccessingSecurityScopedResource() } }
            let expanded = try await expandedArchive(file: file, key: key)
            try await preview(file: expanded, key: key)
        }
        catch { clearPreview(); fail(error) }
    }

    private func expandedArchive(file: URL, key: Data) async throws -> URL {
        guard try await delta.baseID(in: file, key: key) != nil else { return file }
        var chain = [file], visited = Set<UUID>(), temporary: [URL] = []
        defer { for file in temporary { try? FileManager.default.removeItem(at: file) } }
        var current = file
        while let baseID = try await delta.baseID(in: current, key: key) {
            try Task.checkCancellation()
            guard chain.count < 33, visited.insert(baseID).inserted else { throw ConfigBackupError.invalidArchive }
            let localFile = await local.fileURL(baseID)
            if FileManager.default.fileExists(atPath: localFile.path) { current = localFile }
            else {
                guard let github else { throw GitHubBackupTransport.Failure.incomplete }
                let version = try await github.version(id: baseID)
                let downloaded = try previewURL()
                temporary.append(downloaded)
                try await github.download(version: version, to: downloaded, key: key)
                current = downloaded
            }
            chain.append(current)
        }
        let output = try previewURL()
        do { _ = try await delta.reconstruct(chain: chain, output: output, key: key); return output }
        catch { try? FileManager.default.removeItem(at: output); throw error }
    }

    private func preview(file: URL, key: Data) async throws {
        let access = file.startAccessingSecurityScopedResource()
        defer { if access { file.stopAccessingSecurityScopedResource() } }
        let preview = try await engine.inspect(file, key)
        try Task.checkCancellation()
        restoreFile = file; restoreKey = key; restorePreview = preview
        statusText = "Backup checked. Choose what to restore."
    }

    func restore(sections: Set<ArtifactBackupSection>) async {
        await retainOperation(.restore) { await self.performRestore(sections: sections) }
    }

    private func performRestore(sections: Set<ArtifactBackupSection>) async {
        guard !isBusy, !needsRestart, !hasPendingMaintenance, !sections.isEmpty, let file = restoreFile, let key = restoreKey else { return }
        guard canStartRestore() else { return }
        isBusy = true; errorMessage = nil; statusText = "Preparing a safe restore…"
        defer { isBusy = false }
        do {
            let access = file.startAccessingSecurityScopedResource(); defer { if access { file.stopAccessingSecurityScopedResource() } }
            statusText = "Keeping a recovery copy of this Mac…"
            var beforeFile: URL?
            do {
                let beforeKey = recoverySaved ? try self.key() : key
                let source = try await local.archiveURL(); beforeFile = source
                let summary = try await engine.create(source, beforeKey)
                _ = try await engine.inspect(source, beforeKey)
                _ = try await local.record(summary, from: source, purpose: "Before restore", recoveryOnly: true)
                beforeFile = nil
            } catch {
                if let beforeFile { try? FileManager.default.removeItem(at: beforeFile) }
                try Task.checkCancellation()
                // Broken current data must remain recoverable too. The core
                // keeps its raw before-state even when a portable export fails.
            }
            try Task.checkCancellation()
            statusText = "Preparing the selected restore…"
            try await engine.stage(file, key, sections)
            if Task.isCancelled { _ = try engine.cancelPlanned(); throw CancellationError() }
            cleanupPreviewFiles()
            needsRestart = true; restorePreview = nil; restoreKey = nil; restoreFile = nil
            statusText = "Restore is ready. Quit Whytap normally and open it again when your work is finished."
            // Keep a fresh Mac on the source recovery credential, while retaining
            // its previous local history key. A cache error must not disguise an
            // already armed transaction as a failed restore.
            if !recoverySaved {
                do {
                    let encodedPrevious = try keyStore.read()
                    let previous = encodedPrevious.flatMap { Data(base64Encoded: $0) }
                    if let previous, previous.count == 32, previous != key {
                        let id = ConfigBackupArchive.keyID(previous)
                        var ids = defaults.stringArray(forKey: "backup.archived-key-ids.v1") ?? []
                        guard ids.count < 32 || ids.contains(id) else { throw ConfigBackupError.keyUnavailable }
                        try archivedKeyStore(id).save(previous.base64EncodedString())
                        if !ids.contains(id) { ids.append(id) }
                        defaults.set(ids, forKey: "backup.archived-key-ids.v1")
                    }
                    try keyStore.save(key.base64EncodedString()); keyCache = key
                    recoverySaved = true; defaults.set(true, forKey: "backup.recovery-verified.v1")
                    rememberRecoveryCodePresented()
                } catch {
                    errorMessage = "Restore is ready, but its code could not be remembered for future backups. Keep your recovery code and finish backup setup after reopening Whytap."
                }
            }
        } catch { fail(error) }
    }

    func restoreSettingsDefaults(_ section: ConfigBackupSection) async {
        await restoreSettingsBlock(section, version: ConfigBackupSnapshot(reason: "App defaults", preferences: [:]))
    }

    func restoreSettingsBlock(_ section: ConfigBackupSection, version: ConfigBackupSnapshot) async {
        guard !isBusy, !needsRestart, !hasPendingMaintenance else { return }
        guard canStartRestore() else { return }
        isBusy = true; defer { isBusy = false }
        do {
            // Capture healthy current values for the selectable local history;
            // the core transaction also retains exact raw before-state if the
            // current settings themselves are damaged.
            await captureSettings()
            let key = try key()
            let (file, group) = try BackupSettingsBlockRestore.archive(version, section: section, key: key, directory: settingsFiles.root)
            defer { try? FileManager.default.removeItem(at: file) }
            try await engine.stage(file, key, [group])
            needsRestart = true
            statusText = "\(section.title) is ready to restore. Quit Whytap normally and open it again when your work is finished."
            errorMessage = nil
        } catch { fail(error) }
    }
    func cancelRestore() {
        if operationKind == .preview || operationKind == .restore { cancelCurrentOperation() }
        clearPreview()
    }
    private func clearPreview() { restorePreview = nil; restoreKey = nil; restoreFile = nil; cleanupPreviewFiles() }
    private func cleanupPreviewFiles() {
        for file in temporaryPreviewFiles { try? FileManager.default.removeItem(at: file) }
        temporaryPreviewFiles.removeAll()
    }
    private func previewURL() throws -> URL {
        let folder = local.root.appendingPathComponent("restore-work", isDirectory: true)
        try ConfigBackupFiles.ensurePrivateDirectory(folder)
        let file = folder.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        temporaryPreviewFiles.insert(file)
        return file
    }
    func cancelCurrentOperation() {
        guard let task = operationTask else { return }
        if operationKind == .backup {
            setEnabled(false)
            defaults.set(true, forKey: "backup.github-auto-sync.v1")
        }
        task.cancel()
        statusText = "Cancelling… Your saved data and previous backups are kept."
    }
    private func retainOperation(_ kind: Operation, cancelWithCaller: Bool = false,
                                 _ operation: @escaping @MainActor () async -> Void) async {
        guard !stopped, operationTask == nil, !isBusy else { return }
        let id = UUID(); operationID = id; operationKind = kind; canCancelOperation = kind != .maintenance
        let task = Task { @MainActor in await operation() }
        operationTask = task
        if cancelWithCaller {
            await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        } else {
            await task.value
        }
        guard operationID == id else { return }
        operationTask = nil; operationKind = nil; canCancelOperation = false
        if task.isCancelled {
            if kind == .preview || kind == .restore { clearPreview() }
            statusText = kind == .backup ? "Backup paused. Your local history and existing copies are kept." : "Operation cancelled. Your existing data is kept."
        }
    }
    func cancelPlannedRestore() {
        guard needsRestart, !isBusy else { return }
        do {
            _ = try engine.cancelPlanned()
            needsRestart = false
            statusText = "Planned restore cancelled. Your current data is kept."
            errorMessage = nil
        } catch { fail(error) }
    }
    func dismissRestoreNotice() {
        if let restoreNotice { defaults.set(restoreNotice.id.uuidString, forKey: "backup.last-outcome.v1") }
        restoreNotice = nil
    }
    func showRecoveryFiles() {
        guard let recoveryCheckpoint else { return }
        NSWorkspace.shared.activateFileViewerSelecting([recoveryCheckpoint.directory])
    }
    func showParkedFiles(_ item: ArtifactParkedItem) { NSWorkspace.shared.activateFileViewerSelecting([item.parkedURL]) }
    func activateRecoveredItem(_ item: ArtifactParkedItem) {
        guard !isBusy, !needsRestart, !hasPendingMaintenance, idle() else { fail(ConfigBackupError.busy); return }
        do { try engine.activate(item); parkedItems = engine.parked(); errorMessage = nil }
        catch { fail(error) }
    }
    func clearError() { errorMessage = nil }

    private func selectDestination(id: String) {
        if defaults.string(forKey: "backup.destination-id.v1") != id {
            destinationRevision += 1
            lastRemoteBackupAt = nil
            defaults.removeObject(forKey: "backup.last-copied.v1")
        }
        defaults.set(id, forKey: "backup.destination-id.v1")
    }

    private var destinationKind: String? { defaults.string(forKey: "backup.destination-kind.v1") }
    private func backupFolder() throws -> URL {
        guard let data = defaults.data(forKey: "backup.folder-bookmark.v1") else { throw ConfigBackupError.unsafePath }
        var stale = false
        let folder = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw ConfigBackupError.unsafePath }
        return folder
    }

    private func localHistoryKeys(current: Data) throws -> [Data] {
        let ids = defaults.stringArray(forKey: "backup.archived-key-ids.v1") ?? []
        guard ids.count <= 32 else { throw ConfigBackupError.invalidArchive }
        var keys = [current]
        for id in ids {
            guard id.utf8.count == 64, id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw ConfigBackupError.invalidArchive }
            if let encoded = try archivedKeyStore(id).read(), let value = Data(base64Encoded: encoded),
               value.count == 32, ConfigBackupArchive.keyID(value) == id { keys.append(value) }
        }
        return keys
    }

    private func markDirty() { needsFullBackup = true; changeRevision += 1 }

    private func captureSettings() async {
        if let running = captureTask { await running.value; await captureSettings(); return }
        let task = Task { @MainActor in
            defer { self.captureTask = nil }
            await self.performCaptureSettings()
        }
        captureTask = task
        await task.value
    }

    private func performCaptureSettings() async {
        guard !needsRestart else { return }
        do {
            let key = try key()
            var warnings: [String] = []
            let values = try ConfigBackupRegistry.capture(defaults, warnings: &warnings)
            var credentials: [String: String] = [:]
            let accounts = try ConfigBackupRegistry.credentialAccounts(in: defaults)
            do {
                for account in accounts {
                    if let value = try providerStore(account).read() { credentials[account] = value }
                }
            } catch { throw ConfigBackupError.keyUnavailable }
            let previous = try await settingsFiles.load(keys: localHistoryKeys(current: key))
            localSettingsVersions = previous
            if let latest = previous.first, latest.preferences == values,
               let previousCredentials = latest.credentials,
               (previousCredentials == credentials || ConfigBackupRegistry.settingsCredentialsMatch(previousCredentials, credentials)) { return }
            let reason = warnings.isEmpty ? "Saved on this Mac" : "Saved on this Mac · Keys & models needs review"
            let snapshot = ConfigBackupSnapshot(reason: reason, preferences: values, credentials: credentials)
            _ = try await settingsFiles.save(ConfigBackupArchive.seal(snapshot, key: key), id: snapshot.id)
            localSettingsVersions.insert(snapshot, at: 0)
            try await settingsFiles.prune(removing: Set(localSettingsVersions.dropFirst(300).map(\.id)))
            localSettingsVersions = Array(localSettingsVersions.prefix(300))
            markDirty()
        } catch { fail(error) }
    }

    func poll() async {
        guard !stopped, !isBusy, !needsRestart else { return }
        // A pause written elsewhere (another window, `defaults write`) applies
        // without restarting Whytap.
        let storedEnabled = defaults.bool(forKey: "backup.enabled.v1")
        if storedEnabled != isEnabled, !storedEnabled || !hasPendingMaintenance { isEnabled = storedEnabled }
        await captureSettings()
        if hasPendingMaintenance {
            if !maintenanceRetryAttempted && idle() { await resumeBackupManagement() }
            return
        }
        let probe = changeProbe
        let stamp = await Task.detached(priority: .utility) { probe() }.value
        // A detected change only marks the copy as pending. Captures stay
        // paced by the hourly schedule even when a source changes constantly.
        if stamp != sourceStamp { markDirty() }
        let captureDue = now().timeIntervalSince(lastContentCheck) >= Self.automaticCaptureInterval
        guard isEnabled, recoverySaved, idle(), now().timeIntervalSince(lastAttempt) >= 120,
              stamp != stalledSourceStamp || captureDue else { return }
        if destinationKind == "github", githubConnectionState != .connected,
           !githubRequiresReconnect, github != nil, now() >= nextAutomaticAttempt {
            await retainOperation(.connection) {
                self.isBusy = true
                await self.updateGitHubConnection()
                self.isBusy = false
            }
            guard !stopped, !Task.isCancelled, !needsRestart, !hasPendingMaintenance,
                  isEnabled, recoverySaved, idle() else { return }
        }
        var shortage: String?
        if captureDue {
            shortage = await diskShortage(automatic: true)
            // The switch may have paused sync while the disk check awaited.
            guard !stopped, !isBusy, !needsRestart, !hasPendingMaintenance, isEnabled else { return }
            if shortage == nil {
                await retainOperation(.backup) { await self.performBackupNow(automatic: true) }
                return
            }
        }
        // Uploading a waiting copy needs no disk space and releases its parent.
        if now() >= nextAutomaticAttempt, !githubRequiresReconnect,
                let pending = try? await local.pendingCopies(destinationID: defaults.string(forKey: "backup.destination-id.v1") ?? ""), !pending.isEmpty {
            await retainOperation(.backup) { await self.retryPendingCopies() }
        }
        if let shortage { statusText = "Backup needs attention."; errorMessage = shortage }
    }

    private func retryPendingCopies() async {
            isBusy = true; lastAttempt = now()
            automaticOperationRunning = true
            defer { automaticOperationRunning = false }
            do {
                let copied = try await copyPending(key: key())
                if copied > 0 {
                    errorMessage = nil; statusText = "Your encrypted backup is up to date."
                    transferFailureCount = 0; nextAutomaticAttempt = .distantPast
                    await refreshVersionsQuietly()
                } else if try await local.pendingCopies(destinationID: defaults.string(forKey: "backup.destination-id.v1") ?? "").isEmpty {
                    // Every waiting copy had vanished; its old transfer error no longer applies.
                    errorMessage = nil; transferFailureCount = 0; nextAutomaticAttempt = .distantPast
                    await refreshVersionsQuietly(includeDestination: false)
                }
            } catch { recordBackupFailure(error, sourceStamp: nil); fail(error) }
            isBusy = false
    }

    private func recordBackupFailure(_ error: Error, sourceStamp: String?) {
        if error is CancellationError || Task.isCancelled { return }
        if let failure = error as? ArtifactBackupError {
            switch failure {
            case .unsafeContent, .unsupportedFile(_), .tooLarge, .invalidContent(_), .requiredFileMissing(_):
                stalledSourceStamp = sourceStamp
            default: break
            }
        }
        if (error as NSError).domain == NSURLErrorDomain || error is GitHubBackupTransport.Failure {
            transferFailureCount += 1
            let delay = min(900, 120 * pow(2, Double(min(transferFailureCount - 1, 3))))
            nextAutomaticAttempt = now().addingTimeInterval(delay)
            if let failure = error as? GitHubBackupTransport.Failure, case .rateLimited(let until) = failure {
                nextAutomaticAttempt = max(nextAutomaticAttempt, until)
            }
        }
    }

    private func canStartRestore() -> Bool {
        guard idle() else { fail(ConfigBackupError.busy); return false }
        guard !AppState.shared.calendarConnectionActive else {
            errorMessage = "Finish calendar sign-in before restoring a backup."
            return false
        }
        guard !AppState.shared.calendarHoverActive else {
            errorMessage = "Close Calendar before restoring a backup."
            return false
        }
        guard !AppState.shared.plannerActive && !AppState.shared.todoActive else {
            errorMessage = "Finish or clear your To-do draft and close To-do and Planner before restoring a backup."
            return false
        }
        return true
    }

    static var isIdle: Bool {
        let state = AppState.shared
        return !state.meetingRecordingActive && !state.isMeetingRecording && state.phase == .idle && state.agentPhase == .idle
    }
    private func fail(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        statusText = "Backup needs attention."
        if let error = error as? ConfigBackupError { errorMessage = error.localizedDescription }
        else if let error = error as? BackupManagementError { errorMessage = error.localizedDescription }
        else if let error = error as? ArtifactBackupError { errorMessage = error.localizedDescription }
        else if let error = error as? GitHubBackupTransport.Failure {
            errorMessage = error.localizedDescription
            if error.requiresReconnect {
                githubRequiresReconnect = true
                githubConnectionState = .needsAttention; githubConnectionError = error.localizedDescription
            }
        }
        else if (error as NSError).domain == NSURLErrorDomain {
            errorMessage = "The backup destination could not be reached. Your local copy is kept; Whytap will retry when connected."
        } else if (error as NSError).code == NSFileWriteOutOfSpaceError {
            errorMessage = "There is not enough space for a backup. Free some space or choose another destination, then retry."
        } else { errorMessage = "The backup could not finish. Your existing data and previous copies are kept. Check the destination and try again." }
    }
}

extension Notification.Name {
    static let exodiaBackupArtifactsChanged = Notification.Name("exodia.backup.artifactsChanged")
}

/// Change detection is a scheduling hint, never a substitute for the engine's
/// coherent store export and full authenticated archive validation.
enum BackupChangeProbe {
    static func stamp(locations paths: ArtifactBackupLocations = .production) -> String {
        // Meeting audio and the history database are not backed up, so their
        // churn (every clipboard copy, every recording chunk) is not a change.
        let roots = [paths.caseVault, paths.usageDatabase, paths.monitorRoot, paths.notifyRoot,
                     paths.meetingsCatalog, paths.agentMemory, paths.plannerArchive]
        var values: [String] = []
        func add(_ file: URL) {
            var information = stat()
            guard lstat(file.path, &information) == 0, information.st_mode & S_IFMT != S_IFLNK else { return }
            values.append(file.path + ":\(information.st_ino):\(information.st_size):\(information.st_mtimespec.tv_sec):\(information.st_mtimespec.tv_nsec):\(information.st_ctimespec.tv_sec):\(information.st_ctimespec.tv_nsec)")
        }
        for root in roots {
            let excludesCaches = root == paths.monitorRoot || root == paths.notifyRoot
            add(root)
            if let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey], options: [.skipsPackageDescendants]) {
                for case let file as URL in walk {
                    if excludesCaches,
                       let metadata = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                       metadata.isDirectory == true, metadata.isSymbolicLink != true,
                       (try? ArtifactBackupCache.isTaggedDirectory(file)) == true {
                        walk.skipDescendants()
                        continue
                    }
                    if values.count >= ArtifactBackupManifest.maxEntries { return "over-limit" }
                    add(file)
                }
            }
        }
        return SHA256.hash(data: Data(values.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

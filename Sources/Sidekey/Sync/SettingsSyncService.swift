import Combine
import Foundation

enum SettingsSyncFetch: Equatable {
    case notModified
    case missing
    case found(data: Data, sha: String, etag: String?)
}

enum SettingsSyncFailure: Error, Equatable {
    /// The shared file changed between reading and writing it.
    case conflict
}

/// Where the shared document lives. Production: the backup repository on GitHub.
protocol SettingsSyncRemote: Sendable {
    func fetchSyncFile(path: String, etag: String?) async throws -> SettingsSyncFetch
    func putSyncFile(path: String, data: Data, sha: String?) async throws -> String
}

enum SettingsSyncStatus: Equatable {
    case off
    /// Sync needs a GitHub backup with a recovery code on this Mac first.
    case needsBackup
    case syncing
    case synced(Date)
    /// The shared settings are sealed with another recovery code.
    case differentKey
    case failed(String)

    var text: String {
        switch self {
        case .off: return "Off"
        case .needsBackup: return "Connect GitHub in Backup and make a backup first."
        case .syncing: return "Syncing…"
        case .synced: return "Settings synced"
        case .differentKey: return "Your other Mac uses a different recovery code. Restore this Mac with that code, then turn sync on."
        case .failed(let message): return message
        }
    }
}

/// Keeps preferences and provider keys the same on every Mac that turned sync
/// on with one recovery code. A round reads the shared document, merges it with
/// this Mac's values item by item, applies what the other Mac changed and
/// writes back what changed here. Rounds run a minute apart and a few seconds
/// after a local change, only while this Mac's sync switch is on.
// WHY: .project-docs/decisions/2026-11-20-settings-sync.md
@MainActor
final class SettingsSyncService: ObservableObject {
    static let shared = SettingsSyncService(dependencies: .production)
    static let enabledKey = "backup.settings-sync.enabled.v1"

    struct Dependencies {
        var defaults: UserDefaults
        var secretStore: (String) -> TokenStore
        var backupKey: () throws -> Data?
        var remote: () throws -> SettingsSyncRemote?
        var ledgerURL: URL
        var path: String
        var now: () -> Date
        /// True while a restore waits for relaunch: the stores will be replaced.
        var isPaused: @MainActor () -> Bool
        var reload: @MainActor (Set<String>) -> Void

        @MainActor static var production: Dependencies {
            Dependencies(
                defaults: .standard,
                secretStore: { KeychainStore(account: $0) },
                backupKey: {
                    guard let stored = try KeychainStore(account: BackupViewModel.keyAccount).read() else { return nil }
                    return Data(base64Encoded: stored)
                },
                remote: {
                    let defaults = UserDefaults.standard
                    guard defaults.string(forKey: "backup.destination-kind.v1") == "github",
                          let owner = defaults.string(forKey: "backup.github-owner.v1"),
                          let token = try KeychainStore(account: "backup.github-token.v1").read() else { return nil }
                    return try GitHubBackupTransport(token: token, owner: owner)
                },
                ledgerURL: productionLedgerURL,
                path: BuildConfig.flavor == .beta ? "whytap-sync/settings-beta.v1.json" : "whytap-sync/settings.v1.json",
                now: Date.init,
                isPaused: { BackupViewModel.shared.needsRestart },
                reload: { SettingsSyncLiveReload.reload(items: $0) }
            )
        }
    }

    @Published private(set) var isEnabled = false
    @Published private(set) var status: SettingsSyncStatus = .off

    private let deps: Dependencies
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var running: Task<Void, Never>?
    private var rerun = false
    private var retryAt = Date.distantPast
    private var failures = 0
    /// The last document read or written, reused while GitHub answers 304.
    /// Bound to the key it was opened with: a new recovery code reads again.
    private var cached: (document: SettingsSyncDocument, sha: String, etag: String?, keyID: String)?
    /// Changes when the switch flips. A round started before a flip stops
    /// before it applies, saves or uploads anything.
    private var generation = 0
    /// When edits were first seen while a round was busy writing the ledger.
    private var noticedWhileRunning: [String: (hash: String, at: Date)] = [:]

    init(dependencies: Dependencies) {
        deps = dependencies
    }

    func start() {
        guard timer == nil else { return }
        isEnabled = deps.defaults.bool(forKey: Self.enabledKey)
        status = isEnabled ? .syncing : .off
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: deps.defaults)
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.requestSync() }
            .store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestSync() }
        }
        requestSync()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        subscriptions.removeAll()
        running?.cancel()
    }

    /// Turning sync off forgets what this Mac agreed with the others, so
    /// turning it on again joins like a new Mac: it takes the shared settings.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        deps.defaults.set(enabled, forKey: Self.enabledKey)
        cached = nil; failures = 0; retryAt = .distantPast
        generation += 1
        noticedWhileRunning = [:]
        if enabled {
            status = .syncing
            requestSync(force: true)
        } else {
            running?.cancel(); rerun = false
            try? FileManager.default.removeItem(at: deps.ledgerURL)
            status = .off
        }
    }

    /// A restored backup replaces this Mac's settings wholesale. They are
    /// older than the shared ones, so the next round joins instead of
    /// presenting them as new changes.
    nonisolated static func forgetAgreement(ledgerURL: URL = Dependencies.productionLedgerURL) {
        try? FileManager.default.removeItem(at: ledgerURL)
    }

    /// A restore of settings or keys marks itself before it starts. Only an
    /// applied restore changes the agreement, and only for what it replaced:
    /// those items join again (shared values win), every other item keeps its
    /// agreement, including a key removed here but not shared yet. A rolled
    /// back or cancelled restore changes nothing. A marker left by a crash
    /// after the restore finished counts as applied.
    ///
    /// A marker already there belongs to this restore, written before an
    /// interruption, when its plan was still readable: it is kept. Without a
    /// ledger there is no agreement to protect. A marker that cannot be
    /// written stops the restore before it applies, so it can be retried.
    nonisolated static func restoreWillStart(sections: [ArtifactBackupSection],
                                             ledgerURL: URL = Dependencies.productionLedgerURL) throws {
        let prefixes = rejoinPrefixes(sections)
        let marker = restoreMarker(ledgerURL)
        guard !prefixes.isEmpty, !FileManager.default.fileExists(atPath: marker.path),
              FileManager.default.fileExists(atPath: ledgerURL.path) else { return }
        try JSONEncoder.settingsSync.encode(prefixes).write(to: marker, options: [.atomic])
    }

    nonisolated static func restoreFinished(applied: Bool, ledgerURL: URL = Dependencies.productionLedgerURL) {
        let marker = restoreMarker(ledgerURL)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        if applied {
            let prefixes = (try? Data(contentsOf: marker)).flatMap { try? JSONDecoder.settingsSync.decode([String].self, from: $0) }
                ?? ["pref:", "key:"]
            if let data = try? Data(contentsOf: ledgerURL),
               var ledger = try? JSONDecoder.settingsSync.decode(SettingsSyncLedger.self, from: data) {
                ledger.rejoin = Array(Set(ledger.rejoin ?? []).union(prefixes)).sorted()
                if let updated = try? JSONEncoder.settingsSync.encode(ledger) {
                    guard (try? updated.write(to: ledgerURL, options: [.atomic])) != nil else {
                        forgetAgreement(ledgerURL: ledgerURL) // cannot mark: joining whole is the safe side
                        try? FileManager.default.removeItem(at: marker)
                        return
                    }
                }
            }
        }
        try? FileManager.default.removeItem(at: marker)
    }

    nonisolated static func resolveInterruptedRestore(ledgerURL: URL = Dependencies.productionLedgerURL) {
        restoreFinished(applied: true, ledgerURL: ledgerURL)
    }

    nonisolated static func rejoinPrefixes(_ sections: [ArtifactBackupSection]) -> [String] {
        (sections.contains(.settings) ? ["pref:"] : []) + (sections.contains(.credentials) ? ["key:"] : [])
    }

    nonisolated private static func restoreMarker(_ ledgerURL: URL) -> URL {
        ledgerURL.deletingLastPathComponent().appendingPathComponent("restore-in-progress")
    }

    func requestSync(force: Bool = false) {
        guard isEnabled else { return }
        noticeLocalChanges()
        if force { retryAt = .distantPast }
        guard deps.now() >= retryAt else { return }
        if running != nil { rerun = true; return }
        running = Task { [weak self] in
            await self?.runRounds()
        }
    }

    /// Runs one round now and waits for it. Tests and the Settings button use it.
    func syncNow() async {
        requestSync(force: true)
        while let task = running { await task.value }
    }

    private func runRounds() async {
        // A cancelled task leaves a pending request for the next task.
        while !Task.isCancelled && isEnabled {
            rerun = false
            await round()
            if !rerun { break }
        }
        running = nil
        // A request that arrived while a cancelled round was finishing.
        if rerun && isEnabled { rerun = false; requestSync() }
    }

    /// Stamps local edits even while rounds back off or GitHub is away.
    /// While a round runs it alone writes the ledger; the request makes it
    /// run again at once, and that round stamps the edit.
    private func noticeLocalChanges() {
        do {
            let ledger = try loadLedger()
            let current = try currentValues(ledger: ledger)
            let noticed = ledger.recordingLocalChanges(current: current, now: deps.now(), noticed: noticedWhileRunning)
            guard running == nil else {
                // Remember only when; the running round stamps it with this time.
                // A value back at its agreed state forgets its earlier sighting.
                for (item, entry) in noticedWhileRunning where entry.hash != SettingsSyncItem.hash(current[item]) {
                    noticedWhileRunning[item] = nil
                }
                for (item, record) in noticed.records where record != ledger.records[item] {
                    let hash = SettingsSyncItem.hash(current[item])
                    if noticedWhileRunning[item]?.hash != hash { noticedWhileRunning[item] = (hash, deps.now()) }
                }
                return
            }
            if noticed != ledger { try saveLedger(noticed) }
        } catch {
            // The round reports read failures; noticing retries on the next request.
        }
    }

    private func ensureCurrent(_ round: Int) throws {
        guard round == generation, isEnabled, !deps.isPaused(), !Task.isCancelled else { throw CancellationError() }
    }

    private func round() async {
        guard isEnabled, !deps.isPaused() else { return }
        let round = generation
        do {
            guard let key = try deps.backupKey(), key.count == 32, let remote = try deps.remote() else {
                status = .needsBackup
                return
            }
            if case .synced = status {} else { status = .syncing }
            for attempt in 1...3 {
                do {
                    try await exchange(remote: remote, key: key, round: round)
                    break
                } catch SettingsSyncFailure.conflict where attempt < 3 {
                    cached = nil
                }
            }
            failures = 0
            status = .synced(deps.now())
        } catch where round != generation {
            // A round from before the switch flipped: its outcome is stale.
        } catch SettingsSyncEnvelope.Failure.differentKey {
            status = .differentKey
            retryAt = deps.now().addingTimeInterval(900)
        } catch is CancellationError {
        } catch {
            failures += 1
            var delay = min(900, 60 * pow(2, Double(failures - 1)))
            var message = (error as? LocalizedError)?.errorDescription ?? "Settings could not be synced. Whytap will retry."
            if case GitHubBackupTransport.Failure.rateLimited(let until)? = error as? GitHubBackupTransport.Failure {
                delay = max(delay, until.timeIntervalSince(deps.now()))
            }
            if error as? SettingsSyncEnvelope.Failure == .newerFormat {
                message = "Another Mac syncs with a newer Whytap. Update Whytap on this Mac."
            } else if error as? SettingsSyncEnvelope.Failure == .damaged {
                message = "The synced settings could not be read. Whytap will retry."
            }
            status = .failed(message)
            retryAt = deps.now().addingTimeInterval(delay)
        }
    }

    private func exchange(remote: SettingsSyncRemote, key: Data, round: Int) async throws {
        let keyID = ConfigBackupArchive.keyID(key)
        // 1. Note local edits with the time they were seen, before the network.
        var ledger = try loadLedger()
        let noticed = ledger.recordingLocalChanges(current: try currentValues(ledger: ledger), now: deps.now(),
                                                   noticed: noticedWhileRunning)
        if noticed != ledger { try saveLedger(noticed); ledger = noticed }

        // 2. Read the shared document.
        let usable = cached?.keyID == keyID ? cached : nil
        let fetched = try await remote.fetchSyncFile(path: deps.path, etag: usable?.etag)
        try ensureCurrent(round)
        var shared: SettingsSyncDocument?
        var sha: String?
        switch fetched {
        case .notModified:
            guard let usable else { throw GitHubBackupTransport.Failure.invalidResponse }
            shared = usable.document; sha = usable.sha
        case .missing:
            cached = nil
        case .found(let data, let foundSHA, let etag):
            let document = try SettingsSyncEnvelope.open(data, key: key)
            cached = (document, foundSHA, etag, keyID)
            shared = document; sha = foundSHA
        }

        // 3. Values may have changed while GitHub answered: read them again.
        //    Keys the shared document names are read too, so a key this Mac
        //    holds but has not agreed on yet is compared, not uploaded later.
        ledger = try loadLedger()
        let sharedAccounts = Set((shared?.entries.keys).map(Array.init) ?? []).compactMap(SettingsSyncItem.secretAccount)
        let current = try currentValues(ledger: ledger, extraAccounts: Set(sharedAccounts))
        ledger = ledger.recordingLocalChanges(current: current, now: deps.now(), noticed: noticedWhileRunning)
        let plan = SettingsSyncPlan.make(current: current, ledger: ledger, remote: shared.map(Self.sanitized), now: deps.now())

        // 4. Save the agreement before writing: a failed save leaves nothing
        //    applied, so no applied removal can later look like a local one.
        //    A Mac has joined once it takes an existing shared document; the
        //    first Mac, once its upload succeeds. Each item being written
        //    keeps its old agreement plus the target, so a write that never
        //    lands is retried, never shared as a removal.
        var next = plan.ledger
        next.joined = ledger.joined || shared != nil
        next.rejoin = shared != nil ? nil : ledger.rejoin
        for item in plan.apply.keys {
            var old = ledger.records[item] ?? .init(hash: SettingsSyncItem.hash(current[item]), modifiedAt: .distantPast,
                                                    device: ledger.device)
            old.pending = plan.ledger.records[item].map { .init(hash: $0.hash, modifiedAt: $0.modifiedAt, device: $0.device) }
            next.records[item] = old
        }
        try saveLedger(next)
        let failed = apply(plan.apply)
        let applied = Set(plan.apply.keys).subtracting(failed.keys)
        for item in applied { next.records[item] = plan.ledger.records[item] }
        if !applied.isEmpty {
            deps.reload(applied)
            // A store's setter saves what it shows; a setting the other Mac
            // removed stays removed instead of returning as its default.
            for item in applied where plan.apply[item] == .some(nil) {
                if let key = SettingsSyncItem.preferenceKey(item), deps.defaults.object(forKey: key) != nil,
                   key != ConfigBackupRegistry.aiRoutingKey {
                    deps.defaults.removeObject(forKey: key)
                }
            }
        }
        if let error = failed.values.first {
            try? saveLedger(next)
            throw error
        }
        try saveLedger(next)
        noticedWhileRunning = noticedWhileRunning.filter { next.records[$0.key]?.hash != $0.value.hash }

        // 5. Share what changed here.
        if plan.needsUpload, plan.document != shared {
            try ensureCurrent(round)
            let sealed = try SettingsSyncEnvelope.seal(plan.document, key: key)
            let newSHA = try await remote.putSyncFile(path: deps.path, data: sealed, sha: sha)
            cached = (plan.document, newSHA, nil, keyID)
            try ensureCurrent(round)
        }
        if !next.joined || next.rejoin != nil {
            try ensureCurrent(round)
            next.joined = true
            next.rejoin = nil
            try saveLedger(next)
        }
    }

    /// A value this build would reject is treated as not shared, so this
    /// Mac's own value replaces it instead of being overwritten by it.
    private static func sanitized(_ document: SettingsSyncDocument) -> SettingsSyncDocument {
        var result = document
        for (item, entry) in document.entries {
            guard SettingsSyncItem.isApplicable(item), let value = entry.value else { continue }
            if !isValid(item: item, value: value) { result.entries[item] = nil }
        }
        return result
    }

    private static func isValid(item: String, value: SettingsSyncValue) -> Bool {
        switch value {
        case .preference(let preference):
            guard let key = SettingsSyncItem.preferenceKey(item) else { return false }
            return (try? ConfigBackupRegistry.validate([key: preference])) != nil
        case .secret(let secret):
            guard let account = SettingsSyncItem.secretAccount(item) else { return false }
            return (try? ConfigBackupRegistry.validate([:], credentials: [account: secret])) != nil
        }
    }

    // MARK: Local values

    /// Keychain accounts include every key this Mac agreed on before, so a key
    /// counts as removed only when its Keychain item is really gone. An
    /// unreadable value stops the round: it never reads as a removal.
    private func currentValues(ledger: SettingsSyncLedger, extraAccounts: Set<String> = []) throws -> [String: SettingsSyncValue] {
        var result: [String: SettingsSyncValue] = [:]
        for (key, value) in try ConfigBackupRegistry.capture(deps.defaults) where SettingsSyncItem.syncsPreference(key) {
            result[SettingsSyncItem.preference(key)] = .preference(value)
        }
        var accounts = try ConfigBackupRegistry.credentialAccounts(in: deps.defaults)
        accounts.formUnion(ledger.records.keys.compactMap(SettingsSyncItem.secretAccount))
        accounts.formUnion(extraAccounts)
        for account in accounts where SettingsSyncItem.syncsSecret(account) {
            if let value = try deps.secretStore(account).read(), !value.isEmpty {
                result[SettingsSyncItem.secret(account)] = .secret(value)
            }
        }
        return result
    }

    /// Writes each change on its own and returns the ones that failed.
    private func apply(_ changes: [String: SettingsSyncValue?]) -> [String: Error] {
        var failed: [String: Error] = [:]
        for (item, value) in changes {
            do { try apply(item: item, value: value) } catch { failed[item] = error }
        }
        return failed
    }

    private func apply(item: String, value: SettingsSyncValue?) throws {
        if let key = SettingsSyncItem.preferenceKey(item) {
            switch value {
            case .preference(let preference)?:
                deps.defaults.set(try preference.propertyListValue(), forKey: key)
            case nil where key == ConfigBackupRegistry.aiRoutingKey:
                // Removing the routing document would rerun its migration.
                let empty = AIRoutingState(routes: [:], migratedRoutes: [:], servers: [], migrationVersion: 1)
                deps.defaults.set(try JSONEncoder().encode(empty), forKey: key)
            case nil:
                deps.defaults.removeObject(forKey: key)
            default:
                return
            }
        } else if let account = SettingsSyncItem.secretAccount(item) {
            switch value {
            case .secret(let secret)?: try deps.secretStore(account).save(secret)
            case nil: try deps.secretStore(account).delete()
            default: return
            }
        }
    }

    // MARK: Ledger

    private func loadLedger() throws -> SettingsSyncLedger {
        guard FileManager.default.fileExists(atPath: deps.ledgerURL.path) else {
            return SettingsSyncLedger(device: UUID().uuidString)
        }
        let data = try Data(contentsOf: deps.ledgerURL)
        guard let ledger = try? JSONDecoder.settingsSync.decode(SettingsSyncLedger.self, from: data) else {
            // A damaged ledger only costs the join rule: shared values win once.
            return SettingsSyncLedger(device: UUID().uuidString)
        }
        return ledger
    }

    private func saveLedger(_ ledger: SettingsSyncLedger) throws {
        let directory = deps.ledgerURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder.settingsSync.encode(ledger).write(to: deps.ledgerURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: deps.ledgerURL.path)
    }
}

extension SettingsSyncService.Dependencies {
    nonisolated static var productionLedgerURL: URL {
        ArtifactBackupLocations.production.bundleRoot
            .appendingPathComponent("settings-sync", isDirectory: true)
            .appendingPathComponent("ledger.json")
    }
}

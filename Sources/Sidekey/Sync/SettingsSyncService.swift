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
    private var cached: (document: SettingsSyncDocument, sha: String, etag: String?)?

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
        if enabled {
            status = .syncing
            requestSync(force: true)
        } else {
            running?.cancel()
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

    func requestSync(force: Bool = false) {
        guard isEnabled else { return }
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
        repeat {
            rerun = false
            await round()
        } while rerun && !Task.isCancelled && isEnabled
        running = nil
    }

    private func round() async {
        guard isEnabled, !deps.isPaused() else { return }
        do {
            guard let key = try deps.backupKey(), key.count == 32, let remote = try deps.remote() else {
                status = .needsBackup
                return
            }
            if case .synced = status {} else { status = .syncing }
            for attempt in 1...3 {
                do {
                    try await exchange(remote: remote, key: key)
                    break
                } catch SettingsSyncFailure.conflict where attempt < 3 {
                    cached = nil
                }
            }
            failures = 0
            status = .synced(deps.now())
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

    private func exchange(remote: SettingsSyncRemote, key: Data) async throws {
        var ledger = try loadLedger()
        let current = try currentValues(ledger: ledger)

        let fetched = try await remote.fetchSyncFile(path: deps.path, etag: cached?.etag)
        try Task.checkCancellation()
        var shared: SettingsSyncDocument?
        var sha: String?
        switch fetched {
        case .notModified:
            guard let cached else { throw GitHubBackupTransport.Failure.invalidResponse }
            shared = cached.document; sha = cached.sha
        case .missing:
            cached = nil
        case .found(let data, let foundSHA, let etag):
            let document = try SettingsSyncEnvelope.open(data, key: key)
            cached = (document, foundSHA, etag)
            shared = document; sha = foundSHA
        }
        guard isEnabled else { throw CancellationError() }

        // Items this build cannot apply (a newer app's) pass through the merge unchanged.
        let plan = SettingsSyncPlan.make(current: current, ledger: ledger, remote: shared.map(Self.sanitized), now: deps.now())
        let document = plan.document
        try apply(plan.apply)
        ledger = plan.ledger
        try saveLedger(ledger)
        if !plan.apply.isEmpty { deps.reload(Set(plan.apply.keys)) }

        guard plan.needsUpload, document != shared else { return }
        let sealed = try SettingsSyncEnvelope.seal(document, key: key)
        let newSHA = try await remote.putSyncFile(path: deps.path, data: sealed, sha: sha)
        cached = (document, newSHA, nil)
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
    private func currentValues(ledger: SettingsSyncLedger) throws -> [String: SettingsSyncValue] {
        var result: [String: SettingsSyncValue] = [:]
        for (key, value) in try ConfigBackupRegistry.capture(deps.defaults) where SettingsSyncItem.syncsPreference(key) {
            result[SettingsSyncItem.preference(key)] = .preference(value)
        }
        var accounts = try ConfigBackupRegistry.credentialAccounts(in: deps.defaults)
        accounts.formUnion(ledger.records.keys.compactMap(SettingsSyncItem.secretAccount))
        for account in accounts where SettingsSyncItem.syncsSecret(account) {
            if let value = try deps.secretStore(account).read(), !value.isEmpty {
                result[SettingsSyncItem.secret(account)] = .secret(value)
            }
        }
        return result
    }

    private func apply(_ changes: [String: SettingsSyncValue?]) throws {
        for (item, value) in changes {
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
                    continue
                }
            } else if let account = SettingsSyncItem.secretAccount(item) {
                switch value {
                case .secret(let secret)?: try deps.secretStore(account).save(secret)
                case nil: try deps.secretStore(account).delete()
                default: continue
                }
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

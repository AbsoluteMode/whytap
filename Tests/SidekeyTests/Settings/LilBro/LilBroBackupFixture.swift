import Foundation
@testable import Sidekey

/// A Backup model on its own files and defaults, for drawing Backup in the
/// states a person reaches: backed up (its switches show) and with every
/// card and follow-up on screen at once (builder ticket 651).
@MainActor
enum LilBroBackupFixture {
    static func model(root: URL) -> (BackupViewModel, UserDefaults, String) {
        let suite = "exodia.lilbro.backup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        var environment = ArtifactBackupEnvironment()
        environment.locations = .isolated(root: root)
        environment.defaults = defaults
        environment.credentialStore = { _ in InMemoryTokenStore() }
        environment.caseVaultKeys = StubCaseVaultKeys()
        environment.pendingKeyStore = InMemoryTokenStore()
        environment.recoveryKeyStore = InMemoryTokenStore()
        let engine = ArtifactBackupEngine(environment: environment)
        let actions = BackupEngineActions(
            create: { try await engine.createArchive(at: $0, key: $1) },
            inspect: { try await engine.inspectArchive(at: $0, key: $1) },
            stage: { try await engine.stageRestore(from: $0, key: $1, sections: $2) })
        let model = BackupViewModel(
            defaults: defaults, keyStore: InMemoryTokenStore(), githubTokenStore: InMemoryTokenStore(),
            local: BackupLocalStore(root: root.appendingPathComponent("local", isDirectory: true)),
            settingsFiles: ConfigBackupFiles(root: root.appendingPathComponent("settings", isDirectory: true)),
            engine: actions, changeProbe: { "" }, idle: { true }, providerStore: { _ in InMemoryTokenStore() },
            previousRestoreOutcome: { nil })
        return (model, defaults, suite)
    }

    /// A Mac that backed up to GitHub: Automatic backup and Sync settings show.
    static func backedUp(_ model: BackupViewModel, _ defaults: UserDefaults) {
        defaults.set("github", forKey: "backup.destination-kind.v1")
        model.lastBackupAt = Date(timeIntervalSince1970: 1_790_000_000)
        model.lastRemoteBackupAt = model.lastBackupAt
        model.isEnabled = true
    }

    /// Every card and follow-up Backup can show, at once.
    static func everything(_ model: BackupViewModel, _ defaults: UserDefaults) {
        backedUp(model, defaults)
        model.isBusy = true
        model.canCancelOperation = true
        model.statusText = "Backing up…"
        model.recoveryCode = "TEST-CODE-ONLY"
        model.errorMessage = "Something did not finish."
        model.needsRestart = true
        model.hasPendingMaintenance = true
        model.managementWarning = "Older copies were kept."
        model.restoreNotice = ArtifactRestoreOutcome(id: UUID(), finishedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                                     state: .applied, sections: [], message: "Restored", warnings: [])
        model.recoveryCheckpoint = ArtifactRecoveryCheckpoint(
            id: UUID(), createdAt: Date(timeIntervalSince1970: 1_790_000_000), sections: [], fileCount: 1, bytes: 1,
            includesProviderKeys: false, directoryPath: NSTemporaryDirectory())
    }
}

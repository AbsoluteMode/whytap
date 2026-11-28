import XCTest
@testable import Sidekey

/// Every preference write captures settings 600 ms later, including the
/// island's Drop Mode and language switches. Its Keychain reads (about 1 ms
/// each, sometimes over 10) used to run on the main thread and took 15-18 ms
/// of frames from the island after each Drop Mode switch.
// WHY: .project-docs/decisions/2026-11-28-drop-mode-switch-motion.md
@MainActor
final class BackupCaptureMainThreadTests: XCTestCase {
    /// Records which thread reads it; the secret comes from memory.
    private final class ThreadRecordingStore: TokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private let secret: String?
        private(set) var readsOnMain = 0
        private(set) var readsOffMain = 0
        init(_ secret: String?) { self.secret = secret }
        func save(_ token: String) throws {}
        func read() throws -> String? {
            lock.lock(); defer { lock.unlock() }
            if Thread.isMainThread { readsOnMain += 1 } else { readsOffMain += 1 }
            return secret
        }
        func delete() throws {}
    }

    func testADropModeWriteCapturesSettingsWithKeysReadOffTheMainThread() async throws {
        let profile = try ArtifactBackupTestProfile()
        defer { profile.tearDown() }
        var stores: [String: ThreadRecordingStore] = [:]
        for account in ConfigBackupRegistry.credentialAccounts {
            stores[account] = ThreadRecordingStore(account == "byok.soniox.api_key" ? "synthetic-soniox" : nil)
        }
        let engine = ArtifactBackupEngine(environment: profile.environment())
        let model = BackupViewModel(defaults: profile.defaults, keyStore: MemoryTokenStore(), githubTokenStore: MemoryTokenStore(),
            local: BackupLocalStore(root: profile.root.appendingPathComponent("archives")),
            settingsFiles: ConfigBackupFiles(root: profile.root.appendingPathComponent("settings-history")),
            engine: BackupEngineActions(create: { try await engine.createArchive(at: $0, key: $1) },
                                        inspect: { try await engine.inspectArchive(at: $0, key: $1) },
                                        stage: { try await engine.stageRestore(from: $0, key: $1, sections: $2) }),
            changeProbe: { "stable" }, idle: { false },
            providerStore: { stores[$0] ?? ThreadRecordingStore(nil) },
            previousRestoreOutcome: { nil }, archivedKeyStore: { _ in MemoryTokenStore() },
            pendingKeyStore: MemoryTokenStore(), now: { Date() }, availableCapacity: { _ in 500_000_000_000 },
            recoveryAuthentication: { true }, cleanupWork: {})
        await model.start()?.value
        defer { model.stop() }
        try await Task.sleep(for: .seconds(1))
        let versionsBefore = model.localSettingsVersions.count

        UserPreferencesCache(defaults: profile.defaults).setMode(.smart)
        let deadline = Date().addingTimeInterval(5)
        while model.localSettingsVersions.count == versionsBefore, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(model.localSettingsVersions.count, versionsBefore + 1, "The switch is still saved in settings history")
        let latest = try XCTUnwrap(model.localSettingsVersions.first)
        XCTAssertEqual(latest.credentials?["byok.soniox.api_key"], "synthetic-soniox", "Keys are still captured")
        XCTAssertEqual(stores.values.map(\.readsOnMain).reduce(0, +), 0, "No Keychain read on the main thread")
        XCTAssertGreaterThan(stores.values.map(\.readsOffMain).reduce(0, +), 0)
    }

    func testAnUnreadableKeyStillFailsTheCapture() async throws {
        struct Unreadable: TokenStore {
            func save(_ token: String) throws {}
            func read() throws -> String? { throw KeychainError.unexpectedData }
            func delete() throws {}
        }
        do {
            _ = try await BackupViewModel.readCredentials([("byok.soniox.api_key", Unreadable())])
            XCTFail("An unreadable key must not be captured as absent")
        } catch {}
        let values = try await BackupViewModel.readCredentials([("a", MemoryTokenStore("x")), ("b", MemoryTokenStore())])
        XCTAssertEqual(values, ["a": "x"])
    }
}

import XCTest
@testable import Sidekey

@MainActor
final class PlannerBackupTests: XCTestCase {
    override func setUp() { super.setUp(); openCalendarForThisTest() }

    func testRefreshRotationDoesNotConsumeSettingsHistoryButRealChangesCaptureIt() async throws {
        var profile = try ArtifactBackupTestProfile()
        let account = ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Synthetic")
        profile.defaults.set(try JSONEncoder().encode([account]), forKey: CalendarAccountSettings.accountsKey)
        let name = CalendarKeychain.account(account.id)
        var credential = CalendarCredential(provider: .microsoft, clientID: "fixture-client",
            accessToken: "fixture-access", refreshToken: "fixture-first", expiresAt: .distantFuture)
        profile.addCredential(name, String(decoding: try JSONEncoder().encode(credential), as: UTF8.self))
        profile.addCredential("byok.openrouter.llm_api_key", "fixture-api-key")
        let model = BackupViewModel(defaults: profile.defaults,
            keyStore: MemoryTokenStore(ConfigBackupArchive.makeKey().base64EncodedString()), githubTokenStore: MemoryTokenStore(),
            local: BackupLocalStore(root: profile.root.appendingPathComponent("archives")),
            settingsFiles: ConfigBackupFiles(root: profile.root.appendingPathComponent("settings")),
            changeProbe: { "isolated-planner-fixture" }, idle: { false },
            providerStore: { profile.credentialStores[$0] ?? MemoryTokenStore() }, previousRestoreOutcome: { nil },
            archivedKeyStore: { _ in MemoryTokenStore() }, pendingKeyStore: MemoryTokenStore())
        defer { model.stop(); profile.tearDown() }
        await model.start()?.value
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.localSettingsVersions.count, 1)
        credential.refreshToken = "fixture-rotated"
        let rotated = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        try profile.credentialStores[name]?.save(rotated)
        await model.poll()
        XCTAssertEqual(model.localSettingsVersions.count, 1, "The minute poll must ignore token-only rotation")
        profile.defaults.set(true, forKey: "sidekey.preferences.hideHelpers")
        await model.poll()
        XCTAssertEqual(model.localSettingsVersions.count, 2)
        XCTAssertEqual(model.localSettingsVersions.first?.credentials?[name], rotated)
        credential.clientID = "fixture-new-client"
        try profile.credentialStores[name]?.save(String(decoding: try JSONEncoder().encode(credential), as: UTF8.self))
        await model.poll()
        XCTAssertEqual(model.localSettingsVersions.count, 3, "A changed OAuth client must be backed up")
        try profile.credentialStores["byok.openrouter.llm_api_key"]?.save("fixture-replaced-api-key")
        await model.poll()
        XCTAssertEqual(model.localSettingsVersions.count, 4, "Other provider keys retain normal change detection")
        try profile.credentialStores["byok.openrouter.llm_api_key"]?.save("")
        await model.poll()
        XCTAssertEqual(model.localSettingsVersions.count, 5)
        await model.poll()
        XCTAssertEqual(model.localSettingsVersions.count, 5, "Unchanged bytes keep the earlier comparison behavior even for an invalid key")
        XCTAssertNil(model.errorMessage)
        await model.stopAndWait()
    }

    func testTasksEventsAccountsAndCredentialsRestoreIntoAnIsolatedProfile() async throws {
        var source = try ArtifactBackupTestProfile(), target = try ArtifactBackupTestProfile()
        defer { source.tearDown(); target.tearDown() }
        let store = PlannerStore(url: source.locations.plannerArchive)
        XCTAssertTrue(store.saveTask(PlannerTask(title: "Подготовить повестку", completed: true)))
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertTrue(store.saveEvent(PlannerEvent(title: "Обсудить проект", start: start,
                                                 end: start.addingTimeInterval(3600))))
        let account = ConnectedCalendarAccount(id: UUID(), provider: .google, label: "Synthetic calendar")
        source.defaults.set(try JSONEncoder().encode([account]), forKey: CalendarAccountSettings.accountsKey)
        source.defaults.set(["local"], forKey: CalendarAccountSettings.hiddenFeedsKey)
        let name = CalendarKeychain.account(account.id)
        let credential = CalendarCredential(provider: .google, clientID: "fixture-native-client",
            accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: .distantFuture)
        let secret = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        source.addCredential(name, secret); target.addCredential(name, nil)
        let archive = source.root.appendingPathComponent("planner.exodiabackup")
        let key = ArtifactBackupTestKeys.make()
        let sections: Set<ArtifactBackupSection> = [.planner, .settings, .credentials]
        let summary = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: archive, key: key, sections: sections)
        XCTAssertEqual(summary.sections, sections)
        XCTAssertFalse(String(decoding: try Data(contentsOf: archive), as: UTF8.self).contains("fixture-refresh"))
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: archive, key: key, sections: sections)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        let restored = PlannerStore(url: target.locations.plannerArchive)
        XCTAssertEqual(restored.archive, store.archive)
        XCTAssertEqual(try CalendarAccountSettings.decode(XCTUnwrap(target.defaults.data(forKey: CalendarAccountSettings.accountsKey))), [account])
        XCTAssertEqual(target.defaults.stringArray(forKey: CalendarAccountSettings.hiddenFeedsKey), ["local"])
        XCTAssertEqual(try target.credentialStores[name]?.read(), secret)
    }

    func testInvalidPlannerIsRejectedBeforeReplacingAnything() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown() }
        let store = PlannerStore(url: target.locations.plannerArchive)
        XCTAssertTrue(store.saveTask(PlannerTask(title: "Keep this task")))
        let original = try Data(contentsOf: target.locations.plannerArchive)
        let archive = target.root.appendingPathComponent("invalid.exodiabackup")
        let key = ArtifactBackupTestKeys.make()
        _ = try ArtifactBackupTestArchive.make(at: archive, key: key, entries: [
            ("planner/planner-v1.json", .planner, Data("{\"version\":999}".utf8))])
        do {
            try await ArtifactBackupEngine(environment: target.environment())
                .stageRestore(from: archive, key: key, sections: [.planner])
            XCTFail("An authenticated but unreadable Planner must not be applied")
        } catch { XCTAssertEqual(error as? ArtifactBackupError, .invalidContent("Planner")) }
        XCTAssertEqual(try Data(contentsOf: target.locations.plannerArchive), original)
    }

    func testFailedRestorePutsThePreviousPlannerBack() async throws {
        let source = try ArtifactBackupTestProfile(), target = try ArtifactBackupTestProfile()
        defer { source.tearDown(); target.tearDown() }
        XCTAssertTrue(PlannerStore(url: source.locations.plannerArchive).saveTask(PlannerTask(title: "Incoming task")))
        XCTAssertTrue(PlannerStore(url: target.locations.plannerArchive).saveTask(PlannerTask(title: "Current task")))
        let previous = try Data(contentsOf: target.locations.plannerArchive)
        let archive = source.root.appendingPathComponent("planner.exodiabackup"), key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment())
            .createArchive(at: archive, key: key, sections: [.planner])
        var faults = ArtifactBackupFaults()
        faults.beforeCommit = { throw CocoaError(.fileWriteOutOfSpace) }
        let environment = target.environment(faults: faults)
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: archive, key: key, sections: [.planner])
        do { _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment); XCTFail("Expected rollback") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: target.locations.plannerArchive), previous)
    }

    func testProviderKeyEnumerationUsesOnlyValidatedCalendarAccounts() throws {
        let profile = try ArtifactBackupTestProfile()
        defer { profile.tearDown() }
        let id = UUID()
        let account = ConnectedCalendarAccount(id: id, provider: .microsoft, label: "Synthetic")
        profile.defaults.set(try JSONEncoder().encode([account]), forKey: CalendarAccountSettings.accountsKey)
        XCTAssertTrue(try ConfigBackupRegistry.credentialAccounts(in: profile.defaults).contains(CalendarKeychain.account(id)))
        XCTAssertFalse(ConfigBackupRegistry.isCredentialAccount("calendar.other-account"))
        profile.defaults.set(try JSONEncoder().encode([account, account]), forKey: CalendarAccountSettings.accountsKey)
        XCTAssertThrowsError(try ConfigBackupRegistry.credentialAccounts(in: profile.defaults))
    }

    func testRegisteredNativeClientConfigurationUsesOnlyTheSelectedProvider() {
        let info: [String: Any] = ["WhytapCalendarOAuthClients": [
            "google": ["clientID": "fixture-google", "clientSecret": "fixture-public-desktop-config"],
            "microsoft": ["clientID": "fixture-microsoft", "clientSecret": "unused"]]]
        XCTAssertEqual(CalendarClientConfiguration.registered(.google, info: info)?.clientID, "fixture-google")
        XCTAssertEqual(CalendarClientConfiguration.registered(.google, info: info)?.clientSecret, "fixture-public-desktop-config")
        XCTAssertNil(CalendarClientConfiguration.registered(.microsoft, info: info)?.clientSecret)
        XCTAssertNil(CalendarClientConfiguration.registered(.zoom, info: info))
        XCTAssertNil(CalendarClientConfiguration.registered(.apple, info: info))
    }

    func testRestoreOfPrePlannerSettingsKeepsCurrentCalendarConnections() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown() }
        let accounts = try JSONEncoder().encode([ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Keep account")])
        target.defaults.set(accounts, forKey: CalendarAccountSettings.accountsKey)
        target.defaults.set(["local"], forKey: CalendarAccountSettings.hiddenFeedsKey)
        target.defaults.set(true, forKey: CalendarAccountSettings.appleEnabledKey)
        let payload = ArtifactSettingsPayload(schema: 3, values: ["sidekey.preferences.hideHelpers": .bool(true)])
        let archive = target.root.appendingPathComponent("older.exodiabackup"), key = ArtifactBackupTestKeys.make()
        _ = try ArtifactBackupTestArchive.make(at: archive, key: key, entries: [
            ("settings/preferences.json", .settings, try JSONEncoder.artifactBackup.encode(payload))])
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: archive, key: key, sections: [.settings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.defaults.data(forKey: CalendarAccountSettings.accountsKey), accounts)
        XCTAssertEqual(target.defaults.stringArray(forKey: CalendarAccountSettings.hiddenFeedsKey), ["local"])
        XCTAssertTrue(target.defaults.bool(forKey: CalendarAccountSettings.appleEnabledKey))
        XCTAssertTrue(target.defaults.bool(forKey: "sidekey.preferences.hideHelpers"))
    }

    func testLegacyManifestAndDeltaMetadataStayReadable() throws {
        let manifest = ArtifactBackupManifest(schema: 1, id: UUID(), createdAt: Date(), flavor: "prod",
            sections: [.settings], entries: [], contentBytes: 0, warnings: [])
        XCTAssertEqual(try ArtifactBackupManifest.decode(manifest.encoded()).schema, 1)
        let metadata = BackupDeltaFormat.Metadata(baseID: UUID(), currentManifest: manifest)
        XCTAssertEqual(try BackupDeltaFormat.decodeMetadata(BackupDeltaFormat.encodeMetadata(metadata)).currentManifest.schema, 1)
    }

    func testPlannerEditsBlockRestoreWithoutPausingOrdinaryBackups() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown(); AppState.shared.plannerActive = false }
        let model = BackupViewModel(defaults: target.defaults, keyStore: MemoryTokenStore(),
            githubTokenStore: MemoryTokenStore(), local: BackupLocalStore(root: target.root),
            settingsFiles: ConfigBackupFiles(root: target.root.appendingPathComponent("settings")),
            previousRestoreOutcome: { nil }, pendingKeyStore: MemoryTokenStore())
        AppState.shared.plannerActive = true
        XCTAssertTrue(BackupViewModel.isIdle, "Reading saved Planner content must not prevent ordinary backup")
        await model.restoreSettingsDefaults(.other)
        XCTAssertFalse(model.needsRestart)
        XCTAssertTrue(model.errorMessage?.contains("Planner") == true)
        await model.stopAndWait()
    }

    func testTodoDraftBlocksRestoreWithoutPausingOrdinaryBackups() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown(); AppState.shared.todoActive = false }
        let model = BackupViewModel(defaults: target.defaults, keyStore: MemoryTokenStore(),
            githubTokenStore: MemoryTokenStore(), local: BackupLocalStore(root: target.root),
            settingsFiles: ConfigBackupFiles(root: target.root.appendingPathComponent("settings")),
            previousRestoreOutcome: { nil }, pendingKeyStore: MemoryTokenStore())
        AppState.shared.todoActive = true
        XCTAssertTrue(BackupViewModel.isIdle, "Reading saved Planner content must not prevent ordinary backup")
        await model.restoreSettingsDefaults(.other)
        XCTAssertFalse(model.needsRestart)
        XCTAssertTrue(model.errorMessage?.contains("To-do") == true)
        await model.stopAndWait()
    }

    func testCalendarHoverBlocksRestoreWithoutBlockingOrdinaryBackup() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown(); AppState.shared.calendarHoverActive = false }
        let model = BackupViewModel(defaults: target.defaults, keyStore: MemoryTokenStore(),
            githubTokenStore: MemoryTokenStore(), local: BackupLocalStore(root: target.root),
            settingsFiles: ConfigBackupFiles(root: target.root.appendingPathComponent("settings")),
            previousRestoreOutcome: { nil }, pendingKeyStore: MemoryTokenStore())
        AppState.shared.calendarHoverActive = true
        XCTAssertTrue(BackupViewModel.isIdle)
        await model.restoreSettingsDefaults(.other)
        XCTAssertFalse(model.needsRestart)
        XCTAssertTrue(model.errorMessage?.contains("Close Calendar") == true)
        await model.stopAndWait()
    }
}

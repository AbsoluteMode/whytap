import CryptoKit
import XCTest
@testable import Sidekey

@MainActor
final class BackupSimpleFlowTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []
    private var session: URLSession!
    private var remote: BackupGitHubFixture!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        remote = BackupGitHubFixture(json: { try! JSONSerialization.data(withJSONObject: $0) })
        StubURLProtocol.handler = { [remote] request in try remote!.handle(request) }
    }

    override func tearDown() {
        session.invalidateAndCancel(); StubURLProtocol.reset()
        profiles.forEach { $0.tearDown() }; profiles.removeAll()
        super.tearDown()
    }

    private func profile() throws -> ArtifactBackupTestProfile {
        var profile = try ArtifactBackupTestProfile()
        profile.addCredential("byok.soniox.api_key", nil)
        profiles.append(profile)
        return profile
    }

    private func model(_ profile: ArtifactBackupTestProfile,
                       keyStore: MemoryTokenStore = MemoryTokenStore(),
                       githubTokenStore: MemoryTokenStore = MemoryTokenStore(),
                       now: @escaping @MainActor () -> Date = { Date() },
                       changeProbe: @escaping @Sendable () -> String = { "synthetic" },
                       idle: @escaping @MainActor () -> Bool = { true },
                       recoveryAuthentication: @escaping @MainActor () async throws -> Bool = { true },
                       beforeCreate: @escaping @MainActor () async -> Void = {}) -> BackupViewModel {
        let environment = profile.environment()
        let engine = ArtifactBackupEngine(environment: environment)
        return BackupViewModel(defaults: profile.defaults, keyStore: keyStore, githubTokenStore: githubTokenStore,
            local: BackupLocalStore(root: profile.root.appendingPathComponent("archives")),
            settingsFiles: ConfigBackupFiles(root: profile.root.appendingPathComponent("settings-history")),
            engine: BackupEngineActions(create: { file, key in
                await beforeCreate()
                return try await engine.createArchive(at: file, key: key)
            },
                inspect: { try await engine.inspectArchive(at: $0, key: $1) },
                stage: { try await engine.stageRestore(from: $0, key: $1, sections: $2) },
                createIfChanged: { file, key, previous in
                    await beforeCreate()
                    return try await engine.createArchiveIfChanged(at: file, key: key, previousFingerprint: previous)
                }),
            changeProbe: changeProbe, idle: idle, providerStore: environment.credentialStore,
            previousRestoreOutcome: { nil }, archivedKeyStore: { _ in MemoryTokenStore() },
            pendingKeyStore: MemoryTokenStore(), githubSession: session, now: now,
            recoveryAuthentication: recoveryAuthentication,
            cleanupWork: { try await engine.cleanupAbandonedWork() })
    }

    func testConnectChecksGitHubWithoutCreatingABackupOrRequestingACode() async throws {
        let model = model(try profile())
        XCTAssertFalse(model.canUseGitHubBackup)
        await model.connectGitHub(token: "synthetic-token")
        XCTAssertTrue(model.canUseGitHubBackup)
        XCTAssertEqual(model.githubConnectionState, .connected)
        XCTAssertNil(model.lastBackupAt)
        XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.httpMethod == "GET" })
        model.disconnectGitHub()
        XCTAssertFalse(model.canUseGitHubBackup)
        XCTAssertEqual(model.githubConnectionState, .disconnected)
    }

    func testCheckerRejectsRevokedAccessAndDoesNotCreateRepositories() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (401, [:], Data()) }
        await model.checkGitHubConnection()
        XCTAssertFalse(model.canUseGitHubBackup)
        XCTAssertEqual(model.githubConnectionState, .needsAttention)
        XCTAssertNotNil(model.githubConnectionError)
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.httpMethod == "GET" })
        await model.backupEverything()
        XCTAssertNil(model.lastBackupAt)
    }

    func testOneActionBacksUpAllDataAndCodeRestoresOnACleanMacWithoutConfirmation() async throws {
        let source = try profile(), target = try profile()
        source.defaults.set("fast", forKey: "sidekey.preferences.transcriptionMode")
        source.defaults.set(false, forKey: "notifications.meetingReady.enabled")
        target.defaults.set(true, forKey: "notifications.meetingReady.enabled")
        try source.credentialStores["byok.soniox.api_key"]!.save("synthetic-provider-key")
        let backup = model(source)
        await backup.connectGitHub(token: "synthetic-token")
        await backup.backupEverything()
        XCTAssertNil(backup.errorMessage)
        XCTAssertNotNil(backup.lastRemoteBackupAt)
        XCTAssertFalse(backup.recoveryCode.isEmpty)
        XCTAssertEqual(remote.publishCount, 1)
        XCTAssertTrue(backup.isEnabled, "Creating the GitHub backup enables subsequent sync")
        let code = backup.recoveryCode
        let restore = model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        XCTAssertNil(restore.errorMessage)
        XCTAssertTrue(restore.needsRestart)
        XCTAssertNil(restore.restorePreview, "The user does not have to choose groups or confirm a preview")
        XCTAssertNil(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "Do not apply over open stores")
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "fast")
        XCTAssertFalse(target.defaults.bool(forKey: "notifications.meetingReady.enabled"))
        XCTAssertEqual(try target.credentialStores["byok.soniox.api_key"]!.read(), "synthetic-provider-key")
    }

    func testSettingsSyncIsOfferedAfterRestoreOnACleanMac() async throws {
        let source = try profile(), target = try profile()
        let first = model(source)
        await first.connectGitHub(token: "synthetic-token")
        await first.backupEverything()
        let code = first.recoveryCode
        XCTAssertFalse(code.isEmpty)
        XCTAssertEqual(remote.publishCount, 1)

        let keyStore = MemoryTokenStore(), githubTokenStore = MemoryTokenStore()
        let second = model(target, keyStore: keyStore, githubTokenStore: githubTokenStore)
        await second.connectGitHub(token: "synthetic-token")
        await second.restoreEverything(code: code)
        XCTAssertNil(second.errorMessage)
        XCTAssertTrue(second.needsRestart)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())

        let restarted = model(target, keyStore: keyStore, githubTokenStore: githubTokenStore)
        await restarted.start()?.value
        await restarted.stopAndWait()
        XCTAssertTrue(restarted.canUseGitHubBackup)
        XCTAssertTrue(restarted.recoverySaved)
        XCTAssertFalse(restarted.needsRestart)
        XCTAssertEqual(remote.publishCount, 1, "Restore does not need to upload another backup")
        XCTAssertNil(restarted.lastRemoteBackupAt)
        XCTAssertFalse(restarted.showsAutomaticBackup, "Automatic backup still waits for this Mac's own upload")
        XCTAssertTrue(restarted.showsSettingsSync, "the sync switch is offered after a restore on a clean Mac")

        let fresh = model(try profile())
        await fresh.connectGitHub(token: "synthetic-token")
        XCTAssertFalse(fresh.showsSettingsSync, "without a recovery code there is nothing to sync with")
    }

    func testUploadStatusCountsPartsAndEndsWithTheCheckedResult() async throws {
        let backup = model(try profile())
        await backup.connectGitHub(token: "synthetic-token")
        var shown: [String] = []
        let observation = backup.$statusText.sink { shown.append($0) }
        defer { observation.cancel() }
        await backup.backupEverything()
        XCTAssertNil(backup.errorMessage)
        XCTAssertEqual(remote.publishCount, 1)
        XCTAssertTrue(shown.contains("Uploading backup part 1 of 1…"), "\(shown)")
        XCTAssertFalse(backup.statusText.hasPrefix("Uploading backup part"), "Progress never outlives the upload")
    }

    func testCreatedBackupSyncsSettingsAndRetriesOfflineChangesWithoutRevealingCode() async throws {
        let source = try profile()
        var time = Date()
        var idle = true
        let model = model(source, now: { time }, idle: { idle })
        await model.connectGitHub(token: "synthetic-token")
        await model.poll() // Capture the initial settings history before creation.
        await model.backupEverything()
        XCTAssertEqual(model.syncState, .synced)
        XCTAssertEqual(model.githubBackupURL?.absoluteString, "https://github.com/developer/Exodia-Backup/releases")
        let code = model.recoveryCode
        model.hideRecoveryCode()
        source.defaults.set("fast", forKey: "sidekey.preferences.transcriptionMode")
        await model.poll()
        XCTAssertEqual(model.syncState, .waiting, "The cooldown must not show a stale green check")
        XCTAssertEqual(remote.publishCount, 1)
        time.addTimeInterval(3600)
        idle = false
        await model.poll()
        XCTAssertEqual(remote.publishCount, 1, "Active work defers sync")
        idle = true
        remote.corruptReadback = true
        await model.poll()
        XCTAssertEqual(model.syncState, .needsAttention)
        XCTAssertTrue(model.isEnabled, "Offline failures remain retryable")
        XCTAssertEqual(remote.publishCount, 1)
        remote.corruptReadback = false
        time.addTimeInterval(121)
        await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.syncState, .synced)
        XCTAssertEqual(remote.publishCount, 2)
        XCTAssertTrue(model.recoveryCode.isEmpty, "Background sync never reveals the credential")
        let target = try profile()
        let restore = self.model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        XCTAssertNil(restore.errorMessage)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "fast")
    }

    func testExistingManualGitHubBackupAdoptsSyncOnceAndKeepsLaterPause() async throws {
        let source = try profile()
        let key = MemoryTokenStore(), token = MemoryTokenStore()
        let first = model(source, keyStore: key, githubTokenStore: token)
        await first.connectGitHub(token: "synthetic-token")
        await first.backupEverything()
        await first.stopAndWait()
        source.defaults.set(false, forKey: "backup.enabled.v1")
        source.defaults.removeObject(forKey: "backup.github-auto-sync.v1") // Previous manual-only release.
        let next = model(source, keyStore: key, githubTokenStore: token)
        await next.start()?.value
        XCTAssertTrue(next.isEnabled)
        XCTAssertTrue(source.defaults.bool(forKey: "backup.github-auto-sync.v1"))
        next.setEnabled(false)
        await next.stopAndWait()
        let paused = model(source, keyStore: key, githubTokenStore: token)
        await paused.start()?.value
        XCTAssertFalse(paused.isEnabled, "A later explicit pause must survive restart")
        await paused.stopAndWait()
    }

    func testCredentialOnlyChangeAutomaticallySyncsAndRestoresWithTheSameCode() async throws {
        let source = try profile(), target = try profile()
        let account = "byok.soniox.api_key"
        try source.credentialStores[account]!.save("synthetic-old-key")
        var time = Date()
        let model = model(source, now: { time })
        await model.connectGitHub(token: "synthetic-token")
        await model.poll()
        await model.backupEverything()
        let code = model.recoveryCode
        model.hideRecoveryCode()
        XCTAssertEqual(remote.publishCount, 1)

        // No setting or artifact notification accompanies a Keychain-only edit.
        try source.credentialStores[account]!.save("synthetic-new-key")
        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.syncState, .synced)
        XCTAssertEqual(remote.publishCount, 2)
        XCTAssertTrue(model.recoveryCode.isEmpty)

        let restore = self.model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        XCTAssertNil(restore.errorMessage)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(try target.credentialStores[account]!.read(), "synthetic-new-key")
    }

    func testOfflineEditsDoNotAccumulateFullArchivesAndNewestSettingsRestore() async throws {
        let source = try profile(), target = try profile()
        var time = Date(), offline = false
        StubURLProtocol.handler = { [remote] request in
            if offline { throw URLError(.notConnectedToInternet) }
            return try remote!.handle(request)
        }
        let model = model(source, now: { time })
        await model.connectGitHub(token: "synthetic-token")
        await model.poll()
        await model.backupEverything()
        let code = model.recoveryCode
        model.hideRecoveryCode()
        offline = true
        for index in 0..<6 {
            source.defaults.set("offline-\(index)", forKey: "sidekey.preferences.transcriptionMode")
            try source.write("unique-artifact-\(index)", to: source.locations.monitorRoot.appendingPathComponent("dashboards/notes.txt"))
            time.addTimeInterval(3600)
            await model.poll()
        }
        let archives = try FileManager.default.contentsOfDirectory(atPath: source.root.appendingPathComponent("archives").path)
            .filter { $0.hasSuffix(".exodiabackup") }
        XCTAssertLessThanOrEqual(archives.count, 3, "Retain the working generation, resumable transfer and freshest pending snapshot")
        XCTAssertEqual(remote.publishCount, 1)
        let freshest = try XCTUnwrap(model.versions.first?.localURL)
        let localTarget = try profile(), localEnvironment = localTarget.environment()
        try await ArtifactBackupEngine(environment: localEnvironment).stageRestore(from: freshest,
            key: ConfigBackupArchive.key(from: code), sections: [.workspace])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: localEnvironment)
        XCTAssertEqual(localTarget.contents(of: localTarget.locations.monitorRoot.appendingPathComponent("dashboards/notes.txt")), "unique-artifact-5")
        offline = false
        time.addTimeInterval(1_000)
        await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.syncState, .synced)

        let restore = self.model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        XCTAssertNil(restore.errorMessage)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "offline-5")
        XCTAssertEqual(target.contents(of: target.locations.monitorRoot.appendingPathComponent("dashboards/notes.txt")), "unique-artifact-5")
    }

    func testHourlyContentHashFindsAnArtifactChangeWithoutAMetadataHintAndDeduplicatesUnchangedData() async throws {
        let source = try profile(), target = try profile()
        let file = source.locations.monitorRoot.appendingPathComponent("dashboards/note.txt")
        try source.write("version-one", to: file)
        var time = Date(), captures = 0
        let model = model(source, now: { time }, changeProbe: { "unchanged-metadata-hint" }, beforeCreate: { captures += 1 })
        await model.connectGitHub(token: "synthetic-token")
        await model.poll()
        await model.backupEverything()
        let code = model.recoveryCode
        XCTAssertEqual(captures, 1)
        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertEqual(captures, 2, "Hash coherent content at least hourly even without a metadata hint")
        XCTAssertEqual(remote.publishCount, 1, "An unchanged hash must not create or upload a snapshot")
        XCTAssertEqual(model.versions.count, 1)
        try source.write("version-two", to: file)
        time.addTimeInterval(3599)
        await model.poll()
        XCTAssertEqual(remote.publishCount, 1)
        time.addTimeInterval(1)
        await model.poll()
        XCTAssertEqual(captures, 3)
        XCTAssertEqual(remote.publishCount, 2)
        XCTAssertNil(model.errorMessage)
        let restore = self.model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        XCTAssertNil(restore.errorMessage)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.contents(of: target.locations.monitorRoot.appendingPathComponent("dashboards/note.txt")), "version-two")
    }

    func testUnchangedUnsupportedSourceRetriesAtMostHourly() async throws {
        let source = try profile()
        var time = Date(), captures = 0
        let model = model(source, now: { time }, beforeCreate: { captures += 1 })
        await model.connectGitHub(token: "synthetic-token")
        await model.poll()
        await model.backupEverything()
        XCTAssertEqual(captures, 1)
        try source.write("unsupported", to: source.locations.notifyRoot.appendingPathComponent(".env"))
        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertEqual(captures, 2)
        XCTAssertNotNil(model.errorMessage)
        for _ in 0..<3 { time.addTimeInterval(121); await model.poll() }
        XCTAssertEqual(captures, 2, "Do not restage an unchanged failing source every two minutes")
        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertEqual(captures, 3, "Retry source validation on the next hourly check")
    }

    func testMetadataOnlyArtifactChangeDoesNotCreateAnotherArchiveOrRelease() async throws {
        let source = try profile()
        let file = source.locations.monitorRoot.appendingPathComponent("dashboards/note.txt")
        try source.write("unchanged", to: file)
        var time = Date()
        let locations = source.locations
        let model = model(source, now: { time }, changeProbe: { BackupChangeProbe.stamp(locations: locations) })
        await model.connectGitHub(token: "synthetic-token")
        await model.poll()
        await model.backupEverything()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: file.path)
        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(remote.publishCount, 1)
        XCTAssertEqual(model.versions.count, 1)
    }

    func testHourlyCalendarTokenRotationDoesNotCreateAnArchiveButTheNextRealEditCarriesIt() async throws {
        var source = try profile(), target = try profile()
        let account = ConnectedCalendarAccount(id: UUID(), provider: .microsoft, label: "Synthetic calendar")
        let name = CalendarKeychain.account(account.id)
        source.defaults.set(try JSONEncoder().encode([account]), forKey: CalendarAccountSettings.accountsKey)
        var credential = CalendarCredential(provider: .microsoft, clientID: "fixture-client",
            accessToken: "fixture-access", refreshToken: "fixture-first", expiresAt: .distantFuture)
        source.addCredential(name, String(decoding: try JSONEncoder().encode(credential), as: UTF8.self))
        target.addCredential(name, nil)
        var time = Date()
        let model = model(source, now: { time })
        await model.connectGitHub(token: "synthetic-token")
        await model.poll(); await model.backupEverything()
        let code = model.recoveryCode
        credential.refreshToken = "fixture-rotated-with-a-different-length"
        try source.credentialStores[name]!.save(String(decoding: try JSONEncoder().encode(credential), as: UTF8.self))
        time.addTimeInterval(3600); await model.poll()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(remote.publishCount, 1)
        XCTAssertEqual(model.versions.count, 1)
        source.defaults.set(true, forKey: "sidekey.preferences.hideHelpers")
        time.addTimeInterval(3600); await model.poll()
        XCTAssertEqual(remote.publishCount, 2)
        let restore = self.model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        let restored = try JSONDecoder().decode(CalendarCredential.self, from: Data(try XCTUnwrap(target.credentialStores[name]!.read()).utf8))
        XCTAssertEqual(restored.refreshToken, credential.refreshToken)
        credential.clientID = "fixture-new-client"
        try source.credentialStores[name]!.save(String(decoding: try JSONEncoder().encode(credential), as: UTF8.self))
        time.addTimeInterval(3600); await model.poll()
        XCTAssertEqual(remote.publishCount, 3, "A different calendar client is a real credential change")
    }

    func testStartupRemovesAbandonedWorkAndOrphansButKeepsIndexedAndResumableCopies() async throws {
        let source = try profile(), key = ArtifactBackupTestKeys.make()
        let local = BackupLocalStore(root: source.root.appendingPathComponent("archives"))
        let file = try await local.archiveURL()
        let summary = try await ArtifactBackupEngine(environment: source.environment()).createArchive(at: file, key: key)
        let keptArchive = try await local.record(summary, from: file)
        let destination = "github:synthetic/Exodia-Backup"
        try await local.recordPreparation(id: summary.id, preparation: .init(destinationID: destination, depth: 0))
        let keptUpload = await local.uploadFileURL(id: summary.id, destinationID: destination)
        try source.write("resumable ciphertext", to: keptUpload)
        let orphan = local.root.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        let orphanUpload = local.root.appendingPathComponent(UUID().uuidString + ".0123456789abcdef.upload")
        try source.write("partial ciphertext", to: orphan); try source.write("partial", to: orphanUpload)
        let scratch = source.locations.stagingWorkRoot.appendingPathComponent(UUID().uuidString)
        try source.write("abandoned audio", to: scratch.appendingPathComponent("chunk.wav"))
        let outside = source.root.appendingPathComponent("outside")
        try source.write("keep", to: outside.appendingPathComponent("audio.wav"))
        let link = source.locations.stagingWorkRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        let recovery = source.locations.recoveryRoot.appendingPathComponent("keep.txt")
        let unrelated = local.root.appendingPathComponent("keep.txt")
        try source.write("recoverable", to: recovery); try source.write("unrelated", to: unrelated)
        let model = model(source, keyStore: MemoryTokenStore(key.base64EncodedString()))
        await model.start()?.value
        XCTAssertNil(model.errorMessage)
        await model.stopAndWait()
        XCTAssertFalse(source.exists(orphan)); XCTAssertFalse(source.exists(orphanUpload)); XCTAssertFalse(source.exists(scratch))
        XCTAssertTrue(source.exists(keptArchive)); XCTAssertTrue(source.exists(keptUpload))
        XCTAssertEqual(source.contents(of: outside.appendingPathComponent("audio.wav")), "keep")
        XCTAssertEqual(source.contents(of: recovery), "recoverable")
        XCTAssertEqual(source.contents(of: unrelated), "unrelated")
    }

    func testOrphanCleanupRefusesAnUnreadableCatalogAndHonorsParkedCatalogs() async throws {
        let source = try profile(), local = BackupLocalStore(root: source.root.appendingPathComponent("archives"))
        let orphan = local.root.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        try source.write("keep until catalog is known", to: orphan)
        let catalog = local.root.appendingPathComponent("catalog.json")
        try source.write("broken", to: catalog)
        let scratch = source.locations.stagingWorkRoot.appendingPathComponent(UUID().uuidString)
        try source.write("abandoned plaintext", to: scratch.appendingPathComponent("audio.wav"))
        let model = model(source)
        await model.start()?.value
        XCTAssertNotNil(model.errorMessage)
        await model.stopAndWait()
        XCTAssertFalse(source.exists(scratch), "Scratch cleanup does not depend on a readable catalog")
        do { try await local.cleanupOrphans(); XCTFail("Do not infer orphans from an unreadable catalog") } catch {}
        XCTAssertTrue(source.exists(orphan))
        try source.write("[]", to: catalog)
        try source.write("parked", to: local.root.appendingPathComponent("kept-catalog-\(UUID().uuidString).json"))
        try await local.cleanupOrphans()
        XCTAssertTrue(source.exists(orphan), "Explicit abandonment preserved these unknown archives")
    }

    func testUnreadableMaintenanceKeepsAutomaticBackupsPausedAndFinishesConnectionStartup() async throws {
        let source = try profile(), key = MemoryTokenStore(), token = MemoryTokenStore()
        var time = Date(), captures = 0
        let first = model(source, keyStore: key, githubTokenStore: token, now: { time })
        await first.connectGitHub(token: "synthetic-token"); await first.backupEverything()
        await first.stopAndWait()
        let published = remote.publishCount
        try source.write("unreadable revocation journal", to: source.root.appendingPathComponent("archives/maintenance.json"))
        let restarted = model(source, keyStore: key, githubTokenStore: token, now: { time }, beforeCreate: { captures += 1 })
        await restarted.start()?.value
        XCTAssertTrue(restarted.hasPendingMaintenance)
        XCTAssertFalse(restarted.isEnabled)
        XCTAssertFalse(source.defaults.bool(forKey: "backup.enabled.v1"))
        XCTAssertEqual(restarted.githubConnectionState, .connected, "Housekeeping cannot skip the rest of initialization")
        source.defaults.set(true, forKey: "sidekey.preferences.hideHelpers")
        time.addTimeInterval(4000); await restarted.poll()
        XCTAssertEqual(captures, 0, "Never create an archive under a code pending revocation")
        XCTAssertEqual(remote.publishCount, published)
        await restarted.stopAndWait()
    }

    func testNewMacCannotAccidentallyReplaceTheRecoveryCodeBeforeRestore() async throws {
        let source = try profile(), target = try profile()
        source.defaults.set("saved", forKey: "sidekey.preferences.transcriptionMode")
        let first = model(source)
        await first.connectGitHub(token: "synthetic-token")
        await first.backupEverything()
        let code = first.recoveryCode
        let second = model(target)
        await second.connectGitHub(token: "synthetic-token")
        await second.backupEverything()
        XCTAssertEqual(remote.publishCount, 1)
        XCTAssertNotNil(second.errorMessage)
        XCTAssertTrue(second.recoveryCode.isEmpty)
        await second.restoreEverything(code: code)
        XCTAssertNil(second.errorMessage)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "saved")
    }

    func testLaunchWithoutNetworkOrDuringRateLimitResumesSyncWithoutOpeningSettings() async throws {
        for failure in [-1, 503, 403] {
            remote = BackupGitHubFixture(json: { try! JSONSerialization.data(withJSONObject: $0) })
            let source = try profile(), key = MemoryTokenStore(), token = MemoryTokenStore()
            var time = Date(), unavailable = false
            StubURLProtocol.handler = { [remote] request in
                if unavailable {
                    if failure == -1 { throw URLError(.notConnectedToInternet) }
                    return (failure, failure == 403 ? ["Retry-After": "1800"] : [:], Data())
                }
                return try remote!.handle(request)
            }
            let first = model(source, keyStore: key, githubTokenStore: token, now: { time })
            await first.connectGitHub(token: "synthetic-token")
            await first.backupEverything()
            let published = remote.publishCount
            XCTAssertEqual(published, 1)
            await first.stopAndWait()
            unavailable = true
            let restarted = model(source, keyStore: key, githubTokenStore: token, now: { time })
            await restarted.start()?.value
            XCTAssertEqual(restarted.githubConnectionState, .needsAttention)
            unavailable = false
            source.defaults.set("after-network-returned", forKey: "sidekey.preferences.transcriptionMode")
            let requests = StubURLProtocol.capturedRequests.count
            time.addTimeInterval(61)
            await restarted.poll()
            XCTAssertEqual(StubURLProtocol.capturedRequests.count, requests, "Respect the initial backoff")
            if failure == 403 {
                time.addTimeInterval(1_000)
                await restarted.poll()
                XCTAssertEqual(StubURLProtocol.capturedRequests.count, requests, "Honor GitHub's Retry-After: \(StubURLProtocol.capturedRequests.dropFirst(requests).map { $0.url!.path })")
            }
            time.addTimeInterval(3600)
            await restarted.poll()
            XCTAssertEqual(restarted.githubConnectionState, .connected)
            XCTAssertEqual(remote.publishCount, published + 1)
            XCTAssertEqual(restarted.syncState, .synced)
            await restarted.stopAndWait()
        }
    }

    func testInvalidGitHubCredentialsStayPausedUntilExplicitReconnect() async throws {
        let source = try profile(), key = MemoryTokenStore(), token = MemoryTokenStore()
        var time = Date()
        let first = model(source, keyStore: key, githubTokenStore: token, now: { time })
        await first.connectGitHub(token: "synthetic-token")
        await first.backupEverything()
        await first.stopAndWait()
        StubURLProtocol.handler = { _ in (401, [:], Data()) }
        let restarted = model(source, keyStore: key, githubTokenStore: token, now: { time })
        await restarted.start()?.value
        let requests = StubURLProtocol.capturedRequests.count
        source.defaults.set("after-revocation", forKey: "sidekey.preferences.transcriptionMode")
        time.addTimeInterval(3600)
        await restarted.poll()
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, requests)
        XCTAssertEqual(remote.publishCount, 1)
        StubURLProtocol.handler = { [remote] request in try remote!.handle(request) }
        await restarted.connectGitHub(token: "synthetic-new-token")
        await restarted.poll()
        XCTAssertEqual(remote.publishCount, 2)
        XCTAssertEqual(restarted.syncState, .synced)
        await restarted.stopAndWait()
    }

    func testRestoreFindsTheNewestSnapshotThatMatchesItsRecoveryCode() async throws {
        let source = try profile(), other = try profile(), target = try profile()
        source.defaults.set("original-key-generation", forKey: "sidekey.preferences.transcriptionMode")
        let first = model(source)
        await first.connectGitHub(token: "synthetic-token")
        await first.backupEverything()
        let code = first.recoveryCode
        let otherKey = ArtifactBackupTestKeys.make()
        let otherFile = other.root.appendingPathComponent("other.exodiabackup")
        let summary = try await ArtifactBackupEngine(environment: other.environment())
            .createArchive(at: otherFile, key: otherKey, sections: [.settings])
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        _ = try await transport.upload(file: otherFile, summary: summary, key: otherKey)
        let restore = model(target)
        await restore.connectGitHub(token: "synthetic-token")
        await restore.restoreEverything(code: code)
        XCTAssertNil(restore.errorMessage)
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: target.environment())
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.preferences.transcriptionMode"), "original-key-generation")
    }

    func testAuthenticatedSnapshotDatesOrderNewAndLegacyCopiesIndependentlyOfUploadOrder() async throws {
        for legacy in [false, true] {
            let fixture = BackupGitHubFixture(json: { try! JSONSerialization.data(withJSONObject: $0) })
            StubURLProtocol.handler = { try fixture.handle($0) }
            let source = try profile(), key = ArtifactBackupTestKeys.make()
            let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
            var ids: [String] = []
            for timestamp in [1_792_411_400.0, 1_792_411_200.0] { // Newest uploaded FIRST.
                var environment = source.environment()
                environment.now = { Date(timeIntervalSince1970: timestamp) }
                let file = source.root.appendingPathComponent(UUID().uuidString + ".exodiabackup")
                let summary = try await ArtifactBackupEngine(environment: environment)
                    .createArchive(at: file, key: key, sections: [.settings])
                ids.append(summary.id.uuidString)
                _ = try await transport.upload(file: file, summary: summary, key: key)
                if legacy {
                    let position = try XCTUnwrap(fixture.assets.firstIndex { $0["name"] as? String == "complete.exodia-index" })
                    let assetID = try XCTUnwrap(fixture.assets[position]["id"] as? Int)
                    let sealed = try XCTUnwrap(fixture.bytes[assetID])
                    let data = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: key),
                                                authenticating: Data("exodia.encrypted-backup.v1".utf8))
                    var index = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                    index.removeValue(forKey: "createdAt")
                    let replacement = try XCTUnwrap(AES.GCM.seal(JSONSerialization.data(withJSONObject: index),
                        using: SymmetricKey(data: key), authenticating: Data("exodia.encrypted-backup.v1".utf8)).combined)
                    fixture.bytes[assetID] = replacement
                    fixture.assets[position]["size"] = replacement.count
                }
            }
            let versions = try await transport.versions(key: key)
            XCTAssertEqual(versions.map(\.id), ids, "Authenticated capture time must win over reversed release dates, legacy=\(legacy)")
            let unrelated = try await transport.versions(key: ArtifactBackupTestKeys.make())
            XCTAssertTrue(unrelated.isEmpty)
        }
    }

    func testCancellingSyncKeepsItPausedWithoutRevealingTheCode() async throws {
        let source = try profile()
        var pause = false
        var resume: CheckedContinuation<Void, Never>?
        let started = expectation(description: "sync started")
        let model = model(source, beforeCreate: {
            if pause {
                started.fulfill()
                await withCheckedContinuation { resume = $0 }
            }
        })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        model.hideRecoveryCode()
        pause = true
        let operation = Task { await model.backupEverything() }
        await fulfillment(of: [started], timeout: 2)
        model.cancelCurrentOperation()
        resume?.resume()
        await operation.value
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(source.defaults.bool(forKey: "backup.github-auto-sync.v1"))
        XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertEqual(model.syncState, .paused)
        XCTAssertEqual(remote.publishCount, 1)
    }

    func testArtifactChangesDuringUploadRemainPending() async throws {
        let source = try profile()
        let model = model(source, changeProbe: {
            FileManager.default.fileExists(atPath: source.root.appendingPathComponent("changed").path) ? "after" : "before"
        }, beforeCreate: {
            try! source.write("changed", to: source.root.appendingPathComponent("changed"))
        })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.syncState, .waiting)
        XCTAssertTrue(model.isEnabled)
    }

    func testLeavingBackupWhileUploadingDoesNotRevealCodeLater() async throws {
        let started = expectation(description: "backup started")
        var resume: CheckedContinuation<Void, Never>?
        let model = model(try profile(), beforeCreate: {
            started.fulfill()
            await withCheckedContinuation { resume = $0 }
        })
        await model.connectGitHub(token: "synthetic-token")
        let operation = Task { await model.backupEverything() }
        await fulfillment(of: [started], timeout: 2)
        model.hideRecoveryCode()
        resume?.resume()
        await operation.value
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.lastRemoteBackupAt)
        XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertEqual(model.syncState, .recoveryCodeNeeded, "A never-shown code must not report protected recovery as complete")
        await model.showRecoveryCode()
        XCTAssertFalse(model.recoveryCode.isEmpty)
        XCTAssertEqual(model.syncState, .synced)
    }

    func testRepeatedBackupDoesNotRevealRecoveryCodeWithoutAuthentication() async throws {
        var authorized = false, prompts = 0
        let model = model(try profile(), recoveryAuthentication: {
            prompts += 1
            return authorized
        })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        let code = model.recoveryCode
        XCTAssertFalse(code.isEmpty)
        model.hideRecoveryCode()
        await model.backupEverything()
        XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertEqual(prompts, 0, "Ordinary backups do not prompt or reveal credentials")
        // Switching a destination clears its remote date, but the same code
        // has already been presented and must still require authentication.
        model.lastRemoteBackupAt = nil
        await model.backupEverything()
        XCTAssertTrue(model.recoveryCode.isEmpty)
        await model.showRecoveryCode()
        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(model.recoveryCode.isEmpty)
        authorized = true
        await model.showRecoveryCode()
        XCTAssertEqual(prompts, 2)
        XCTAssertEqual(model.recoveryCode, code)
    }

    func testPermanentSourceFailureRetriesOnlyAtTheNextHourlyCapture() async throws {
        let source = try profile()
        var time = Date(), attempts = 0
        let model = model(source, now: { time }, changeProbe: {
            BackupChangeProbe.stamp(locations: source.locations)
        }, beforeCreate: { attempts += 1 })
        await model.connectGitHub(token: "synthetic-token")
        await model.backupEverything()
        let initial = attempts
        let unsupported = source.locations.notifyRoot.appendingPathComponent(".env")
        try source.write("synthetic config", to: unsupported)
        time.addTimeInterval(3600)
        await model.poll()
        XCTAssertEqual(attempts, initial + 1)
        XCTAssertTrue(model.errorMessage?.contains("Notifications/.env") == true)
        time.addTimeInterval(1_000)
        await model.poll()
        XCTAssertEqual(attempts, initial + 1, "A deterministic source error must not repeatedly export recordings")
        try FileManager.default.removeItem(at: unsupported)
        time.addTimeInterval(2_600)
        await model.poll()
        XCTAssertEqual(attempts, initial + 2)
        XCTAssertNil(model.errorMessage)
    }

    func testStoppedModelRejectsLateChecksAfterSessionInvalidation() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        await model.stopAndWait()
        let count = StubURLProtocol.capturedRequests.count
        session.invalidateAndCancel()
        // Reproduces the render teardown ordering that used to abort XCTest
        // with NSGenericException, often during a later unrelated test suite.
        await model.checkGitHubConnection()
        await model.connectGitHub(token: "synthetic-token")
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, count)
        XCTAssertFalse(model.isBusy)
    }

    func testCancelledViewCheckDoesNotStartAnotherRequest() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        let count = StubURLProtocol.capturedRequests.count
        let check = Task { await model.checkGitHubConnection() }
        check.cancel()
        await check.value
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, count)
        await model.stopAndWait()
    }

    func testCancellingAnInFlightViewCheckCancelsItsRetainedRequest() async throws {
        session.invalidateAndCancel()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PendingGitHubCheckProtocol.self]
        session = URLSession(configuration: configuration)
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        XCTAssertTrue(model.canUseGitHubBackup)
        let started = expectation(description: "HTTP check is pending")
        let finished = expectation(description: "view task cancelled its retained request")
        PendingGitHubCheckProtocol.onPendingCheck = { started.fulfill() }
        defer { PendingGitHubCheckProtocol.onPendingCheck = nil }
        let check = Task {
            await model.checkGitHubConnection()
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)
        check.cancel()
        await fulfillment(of: [finished], timeout: 2)
        await model.stopAndWait()
        await check.value
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.githubConnectionState, .connected, "Leaving a view must not turn a valid connection into an auth error")
    }

    func testWrongCodeAndMissingBackupNeverStageARestore() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        await model.restoreEverything(code: "wrong")
        XCTAssertNotNil(model.errorMessage); XCTAssertFalse(model.needsRestart)
        await model.restoreEverything(code: try ConfigBackupArchive.recoveryCode(for: ConfigBackupArchive.makeKey()))
        XCTAssertEqual(model.errorMessage, "No backups found in GitHub.")
        XCTAssertFalse(model.needsRestart)
    }

    func testFailedUploadNeverReturnsASuccessCodeAndKeepsLocalCopy() async throws {
        let model = model(try profile())
        await model.connectGitHub(token: "synthetic-token")
        remote.corruptReadback = true
        await model.backupEverything()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.recoveryCode.isEmpty)
        XCTAssertNotNil(model.lastBackupAt)
        XCTAssertNil(model.lastRemoteBackupAt)
        XCTAssertEqual(remote.publishCount, 0)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(model.syncState, .needsAttention)
        XCTAssertFalse(model.statusText.hasPrefix("Saving"))
    }
}

/// A request that stays in flight until URLSession receives task cancellation.
private final class PendingGitHubCheckProtocol: URLProtocol {
    static var onPendingCheck: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        if path.hasSuffix("/Exodia-Backup"), let onPendingCheck = Self.onPendingCheck {
            onPendingCheck()
            return
        }
        let object: Any
        if path == "/user" { object = ["login": "developer"] }
        else if path.hasSuffix("/Exodia-Backup") { object = ["name": "Exodia-Backup", "private": true] }
        else { object = [] as [String] }
        let data = try! JSONSerialization.data(withJSONObject: object)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

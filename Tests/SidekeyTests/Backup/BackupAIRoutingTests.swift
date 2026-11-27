import XCTest
@testable import Sidekey

@MainActor
final class BackupAIRoutingTests: XCTestCase {
    private func routing(_ servers: [ServerEndpoint], model: String = "synthetic-model") throws -> Data {
        var routes = [AIFeature.translation.rawValue: FeatureRoute(account: .anthropic, model: model)]
        if let server = servers.first {
            routes[AIFeature.dropFast.rawValue] = FeatureRoute(account: .server(server.id), model: "synthetic-speech")
        }
        return try JSONEncoder().encode(AIRoutingState(routes: routes, migratedRoutes: routes,
                                                       servers: servers, migrationVersion: 1))
    }

    private func server() -> ServerEndpoint {
        let id = UUID()
        return ServerEndpoint(id: id, name: "Synthetic server", baseURL: "https://example.invalid/v1",
                              keyAccount: "byok.server.\(id.uuidString.lowercased()).api_key")
    }

    func testRoutesAndAllRegisteredServerKeysRestoreOnAnotherMac() async throws {
        var source = try ArtifactBackupTestProfile(); defer { source.tearDown() }
        var target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        let first = server(), second = server(), unrelated = server()
        let data = try routing([first, second])
        source.defaults.set(data, forKey: ConfigBackupRegistry.aiRoutingKey)
        for account in [first.keyAccount, second.keyAccount, ProviderAccount.anthropicKeychainAccount] {
            source.addCredential(account, "synthetic-" + account)
            target.addCredential(account, nil)
        }
        source.addCredential("backup.archive-key.v1", "MUST_NOT_EXPORT")
        target.addCredential(unrelated.keyAccount, "synthetic-unrelated")
        let file = source.root.appendingPathComponent("routing.exodiabackup"), key = ConfigBackupArchive.makeKey()
        let environment = target.environment()
        let engine = ArtifactBackupEngine(environment: source.environment())
        _ = try await engine.createArchive(at: file, key: key, sections: [.settings, .credentials])
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [.settings, .credentials])
        XCTAssertEqual(try ArtifactBackupEngine.applyPendingRestore(environment: environment)?.state, .applied)
        XCTAssertEqual(target.defaults.data(forKey: ConfigBackupRegistry.aiRoutingKey), data)
        let restored = AIRoutingStore(defaults: target.defaults)
        XCTAssertTrue(restored.isMigrated)
        XCTAssertEqual(restored.server(first.id), first)
        XCTAssertEqual(restored.route(for: .translation)?.account, .anthropic)
        for account in [first.keyAccount, second.keyAccount, ProviderAccount.anthropicKeychainAccount] {
            XCTAssertEqual(target.credentialStores[account]?.value, "synthetic-" + account)
        }
        XCTAssertEqual(target.credentialStores[unrelated.keyAccount]?.value, "synthetic-unrelated")
    }

    func testInterruptedRestoreRollsBackNewAndExistingServerKeysAndExactRoutingBytes() async throws {
        var source = try ArtifactBackupTestProfile(); defer { source.tearDown() }
        var target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        let first = server(), second = server()
        source.defaults.set(try routing([first, second]), forKey: ConfigBackupRegistry.aiRoutingKey)
        source.addCredential(first.keyAccount, "synthetic-imported-one")
        source.addCredential(second.keyAccount, "synthetic-imported-two")
        target.addCredential(first.keyAccount, "synthetic-existing")
        target.addCredential(second.keyAccount, nil)
        // The target may have an unreadable newer document. Its exact bytes,
        // not a re-encoded/lenient view, must survive a rollback.
        let original = Data("{\"unknown-newer-document\":true}".utf8)
        target.defaults.set(original, forKey: ConfigBackupRegistry.aiRoutingKey)
        let key = ConfigBackupArchive.makeKey(), file = source.root.appendingPathComponent("rollback.exodiabackup")
        _ = try await ArtifactBackupEngine(environment: source.environment()).createArchive(at: file, key: key, sections: [.settings, .credentials])
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [.settings, .credentials])
        var faults = ArtifactBackupFaults()
        faults.interruptAfter = { $0 == .metadata }
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: target.environment(faults: faults)))
        XCTAssertEqual(target.credentialStores[second.keyAccount]?.value, "synthetic-imported-two")
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .restoreInterrupted)
        }
        XCTAssertEqual(target.defaults.data(forKey: ConfigBackupRegistry.aiRoutingKey), original)
        XCTAssertEqual(target.credentialStores[first.keyAccount]?.value, "synthetic-existing")
        XCTAssertNil(target.credentialStores[second.keyAccount]?.value)
    }

    func testUnreadableIncomingServerKeyAbortsBeforeChangingAnySettings() async throws {
        var source = try ArtifactBackupTestProfile(); defer { source.tearDown() }
        var target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        let server = server()
        source.defaults.set(try routing([server]), forKey: ConfigBackupRegistry.aiRoutingKey)
        source.addCredential(server.keyAccount, "synthetic-source")
        target.addCredential(server.keyAccount, "synthetic-original")
        target.credentialStores[server.keyAccount]?.failOnRead = true
        let key = ConfigBackupArchive.makeKey(), file = source.root.appendingPathComponent("read.exodiabackup")
        _ = try await ArtifactBackupEngine(environment: source.environment()).createArchive(at: file, key: key, sections: [.settings, .credentials])
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [.settings, .credentials])
        XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment)) { error in
            XCTAssertEqual(error as? ArtifactBackupError, .keyUnavailable)
        }
        XCTAssertNil(target.defaults.object(forKey: ConfigBackupRegistry.aiRoutingKey))
        XCTAssertEqual(target.credentialStores[server.keyAccount]?.value, "synthetic-original")
    }

    func testLocalHistoryEncryptsRoutingAndRegisteredKeysWithoutCloudSetup() async throws {
        let profile = try ArtifactBackupTestProfile(); defer { profile.tearDown() }
        let server = server(), data = try routing([server])
        profile.defaults.set(data, forKey: ConfigBackupRegistry.aiRoutingKey)
        let key = ConfigBackupArchive.makeKey()
        let store = ConfigBackupFiles(root: profile.root.appendingPathComponent("history"))
        let model = BackupViewModel(defaults: profile.defaults, keyStore: MemoryTokenStore(key.base64EncodedString()),
                                    githubTokenStore: MemoryTokenStore(), local: BackupLocalStore(root: profile.root.appendingPathComponent("full")),
                                    settingsFiles: store, changeProbe: { "synthetic" }, idle: { true },
                                    providerStore: { account in MemoryTokenStore(account == server.keyAccount ? "synthetic-server-key" : nil) },
                                    previousRestoreOutcome: { nil })
        model.start(); defer { model.stop() }
        for _ in 0..<100 where model.localSettingsVersions.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let saved = try XCTUnwrap(model.localSettingsVersions.first)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(saved.preferences[ConfigBackupRegistry.aiRoutingKey], .data(data))
        XCTAssertEqual(saved.credentials?[server.keyAccount], "synthetic-server-key")
        let reopened = try await store.load(key: key)
        XCTAssertEqual(reopened.first, saved)
    }

    func testServerAccountsCannotRedirectTheAllowlistToOtherSecrets() throws {
        let profile = try ArtifactBackupTestProfile(); defer { profile.tearDown() }
        let server = server()
        var redirected = server
        for account in ["backup.archive-key.v1", "unrelated.secret", self.server().keyAccount, "byok.anthropic.api_key"] {
            redirected = ServerEndpoint(id: server.id, name: server.name, baseURL: server.baseURL, keyAccount: account)
            let data = try routing([redirected])
            profile.defaults.set(data, forKey: ConfigBackupRegistry.aiRoutingKey)
            let captured = try ConfigBackupRegistry.capture(profile.defaults)
            XCTAssertNotNil(captured[ConfigBackupRegistry.aiRoutingPreservedKey])
            XCTAssertFalse(try ConfigBackupRegistry.credentialAccounts(in: profile.defaults).contains(account)
                           && !ConfigBackupRegistry.credentialAccounts.contains(account))
            XCTAssertThrowsError(try ConfigBackupRegistry.validate([ConfigBackupRegistry.aiRoutingKey: .data(data)]))
        }
        for account in ["byok.server.not-a-uuid.api_key", "backup.archive-key.v1", "byok.server.\(server.id.uuidString).api_key"] {
            XCTAssertThrowsError(try ConfigBackupRegistry.validate([:], credentials: [account: "synthetic"]))
        }
        XCTAssertNoThrow(try ConfigBackupRegistry.validate([:], credentials: [server.keyAccount: "synthetic"]))
    }

    func testMigratedServerKeepsItsOriginalLegacyKeyAccount() throws {
        let profile = try ArtifactBackupTestProfile(); defer { profile.tearDown() }
        let servers = ["byok.selfHosted.api_key", "byok.custom_llm.api_key"].map {
            ServerEndpoint(id: UUID(), name: "Legacy", baseURL: "https://example.invalid", keyAccount: $0)
        }
        let data = try routing(servers)
        profile.defaults.set(data, forKey: ConfigBackupRegistry.aiRoutingKey)
        XCTAssertEqual(try ConfigBackupRegistry.capture(profile.defaults)[ConfigBackupRegistry.aiRoutingKey], .data(data))
        XCTAssertTrue(try ConfigBackupRegistry.credentialAccounts(in: profile.defaults).isSuperset(of: servers.map(\.keyAccount)))
    }

    func testSourceResetLeavesRoutesUnconfiguredAndNeverRerunsLegacyMigration() async throws {
        let target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        target.defaults.set(try routing([server()]), forKey: ConfigBackupRegistry.aiRoutingKey)
        target.defaults.set("yourKey", forKey: "sidekey.models.transcriptionLevel")
        target.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        let key = ConfigBackupArchive.makeKey()
        let (file, section) = try BackupSettingsBlockRestore.archive(ConfigBackupSnapshot(reason: "Defaults", preferences: [:]), section: .models, key: key, directory: target.root)
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [section])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        let routing = AIRoutingStore(defaults: target.defaults)
        XCTAssertTrue(routing.isMigrated)
        XCTAssertTrue(routing.state.routes.isEmpty)
        XCTAssertTrue(routing.state.servers.isEmpty)
        XCTAssertNil(target.defaults.object(forKey: "sidekey.models.byokProvider"))
    }

    func testOldFullArchivePreservesNewRoutesAndStillRestoresLegacyPreferences() async throws {
        let target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        let original = try routing([server()])
        target.defaults.set(original, forKey: ConfigBackupRegistry.aiRoutingKey)
        let key = ConfigBackupArchive.makeKey(), file = target.root.appendingPathComponent("old.exodiabackup")
        _ = try ArtifactBackupTestArchive.make(at: file, key: key, entries: [
            ("settings/preferences.json", .settings, try ArtifactBackupTestArchive.settingsPayload(schema: 2, values: ["sidekey.models.byokProvider": .string("soniox")]))
        ])
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [.settings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.defaults.data(forKey: ConfigBackupRegistry.aiRoutingKey), original)
        XCTAssertEqual(target.defaults.string(forKey: "sidekey.models.byokProvider"), "soniox")
    }

    func testOldHistoryBlockDoesNotEraseRoutesButNewHistoryRestoresThemExactly() async throws {
        let target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        let original = try routing([server()]), saved = try routing([server()], model: "older-model")
        target.defaults.set(original, forKey: ConfigBackupRegistry.aiRoutingKey)
        let key = ConfigBackupArchive.makeKey()
        var snapshot = ConfigBackupSnapshot(reason: "Old history", preferences: [:])
        snapshot.schemaVersion = 1
        let encoded = try ConfigBackupArchive.seal(snapshot, key: key)
        let old = try ConfigBackupArchive.open(encoded, key: key)
        let environment = target.environment()
        let (file, section) = try BackupSettingsBlockRestore.archive(old, section: .models, key: key, directory: target.root)
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [section])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.defaults.data(forKey: ConfigBackupRegistry.aiRoutingKey), original)
        let current = ConfigBackupSnapshot(reason: "New history", preferences: [ConfigBackupRegistry.aiRoutingKey: .data(saved)])
        let (newFile, _) = try BackupSettingsBlockRestore.archive(current, section: .models, key: key, directory: target.root)
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: newFile, key: key, sections: [.settings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.defaults.data(forKey: ConfigBackupRegistry.aiRoutingKey), saved)
    }

    func testBrokenRoutingDoesNotBlockOtherArtifactsAndKeepsEveryRawCopy() async throws {
        let source = try ArtifactBackupTestProfile(); defer { source.tearDown() }
        let target = try ArtifactBackupTestProfile(); defer { target.tearDown() }
        source.defaults.set("unreadable original routing", forKey: ConfigBackupRegistry.aiRoutingKey)
        source.defaults.set(Data([9, 8, 7]), forKey: ConfigBackupRegistry.aiRoutingPreservedKey)
        try source.write("synthetic persistent instructions", to: source.locations.agentMemory)
        let file = source.root.appendingPathComponent("broken-routing.exodiabackup"), key = ConfigBackupArchive.makeKey()
        let sourceEngine = ArtifactBackupEngine(environment: source.environment())
        _ = try await sourceEngine.createArchive(at: file, key: key, sections: [.settings, .workspace])
        let preview = try await sourceEngine.inspectArchive(at: file, key: key)
        XCTAssertTrue(preview.warnings.contains { $0.contains("unreadable server") })
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [.settings, .workspace])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        let preserved = try XCTUnwrap(target.defaults.dictionary(forKey: ConfigBackupRegistry.aiRoutingPreservedKey))
        XCTAssertEqual(preserved["routing"] as? String, "unreadable original routing")
        XCTAssertEqual(preserved["previousCopy"] as? Data, Data([9, 8, 7]))
        XCTAssertEqual(target.contents(of: target.locations.agentMemory), "synthetic persistent instructions")
        XCTAssertEqual(source.defaults.string(forKey: ConfigBackupRegistry.aiRoutingKey), "unreadable original routing")
        XCTAssertTrue(AIRoutingStore(defaults: target.defaults).isMigrated)
    }

    func testPartlyUnreadableServerListStillCapturesValidServerKeys() throws {
        let profile = try ArtifactBackupTestProfile(); defer { profile.tearDown() }
        let good = server()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: routing([good])) as? [String: Any])
        var servers = try XCTUnwrap(object["servers"] as? [Any])
        servers.append(["id": "unknown-new-server-shape", "keyAccount": "backup.archive-key.v1"])
        object["servers"] = servers
        let raw = try JSONSerialization.data(withJSONObject: object)
        profile.defaults.set(raw, forKey: ConfigBackupRegistry.aiRoutingKey)
        var warnings: [String] = []
        let captured = try ConfigBackupRegistry.capture(profile.defaults, warnings: &warnings)
        XCTAssertFalse(warnings.isEmpty)
        XCTAssertTrue(try ConfigBackupRegistry.credentialAccounts(in: profile.defaults).contains(good.keyAccount))
        XCTAssertFalse(try ConfigBackupRegistry.credentialAccounts(in: profile.defaults).contains("backup.archive-key.v1"))
        XCTAssertNotNil(captured[ConfigBackupRegistry.aiRoutingPreservedKey])
    }

    func testRepairedBackupPreservesTheSubtitleSplitAndExplicitlyUnsetLLM() throws {
        let profile = try ArtifactBackupTestProfile(); defer { profile.tearDown() }
        let speech = FeatureRoute(account: .soniox, model: "stt-rt-v5")
        let text = FeatureRoute(account: .openRouter, model: "text-only")
        let state = AIRoutingState(routes: [AIFeature.subtitlesAudio.rawValue: speech,
                                            AIFeature.translation.rawValue: text],
                                   migratedRoutes: [:], servers: [server()], migrationVersion: 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var servers = try XCTUnwrap(object["servers"] as? [Any])
        servers.append(["id": "invalid-new-server-shape"])
        object["servers"] = servers
        profile.defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ConfigBackupRegistry.aiRoutingKey)

        let captured = try ConfigBackupRegistry.capture(profile.defaults)
        try ConfigBackupRegistry.apply(captured, sections: [.models], to: profile.defaults)
        let restored = AIRoutingStore(defaults: profile.defaults)
        restored.separateSubtitleTranslationIfNeeded()

        XCTAssertEqual(restored.state.migrationVersion, 2)
        XCTAssertEqual(restored.route(for: .translation), text)
        XCTAssertNil(restored.route(for: .subtitlesTranslation))
    }

    func testUnmigratedImportedRoutingCannotSilentlySwitchToLegacyRoutes() throws {
        let profile = try ArtifactBackupTestProfile(); defer { profile.tearDown() }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: routing([server()])) as? [String: Any])
        object["migrationVersion"] = 0
        let raw = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ConfigBackupRegistry.apply([ConfigBackupRegistry.aiRoutingKey: .data(raw)], sections: [.models], to: profile.defaults))
        XCTAssertNil(profile.defaults.object(forKey: ConfigBackupRegistry.aiRoutingKey))
        profile.defaults.set(raw, forKey: ConfigBackupRegistry.aiRoutingKey)
        let captured = try ConfigBackupRegistry.capture(profile.defaults)
        try ConfigBackupRegistry.apply(captured, sections: [.models], to: profile.defaults)
        let routing = AIRoutingStore(defaults: profile.defaults)
        XCTAssertTrue(routing.isMigrated)
        XCTAssertEqual(routing.route(for: .translation)?.account, .anthropic)
        XCTAssertNotNil(profile.defaults.object(forKey: ConfigBackupRegistry.aiRoutingPreservedKey))
    }
}

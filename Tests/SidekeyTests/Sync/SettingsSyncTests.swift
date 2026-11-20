import Combine
import Foundation
import XCTest
@testable import Sidekey

/// Shared GitHub stand-in: one file with a version number. Writes are
/// conditional on the version read, like the Contents API blob SHA.
actor FakeSyncRemote: SettingsSyncRemote {
    private(set) var data: Data?
    private(set) var version = 0
    private(set) var puts = 0
    private(set) var fetches = 0
    /// Runs once at the start of the next write: another Mac writes first.
    var interject: (@Sendable (FakeSyncRemote) async -> Void)?
    /// Runs once while the next read is in flight.
    var duringFetch: (@Sendable () async -> Void)?
    var offline = false

    func fetchSyncFile(path: String, etag: String?) async throws -> SettingsSyncFetch {
        if offline { throw URLError(.notConnectedToInternet) }
        if let duringFetch { self.duringFetch = nil; await duringFetch() }
        fetches += 1
        guard let data else { return .missing }
        if etag == "\"\(version)\"" { return .notModified }
        return .found(data: data, sha: "\(version)", etag: "\"\(version)\"")
    }

    func putSyncFile(path: String, data: Data, sha: String?) async throws -> String {
        if let interject { self.interject = nil; await interject(self) }
        guard sha == (self.data == nil ? nil : "\(version)") else { throw SettingsSyncFailure.conflict }
        self.data = data; version += 1; puts += 1
        return "\(version)"
    }

    func overwrite(_ data: Data) { self.data = data; version += 1 }
    func setInterject(_ block: (@Sendable (FakeSyncRemote) async -> Void)?) { interject = block }
    func setDuringFetch(_ block: (@Sendable () async -> Void)?) { duringFetch = block }
    func setOffline(_ value: Bool) { offline = value }
}

final class FakeSecrets: @unchecked Sendable {
    var values: [String: String] = [:]
    var unreadable: Set<String> = []
    var unwritable: Set<String> = []
    func store(_ account: String) -> TokenStore { Store(owner: self, account: account) }
    struct Store: TokenStore {
        let owner: FakeSecrets, account: String
        func save(_ token: String) throws {
            if owner.unwritable.contains(account) { throw KeychainError.unhandledError(-25308) }
            owner.values[account] = token
        }
        func read() throws -> String? {
            if owner.unreadable.contains(account) { throw KeychainError.unhandledError(-25308) }
            return owner.values[account]
        }
        func delete() throws { owner.values[account] = nil }
    }
}

@MainActor
final class SettingsSyncTests: XCTestCase {
    /// One Mac: its own defaults, Keychain and ledger, sharing `remote` and `key`.
    @MainActor final class Mac {
        let defaults: UserDefaults
        let suite: String
        let secrets = FakeSecrets()
        let ledgerURL: URL
        var reloaded: [Set<String>] = []
        /// What a store's setter does on reload: write the value it shows.
        var onReload: ((UserDefaults) -> Void)?
        var key: Data
        var clock: Date
        var service: SettingsSyncService!

        init(remote: FakeSyncRemote, key: Data, clock: Date) {
            suite = "settings-sync-test-" + UUID().uuidString
            defaults = UserDefaults(suiteName: suite)!
            ledgerURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(suite, isDirectory: true).appendingPathComponent("ledger.json")
            self.key = key; self.clock = clock
            service = SettingsSyncService(dependencies: .init(
                defaults: defaults,
                secretStore: { [secrets] in secrets.store($0) },
                backupKey: { [unowned self] in self.key },
                remote: { remote },
                ledgerURL: ledgerURL,
                path: "whytap-sync/settings.v1.json",
                now: { [unowned self] in self.clock },
                isPaused: { false },
                reload: { [unowned self] in self.reloaded.append($0); self.onReload?(self.defaults) }))
        }

        func turnOn() async { service.setEnabled(true); await service.syncNow() }
        func sync(after seconds: TimeInterval = 5) async { clock.addTimeInterval(seconds); await service.syncNow() }
        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
        }
    }

    private let mode = "sidekey.preferences.transcriptionMode"
    private let meetingKey = "hotkeys.meetingRecordShortcut"
    private let vocabulary = "sidekey.preferences.vocabularyTerms"
    private let display = "sidekey.dynamicIsland.preferredDisplayUUID"
    private let soniox = "byok.soniox.api_key"
    private let openRouter = "byok.openrouter.llm_api_key"

    private var macs: [Mac] = []
    private var remote: FakeSyncRemote!
    private var key: Data!

    override func setUp() async throws {
        remote = FakeSyncRemote()
        key = ConfigBackupArchive.makeKey()
    }

    override func tearDown() async throws {
        macs.forEach { $0.cleanUp() }
        macs = []
    }

    private func mac(at offset: TimeInterval = 0) -> Mac {
        let mac = Mac(remote: remote, key: key, clock: Date(timeIntervalSince1970: 1_800_000_000 + offset))
        macs.append(mac)
        return mac
    }

    private func shared() async throws -> SettingsSyncDocument {
        let stored = await remote.data
        let data = try XCTUnwrap(stored)
        return try SettingsSyncEnvelope.open(data, key: key)
    }

    // MARK: Scenarios

    func testFirstMacUploadsItsSettingsAndKeysButNotItsDisplay() async throws {
        let first = mac()
        first.defaults.set("smart", forKey: mode)
        first.defaults.set("display-1", forKey: display)
        first.secrets.values[soniox] = "soniox-secret"
        await first.turnOn()

        XCTAssertEqual(first.service.status, .synced(first.clock))
        let document = try await shared()
        XCTAssertEqual(document.entries[SettingsSyncItem.preference(mode)]?.value, .preference(.string("smart")))
        XCTAssertEqual(document.entries[SettingsSyncItem.secret(soniox)]?.value, .secret("soniox-secret"))
        XCTAssertNil(document.entries[SettingsSyncItem.preference(display)])
        // GitHub only ever sees ciphertext.
        let remoteData = await remote.data
        let stored = try XCTUnwrap(remoteData)
        XCTAssertNil(String(decoding: stored, as: UTF8.self).range(of: "soniox-secret"))
    }

    func testJoiningMacTakesSharedSettingsAndKeepsItsOwnExtras() async throws {
        let first = mac()
        first.defaults.set("smart", forKey: mode)
        first.secrets.values[soniox] = "from-first"
        await first.turnOn()

        let second = mac(at: 3600)
        second.defaults.set("fast", forKey: mode)
        second.defaults.set("display-2", forKey: display)
        second.secrets.values[soniox] = "stale-on-second"
        second.secrets.values[openRouter] = "only-on-second"
        await second.turnOn()

        XCTAssertEqual(second.defaults.string(forKey: mode), "smart", "a joining Mac takes the shared value even though its own edit is later")
        XCTAssertEqual(second.secrets.values[soniox], "from-first")
        XCTAssertEqual(second.defaults.string(forKey: display), "display-2", "the island display stays per Mac")
        XCTAssertTrue(second.reloaded.contains { $0.contains(SettingsSyncItem.preference(mode)) })

        await first.sync()
        XCTAssertEqual(first.secrets.values[openRouter], "only-on-second", "a key only the joining Mac had reaches the other Mac")
        XCTAssertEqual(first.defaults.string(forKey: mode), "smart")
    }

    func testEditsToDifferentSettingsOnBothMacsBothSurvive() async throws {
        let first = mac(), second = mac()
        await first.turnOn(); await second.turnOn()

        first.defaults.set("smart", forKey: mode)
        second.defaults.set(["Whytap", "Soniox"], forKey: vocabulary)
        await first.sync()
        await second.sync()
        await first.sync()

        XCTAssertEqual(first.defaults.stringArray(forKey: vocabulary), ["Whytap", "Soniox"])
        XCTAssertEqual(second.defaults.string(forKey: mode), "smart")
    }

    func testTheLaterEditOfOneSettingWins() async throws {
        let first = mac(), second = mac()
        await first.turnOn(); await second.turnOn()

        first.defaults.set("option+m", forKey: meetingKey)
        first.clock.addTimeInterval(10)
        second.defaults.set("control+m", forKey: meetingKey)
        second.clock.addTimeInterval(20)
        // The earlier edit reaches GitHub first; the later one still wins.
        await first.service.syncNow()
        await second.service.syncNow()
        await first.sync()

        XCTAssertEqual(first.defaults.string(forKey: meetingKey), "control+m")
        XCTAssertEqual(second.defaults.string(forKey: meetingKey), "control+m")
    }

    func testRemovingAKeyOnOneMacRemovesItOnTheOther() async throws {
        let first = mac(), second = mac()
        first.secrets.values[soniox] = "secret"
        await first.turnOn(); await second.turnOn()
        XCTAssertEqual(second.secrets.values[soniox], "secret")

        first.secrets.values[soniox] = nil
        await first.sync()
        await second.sync()

        XCTAssertNil(second.secrets.values[soniox])
        let document = try await shared()
        XCTAssertNotNil(document.entries[SettingsSyncItem.secret(soniox)])
        XCTAssertNil(document.entries[SettingsSyncItem.secret(soniox)]?.value, "the removal is recorded, so the key does not come back")
    }

    func testUnreadableKeychainStopsTheRoundInsteadOfDeletingTheKeyEverywhere() async throws {
        let first = mac(), second = mac()
        first.secrets.values[soniox] = "secret"
        await first.turnOn(); await second.turnOn()
        let putsBefore = await remote.puts

        first.secrets.unreadable = [soniox]
        await first.sync()

        if case .failed = first.service.status {} else { XCTFail("expected a visible failure, got \(first.service.status)") }
        let puts = await remote.puts
        XCTAssertEqual(puts, putsBefore)
        await second.sync()
        XCTAssertEqual(second.secrets.values[soniox], "secret")
    }

    func testAWriteThatLosesTheRaceIsMergedAndRetried() async throws {
        let first = mac(), second = mac()
        await first.turnOn(); await second.turnOn()

        second.defaults.set(["Whytap"], forKey: vocabulary)
        first.defaults.set("smart", forKey: mode)
        let secondService = second.service!
        await remote.setInterject { _ in await secondService.syncNow() }
        await first.sync()

        let document = try await shared()
        XCTAssertEqual(document.entries[SettingsSyncItem.preference(mode)]?.value, .preference(.string("smart")))
        XCTAssertEqual(document.entries[SettingsSyncItem.preference(vocabulary)]?.value, .preference(.strings(["Whytap"])))
        XCTAssertEqual(first.defaults.stringArray(forKey: vocabulary), ["Whytap"])
        XCTAssertEqual(first.service.status, .synced(first.clock))
    }

    func testAnotherRecoveryCodeIsReportedAndNeverOverwritten() async throws {
        let first = mac()
        first.defaults.set("smart", forKey: mode)
        await first.turnOn()
        let before = await remote.data

        let other = mac()
        other.key = ConfigBackupArchive.makeKey()
        other.defaults.set("fast", forKey: mode)
        await other.turnOn()

        XCTAssertEqual(other.service.status, .differentKey)
        let after = await remote.data
        XCTAssertEqual(after, before)
        XCTAssertEqual(other.defaults.string(forKey: mode), "fast")
    }

    func testWithoutABackupKeySyncAsksForABackup() async throws {
        let first = mac()
        first.key = Data()
        await first.turnOn()
        XCTAssertEqual(first.service.status, .needsBackup)
        let fetches = await remote.fetches
        XCTAssertEqual(fetches, 0)
    }

    func testTurningSyncOffAndOnRejoinsAndTakesTheSharedSettings() async throws {
        let first = mac(), second = mac()
        await first.turnOn(); await second.turnOn()
        second.service.setEnabled(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.ledgerURL.path))

        first.defaults.set("smart", forKey: mode)
        await first.sync()
        second.defaults.set("fast", forKey: mode)
        second.clock.addTimeInterval(60)
        await second.turnOn()

        XCTAssertEqual(second.defaults.string(forKey: mode), "smart")
    }

    func testUnknownItemsFromANewerAppAndInvalidValuesAreLeftAlone() async throws {
        let first = mac()
        await first.turnOn()
        var document = try await shared()
        document.entries["pref:some.future.setting"] = .init(value: .preference(.string("x")), modifiedAt: .distantFuture, device: "Z")
        document.entries[SettingsSyncItem.preference(mode)] = .init(value: .preference(.bool(true)), modifiedAt: .distantFuture, device: "Z")
        await remote.overwrite(try SettingsSyncEnvelope.seal(document, key: key))

        first.defaults.set("smart", forKey: mode)
        await first.sync()

        XCTAssertEqual(first.defaults.string(forKey: mode), "smart", "a wrongly typed shared value is not written into defaults")
        XCTAssertNil(first.defaults.object(forKey: "some.future.setting"))
        let merged = try await shared()
        XCTAssertNotNil(merged.entries["pref:some.future.setting"], "a newer app's item survives this Mac's write")
        XCTAssertEqual(merged.entries[SettingsSyncItem.preference(mode)]?.value, .preference(.string("smart")))
    }

    func testAnUnchangedRoundWritesNothing() async throws {
        let first = mac()
        first.defaults.set("smart", forKey: mode)
        await first.turnOn()
        let puts = await remote.puts
        await first.sync()
        await first.sync()
        let after = await remote.puts
        XCTAssertEqual(after, puts)
    }

    // MARK: Review findings

    func testAKeySavedWhileGitHubAnswersIsKeptAndShared() async throws {
        let first = mac(), second = mac()
        first.secrets.values[soniox] = "old"
        await first.turnOn(); await second.turnOn()
        second.secrets.values[soniox] = nil
        await second.sync()

        let firstSecrets = first.secrets, account = soniox
        await remote.setDuringFetch { firstSecrets.values[account] = "new" }
        await first.sync(after: 30)
        await second.sync()

        XCTAssertEqual(first.secrets.values[soniox], "new", "the removal read from GitHub must not delete a key saved meanwhile")
        XCTAssertEqual(second.secrets.values[soniox], "new")
    }

    func testAnEditMadeOfflineKeepsItsTimeAndLosesToALaterEdit() async throws {
        let first = mac(), second = mac()
        await first.turnOn(); await second.turnOn()

        await remote.setOffline(true)
        first.defaults.set("option+m", forKey: meetingKey)
        await first.sync(after: 10)
        await remote.setOffline(false)
        second.defaults.set("control+m", forKey: meetingKey)
        await second.sync(after: 100)
        await first.sync(after: 1000)

        XCTAssertEqual(first.defaults.string(forKey: meetingKey), "control+m")
        XCTAssertEqual(second.defaults.string(forKey: meetingKey), "control+m")
    }

    func testANewRecoveryCodeNeverReusesTheDocumentOpenedWithTheOldOne() async throws {
        let first = mac()
        first.defaults.set("smart", forKey: mode)
        await first.turnOn()
        let before = await remote.data

        first.key = ConfigBackupArchive.makeKey()
        first.defaults.set("fast", forKey: mode)
        await first.sync()

        XCTAssertEqual(first.service.status, .differentKey)
        let after = await remote.data
        XCTAssertEqual(after, before, "the shared settings are not re-sealed with the new code")
    }

    func testAJoinThatLosesTheWriteRaceStillTakesTheSharedValues() async throws {
        let first = mac()
        first.defaults.set("smart", forKey: mode)
        await first.turnOn()

        let second = mac(at: 3600)
        second.defaults.set("fast", forKey: mode)
        second.defaults.set("control+m", forKey: meetingKey)
        let firstMac = first
        await remote.setInterject { _ in
            await MainActor.run { firstMac.defaults.set(["Whytap"], forKey: "sidekey.preferences.vocabularyTerms") }
            await firstMac.sync(after: 1)
        }
        await second.turnOn()

        XCTAssertEqual(first.clock, Date(timeIntervalSince1970: 1_800_000_001), "the other Mac wrote during the join")
        XCTAssertEqual(second.defaults.string(forKey: mode), "smart", "the retried join still yields to shared values")
        XCTAssertEqual(second.defaults.stringArray(forKey: vocabulary), ["Whytap"])
        XCTAssertEqual(second.service.status, .synced(second.clock))
        let document = try await shared()
        XCTAssertEqual(document.entries[SettingsSyncItem.preference(meetingKey)]?.value, .preference(.string("control+m")))
        XCTAssertEqual(document.entries[SettingsSyncItem.preference(mode)]?.value, .preference(.string("smart")))
    }

    func testAKeyTheKeychainRefusesIsRetriedNotTreatedAsRemoved() async throws {
        let first = mac(), second = mac()
        await first.turnOn(); await second.turnOn()
        first.secrets.values[soniox] = "secret"
        first.defaults.set("smart", forKey: mode)
        await first.sync()

        second.secrets.unwritable = [soniox]
        await second.sync()
        if case .failed = second.service.status {} else { XCTFail("expected a visible failure") }
        XCTAssertEqual(second.defaults.string(forKey: mode), "smart", "other items still apply")

        second.secrets.unwritable = []
        await second.sync(after: 1000)
        XCTAssertEqual(second.secrets.values[soniox], "secret")
        await first.sync()
        XCTAssertEqual(first.secrets.values[soniox], "secret", "the refused write never becomes a removal")
    }

    func testAnEditDuringBackoffKeepsItsTime() async throws {
        let first = mac(), second = mac()
        await first.turnOn(); await second.turnOn()

        await remote.setOffline(true)
        await first.sync(after: 1)                       // fails, backs off for a minute
        first.clock.addTimeInterval(10)
        first.defaults.set("option+m", forKey: meetingKey)
        first.service.requestSync()                      // skipped by backoff, edit still noticed
        await remote.setOffline(false)
        second.defaults.set("control+m", forKey: meetingKey)
        await second.sync(after: 100)
        await first.sync(after: 1000)

        XCTAssertEqual(first.defaults.string(forKey: meetingKey), "control+m")
    }

    func testAKeyDroppedBeforeTheFirstSharedRoundIsNotSharedAsARemoval() async throws {
        let first = mac()
        first.secrets.values[soniox] = "first"
        await remote.setOffline(true)
        await first.turnOn()                             // join fails offline
        first.secrets.values[soniox] = nil
        await remote.setOffline(false)
        await first.sync(after: 1000)

        let second = mac(at: 2000)
        second.secrets.values[soniox] = "second"
        await second.turnOn()

        XCTAssertEqual(second.secrets.values[soniox], "second")
        let document = try await shared()
        XCTAssertEqual(document.entries[SettingsSyncItem.secret(soniox)]?.value, .secret("second"))
    }

    func testASettingRemovedOnTheOtherMacStaysRemovedWhenAStoreSavesItsDefault() async throws {
        let first = mac(), second = mac()
        first.defaults.set("option+m", forKey: meetingKey)
        await first.turnOn(); await second.turnOn()
        let key = meetingKey
        second.onReload = { defaults in if defaults.object(forKey: key) == nil { defaults.set("default", forKey: key) } }

        first.defaults.removeObject(forKey: meetingKey)
        await first.sync()
        await second.sync()
        await second.sync()
        await first.sync()

        XCTAssertNil(second.defaults.object(forKey: meetingKey))
        XCTAssertNil(first.defaults.object(forKey: meetingKey), "the store's default never comes back as an edit")
    }

    func testARestoredKeyForARemovedServerIsNotUploadedAgain() async throws {
        let first = mac(), second = mac()
        let id = UUID()
        let server = "byok.server.\(id.uuidString.lowercased()).api_key"
        let endpoint = ServerEndpoint(id: id, name: "Lab", baseURL: "https://lab.example", keyAccount: server)
        func routing(_ servers: [ServerEndpoint]) throws -> Data {
            try JSONEncoder().encode(AIRoutingState(routes: [:], migratedRoutes: [:], servers: servers, migrationVersion: 4))
        }
        first.defaults.set(try routing([endpoint]), forKey: AIRoutingStore.defaultsKey)
        first.secrets.values[server] = "server-key"
        await first.turnOn()
        // Removing the server removes its key.
        first.defaults.set(try routing([]), forKey: AIRoutingStore.defaultsKey)
        first.secrets.values[server] = nil
        await first.sync()
        let removal = try await shared()
        XCTAssertNotNil(removal.entries[SettingsSyncItem.secret(server)])
        XCTAssertNil(removal.entries[SettingsSyncItem.secret(server)]?.value)

        // An old backup on the other Mac still holds the key, without the server.
        second.secrets.values[server] = "server-key"
        await second.turnOn()
        await second.sync(after: 1000)

        XCTAssertNil(second.secrets.values[server], "joining takes the shared removal")
        let document = try await shared()
        XCTAssertNil(document.entries[SettingsSyncItem.secret(server)]?.value)
    }

    func testAKeyRemovedWhileTheJoiningWriteIsInFlightIsRemovedOnlyAsTheUsersEdit() async throws {
        let first = mac()
        first.secrets.values[soniox] = "shared"
        await first.turnOn()

        let second = mac(at: 100)
        second.defaults.set("control+m", forKey: meetingKey)
        let secondMac = second, account = soniox
        await remote.setInterject { _ in
            await MainActor.run {
                secondMac.secrets.values[account] = nil
                secondMac.service.requestSync()
            }
        }
        await second.turnOn()
        XCTAssertEqual(second.service.status, .synced(second.clock))

        // The removal was the user's own edit after receiving the key: it is
        // shared once, from the round that follows the join, never lost.
        await first.sync(after: 1000)
        XCTAssertNil(first.secrets.values[soniox])
        XCTAssertNil(second.secrets.values[soniox])
    }

    func testAReceivedKeyRemovedDuringAConflictingJoinWriteStaysRemoved() async throws {
        let first = mac()
        first.secrets.values[soniox] = "shared"
        await first.turnOn()

        let second = mac(at: 100)
        second.defaults.set("control+m", forKey: meetingKey)
        let firstMac = first, secondMac = second, account = soniox
        await remote.setInterject { _ in
            await MainActor.run {
                secondMac.clock.addTimeInterval(1)
                secondMac.secrets.values[account] = nil
                secondMac.service.requestSync()
                firstMac.defaults.set(["Whytap"], forKey: "sidekey.preferences.vocabularyTerms")
            }
            await firstMac.sync(after: 50)               // makes the joining write conflict
        }
        await second.turnOn()

        XCTAssertNil(second.secrets.values[soniox], "the user's removal survives the retried write")
        await first.sync(after: 1000)
        XCTAssertNil(first.secrets.values[soniox])
        XCTAssertEqual(second.defaults.stringArray(forKey: vocabulary), ["Whytap"])
    }

    func testAnEditSeenDuringAWriteKeepsTheTimeItWasSeen() async throws {
        let first = mac(), second = mac()
        await first.turnOn(); await second.turnOn()

        first.defaults.set("smart", forKey: mode)        // gives the next round something to write
        let firstMac = first, secondMac = second, key = meetingKey
        await remote.setInterject { _ in
            await MainActor.run {
                firstMac.clock.addTimeInterval(1)
                firstMac.defaults.set("option+m", forKey: key)
                firstMac.service.requestSync()
                secondMac.defaults.set("control+m", forKey: key)
            }
            await secondMac.sync(after: 50)
            await MainActor.run { firstMac.clock.addTimeInterval(500) }
        }
        await first.sync(after: 10)
        await second.sync(after: 1000)

        XCTAssertEqual(first.defaults.string(forKey: meetingKey), "control+m", "the later edit on the other Mac wins")
        XCTAssertEqual(second.defaults.string(forKey: meetingKey), "control+m")
    }

    func testTurningSyncOffAndOnQuicklyStillSyncs() async throws {
        let first = mac()
        first.defaults.set("smart", forKey: mode)
        first.service.setEnabled(true)
        first.service.setEnabled(false)
        first.service.setEnabled(true)
        await first.service.syncNow()
        XCTAssertEqual(first.service.status, .synced(first.clock))
        let document = try await shared()
        XCTAssertEqual(document.entries[SettingsSyncItem.preference(mode)]?.value, .preference(.string("smart")))
    }

    // MARK: Envelope

    func testEnvelopeDetectsTamperingAndNewerFormats() throws {
        let document = SettingsSyncDocument(entries: ["key:" + soniox: .init(value: .secret("s"), modifiedAt: Date(timeIntervalSince1970: 1_800_000_000.123), device: "A")])
        var sealed = try SettingsSyncEnvelope.seal(document, key: key)
        XCTAssertEqual(try SettingsSyncEnvelope.open(sealed, key: key), document)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        var bytes = try XCTUnwrap(Data(base64Encoded: object["sealed"] as! String))
        bytes[bytes.count - 1] ^= 0xFF
        object["sealed"] = bytes.base64EncodedString()
        sealed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try SettingsSyncEnvelope.open(sealed, key: key)) {
            XCTAssertEqual($0 as? SettingsSyncEnvelope.Failure, .damaged)
        }

        object["version"] = 2
        XCTAssertThrowsError(try SettingsSyncEnvelope.open(try JSONSerialization.data(withJSONObject: object), key: key)) {
            XCTAssertEqual($0 as? SettingsSyncEnvelope.Failure, .newerFormat)
        }
    }

    // MARK: GitHub Contents API

    func testGitHubFileIsReadConditionallyAndWrittenWithItsSHA() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let payload = Data("sealed-bytes".utf8)
        var stored: Data?
        StubURLProtocol.handler = { request in
            if request.url?.path == "/repos/developer/Exodia-Backup" {
                return (200, [:], try JSONSerialization.data(withJSONObject: ["name": "Exodia-Backup", "private": true]))
            }
            XCTAssertEqual(request.url?.path, "/repos/developer/Exodia-Backup/contents/whytap-sync/settings.v1.json")
            if request.httpMethod == "PUT" {
                let body = try JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies.last!) as! [String: Any]
                if stored != nil, body["sha"] as? String != "abc" { return (409, [:], Data()) }
                stored = Data(base64Encoded: body["content"] as! String)
                return (stored == nil ? 422 : 200, [:], try JSONSerialization.data(withJSONObject: ["content": ["sha": "abc"]]))
            }
            guard let stored else { return (404, [:], Data()) }
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"" { return (304, [:], Data()) }
            let base64 = stored.base64EncodedString().enumerated().map { $0.offset % 60 == 59 ? "\($0.element)\n" : "\($0.element)" }.joined()
            return (200, ["ETag": "\"e1\""], try JSONSerialization.data(withJSONObject: [
                "sha": "abc", "content": base64, "encoding": "base64", "size": stored.count]))
        }
        let transport = try GitHubBackupTransport(token: "token", owner: "developer", session: session)

        let missing = try await transport.fetchSyncFile(path: "whytap-sync/settings.v1.json", etag: nil)
        XCTAssertEqual(missing, .missing)
        let created = try await transport.putSyncFile(path: "whytap-sync/settings.v1.json", data: payload, sha: nil)
        XCTAssertEqual(created, "abc")
        let found = try await transport.fetchSyncFile(path: "whytap-sync/settings.v1.json", etag: nil)
        XCTAssertEqual(found, .found(data: payload, sha: "abc", etag: "\"e1\""))
        let notModified = try await transport.fetchSyncFile(path: "whytap-sync/settings.v1.json", etag: "\"e1\"")
        XCTAssertEqual(notModified, .notModified)
        do {
            _ = try await transport.putSyncFile(path: "whytap-sync/settings.v1.json", data: payload, sha: "stale")
            XCTFail("a stale SHA must not overwrite the file")
        } catch {
            XCTAssertEqual(error as? SettingsSyncFailure, .conflict)
        }
    }
}

/// Stores that keep their own copy pick up values another Mac wrote.
@MainActor
final class SettingsSyncLiveReloadTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "settings-sync-reload-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suite) }

    func testRoutingStoreReadsAnotherMacsRoutes() throws {
        let store = AIRoutingStore(defaults: defaults)
        XCTAssertNil(store.route(for: .agent))
        let route = FeatureRoute(account: .anthropic, model: "claude-opus-5-5")
        let state = AIRoutingState(routes: [AIFeature.agent.rawValue: route], migratedRoutes: [:], servers: [], migrationVersion: 4)
        defaults.set(try JSONEncoder().encode(state), forKey: AIRoutingStore.defaultsKey)

        store.reloadFromDefaults()

        XCTAssertEqual(store.route(for: .agent), route)
    }

    func testHotkeysPublishOnlyWhatChanged() {
        let preferences = HotkeyPreferences(defaults: defaults)
        let replacement = HotkeyConfiguration.defaults.agentCloseShortcut
        XCTAssertNotEqual(preferences.meetingRecordShortcut, replacement)
        var published = 0
        let subscription = preferences.$agentTextShortcut.dropFirst().sink { _ in published += 1 }
        defaults.set(replacement.rawValue, forKey: "hotkeys.meetingRecordShortcut")

        preferences.reloadFromDefaults()

        XCTAssertEqual(preferences.meetingRecordShortcut, replacement)
        XCTAssertEqual(published, 0, "an unchanged shortcut is not reassigned, so its hotkey is not rebuilt")
        subscription.cancel()
    }

    func testToolboxLayoutReloads() {
        let store = HoverLayoutStore(defaults: defaults)
        let original = store.slots
        let reordered = [original[1], original[0]] + original.dropFirst(2)
        defaults.set(reordered.map(\.rawValue), forKey: HoverLayoutStore.defaultsKey)

        store.reloadFromDefaults()

        XCTAssertEqual(store.slots, reordered)
    }
}

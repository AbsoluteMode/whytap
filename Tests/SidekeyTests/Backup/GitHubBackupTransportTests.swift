import CryptoKit
import XCTest
@testable import Sidekey

final class GitHubBackupTransportTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        super.setUp(); StubURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel(); session = nil; StubURLProtocol.reset(); super.tearDown()
    }
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
    private func repository(private isPrivate: Bool = true, name: String = "Exodia-Backup") -> Data {
        json(["name": name, "private": isPrivate, "permissions": ["push": true]])
    }

    func testRateLimitedForbiddenResponsesCarryTheirRetryDeadline() async throws {
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let deadline = Date().addingTimeInterval(3_600)
        for headers in [["Retry-After": "3600"],
                        ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(deadline.timeIntervalSince1970)]] {
            StubURLProtocol.handler = { _ in (403, headers, Data()) }
            do { try await transport.checkConnection(); XCTFail("Expected rate limit") }
            catch {
                guard case .rateLimited(let until) = error as? GitHubBackupTransport.Failure else {
                    XCTFail("Unexpected failure: \(error)"); continue
                }
                XCTAssertGreaterThanOrEqual(until.timeIntervalSince(deadline), -1)
                XCTAssertFalse((error as? GitHubBackupTransport.Failure)!.requiresReconnect)
            }
        }
        StubURLProtocol.handler = { _ in (403, [:], Data()) }
        do { try await transport.checkConnection(); XCTFail("Expected permission failure") }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .permission) }
    }

    func testExplicitDeletionWorksForPublicRepositoryAndIncludesDraftsButKeepsUnrelatedReleases() async throws {
        let kept = UUID(), old = UUID(), draft = UUID()
        func release(_ id: Int, _ tag: String, _ marker: String, draft: Bool = false) -> [String: Any] {
            ["id": id, "draft": draft, "tag_name": tag, "body": marker,
             "created_at": "2026-10-19T12:00:00Z", "assets": []]
        }
        var releases = [
            release(1, "exodia-backup-" + kept.uuidString.lowercased(), "exodia.encrypted-backup.v1"),
            release(2, "exodia-backup-" + old.uuidString.lowercased(), "exodia.encrypted-backup.v1"),
            release(3, "exodia-backup-" + draft.uuidString.lowercased(), "exodia.encrypted-backup.v1", draft: true),
            release(4, "unrelated", "exodia.encrypted-backup.v1"),
            release(5, "exodia-backup-" + UUID().uuidString.lowercased(), "User's release")
        ]
        var deleted: [Int] = []
        StubURLProtocol.handler = { request in
            let path = request.url!.path
            if path == "/repos/developer/Exodia-Backup" { return (200, [:], self.repository(private: false)) }
            if path == "/repos/developer/Exodia-Backup/releases" { return (200, [:], self.json(releases)) }
            guard let id = Int(path.components(separatedBy: "/").last!) else { XCTFail("Unexpected route"); return (500, [:], Data()) }
            if request.httpMethod == "DELETE" {
                deleted.append(id); releases.removeAll { ($0["id"] as? Int) == id }
                return (204, [:], Data())
            }
            return (releases.contains { ($0["id"] as? Int) == id } ? 200 : 404, [:], Data())
        }
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        try await transport.deleteBackups(except: kept)
        XCTAssertEqual(deleted, [2, 3])
        XCTAssertEqual(releases.compactMap { $0["id"] as? Int }, [1, 4, 5])
        try await transport.deleteBackups(except: kept)
        XCTAssertEqual(deleted, [2, 3], "Retry must not delete the replacement or unrelated releases")
        XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.httpMethod == "PATCH" || $0.httpMethod == "POST" })
    }

    func testDeletionRequiresAnAbsentReadbackAndDoesNotReportSuccessForAConcurrentUpload() async throws {
        let id = UUID()
        let release: [String: Any] = ["id": 7, "draft": false, "tag_name": "exodia-backup-" + id.uuidString.lowercased(),
            "body": "exodia.encrypted-backup.v1", "created_at": "2026-10-19T12:00:00Z", "assets": []]
        var readbackStatus = 200
        StubURLProtocol.handler = { request in
            if request.url!.path == "/repos/developer/Exodia-Backup" { return (200, [:], self.repository()) }
            if request.url!.path.hasSuffix("/releases") { return (200, [:], self.json([release])) }
            return (request.httpMethod == "DELETE" ? 204 : readbackStatus, [:], Data())
        }
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        do { try await transport.deleteBackups(); XCTFail("A delete response is not proof of removal") }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .incomplete) }
        readbackStatus = 404
        do { try await transport.deleteBackups(); XCTFail("A newly listed copy must keep cleanup pending") }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .incomplete) }
    }

    func testConnectCreatesOnlyAPrivateWhytapBackupRepositoryAndChecksTheResult() async throws {
        var seenRepository = false
        StubURLProtocol.handler = { request in
            if request.url!.path == "/user" { return (200, [:], self.json(["login": "developer"])) }
            if request.url!.path == "/user/repos" {
                let body = try JSONSerialization.jsonObject(with: StubURLProtocol.capturedBodies.last!) as! [String: Any]
                XCTAssertEqual(body["private"] as? Bool, true)
                XCTAssertEqual(body["auto_init"] as? Bool, true)
                XCTAssertEqual(body["name"] as? String, "Whytap-Backup")
                seenRepository = true
                return (201, [:], self.repository(name: "Whytap-Backup"))
            }
            if request.url!.path == "/repos/developer/Whytap-Backup", seenRepository {
                return (200, [:], self.repository(name: "Whytap-Backup"))
            }
            return (404, [:], Data())
        }
        let connection = try await GitHubBackupTransport.connect(token: "synthetic-token", session: session)
        let name = await connection.destinationName
        XCTAssertEqual(name, "developer/Whytap-Backup")
        XCTAssertEqual(StubURLProtocol.capturedRequests.map { $0.url!.path },
                       ["/user", "/repos/developer/Exodia-Backup", "/repos/developer/Whytap-Backup", "/user/repos", "/repos/developer/Whytap-Backup"])
        XCTAssertEqual(StubURLProtocol.capturedRequests.map { $0.url!.host! }, Array(repeating: "api.github.com", count: 5))
        XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.url!.absoluteString.contains("synthetic-token") })
    }

    func testConnectKeepsAnExistingExodiaBackupWithoutCreatingAnother() async throws {
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/user": return (200, [:], self.json(["login": "developer"]))
            case "/repos/developer/Exodia-Backup": return (200, [:], self.repository())
            default: XCTFail("unexpected request \(request.url!.path)"); return (404, [:], Data())
            }
        }
        let connection = try await GitHubBackupTransport.connect(token: "synthetic-token", session: session)
        let name = await connection.destinationName
        XCTAssertEqual(name, "developer/Exodia-Backup", "earlier backups stay reachable")
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testReconnectKeepsTheSavedRepositoryOnlyForTheSameAccount() async throws {
        StubURLProtocol.handler = { request in
            if request.url!.path == "/user" { return (200, [:], self.json(["login": "developer"])) }
            return (200, [:], self.repository(name: request.url!.lastPathComponent))   // both names exist
        }
        let same = try await GitHubBackupTransport.connect(token: "synthetic-token",
                                                           saved: (owner: "Developer", repository: "Whytap-Backup"), session: session)
        let kept = await same.destinationName
        XCTAssertEqual(kept, "developer/Whytap-Backup")
        let other = try await GitHubBackupTransport.connect(token: "synthetic-token",
                                                            saved: (owner: "someone-else", repository: "Whytap-Backup"), session: session)
        let found = await other.destinationName
        XCTAssertEqual(found, "developer/Exodia-Backup", "another account's choice does not carry over")
    }

    func testReconnectRefusesASavedRepositoryTheTokenCannotSee() async throws {
        StubURLProtocol.handler = { request in
            switch request.url!.path {
            case "/user": return (200, [:], self.json(["login": "developer"]))
            case "/repos/developer/Exodia-Backup": return (200, [:], self.repository())
            default: return (404, [:], Data())                     // the saved Whytap-Backup is hidden
            }
        }
        do {
            _ = try await GitHubBackupTransport.connect(token: "synthetic-token",
                                                        saved: (owner: "developer", repository: "Whytap-Backup"), session: session)
            XCTFail("a hidden saved repository must not switch the destination")
        } catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .permission) }
        XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.url!.path == "/repos/developer/Exodia-Backup" })
    }

    func testReconnectFollowsARenameOfTheSavedRepository() async throws {
        StubURLProtocol.handler = { request in
            if request.url!.path == "/user" { return (200, [:], self.json(["login": "developer"])) }
            return (200, [:], self.repository(name: "Whytap-Backup"))  // GitHub answers the old name with the new one
        }
        let connection = try await GitHubBackupTransport.connect(token: "synthetic-token",
                                                                 saved: (owner: "developer", repository: "Exodia-Backup"), session: session)
        let name = await connection.destinationName
        XCTAssertEqual(name, "developer/Whytap-Backup")
    }

    func testConnectFollowsAnExodiaBackupRenamedOnGitHub() async throws {
        StubURLProtocol.handler = { request in
            if request.url!.path == "/user" { return (200, [:], self.json(["login": "developer"])) }
            // GitHub answers the old name with the renamed repository.
            return (200, [:], self.repository(name: "Whytap-Backup"))
        }
        let connection = try await GitHubBackupTransport.connect(token: "synthetic-token", session: session)
        let name = await connection.destinationName
        XCTAssertEqual(name, "developer/Whytap-Backup")
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testOnlyTheTwoBackupRepositoryNamesAreAccepted() throws {
        let defaults = UserDefaults(suiteName: "repo-" + UUID().uuidString)!
        XCTAssertEqual(GitHubBackupTransport.savedRepository(defaults), "Exodia-Backup")
        defaults.set("Whytap-Backup", forKey: GitHubBackupTransport.repositoryDefaultsKey)
        XCTAssertEqual(GitHubBackupTransport.savedRepository(defaults), "Whytap-Backup")
        defaults.set("../other", forKey: GitHubBackupTransport.repositoryDefaultsKey)
        XCTAssertEqual(GitHubBackupTransport.savedRepository(defaults), "Exodia-Backup")
        XCTAssertThrowsError(try GitHubBackupTransport(token: "synthetic-token", owner: "developer", repository: "Other"))
        XCTAssertEqual(GitHubBackupTransport.backupURL(owner: "developer", repository: "Whytap-Backup")?.absoluteString,
                       "https://github.com/developer/Whytap-Backup/releases")
        XCTAssertNil(GitHubBackupTransport.backupURL(owner: "developer", repository: "Other"))
    }

    func testPublicDestinationIsRefusedWithoutChangingItsVisibility() async throws {
        StubURLProtocol.handler = { request in
            request.url!.path == "/user" ? (200, [:], self.json(["login": "developer"])) : (200, [:], self.repository(private: false))
        }
        do {
            _ = try await GitHubBackupTransport.connect(token: "synthetic-token", session: session)
            XCTFail("A public repository must not be used for new uploads")
        } catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .publicRepository) }
        XCTAssertTrue(StubURLProtocol.capturedRequests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testAnUnexpectedLoginCannotRedirectTheCredential() async throws {
        StubURLProtocol.handler = { _ in (200, [:], self.json(["login": "../other-host/"])) }
        do { _ = try await GitHubBackupTransport.connect(token: "synthetic-token", session: session); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .authentication) }
        XCTAssertEqual(StubURLProtocol.capturedRequests.count, 1)
    }

    func testVersionListHidesDraftAndMissingCompletionMarker() async throws {
        let validID = UUID(), draftID = UUID(), missingID = UUID()
        func release(_ uuid: UUID, id: Int, draft: Bool, complete: Bool) -> [String: Any] {
            ["id": id, "draft": draft, "tag_name": "exodia-backup-" + uuid.uuidString.lowercased(),
             "body": "exodia.encrypted-backup.v1", "created_at": "2026-10-19T12:00:00Z",
             "assets": complete ? [["id": 100 + id, "name": "complete.exodia-index", "size": 50, "state": "uploaded"]] : []]
        }
        StubURLProtocol.handler = { _ in
            (200, [:], self.json([release(validID, id: 1, draft: false, complete: true),
                                 release(draftID, id: 2, draft: true, complete: true),
                                 release(missingID, id: 3, draft: false, complete: false)]))
        }
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let versions = try await transport.versions()
        XCTAssertEqual(versions.map(\.id), [validID.uuidString])
    }

    func testUploadReadbackAndCleanDownloadIncludingResumedPublishedVersion() async throws {
        let fixture = RemoteFixture(json: json)
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("input.exodiabackup")
        // Crosses the transport part boundary. The archive engine tests the
        // actual ciphertext; this transport treats its input as opaque bytes.
        let input = Data(repeating: 0xA5, count: GitHubBackupTransport.partBytes + 127)
        try input.write(to: original)
        let key = ConfigBackupArchive.makeKey(), id = UUID()
        let summary = ArtifactBackupSummary(id: id, createdAt: Date(), totalBytes: Int64(input.count), fileCount: 2, sections: [.settings, .history])
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let releaseID = try await transport.upload(file: original, summary: summary, key: key)
        XCTAssertEqual(releaseID, 7)
        XCTAssertFalse(fixture.draft)
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "part-00001.bin", "complete.exodia-index"])
        XCTAssertEqual(fixture.publishCount, 1)
        let secondID = try await transport.upload(file: original, summary: summary, key: key)
        XCTAssertEqual(secondID, releaseID)
        XCTAssertEqual(fixture.uploadNames.count, 3, "Retry must reuse complete assets")
        let restored = root.appendingPathComponent("restored.exodiabackup")
        let version = BackupVersion(id: id.uuidString, createdAt: Date(), size: Int64(input.count), remoteID: releaseID)
        try await transport.download(version: version, to: restored, key: key)
        XCTAssertEqual(try Data(contentsOf: restored), input)
        XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.url!.absoluteString.contains("synthetic-token") })
    }

    func testAnInterruptedOrCorruptUploadNeverPublishesTheSnapshot() async throws {
        let fixture = RemoteFixture(json: json); fixture.corruptReadback = true
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 3, count: 100).write(to: file)
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 100, fileCount: 1, sections: [.settings])
        do { _ = try await transport.upload(file: file, summary: summary, key: ConfigBackupArchive.makeKey()); XCTFail() }
        catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, .incomplete) }
        XCTAssertTrue(fixture.draft); XCTAssertEqual(fixture.publishCount, 0)
        XCTAssertFalse(fixture.uploadNames.contains("complete.exodia-index"))
    }

    func testSignedAssetRedirectStripsTheTokenAndRejectsHTTPAndUnknownHosts() throws {
        let response = HTTPURLResponse(url: URL(string: "https://api.github.com/repos/developer/Exodia-Backup/releases/assets/1")!, statusCode: 302, httpVersion: nil, headerFields: [:])!
        var redirected = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/signed-object")!)
        redirected.setValue("Bearer synthetic-token", forHTTPHeaderField: "Authorization")
        redirected.setValue("synthetic-cookie", forHTTPHeaderField: "Cookie")
        let safe = try XCTUnwrap(GitHubBackupNetwork.redirectedRequest(redirected, from: response))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(safe.value(forHTTPHeaderField: "Cookie"))
        redirected.url = URL(string: "https://attacker.example/object")!
        XCTAssertNil(GitHubBackupNetwork.redirectedRequest(redirected, from: response))
        redirected.url = URL(string: "http://release-assets.githubusercontent.com/object")!
        XCTAssertNil(GitHubBackupNetwork.redirectedRequest(redirected, from: response))
    }

    func testDraftLookupAndResumeSurviveAnInterruptedReadback() async throws {
        let fixture = RemoteFixture(json: json); fixture.failOneReadback = true
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 7, count: 1000).write(to: file)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 1000, fileCount: 1, sections: [.settings])
        let key = ConfigBackupArchive.makeKey()
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        do { _ = try await transport.upload(file: file, summary: summary, key: key); XCTFail() } catch { }
        XCTAssertTrue(fixture.draft)
        _ = try await transport.upload(file: file, summary: summary, key: key)
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "complete.exodia-index"])
        XCTAssertEqual(fixture.publishCount, 1)
    }

    func testDeletedSavedDraftFallsBackToTheSnapshotTagAndRecordsTheNewDraft() async throws {
        let fixture = RemoteFixture(json: json)
        StubURLProtocol.handler = { request in
            // The draft whose ID the Mac saved was deleted on GitHub.
            if request.url!.path.hasSuffix("/releases/999") { return (404, [:], Data()) }
            return try fixture.handle(request)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 5, count: 1000).write(to: file)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 1000, fileCount: 1, sections: [.settings])
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        let drafts = DraftIDRecorder()
        let releaseID = try await transport.upload(file: file, summary: summary, key: ConfigBackupArchive.makeKey(),
                                                   resumeReleaseID: 999, onDraft: { await drafts.append($0) })
        XCTAssertEqual(releaseID, 7)
        let recorded = await drafts.ids
        XCTAssertEqual(recorded, [7], "The replacement draft ID is persisted for the next resume")
        XCTAssertFalse(fixture.draft)
        XCTAssertEqual(fixture.publishCount, 1)
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "complete.exodia-index"])
        XCTAssertEqual(StubURLProtocol.capturedRequests.filter { $0.url!.path.hasSuffix("/releases/999") }.count, 1)
        XCTAssertEqual(StubURLProtocol.capturedRequests.filter { $0.httpMethod == "POST" && $0.url!.host == "api.github.com" }.count, 1)
        XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.url!.absoluteString.contains("synthetic-token") })
    }

    func testStaleSavedDraftIDReusesTheSnapshotsExistingDraftWithoutADuplicate() async throws {
        let fixture = RemoteFixture(json: json); fixture.failOneReadback = true
        StubURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/releases/999") { return (404, [:], Data()) }
            return try fixture.handle(request)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 6, count: 1000).write(to: file)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 1000, fileCount: 1, sections: [.settings])
        let key = ConfigBackupArchive.makeKey()
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        do { _ = try await transport.upload(file: file, summary: summary, key: key); XCTFail() } catch { }
        XCTAssertTrue(fixture.draft)
        let drafts = DraftIDRecorder()
        let releaseID = try await transport.upload(file: file, summary: summary, key: key,
                                                   resumeReleaseID: 999, onDraft: { await drafts.append($0) })
        XCTAssertEqual(releaseID, 7)
        let recorded = await drafts.ids
        XCTAssertEqual(recorded, [7])
        XCTAssertEqual(StubURLProtocol.capturedRequests.filter { $0.httpMethod == "POST" && $0.url!.host == "api.github.com" }.count, 1,
                       "The snapshot's existing draft is found by its tag, not recreated")
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "complete.exodia-index"])
        XCTAssertEqual(fixture.publishCount, 1)
    }

    func testSavedDraftFallbackKeepsRealAccessFailures() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 9, count: 100).write(to: file)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 100, fileCount: 1, sections: [.settings])
        enum Scenario { case releaseForbidden, releaseUnauthorized, repositoryMissing, accessLostAfterRelease }
        let cases: [(Scenario, GitHubBackupTransport.Failure)] = [
            (.releaseForbidden, .permission), (.releaseUnauthorized, .authentication),
            (.repositoryMissing, .permission), (.accessLostAfterRelease, .permission)
        ]
        for (scenario, expected) in cases {
            StubURLProtocol.reset()
            let fixture = RemoteFixture(json: json)
            StubURLProtocol.handler = { request in
                let path = request.url!.path
                switch scenario {
                case .releaseForbidden where path.hasSuffix("/releases/999"): return (403, [:], Data())
                case .releaseUnauthorized where path.hasSuffix("/releases/999"): return (401, [:], Data())
                case .repositoryMissing where path.hasSuffix("/Exodia-Backup"): return (404, [:], Data())
                // The repository check passed, then every release endpoint is gone.
                case .accessLostAfterRelease where path.contains("/releases"): return (404, [:], Data())
                default: return try fixture.handle(request)
                }
            }
            let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
            let drafts = DraftIDRecorder()
            do {
                _ = try await transport.upload(file: file, summary: summary, key: ConfigBackupArchive.makeKey(),
                                               resumeReleaseID: 999, onDraft: { await drafts.append($0) })
                XCTFail("\(scenario) must not upload")
            } catch { XCTAssertEqual(error as? GitHubBackupTransport.Failure, expected, "\(scenario)") }
            let recorded = await drafts.ids
            XCTAssertTrue(recorded.isEmpty, "\(scenario)")
            XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.httpMethod == "POST" || $0.url!.host == "uploads.github.com" },
                           "\(scenario) must not create a draft or upload parts")
            if scenario == .repositoryMissing {
                XCTAssertFalse(StubURLProtocol.capturedRequests.contains { $0.url!.path.contains("/releases") },
                               "The private-repository gate runs before any release request")
            }
        }
    }

    func testPartSizingRespectsTheReleaseAssetLimitWithoutAllocatingLargeFiles() throws {
        for bytes: Int64 in [1, 16_777_217, 8 * 1024 * 1024 * 1024, 64 * 1024 * 1024 * 1024 + 2_000_000] {
            let part = try GitHubBackupTransport.partSize(for: bytes)
            XCTAssertLessThanOrEqual(part, GitHubBackupTransport.maximumPartBytes)
            XCTAssertLessThanOrEqual((bytes + Int64(part) - 1) / Int64(part), Int64(GitHubBackupTransport.maximumParts))
        }
        XCTAssertThrowsError(try GitHubBackupTransport.partSize(for: .max))
    }

    func testResumeConfirmsUploadedPartsByGitHubDigestWithoutDownloadingThemAndReportsProgress() async throws {
        let fixture = RemoteFixture(json: json); fixture.reportsDigests = true
        fixture.failReadbackOf = "part-00001.bin"
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var input = Data(repeating: 1, count: GitHubBackupTransport.partBytes * 2 + 5)
        input[GitHubBackupTransport.partBytes] = 2; input[GitHubBackupTransport.partBytes * 2] = 3
        try input.write(to: file)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: Int64(input.count), fileCount: 1, sections: [.settings])
        let key = ConfigBackupArchive.makeKey()
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        // A restart interrupts the upload after two parts reached GitHub.
        do { _ = try await transport.upload(file: file, summary: summary, key: key); XCTFail() } catch { }
        XCTAssertTrue(fixture.draft)
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "part-00001.bin"])
        let resumedFrom = StubURLProtocol.capturedRequests.count
        let progress = ProgressRecorder()
        _ = try await transport.upload(file: file, summary: summary, key: key,
                                       onProgress: { part, total in await progress.append(part, total) })
        let resumed = StubURLProtocol.capturedRequests[resumedFrom...]
        let downloaded = resumed.filter { $0.httpMethod == "GET" && $0.url!.path.contains("/releases/assets/") }
            .map { Int($0.url!.lastPathComponent)! }
        XCTAssertFalse(downloaded.contains(assetID("part-00000.bin", in: fixture)), "An already uploaded part is not downloaded again")
        XCTAssertFalse(downloaded.contains(assetID("part-00001.bin", in: fixture)))
        XCTAssertEqual(downloaded, [assetID("part-00002.bin", in: fixture), assetID("complete.exodia-index", in: fixture)],
                       "Only the new part and the index are read back")
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "part-00001.bin", "part-00002.bin", "complete.exodia-index"])
        XCTAssertEqual(fixture.publishCount, 1)
        let reported = await progress.steps
        XCTAssertEqual(reported.map { $0.part }, [1, 2, 3])
        XCTAssertEqual(Set(reported.map { $0.total }), [3])
    }

    func testMismatchedGitHubDigestReplacesTheDraftPartWithoutDownloadingTheOldBytes() async throws {
        let fixture = RemoteFixture(json: json); fixture.reportsDigests = true; fixture.failOneReadback = true
        StubURLProtocol.handler = { request in try fixture.handle(request) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 9, count: 1000).write(to: file)
        let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 1000, fileCount: 1, sections: [.settings])
        let key = ConfigBackupArchive.makeKey()
        let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
        do { _ = try await transport.upload(file: file, summary: summary, key: key); XCTFail() } catch { }
        let stale = assetID("part-00000.bin", in: fixture)
        fixture.assets[0]["digest"] = "sha256:" + String(repeating: "0", count: 64)
        let resumedFrom = StubURLProtocol.capturedRequests.count
        _ = try await transport.upload(file: file, summary: summary, key: key)
        let resumed = StubURLProtocol.capturedRequests[resumedFrom...]
        XCTAssertTrue(resumed.contains { $0.httpMethod == "DELETE" && $0.url!.lastPathComponent == String(stale) })
        XCTAssertFalse(resumed.contains { $0.httpMethod == "GET" && $0.url!.lastPathComponent == String(stale) })
        XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "part-00000.bin", "complete.exodia-index"])
        XCTAssertEqual(fixture.publishCount, 1)
    }

    func testPartsWithoutAUsableDigestAreComparedByOneDownload() async throws {
        for digest in [nil, "sha512:" + String(repeating: "a", count: 128), "sha256:short"] {
            StubURLProtocol.reset()
            let fixture = RemoteFixture(json: json); fixture.failOneReadback = true
            StubURLProtocol.handler = { request in try fixture.handle(request) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            try Data(repeating: 4, count: 1000).write(to: file)
            let summary = ArtifactBackupSummary(id: UUID(), createdAt: Date(), totalBytes: 1000, fileCount: 1, sections: [.settings])
            let key = ConfigBackupArchive.makeKey()
            let transport = try GitHubBackupTransport(token: "synthetic-token", owner: "developer", session: session)
            do { _ = try await transport.upload(file: file, summary: summary, key: key); XCTFail() } catch { }
            if let digest { fixture.assets[0]["digest"] = digest }
            let part = assetID("part-00000.bin", in: fixture)
            let resumedFrom = StubURLProtocol.capturedRequests.count
            _ = try await transport.upload(file: file, summary: summary, key: key)
            let reads = StubURLProtocol.capturedRequests[resumedFrom...].filter { $0.httpMethod == "GET" && $0.url!.lastPathComponent == String(part) }
            XCTAssertEqual(reads.count, 1, "digest \(digest ?? "none"): the matching part is downloaded once, not compared and read back again")
            XCTAssertEqual(fixture.uploadNames, ["part-00000.bin", "complete.exodia-index"])
            XCTAssertEqual(fixture.publishCount, 1)
        }
    }

    private func assetID(_ name: String, in fixture: RemoteFixture) -> Int {
        fixture.assets.first { $0["name"] as? String == name }?["id"] as? Int ?? -1
    }

    private typealias RemoteFixture = BackupGitHubFixture
}

private actor DraftIDRecorder {
    private(set) var ids: [Int] = []
    func append(_ id: Int) { ids.append(id) }
}

private actor ProgressRecorder {
    private(set) var steps: [(part: Int, total: Int)] = []
    func append(_ part: Int, _ total: Int) { steps.append((part, total)) }
}

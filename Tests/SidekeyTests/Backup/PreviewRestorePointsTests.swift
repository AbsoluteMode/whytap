import Darwin
import XCTest
@testable import Sidekey

/// Same-Mac restore points around preview builds: made by the outgoing app with
/// Whytap quit, put back byte for byte by the startup restore transaction, never
/// carrying provider keys or Case. Each test covers one class from the queue
/// review of ticket 639.
/// WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
@MainActor
final class PreviewRestorePointsTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []

    override func tearDown() async throws {
        profiles.forEach { $0.tearDown() }
        profiles.removeAll()
    }

    private func makeProfile() throws -> ArtifactBackupTestProfile {
        var profile = try ArtifactBackupTestProfile()
        profile.addCredential("openrouter", "sk-before")
        profiles.append(profile)
        return profile
    }

    private func environment(_ profile: ArtifactBackupTestProfile,
                             faults: ArtifactBackupFaults = ArtifactBackupFaults()) -> ArtifactBackupEnvironment {
        var environment = profile.environment(faults: faults)
        environment.defaultsDomain = profile.defaultsSuite
        return environment
    }

    private func run(_ arguments: [String], _ profile: ArtifactBackupTestProfile, leaseFree: Bool = true,
                     available: Int64? = nil) -> (code: Int32, json: [String: Any]) {
        var lines: [String] = []
        let code = PreviewRestorePoints.execute(
            arguments, environment: environment(profile),
            lease: { leaseFree ? NSObject() : nil }, available: { _ in available },
            output: { lines.append($0) })
        let json = (try? JSONSerialization.jsonObject(with: Data((lines.last ?? "{}").utf8))) as? [String: Any]
        return (code, json ?? [:])
    }

    private func create(_ profile: ArtifactBackupTestProfile) throws -> String {
        let result = run(["create", "--reason", "preview #1 build 1801"], profile)
        XCTAssertEqual(result.code, 0, "\(result.json)")
        return try XCTUnwrap((result.json["restore_point"] as? [String: Any])?["id"] as? String)
    }

    private func mode(_ url: URL) -> UInt16 {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0, url.path)
        return UInt16(info.st_mode & 0o7777)
    }

    private func apply(_ id: String, _ profile: ArtifactBackupTestProfile, sections: String? = nil) throws {
        let result = run(["apply", id] + (sections.map { ["--sections", $0] } ?? []), profile)
        XCTAssertEqual(result.code, 0, "\(result.json)")
        try ArtifactBackupEngine.applyPendingRestore(environment: environment(profile))
    }

    // MARK: Review item 4: a same-Mac rollback round-trips every covered thing

    func testARollbackPutsBackExactlyWhatThisMacHad() throws {
        var profile = try makeProfile()
        let l = profile.locations
        let notify = l.notifyRoot.appendingPathComponent("sources/build.json")
        let worker = l.notifyRoot.appendingPathComponent("workers/poll.sh")
        let servers = l.monitorRoot.appendingPathComponent("servers.json")
        let cache = l.monitorRoot.appendingPathComponent("cache/.whytap-cache/state.bin")
        let link = l.agentWorkspace.appendingPathComponent("current")
        let planner = l.plannerArchive
        profile.defaults.set(true, forKey: "lilBro.mascotVisible")      // outside the backup allowlist
        profile.defaults.set("deepgram", forKey: "sidekey.models.byokProvider")
        profile.defaults.set("before", forKey: "backup.last-outcome.v1")  // preserved prefix
        try profile.write("{\"enabled\": true}", to: notify)
        try profile.write("#!/bin/sh\necho ok\n", to: worker)
        XCTAssertEqual(chmod(worker.path, 0o755), 0)
        try profile.write("{\"servers\": [\"prod\"]}", to: servers)
        try profile.write(Data([0, 1, 2, 255]), to: cache)
        try profile.write("# Memory before the preview", to: l.agentMemory)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "AGENTS.md")
        try profile.write("{\"tasks\": [1]}", to: planner)
        let id = try create(profile)

        // The preview ran: settings, files, modes and links changed, files were
        // added and removed, a covered folder appeared, and the owner rotated a key.
        profile.defaults.set(false, forKey: "lilBro.mascotVisible")
        profile.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        profile.defaults.set(1, forKey: "preview.newKey")
        profile.defaults.set("after", forKey: "backup.last-outcome.v1")
        try profile.write("{\"enabled\": false}", to: notify)
        XCTAssertEqual(chmod(worker.path, 0o600), 0)
        try FileManager.default.removeItem(at: cache)
        try profile.write("# Memory written by the preview", to: l.agentMemory)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp")
        try profile.write("new", to: l.monitorRoot.appendingPathComponent("added-by-preview.json"))
        let projects = l.bundleRoot.appendingPathComponent("projects/catalog.json")
        try profile.write("{}", to: projects)
        profile.addCredential("openrouter", "sk-rotated")

        try apply(id, profile)

        XCTAssertEqual(profile.defaults.object(forKey: "lilBro.mascotVisible") as? Bool, true)
        XCTAssertEqual(profile.defaults.string(forKey: "sidekey.models.byokProvider"), "deepgram")
        XCTAssertNil(profile.defaults.object(forKey: "preview.newKey"))
        XCTAssertEqual(profile.defaults.string(forKey: "backup.last-outcome.v1"), "after")
        XCTAssertEqual(profile.contents(of: notify), "{\"enabled\": true}")
        XCTAssertEqual(mode(worker), 0o755)
        XCTAssertEqual(profile.contents(of: servers), "{\"servers\": [\"prod\"]}")
        XCTAssertEqual(try Data(contentsOf: cache), Data([0, 1, 2, 255]))
        XCTAssertEqual(profile.contents(of: l.agentMemory), "# Memory before the preview")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "AGENTS.md")
        XCTAssertFalse(profile.exists(l.monitorRoot.appendingPathComponent("added-by-preview.json")))
        XCTAssertFalse(profile.exists(projects.deletingLastPathComponent()))  // absent at capture
        XCTAssertEqual(profile.contents(of: planner), "{\"tasks\": [1]}")
        XCTAssertEqual(profile.credentialStores["openrouter"]?.value, "sk-rotated")
        // Nothing parked or renamed, and what the rollback replaced is kept.
        XCTAssertFalse(profile.exists(l.monitorRoot.appendingPathComponent(
            "servers.json" + ArtifactRestoreDestination.parkedSuffix)))
        let checkpoint = try XCTUnwrap(environment(profile).transaction().recoveryCheckpoint())
        XCTAssertGreaterThan(checkpoint.fileCount, 0)
        XCTAssertFalse(checkpoint.includesProviderKeys)
        XCTAssertFalse(environment(profile).transaction().hasPendingWork)
    }

    /// Ticket 652 item 1: a link that points nowhere still occupies its path. Inside
    /// a covered root it goes to the checkpoint with the root; as a covered root
    /// itself (created by the preview, or replacing a root present at capture) it
    /// is never followed: the restore fails before committing and leaves the
    /// pre-apply state as it was.
    func testDanglingLinksAreNeverMistakenForAbsentEntries() throws {
        let profile = try makeProfile()
        let l = profile.locations
        try profile.write("{\"servers\": []}", to: l.monitorRoot.appendingPathComponent("servers.json"))
        try profile.write("# Before", to: l.agentMemory)
        let id = try create(profile)  // Notify root absent at capture

        let inside = l.monitorRoot.appendingPathComponent("dangling.json")
        try FileManager.default.createSymbolicLink(atPath: inside.path, withDestinationPath: "/nonexistent/x")
        try apply(id, profile, sections: "workspace")
        XCTAssertFalse(ArtifactRestoreTransaction.entryExists(inside))

        let cases: [(String, URL)] = [("created by the preview", l.notifyRoot),
                                      ("replacing a captured root", l.monitorRoot)]
        for (name, root) in cases {
            if ArtifactRestoreTransaction.entryExists(root) { try FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: "/nonexistent/\(name)")
            try profile.write("# Preview", to: l.agentMemory)
            XCTAssertEqual(run(["apply", id, "--sections", "workspace"], profile).code, 0, name)
            XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment(profile)), name)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.path),
                           "/nonexistent/\(name)", name)
            XCTAssertEqual(profile.contents(of: l.agentMemory), "# Preview", name)
            try FileManager.default.removeItem(at: root)
            _ = try? environment(profile).transaction().cancelPlanned()
            environment(profile).transaction().disarm()
        }
    }

    func testCostsKeepWhatWasSpentWhileThePreviewRan() async throws {
        let profile = try makeProfile()
        func event(_ id: String) -> AIUsageEvent {
            AIUsageEvent(id: id, createdAt: Date(timeIntervalSince1970: 1_800_000_000),
                         context: .init(feature: .dropSmartCleanup, account: .openRouter, model: "vendor/model"),
                         currency: .usd, amount: 0.01, basis: .reported, audioSeconds: 0)
        }
        try FileManager.default.createDirectory(at: profile.locations.bundleRoot, withIntermediateDirectories: true)
        try await AIUsageStore(url: profile.locations.usageDatabase).insert(event("before"))
        let id = try create(profile)
        try await AIUsageStore(url: profile.locations.usageDatabase).insert(event("during"))
        try apply(id, profile, sections: "history")
        let ids = try await AIUsageStore(url: profile.locations.usageDatabase)
            .events(from: .distantPast, to: .distantFuture).map(\.id).sorted()
        XCTAssertEqual(ids, ["before", "during"])
    }

    func testOnlyTheChosenSectionsAreRestored() throws {
        let profile = try makeProfile()
        profile.defaults.set("deepgram", forKey: "sidekey.models.byokProvider")
        try profile.write("# Before", to: profile.locations.agentMemory)
        let id = try create(profile)
        profile.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        try profile.write("# Kept", to: profile.locations.agentMemory)
        let result = run(["apply", id, "--sections", "settings"], profile)
        XCTAssertEqual(result.json["sections"] as? [String], ["settings"])  // what was actually staged
        try ArtifactBackupEngine.applyPendingRestore(environment: environment(profile))
        XCTAssertEqual(profile.defaults.string(forKey: "sidekey.models.byokProvider"), "deepgram")
        XCTAssertEqual(profile.contents(of: profile.locations.agentMemory), "# Kept")
    }

    func testAnInterruptedRollbackPutsThePreviewStateBack() throws {
        let profile = try makeProfile()
        profile.defaults.set("deepgram", forKey: "sidekey.models.byokProvider")
        try profile.write("# Before", to: profile.locations.agentMemory)
        let id = try create(profile)
        profile.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        try profile.write("# Preview", to: profile.locations.agentMemory)
        for stage in [ArtifactRestoreStage.checkpoint, .files, .metadata] {
            XCTAssertEqual(run(["apply", id], profile).code, 0, "\(stage)")
            var faults = ArtifactBackupFaults()
            faults.interruptAfter = { $0 == stage }
            XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(
                environment: environment(profile, faults: faults))) {
                XCTAssertTrue($0 is ArtifactRestoreInterruption, "\(stage): \($0)")
            }
            XCTAssertThrowsError(try ArtifactBackupEngine.applyPendingRestore(environment: environment(profile))) {
                XCTAssertEqual($0 as? ArtifactBackupError, .restoreInterrupted, "\(stage)")
            }
            XCTAssertEqual(profile.defaults.string(forKey: "sidekey.models.byokProvider"), "soniox", "\(stage)")
            XCTAssertEqual(profile.contents(of: profile.locations.agentMemory), "# Preview", "\(stage)")
        }
        try apply(id, profile)
        XCTAssertEqual(profile.contents(of: profile.locations.agentMemory), "# Before")
        XCTAssertEqual(profile.defaults.string(forKey: "sidekey.models.byokProvider"), "deepgram")
    }

    // MARK: Review item 1: the command is parsed whole

    func testEveryMalformedCommandIsRefusedBeforeAnythingChanges() throws {
        let profile = try makeProfile()
        let id = try create(profile)
        let malformed: [[String]] = [
            [], ["unknown"], ["list", "--all"], ["list", "x"],
            ["create"], ["create", "--reason"], ["create", "--reason", ""], ["create", "--reason", "  "],
            ["create", "--reason", "--sections"], ["create", "--reason", "a", "--reason", "b"],
            ["create", "--reason", "a", "extra"], ["create", "--flag", "a"],
            ["create", "--reason", "line\nbreak"], ["create", "--reason", String(repeating: "x", count: 201)],
            ["apply"], ["apply", "not-a-uuid"], ["apply", id, "--sections"], ["apply", id, "--section", "settings"],
            ["apply", id, "--sections", ""], ["apply", id, "--sections", "settings,"],
            ["apply", id, "--sections", ",settings"], ["apply", id, "--sections", "settings,settings"],
            ["apply", id, "--sections", "settings,bogus"], ["apply", id, "--sections", "credentials"],
            ["apply", id, "--sections", "caseVault"], ["apply", id, "--sections", "settings", "extra"],
            ["apply", id, "--sections", "settings", "--sections", "planner"], ["apply", id, id],
        ]
        for arguments in malformed {
            XCTAssertEqual(run(arguments, profile).code, 2, "\(arguments)")
        }
        XCTAssertFalse(environment(profile).transaction().hasPendingWork)
        XCTAssertEqual(PreviewRestorePoints.Store(locations: profile.locations).records().count, 1)
        XCTAssertEqual(try PreviewRestorePoints.parse(["apply", id.uppercased(), "--sections", "planner,settings"]),
                       .apply(UUID(uuidString: id)!, [.planner, .settings]))
    }

    // MARK: Review item 2: one exclusive hold for the whole operation

    func testCreateAndApplyNeedTheInstanceLeaseButListDoesNot() throws {
        let profile = try makeProfile()
        let id = try create(profile)
        XCTAssertEqual(run(["create", "--reason", "x"], profile, leaseFree: false).code, 3)
        XCTAssertEqual(run(["apply", id], profile, leaseFree: false).code, 3)
        XCTAssertFalse(environment(profile).transaction().hasPendingWork)
        XCTAssertEqual(PreviewRestorePoints.Store(locations: profile.locations).records().count, 1)
        let listed = run(["list"], profile, leaseFree: false)
        XCTAssertEqual(listed.code, 0)
        XCTAssertEqual((listed.json["restore_points"] as? [[String: Any]])?.first?["id"] as? String, id)
        // The lease itself: one holder at a time until it is released.
        let directory = profile.root.appendingPathComponent("instance", isDirectory: true)
        guard case .acquired(let first) = try ApplicationInstanceLease.acquire(directory: directory, ownerPID: 1) else {
            return XCTFail("the first holder gets the lease")
        }
        guard case .busy = try ApplicationInstanceLease.acquire(directory: directory, ownerPID: 2) else {
            return XCTFail("a second holder must wait")
        }
        first.release()
        guard case .acquired = try ApplicationInstanceLease.acquire(directory: directory, ownerPID: 2) else {
            return XCTFail("released")
        }
    }

    // MARK: Review item 3: another restore is never displaced

    func testAParkedOrUnfinishedRestoreIsNeverReplaced() throws {
        let profile = try makeProfile()
        try profile.write("# Before", to: profile.locations.agentMemory)
        let first = try create(profile)
        let second = try create(profile)
        XCTAssertEqual(run(["apply", first], profile).code, 0)
        let parked = try XCTUnwrap(environment(profile).transaction().plannedRestore())
        let refused = run(["apply", second], profile)
        XCTAssertEqual(refused.code, 1)
        XCTAssertTrue((refused.json["error"] as? String)?.contains("parked or unfinished") ?? false, "\(refused.json)")
        XCTAssertEqual(environment(profile).transaction().plannedRestore(), parked)
        // Evidence of an unfinished restore is protected the same way as a plan.
        XCTAssertTrue(try environment(profile).transaction().cancelPlanned())
        XCTAssertFalse(environment(profile).transaction().hasPendingWork)
        let journal = profile.locations.pendingRestoreRoot.appendingPathComponent("journal.json")
        try profile.write("{}", to: journal)
        XCTAssertTrue(environment(profile).transaction().hasPendingWork)
        XCTAssertEqual(run(["apply", second], profile).code, 1)
        XCTAssertNil(environment(profile).transaction().plannedRestore())
        XCTAssertEqual(profile.contents(of: journal), "{}")
    }

    // MARK: Review item 5: publication, permissions, numbers and damage

    func testRestorePointsArePrivateWholeAndValidated() throws {
        let profile = try makeProfile()
        try profile.write("# Before", to: profile.locations.agentMemory)
        let store = PreviewRestorePoints.Store(locations: profile.locations)
        try store.prepare()
        // Unpublished work from an interrupted create is never a restore point.
        let leftover = store.root.appendingPathComponent(".incoming-" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let id = try create(profile)
        XCTAssertFalse(profile.exists(leftover))
        XCTAssertEqual(mode(store.root), 0o700)
        let point = store.directory(UUID(uuidString: id)!)
        XCTAssertEqual(mode(point), 0o700)
        XCTAssertEqual(mode(point.appendingPathComponent(PreviewRestorePoints.recordName)), 0o600)
        XCTAssertEqual(mode(point.appendingPathComponent(LocalRestoreSnapshot.manifestName)), 0o600)
        // Records that are not restore points: bad numbers, bad sections, another ID.
        let good = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: point.appendingPathComponent(
            PreviewRestorePoints.recordName))) as? [String: Any])
        let changes: [[String: Any]] = [
            ["sequence": Int.max], ["sequence": 0], ["sequence": -1], ["archiveBytes": -1],
            ["archiveBytes": Int64.max], ["sections": [String]()], ["sections": ["credentials"]],
            ["sections": ["settings", "settings"]], ["reason": String(repeating: "x", count: 201)],
            ["id": UUID().uuidString],
        ]
        for (index, change) in changes.enumerated() {
            let other = UUID()
            var record = good.merging(change) { $1 }
            if change["id"] == nil { record["id"] = other.uuidString }
            let directory = store.directory(other)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: record).write(
                to: directory.appendingPathComponent(PreviewRestorePoints.recordName))
            XCTAssertEqual(store.records().map { $0.id.uuidString.lowercased() }, [id], "case \(index)")
        }
        // A tampered snapshot is refused before anything is parked.
        try Data("# Tampered".utf8).write(to: point.appendingPathComponent("files/agent/AGENTS.md"))
        XCTAssertEqual(run(["apply", id], profile).code, 1)
        XCTAssertFalse(environment(profile).transaction().hasPendingWork)
    }

    func testOldRestorePointsArePrunedButNeverTheParkedOne() throws {
        let profile = try makeProfile()
        try profile.write("# Before", to: profile.locations.agentMemory)
        let first = try create(profile)
        XCTAssertEqual(run(["apply", first], profile).code, 0)
        for _ in 0..<(PreviewRestorePoints.kept + 1) { _ = try create(profile) }
        let store = PreviewRestorePoints.Store(locations: profile.locations)
        XCTAssertEqual(store.records().count, PreviewRestorePoints.kept + 1)  // kept + the parked one
        XCTAssertTrue(store.records().contains { $0.id.uuidString.lowercased() == first })
        try ArtifactBackupEngine.applyPendingRestore(environment: environment(profile))
        _ = try create(profile)
        XCTAssertEqual(store.records().count, PreviewRestorePoints.kept)
        XCTAssertFalse(store.records().contains { $0.id.uuidString.lowercased() == first })
        let refused = run(["create", "--reason", "no space"], profile, available: 1)
        XCTAssertEqual(refused.code, 1)
        XCTAssertTrue((refused.json["error"] as? String)?.contains("Not enough free space") ?? false)
        XCTAssertEqual(store.records().count, PreviewRestorePoints.kept)
    }
}

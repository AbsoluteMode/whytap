import XCTest
@testable import Sidekey

/// Restore points around preview builds: made by the outgoing app, applied by
/// the existing restore transaction, never carrying provider keys or Case.
/// WHY: .project-docs/decisions/2026-11-26-preview-restore-points.md
@MainActor
final class PreviewRestorePointsTests: XCTestCase {
    private var profiles: [ArtifactBackupTestProfile] = []

    override func tearDown() async throws {
        profiles.forEach { $0.tearDown() }
        profiles.removeAll()
    }

    private func profile() throws -> ArtifactBackupTestProfile {
        var profile = try ArtifactBackupTestProfile()
        profile.addCredential("openrouter", "sk-before")
        profile.defaults.set("deepgram", forKey: "sidekey.models.byokProvider")
        try profile.write("# Memory before the preview", to: profile.locations.agentMemory)
        profiles.append(profile)
        return profile
    }

    private func store(_ profile: ArtifactBackupTestProfile) -> PreviewRestorePoints.Store {
        PreviewRestorePoints.Store(locations: profile.locations, keyStore: MemoryTokenStore())
    }

    func testARestorePointCarriesDataButNeverKeysOrCase() async throws {
        let profile = try profile()
        let store = store(profile)
        let record = try await PreviewRestorePoints.create(
            reason: "preview #1", environment: profile.environment(), store: store, available: { _ in nil })
        XCTAssertEqual(store.records().map(\.id), [record.id])
        XCTAssertTrue(Set(record.sections).isSubset(of: PreviewRestorePoints.sections))
        XCTAssertFalse(record.sections.contains(.credentials))
        XCTAssertFalse(record.sections.contains(.caseVault))
        XCTAssertTrue(record.sections.contains(.workspace))
        let preview = try await ArtifactBackupEngine(environment: profile.environment())
            .inspectArchive(at: store.archiveURL(record.id), key: store.key(create: false))
        XCTAssertFalse(preview.summary.sections.contains(.credentials))
    }

    func testRollbackRestoresDataKeepsKeysAndRetainsWhatItReplaced() async throws {
        var profile = try profile()
        let store = store(profile)
        let record = try await PreviewRestorePoints.create(
            reason: "preview #1", environment: profile.environment(), store: store, available: { _ in nil })
        // The preview ran: it changed a setting and a file, and the owner
        // rotated a provider key meanwhile.
        profile.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        try profile.write("# Memory written by the preview", to: profile.locations.agentMemory)
        profile.addCredential("openrouter", "sk-rotated")

        _ = try await PreviewRestorePoints.stage(id: record.id, environment: profile.environment(), store: store)
        try ArtifactBackupEngine.applyPendingRestore(environment: profile.environment())

        XCTAssertEqual(profile.defaults.string(forKey: "sidekey.models.byokProvider"), "deepgram")
        XCTAssertEqual(profile.contents(of: profile.locations.agentMemory), "# Memory before the preview")
        XCTAssertEqual(try profile.credentialStores["openrouter"]?.read(), "sk-rotated")
        // What the rollback replaced is kept on this Mac, not destroyed.
        XCTAssertNotNil(ArtifactBackupEngine(environment: profile.environment()).recoveryCheckpoint())
    }

    func testOnlyTheChosenSectionsAreRestored() async throws {
        let profile = try profile()
        let store = store(profile)
        let record = try await PreviewRestorePoints.create(
            reason: "preview #2", environment: profile.environment(), store: store, available: { _ in nil })
        profile.defaults.set("soniox", forKey: "sidekey.models.byokProvider")
        try profile.write("# Kept", to: profile.locations.agentMemory)
        _ = try await PreviewRestorePoints.stage(id: record.id, only: [.settings],
                                                 environment: profile.environment(), store: store)
        try ArtifactBackupEngine.applyPendingRestore(environment: profile.environment())
        XCTAssertEqual(profile.defaults.string(forKey: "sidekey.models.byokProvider"), "deepgram")
        XCTAssertEqual(profile.contents(of: profile.locations.agentMemory), "# Kept")
    }

    func testOldRestorePointsArePrunedAndShortSpaceRefusesCleanly() async throws {
        let profile = try profile()
        let store = store(profile)
        for index in 0..<(PreviewRestorePoints.kept + 2) {
            _ = try await PreviewRestorePoints.create(
                reason: "preview \(index)", environment: profile.environment(), store: store,
                available: { _ in nil })
        }
        XCTAssertEqual(store.records().count, PreviewRestorePoints.kept)
        XCTAssertEqual(store.records().first?.reason, "preview \(PreviewRestorePoints.kept + 1)")
        do {
            _ = try await PreviewRestorePoints.create(
                reason: "no space", environment: profile.environment(), store: store, available: { _ in 1 })
            XCTFail("a restore point needs free space")
        } catch let failure as PreviewRestorePoints.Failure {
            guard case .diskSpace = failure else { return XCTFail("\(failure)") }
        }
        XCTAssertEqual(store.records().count, PreviewRestorePoints.kept)
    }

    func testTheCommandLineRefusesWhileWhytapRunsAndReportsJSON() async throws {
        let profile = try profile()
        let store = store(profile)
        var lines: [String] = []
        let running = await PreviewRestorePoints.execute(
            ["create", "--reason", "x"], environment: profile.environment(), store: store,
            otherInstanceRunning: { true }, output: { lines.append($0) })
        XCTAssertEqual(running, 3)
        XCTAssertTrue(lines.last?.contains("quit it") ?? false)
        var result: Int32
        result = await PreviewRestorePoints.execute(
            ["apply", "not-a-uuid"], environment: profile.environment(), store: store,
            otherInstanceRunning: { false }, output: { lines.append($0) })
        XCTAssertEqual(result, 2)
        result = await PreviewRestorePoints.execute(
            ["apply", UUID().uuidString], environment: profile.environment(), store: store,
            otherInstanceRunning: { false }, output: { lines.append($0) })
        XCTAssertEqual(result, 1)
        result = await PreviewRestorePoints.execute(
            ["create", "--reason", "preview #3"], environment: profile.environment(), store: store,
            otherInstanceRunning: { false }, output: { lines.append($0) })
        XCTAssertEqual(result, 0)
        let id = try XCTUnwrap(store.records().first?.id.uuidString)
        result = await PreviewRestorePoints.execute(
            ["apply", id, "--sections", "settings,bogus"], environment: profile.environment(),
            store: store, otherInstanceRunning: { false }, output: { lines.append($0) })
        XCTAssertEqual(result, 2)
        result = await PreviewRestorePoints.execute(
            ["list"], environment: profile.environment(), store: store,
            otherInstanceRunning: { false }, output: { lines.append($0) })
        XCTAssertEqual(result, 0)
        let listed = try JSONSerialization.jsonObject(with: Data(lines.last!.utf8)) as? [String: Any]
        XCTAssertEqual((listed?["restore_points"] as? [[String: Any]])?.first?["reason"] as? String,
                       "preview #3")
    }
}

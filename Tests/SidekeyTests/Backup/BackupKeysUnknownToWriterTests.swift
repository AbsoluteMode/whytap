import XCTest
@testable import Sidekey

/// Restoring settings resets a preference missing from the backup only when
/// the app that wrote the backup could have saved it. Keys added later keep
/// their current values.
/// WHY: .project-docs/decisions/2026-11-28-backup-keys-unknown-to-the-writer.md
@MainActor
final class BackupKeysUnknownToWriterTests: XCTestCase {
    private let googleText = "hotkeys.googleSearchTextShortcut"
    private let googleVoice = "hotkeys.googleSearchVoiceShortcut"
    private let googleGesture = "hotkeys.googleSearchVoiceGesture"
    private let agentText = "hotkeys.agentTextShortcut"
    private let hoverSlot1 = "hotkeys.hoverSlot1Shortcut"

    private func restore(_ payload: ArtifactSettingsPayload, into target: ArtifactBackupTestProfile) async throws {
        let archive = target.root.appendingPathComponent(UUID().uuidString + ".exodiabackup")
        let key = ArtifactBackupTestKeys.make()
        _ = try ArtifactBackupTestArchive.make(at: archive, key: key, entries: [
            ("settings/preferences.json", .settings, try JSONEncoder.artifactBackup.encode(payload))])
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: archive, key: key, sections: [.settings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
    }

    private func setGoogleShortcuts(_ defaults: UserDefaults) {
        defaults.set("google-text", forKey: googleText)
        defaults.set("google-voice", forKey: googleVoice)
        defaults.set("hold", forKey: googleGesture)
    }

    /// The reported scenario: after updating, the user sets Google Search
    /// shortcuts, then restores Hotkeys from a 2.2.27 archive. That archive
    /// could not contain them, so they stay; keys it did know are restored or
    /// reset as before.
    func testRestoringHotkeysFromA2_2_27ArchiveKeepsTheGoogleSearchShortcuts() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown() }
        setGoogleShortcuts(target.defaults)
        target.defaults.set("changed-after-backup", forKey: agentText)
        target.defaults.set("slot-after-backup", forKey: hoverSlot1)
        // Exactly what 2.2.27 wrote: schema 4, no list of known keys.
        let payload = ArtifactSettingsPayload(values: [agentText: .string("from-archive")], selectedSections: [.hotkeys])
        XCTAssertFalse(String(decoding: try JSONEncoder.artifactBackup.encode(payload), as: UTF8.self).contains("knownKeys"))

        try await restore(payload, into: target)

        XCTAssertEqual(target.defaults.string(forKey: googleText), "google-text")
        XCTAssertEqual(target.defaults.string(forKey: googleVoice), "google-voice")
        XCTAssertEqual(target.defaults.string(forKey: googleGesture), "hold")
        XCTAssertEqual(target.defaults.string(forKey: agentText), "from-archive")
        XCTAssertNil(target.defaults.string(forKey: hoverSlot1), "a key 2.2.27 knew but had no value for is reset as before")
    }

    /// An archive from an app that knew the Google keys and had no value for
    /// them resets them, like any other key it knew.
    func testArchiveWhoseWriterKnewTheKeysResetsThem() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown() }
        setGoogleShortcuts(target.defaults)
        let payload = ArtifactSettingsPayload(values: [:], selectedSections: [.hotkeys],
                                              knownKeys: ConfigBackupRegistry.entries.keys.sorted())
        try await restore(payload, into: target)
        XCTAssertNil(target.defaults.string(forKey: googleText))
        XCTAssertNil(target.defaults.string(forKey: googleVoice))
        XCTAssertNil(target.defaults.string(forKey: googleGesture))
    }

    /// The class, not one instance: any key missing from the writer's list
    /// keeps its value, so later additions need no new exception.
    func testAnyKeyTheWriterDidNotKnowKeepsItsValue() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown() }
        target.defaults.set("slot-now", forKey: hoverSlot1)
        target.defaults.set("agent-now", forKey: agentText)
        let known = ConfigBackupRegistry.entries.keys.filter { $0 != hoverSlot1 }.sorted()
        let payload = ArtifactSettingsPayload(values: [:], selectedSections: [.hotkeys], knownKeys: known)
        try await restore(payload, into: target)
        XCTAssertEqual(target.defaults.string(forKey: hoverSlot1), "slot-now")
        XCTAssertNil(target.defaults.string(forKey: agentText))
    }

    /// Backups written now list their known keys: restoring one from a Mac
    /// where the Google shortcuts were never set resets them on this Mac.
    func testANewBackupCarriesItsKnownKeys() async throws {
        let source = try ArtifactBackupTestProfile(), target = try ArtifactBackupTestProfile()
        defer { source.tearDown(); target.tearDown() }
        source.defaults.set("agent-source", forKey: agentText)
        setGoogleShortcuts(target.defaults)
        let file = source.root.appendingPathComponent("new.exodiabackup"), key = ArtifactBackupTestKeys.make()
        _ = try await ArtifactBackupEngine(environment: source.environment()).createArchive(at: file, key: key, sections: [.settings])
        let environment = target.environment()
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: file, key: key, sections: [.settings])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.defaults.string(forKey: agentText), "agent-source")
        XCTAssertNil(target.defaults.string(forKey: googleText))
    }

    /// Settings history: a Hotkeys snapshot taken by 2.2.27 keeps the Google
    /// shortcuts, while "App defaults" still resets every hotkey.
    func testSettingsHistoryBlockFromAnOlderSnapshotKeepsNewKeysAndDefaultsResetThem() async throws {
        let target = try ArtifactBackupTestProfile()
        defer { target.tearDown() }
        setGoogleShortcuts(target.defaults)
        let key = ArtifactBackupTestKeys.make()
        let folder = target.root.appendingPathComponent("settings", isDirectory: true)
        var old = ConfigBackupSnapshot(reason: "2.2.27", preferences: [agentText: .string("old")])
        old.knownKeys = nil
        let decoded = try JSONDecoder().decode(ConfigBackupSnapshot.self, from: try JSONEncoder().encode(old))
        XCTAssertNil(decoded.knownKeys, "a snapshot saved without the list decodes without it")

        let environment = target.environment()
        let (oldFile, group) = try BackupSettingsBlockRestore.archive(decoded, section: .hotkeys, key: key, directory: folder)
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: oldFile, key: key, sections: [group])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertEqual(target.defaults.string(forKey: agentText), "old")
        XCTAssertEqual(target.defaults.string(forKey: googleText), "google-text")

        let defaultsSnapshot = ConfigBackupSnapshot(reason: "App defaults", preferences: [:])
        let (resetFile, resetGroup) = try BackupSettingsBlockRestore.archive(defaultsSnapshot, section: .hotkeys, key: key, directory: folder)
        try await ArtifactBackupEngine(environment: environment).stageRestore(from: resetFile, key: key, sections: [resetGroup])
        _ = try ArtifactBackupEngine.applyPendingRestore(environment: environment)
        XCTAssertNil(target.defaults.string(forKey: agentText))
        XCTAssertNil(target.defaults.string(forKey: googleText))
    }
}

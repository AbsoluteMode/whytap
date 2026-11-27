import XCTest
@testable import Sidekey

/// The chosen Subtitles engine travels with Keys & models backups and sync.
/// WHY: .project-docs/decisions/2026-11-27-subtitle-engine-choice.md
@MainActor
final class SubtitleEngineRestoreTests: XCTestCase {
    func testRestoringModelPreferencesKeepsTheChosenSubtitleProvider() throws {
        let names = ["source", "destination"].map { "queue-725-" + $0 + UUID().uuidString }
        let source = try XCTUnwrap(UserDefaults(suiteName: names[0]))
        let destination = try XCTUnwrap(UserDefaults(suiteName: names[1]))
        defer {
            source.removePersistentDomain(forName: names[0])
            destination.removePersistentDomain(forName: names[1])
        }
        source.set(SubtitleAudioTranslate.Engine.openAI.rawValue, forKey: SubtitleAudioTranslate.engineChoiceKey)
        let captured = try ConfigBackupRegistry.capture(source)
        try ConfigBackupRegistry.apply(captured, sections: [.models], to: destination)
        let choice = SubtitleAudioTranslate.storedChoice(destination)
        XCTAssertEqual(choice, .openAI)
        let present = SubtitleAudioTranslate.KeyState(ProviderKeyStore.KeyLookup.key("fixture"))
        XCTAssertEqual(SubtitleAudioTranslate.engine(choice: choice, soniox: present, openAI: present), .openAI)
    }

    /// Both engines survive a restore with both keys present, and an older
    /// profile without a choice clears a choice the destination had.
    func testBothEnginesAndAnOlderProfileWithoutAChoice() throws {
        func suite() throws -> (UserDefaults, String) {
            let name = "subtitle-restore-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            addTeardownBlock { defaults.removePersistentDomain(forName: name) }
            return (defaults, name)
        }
        let present = SubtitleAudioTranslate.KeyState(ProviderKeyStore.KeyLookup.key("fixture"))
        for engine in [SubtitleAudioTranslate.Engine.soniox, .openAI] {
            let (source, _) = try suite(), (destination, _) = try suite()
            source.set(engine.rawValue, forKey: SubtitleAudioTranslate.engineChoiceKey)
            try ConfigBackupRegistry.apply(try ConfigBackupRegistry.capture(source), sections: [.models], to: destination)
            let choice = SubtitleAudioTranslate.storedChoice(destination)
            XCTAssertEqual(choice, engine)
            XCTAssertEqual(SubtitleAudioTranslate.engine(choice: choice, soniox: present, openAI: present), engine)
        }
        let (older, _) = try suite(), (destination, _) = try suite()
        destination.set(SubtitleAudioTranslate.Engine.openAI.rawValue, forKey: SubtitleAudioTranslate.engineChoiceKey)
        try ConfigBackupRegistry.apply(try ConfigBackupRegistry.capture(older), sections: [.models], to: destination)
        XCTAssertNil(SubtitleAudioTranslate.storedChoice(destination), "the restored profile had no choice: by the keys")
        XCTAssertEqual(SubtitleAudioTranslate.engine(choice: nil, soniox: present, openAI: present), .soniox)
    }

    /// Settings Sync carries the choice as a Keys & models preference, and
    /// the next Start reads it from UserDefaults without a relaunch.
    func testSyncCarriesTheChoiceAndStartReadsItLive() throws {
        XCTAssertEqual(ConfigBackupRegistry.entries[SubtitleAudioTranslate.engineChoiceKey]?.section, .models)
        let name = "subtitle-live-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var lookups: [String] = []
        let keys = ProviderKeyStore { account in
            lookups.append(account)
            let slot = InMemoryTokenStore(account: account)
            try? slot.save("fixture")
            return slot
        }
        XCTAssertEqual(try SubtitleAudioTranslate.engineAndKey(from: keys, choice: SubtitleAudioTranslate.storedChoice(defaults)).0, .soniox)
        defaults.set(SubtitleAudioTranslate.Engine.openAI.rawValue, forKey: SubtitleAudioTranslate.engineChoiceKey)
        XCTAssertEqual(try SubtitleAudioTranslate.engineAndKey(from: keys, choice: SubtitleAudioTranslate.storedChoice(defaults)).0, .openAI)
    }
}

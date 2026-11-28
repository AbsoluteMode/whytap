import XCTest
@testable import Sidekey

/// A newer harness choice survives an older check's result, and Subtitles
/// read only the Keychain account they need (build-queue probe 725).
/// WHY: .project-docs/decisions/2026-11-27-agent-harness-cli.md
@MainActor
final class HarnessAndSubtitleRouteTests: XCTestCase {
    private final class UnreadableStore: TokenStore, @unchecked Sendable {
        func save(_ token: String) throws {}
        func read() throws -> String? { throw NSError(domain: "fixture", code: 1) }
        func delete() throws {}
    }

    private func defaults() throws -> UserDefaults {
        let suite = "harness-route-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A synced selection that lands while a pick's check is still running
    /// wins: the older pick's success does not replace it.
    func testASyncedChoiceDuringAPickCheckIsKept() async throws {
        let defaults = try defaults()
        let store = AgentProviderStore(defaults: defaults)
        let settings = AgentSettingsStore(defaults: defaults, codexConfig: .init(), whytapMCPCommand: { nil })
        let model = HarnessSettingsModel(store: store, settings: settings, probe: { id in
            if id == .claude {
                // The other Mac's choice arrives while Claude Code is checked.
                defaults.set(CLIProviderID.codex.rawValue, forKey: AgentProviderStore.key)
                store.reload()
            }
            return .connected(sessionID: nil)
        }, refreshClaude: { _ in }, refreshCodex: { _ in })
        await model.choose(.claude)
        XCTAssertEqual(store.activeProvider, .codex)
        XCTAssertNil(model.attempted)
    }

    /// A pick that failed is re-checked by Check again only while it is still
    /// the newest choice; after a synced selection the active one is checked.
    func testAFailedPickIsSupersededByASyncedChoice() async throws {
        let defaults = try defaults()
        let store = AgentProviderStore(defaults: defaults)
        let settings = AgentSettingsStore(defaults: defaults, codexConfig: .init(), whytapMCPCommand: { nil })
        var installed: Set<CLIProviderID> = [.claude]
        var probes: [CLIProviderID] = []
        let model = HarnessSettingsModel(store: store, settings: settings, probe: { id in
            probes.append(id)
            return installed.contains(id) ? .connected(sessionID: nil) : .notInstalled
        }, refreshClaude: { _ in }, refreshCodex: { _ in })
        await model.choose(.claude)
        await model.choose(.codex)
        XCTAssertEqual(store.activeProvider, .claude, "a failed pick changes nothing")
        XCTAssertEqual(model.attempted, .codex, "its problem is shown")
        installed.insert(.codex)
        defaults.set(CLIProviderID.claude.rawValue, forKey: AgentProviderStore.key)
        store.reload()
        XCTAssertEqual(model.attempted, .codex, "the same active harness: the pick still stands")

        // Codex is then installed and Check again makes the failed pick active.
        await model.refresh()
        XCTAssertEqual(store.activeProvider, .codex)
        XCTAssertNil(model.attempted)
        XCTAssertEqual(probes, [.claude, .codex, .codex])
    }

    /// Missing and unreadable keys name only the account that was read.
    func testSubtitlesReportTheChosenAccountOnlyWhenItIsMissingOrUnreadable() {
        let soniox = BYOKKeyStore.account(for: .soniox)
        let openAI = SubtitleAudioTranslate.keychainAccount
        for (state, expected) in [("missing", SubtitleAudioTranslate.Unavailable.missingKey(.openAI)),
                                  ("unreadable", .unreadableKey(.openAI))] {
            var lookups: [String] = []
            let keys = ProviderKeyStore { account in
                lookups.append(account)
                if account == openAI && state == "unreadable" { return UnreadableStore() }
                let slot = InMemoryTokenStore(account: account)
                if account == soniox { try? slot.save("fixture") }
                return slot
            }
            XCTAssertThrowsError(try SubtitleAudioTranslate.engineAndKey(from: keys, choice: .openAI)) {
                XCTAssertEqual($0 as? SubtitleAudioTranslate.Unavailable, expected, state)
            }
            XCTAssertEqual(lookups, [openAI], "a chosen engine never reads the other key")
        }
        // No choice and no usable Soniox key: OpenAI is read next, once.
        var lookups: [String] = []
        let keys = ProviderKeyStore { account in
            lookups.append(account)
            let slot = InMemoryTokenStore(account: account)
            if account == openAI { try? slot.save("fixture") }
            return slot
        }
        XCTAssertEqual(try SubtitleAudioTranslate.engineAndKey(from: keys, choice: nil).0, .openAI)
        XCTAssertEqual(lookups, [soniox, openAI])
    }

    func testNewSelectionFromSyncSurvivesCheckingTheActiveProvider() async throws {
        let suite = "queue-725-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AgentProviderStore(defaults: defaults)
        let settings = AgentSettingsStore(defaults: defaults, codexConfig: .init(), whytapMCPCommand: { nil })
        var probes: [CLIProviderID] = []
        let model = HarnessSettingsModel(store: store, settings: settings, probe: {
            probes.append($0)
            return .connected(sessionID: nil)
        }, refreshClaude: { _ in }, refreshCodex: { _ in })
        await model.choose(.claude)
        defaults.set(CLIProviderID.codex.rawValue, forKey: AgentProviderStore.key)
        store.reload()
        XCTAssertEqual(store.activeProvider, .codex)
        await model.refresh()
        XCTAssertEqual(probes.last, .codex)
        XCTAssertEqual(store.activeProvider, .codex)
    }

    func testSubtitlesOnlyLookUpTheNecessaryCredential() throws {
        for choice: SubtitleAudioTranslate.Engine? in [.soniox, .openAI, nil] {
            var lookups: [String] = []
            let keys = ProviderKeyStore { account in
                lookups.append(account)
                let slot = InMemoryTokenStore()
                try? slot.save("fixture")
                return slot
            }
            _ = try SubtitleAudioTranslate.engineAndKey(from: keys, choice: choice)
            let expected = choice == .openAI ? SubtitleAudioTranslate.keychainAccount : BYOKKeyStore.account(for: .soniox)
            XCTAssertEqual(lookups, [expected], String(describing: choice))
        }
    }
}

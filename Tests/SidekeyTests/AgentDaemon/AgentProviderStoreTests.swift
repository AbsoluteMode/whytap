import XCTest
@testable import Sidekey

@MainActor
final class AgentProviderStoreTests: XCTestCase {
    func testConnectingOneClearsTheOther() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = AgentProviderStore(defaults: defaults)
        store.markConnected(.claude)
        XCTAssertEqual(store.activeProvider, .claude)
        store.markConnected(.codex)
        XCTAssertEqual(store.activeProvider, .codex)   // radio: only one
    }
    func testPersistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        AgentProviderStore(defaults: defaults).markConnected(.claude)
        XCTAssertEqual(AgentProviderStore(defaults: defaults).activeProvider, .claude)
    }

    func testConnectingAlsoRecordsThePick() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = AgentProviderStore(defaults: defaults)
        store.markConnected(.codex)
        XCTAssertEqual(store.preferredProvider, .codex)
    }

    /// A pick made while the CLI is still being installed must survive, so the
    /// chooser reopens on the user's provider instead of the Claude default.
    func testPreferredSurvivesWithoutConnecting() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        AgentProviderStore(defaults: defaults).selectPreferred(.codex)
        let reloaded = AgentProviderStore(defaults: defaults)
        XCTAssertEqual(reloaded.preferredProvider, .codex)
        XCTAssertNil(reloaded.activeProvider, "a pick is not a connection")
    }

    func testDisconnectClearsActiveButKeepsThePick() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = AgentProviderStore(defaults: defaults)
        store.markConnected(.codex)
        store.disconnect()
        XCTAssertNil(store.activeProvider)
        XCTAssertEqual(store.preferredProvider, .codex)
    }
}

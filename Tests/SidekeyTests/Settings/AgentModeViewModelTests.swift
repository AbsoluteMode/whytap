import XCTest
@testable import Sidekey

@MainActor
final class AgentModeViewModelTests: XCTestCase {
    func testConnectSuccessMarksActiveAndPostsConnectedNotice() async {
        let store = AgentProviderStore(defaults: UserDefaults(suiteName: #function)!)
        var notices: [AgentConnectNotice] = []
        let vm = AgentModeViewModel(
            store: store,
            probe: { _ in .connected(sessionID: "s") },
            notify: { notices.append($0) }
        )
        await vm.connect(.claude)
        XCTAssertEqual(store.activeProvider, .claude)
        XCTAssertEqual(notices, [.connected(.claude)])
    }
    func testNotInstalledPostsInstallNotice() async {
        let store = AgentProviderStore(defaults: UserDefaults(suiteName: #function)!)
        var notices: [AgentConnectNotice] = []
        let vm = AgentModeViewModel(store: store, probe: { _ in .notInstalled }, notify: { notices.append($0) })
        await vm.connect(.claude)
        XCTAssertNil(store.activeProvider)
        XCTAssertEqual(notices, [.notInstalled(.claude)])
    }
    func testNotLoggedInPostsLoginNotice() async {
        let store = AgentProviderStore(defaults: UserDefaults(suiteName: #function)!)
        var notices: [AgentConnectNotice] = []
        let vm = AgentModeViewModel(store: store, probe: { _ in .notLoggedIn }, notify: { notices.append($0) })
        await vm.connect(.claude)
        XCTAssertNil(store.activeProvider)
        XCTAssertEqual(notices, [.notLoggedIn(.claude)])
    }
}

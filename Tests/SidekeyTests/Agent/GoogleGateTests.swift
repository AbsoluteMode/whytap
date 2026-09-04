import XCTest
@testable import Sidekey

final class GoogleGateTests: XCTestCase {

    // MARK: - gatedGoogleCallback: () -> Void

    func test_googleCallback_noOp_whenDisabled() {
        var ran = false
        let gated = AppDelegate.gatedGoogleCallback(isEnabled: { false }) { ran = true }
        gated()
        XCTAssertFalse(ran)
    }

    func test_googleCallback_runs_whenEnabled() {
        var ran = false
        let gated = AppDelegate.gatedGoogleCallback(isEnabled: { true }) { ran = true }
        gated()
        XCTAssertTrue(ran)
    }

    func test_googleCallback_readsIsEnabledOnEachCall() {
        // The flag is read-on-use: toggling between calls changes behaviour.
        var enabled = false
        var ran = false
        let gated = AppDelegate.gatedGoogleCallback(isEnabled: { enabled }) { ran = true }

        gated()
        XCTAssertFalse(ran, "should not run while disabled")

        enabled = true
        gated()
        XCTAssertTrue(ran, "should run after flag flips to true")
    }

    // MARK: - gatedGoogleCallbackWithArg: (String) -> Void

    func test_googleCallbackWithArg_noOp_whenDisabled() {
        var received: String? = nil
        let gated = AppDelegate.gatedGoogleCallbackWithArg(isEnabled: { false }) {
            received = $0
        }
        gated("hello")
        XCTAssertNil(received)
    }

    func test_googleCallbackWithArg_runs_whenEnabled() {
        var received: String? = nil
        let gated = AppDelegate.gatedGoogleCallbackWithArg(isEnabled: { true }) {
            received = $0
        }
        gated("hello")
        XCTAssertEqual(received, "hello")
    }
}

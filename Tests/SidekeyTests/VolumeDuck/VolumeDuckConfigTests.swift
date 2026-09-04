import XCTest
@testable import Sidekey

@MainActor
final class VolumeDuckConfigTests: XCTestCase {
    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "volumeduck.test.\(UUID().uuidString)")!
    }

    func test_defaultsToEnabled_whenUnset() {
        XCTAssertTrue(VolumeDuckConfig(defaults: suite()).isEnabled)
    }

    func test_storesAndReadsBack() {
        let d = suite()
        VolumeDuckConfig(defaults: d).isEnabled = false
        XCTAssertFalse(VolumeDuckConfig(defaults: d).isEnabled)
    }
}

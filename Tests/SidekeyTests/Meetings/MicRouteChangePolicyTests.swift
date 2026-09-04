import XCTest
@testable import Sidekey

final class MicRouteChangePolicyTests: XCTestCase {
    func test_restartDebounceWaitsOutBluetoothRouteChurn() {
        XCTAssertGreaterThanOrEqual(
            MicRouteChangePolicy.restartDebounceNanoseconds,
            2_500_000_000
        )
        XCTAssertLessThanOrEqual(
            MicRouteChangePolicy.restartDebounceNanoseconds,
            4_000_000_000
        )
    }
}

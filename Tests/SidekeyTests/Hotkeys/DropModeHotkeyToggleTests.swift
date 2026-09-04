import XCTest
@testable import Sidekey

@MainActor
final class DropModeHotkeyToggleTests: XCTestCase {

    func testPublishStoresModeAndBumpsToken() {
        let state = AppState.shared
        state.publishDropModeHotkeyToggle(.smart)
        let first = state.dropModeHotkeyToggle
        XCTAssertEqual(first?.mode, .smart)

        state.publishDropModeHotkeyToggle(.smart)
        let second = state.dropModeHotkeyToggle
        XCTAssertEqual(second?.mode, .smart)
        // Тот же mode дважды подряд = два разных события (токен растёт),
        // иначе SwiftUI .onChange не сработает на повторном ⌥1⌥1.
        XCTAssertNotEqual(first, second)
        XCTAssertGreaterThan(second?.token ?? 0, first?.token ?? 0)
    }

    func testPublishAlternatingModes() {
        let state = AppState.shared
        state.publishDropModeHotkeyToggle(.fast)
        XCTAssertEqual(state.dropModeHotkeyToggle?.mode, .fast)
        state.publishDropModeHotkeyToggle(.smart)
        XCTAssertEqual(state.dropModeHotkeyToggle?.mode, .smart)
    }
}

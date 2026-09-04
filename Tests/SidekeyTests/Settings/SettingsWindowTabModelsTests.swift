import XCTest
@testable import Sidekey

final class SettingsWindowTabModelsTests: XCTestCase {
    func testModelsTabExistsWithTitleAndId() {
        XCTAssertTrue(SettingsWindowTab.allCases.contains(.models))
        XCTAssertEqual(SettingsWindowTab.models.title, "Models")
        XCTAssertEqual(SettingsWindowTab.models.id, "models")
        XCTAssertFalse(SettingsWindowTab.models.fallbackSystemImageName.isEmpty)
    }
}

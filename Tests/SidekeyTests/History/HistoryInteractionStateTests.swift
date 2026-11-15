import XCTest
@testable import Sidekey

@MainActor
final class HistoryInteractionStateTests: XCTestCase {
    func testRememberedFilterDefaultsToClipboardAndPersistsAcrossInstances() {
        let suite = "history-interaction-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let history = HistoryInteractionState(userDefaults: defaults)
        XCTAssertEqual(history.rememberedFilter(), .clipboard)
        history.rememberFilter(.drop)

        let reopened = HistoryInteractionState(userDefaults: defaults)
        XCTAssertEqual(reopened.rememberedFilter(), .drop)
    }

    func testLosingTheEditableTargetClearsThePasteDestination() {
        let history = HistoryInteractionState()
        XCTAssertNil(history.targetAppName)
        history.setTargetAppName("TextEdit")
        XCTAssertEqual(history.targetAppName, "TextEdit")
        history.setTargetAppName(nil)
        XCTAssertNil(history.targetAppName)
    }
}

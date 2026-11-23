import XCTest
@testable import Sidekey

/// The island and Toolbox each keep their own Filler editor model for a long
/// time. A term added or removed in one must show in the other.
/// WHY: .project-docs/decisions/2026-11-23-drop-learning-shelved.md
@MainActor
final class FillerEditorsSyncTests: XCTestCase {
    func testAManualAddAndRemoveInOneEditorShowInTheOther() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "filler-sync.\(UUID().uuidString)"))
        let island = IslandFillerViewModel(store: FillerTermsStore(defaults: defaults))
        let toolbox = IslandFillerViewModel(store: FillerTermsStore(defaults: defaults))

        island.query = "короче"
        island.submitCurrentQuery()
        XCTAssertEqual(toolbox.terms, ["короче"], "Toolbox sees the island's add")

        toolbox.removeTerm("короче")
        XCTAssertEqual(island.terms, [], "The island sees Toolbox's remove")
    }
}

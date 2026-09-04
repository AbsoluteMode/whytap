import XCTest
@testable import Sidekey

@MainActor
final class IslandTileTitleTests: XCTestCase {
    func test_multi_word_title_breaks_per_word() {
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Input Language"), "INPUT\nLANGUAGE")
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Drop Mode"), "DROP\nMODE")
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Output Language"), "OUTPUT\nLANGUAGE")
    }

    func test_single_word_title_stays_one_line() {
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Hotkeys"), "HOTKEYS")
        XCTAssertEqual(IslandHoverPanelControl.displayTitle("Filler"), "FILLER")
    }
}

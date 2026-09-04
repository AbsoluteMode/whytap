import XCTest
@testable import Sidekey

/// `SettingsWindowView` shell state: the sidebar selection model that ships
/// next to the view. The SwiftUI surface itself is verified by visual
/// inspection; the selection model drives which detail pane renders.
@MainActor
final class SettingsWindowViewTests: XCTestCase {

    func test_selection_defaults_to_models_tab() {
        XCTAssertEqual(SettingsWindowSelection().selectedTab, .models)
    }

    func test_selection_starting_on_notes_leaves_to_default_tab() {
        let selection = SettingsWindowSelection(selectedTab: .notes)
        XCTAssertEqual(selection.selectedTab, .notes)

        selection.leaveNotes()

        XCTAssertEqual(selection.selectedTab, .models)
    }

    func test_selection_remembers_last_non_notes_tab() {
        let selection = SettingsWindowSelection()
        selection.select(.other)
        selection.select(.notes)
        XCTAssertEqual(selection.selectedTab, .notes)

        selection.leaveNotes()

        XCTAssertEqual(selection.selectedTab, .other)
    }

    func test_highlighting_a_tab_also_selects_it() {
        let selection = SettingsWindowSelection()

        selection.setHighlight(.tab(.hotkeys))

        XCTAssertEqual(selection.highlightedTarget, .tab(.hotkeys))
        XCTAssertEqual(selection.selectedTab, .hotkeys)
    }

    func test_highlighting_quit_row_keeps_current_tab() {
        let selection = SettingsWindowSelection()
        selection.select(.other)

        selection.setHighlight(.quitRow)

        XCTAssertEqual(selection.highlightedTarget, .quitRow)
        XCTAssertEqual(selection.selectedTab, .other)
    }
}

import XCTest

final class MeetingsDetailViewStyleTests: XCTestCase {
    /// Note/Transcribe live in the controller's `NotesTopBar` now; the detail
    /// pane exposes a programmatic tab API and the controller navigates between
    /// a list screen and an editor screen (no split view).
    func test_tabs_live_in_topbar_navigation_not_split() throws {
        let root = try projectRoot()

        let topbar = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/Meetings/NotesTopBar.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(topbar.contains("NSSegmentedControl"))

        let detail = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/Meetings/MeetingsDetailView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(detail.contains("func showTab"))
        XCTAssertFalse(detail.contains("NSSegmentedControl("))

        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/Meetings/MeetingsContentController.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(controller.contains("NSSplitViewController"))
        XCTAssertTrue(controller.contains("NotesTopBar"))
    }

    func test_linear_task_action_uses_linear_logo_not_external_link_icon() throws {
        let root = try projectRoot()

        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/Meetings/MeetingProtocolView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("UsefulLinkIconAsset.image(for: \"linear\")"))
        XCTAssertFalse(source.contains("arrow.up.forward.square"))
    }

    func test_note_reader_has_native_share_button() throws {
        let root = try projectRoot()

        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/Meetings/MeetingsDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Label(\"Share\", systemImage: \"square.and.arrow.up\")"))
        XCTAssertTrue(source.contains("model.shareCurrentNote()"))
        XCTAssertTrue(source.contains("NSSharingServicePicker"))
    }

    func test_note_actions_are_reserved_above_content_not_overlaid_on_title() throws {
        let root = try projectRoot()

        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Sidekey/Meetings/MeetingsDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("private var noteToolbar: some View"))
        XCTAssertFalse(source.contains("ZStack(alignment: .topTrailing)"))
    }

    private func projectRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            let candidate = url.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw NSError(domain: "MeetingsDetailViewStyleTests", code: 1)
    }
}

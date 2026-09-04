import AppKit
import SwiftUI
import XCTest
@testable import Sidekey

/// `SettingsWindowController` integration with the new settings shell.
/// Asserts the controller wires the Aurora window chrome correctly and
/// opens on the Models tab by default.
@MainActor
final class SettingsWindowControllerTests: XCTestCase {

    func test_window_controller_constructs_window_with_expected_metadata() {
        let controller = SettingsWindowController()

        let window = controller.window
        XCTAssertNotNil(window)
        XCTAssertEqual(window?.title, "Whytap Settings")
        XCTAssertTrue(window?.styleMask.contains(.titled) ?? false)
        XCTAssertTrue(window?.styleMask.contains(.closable) ?? false)
        XCTAssertTrue(window?.styleMask.contains(.resizable) ?? false)
        XCTAssertTrue(window?.styleMask.contains(.fullSizeContentView) ?? false)
        XCTAssertTrue(window?.titlebarAppearsTransparent ?? false)
        XCTAssertEqual(window?.titleVisibility, .hidden)
        XCTAssertEqual(window?.backgroundColor, .clear)
        XCTAssertFalse(window?.isOpaque ?? true)
        XCTAssertFalse(window?.hasShadow ?? true)
        XCTAssertEqual(window?.level.rawValue, NSWindow.Level.statusBar.rawValue)
        XCTAssertTrue(window?.collectionBehavior.contains(.canJoinAllSpaces) ?? false)
        XCTAssertFalse(window?.collectionBehavior.contains(.stationary) ?? true)
        XCTAssertFalse(window?.collectionBehavior.contains(.ignoresCycle) ?? true)
        XCTAssertTrue(window?.collectionBehavior.contains(.fullScreenAuxiliary) ?? false)
        XCTAssertFalse(window?.collectionBehavior.contains(.fullScreenNone) ?? true)
        // Reuse the same window across menu activations.
        XCTAssertFalse(window?.isReleasedWhenClosed ?? true)
    }

    func test_window_controller_opens_models_by_default() {
        let controller = SettingsWindowController()

        XCTAssertEqual(controller.selectedTab, .models)
    }

    func test_configureToolboxDepsRefreshesHostedSettingsRoot() throws {
        let controller = SettingsWindowController()
        var deps = ToolboxDeps()
        deps.currentDropMode = { .smart }

        controller.configure(toolboxDeps: deps)

        let hosting = try XCTUnwrap(
            controller.window?.contentViewController as? NSHostingController<SettingsWindowView>
        )
        XCTAssertEqual(hosting.rootView.toolboxDeps.currentDropMode(), .smart)
    }

    func test_showSchedulesDeferredRecenterAfterKeyOrdering() throws {
        let sourceURL = try projectRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Settings")
            .appendingPathComponent("SettingsWindowController.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard let showRange = source.range(of: "func show(tab: SettingsWindowTab = .models)") else {
            XCTFail("SettingsWindowController should keep an explicit show(tab:) entrypoint.")
            return
        }
        let showSource = source[showRange.lowerBound...]
        guard let keyOrderRange = showSource.range(of: "window.makeKeyAndOrderFront(nil)"),
              let deferredCenterRange = showSource.range(
                of: "SidekeyWindowChrome.centerOnMainScreenAfterNextLayout(window)"
              ) else {
            XCTFail("show(tab:) should make the window key, then schedule a deferred recenter.")
            return
        }

        XCTAssertLessThan(
            keyOrderRange.lowerBound,
            deferredCenterRange.lowerBound,
            "Deferred recentering should happen after key ordering so first SwiftUI layout cannot shift Settings."
        )
    }

    func test_window_controller_can_show_hotkeys_tab() async {
        let controller = SettingsWindowController()

        controller.show(tab: .hotkeys)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.selectedTab, .hotkeys)
    }

    func test_window_controller_can_show_permissions_tab() async {
        let controller = SettingsWindowController()

        controller.show(tab: .permissions)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.selectedTab, .permissions)
    }

    func test_window_controller_can_show_notes_tab() async {
        let controller = SettingsWindowController()

        controller.show(tab: .notes)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.selectedTab, .notes)
    }

    func test_notes_back_navigation_returns_to_previous_settings_tab() {
        let selection = SettingsWindowSelection(selectedTab: .models)

        selection.select(.hotkeys)
        selection.select(.notes)
        XCTAssertEqual(selection.selectedTab, .notes)

        selection.leaveNotes()

        XCTAssertEqual(selection.selectedTab, .hotkeys)
    }

    func test_notes_tab_renders_in_settings_detail_pane() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Settings")
            .appendingPathComponent("SettingsWindowView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        // Notes is a regular Settings tab now — its surface (list -> editor) lives
        // in the detail pane next to the Settings sidebar, not a full-window screen.
        XCTAssertTrue(source.contains("case .notes"))
        XCTAssertTrue(source.contains("MeetingsContentControllerView"))
        XCTAssertTrue(source.contains("settingsShell"))
    }

    func test_app_delegate_routes_hotkeys_to_settings_tab() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("AppDelegate.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("openSettingsWindow(tab: .hotkeys)"))
    }

    func test_app_delegate_routes_notes_to_settings_tab() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("AppDelegate.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("openSettingsWindow(tab: .notes)"))
    }

    func test_dynamic_island_routes_settings_tile_to_models_tab() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("AppDelegate.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("openSettings: { [weak self] in"))
        XCTAssertTrue(source.contains("self?.openSettingsWindow(tab: .models)"))
    }

    func test_window_controller_show_close_show_does_not_crash() {
        let controller = SettingsWindowController()

        controller.show()
        controller.close()
        controller.show()
        controller.close()

        XCTAssertNotNil(controller.window)
    }

    func test_allCases_contains_toolbox() {
        XCTAssertTrue(SettingsWindowTab.allCases.contains(.toolbox))
    }

    func test_toolbox_tab_has_title() {
        XCTAssertEqual(SettingsWindowTab.toolbox.title, "Toolbox")
    }

    func test_toolbox_tab_has_system_image() {
        XCTAssertFalse(SettingsWindowTab.toolbox.fallbackSystemImageName.isEmpty)
    }

    func test_selection_highlight_starts_nil() {
        let selection = SettingsWindowSelection()
        XCTAssertNil(selection.highlightedTarget)
    }

    func test_selection_highlight_can_be_set() {
        let selection = SettingsWindowSelection()
        selection.setHighlight(.tab(.hotkeys))
        XCTAssertNotNil(selection.highlightedTarget)
        if case .tab(let tab) = selection.highlightedTarget! {
            XCTAssertEqual(tab, .hotkeys)
        } else {
            XCTFail("Expected .tab(.hotkeys)")
        }
    }

    func test_settings_window_view_source_has_quit_row() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Settings")
            .appendingPathComponent("SettingsWindowView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("Quit Whytap"),
                      "Sidebar must have a pinned Quit Whytap row")
        XCTAssertTrue(source.contains("NSApp.terminate(nil)"),
                      "Quit row must call NSApp.terminate(nil)")
    }

    func test_settings_window_view_source_has_pinned_faq_row() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Settings")
            .appendingPathComponent("SettingsWindowView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("FAQ & Learning"),
                      "Settings sidebar must expose the FAQ without a hidden hotkey")
        XCTAssertTrue(source.contains("HelpWindowContent.learningCenterURL"),
                      "FAQ row must open the flavor-aware Learning Center URL")
    }

    func test_settings_window_view_source_has_toolbox_case() throws {
        let root = try projectRoot()
        let sourceURL = root
            .appendingPathComponent("Sources")
            .appendingPathComponent("Sidekey")
            .appendingPathComponent("Settings")
            .appendingPathComponent("SettingsWindowView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("case .toolbox:"),
                      "detailPane must handle .toolbox tab")
        XCTAssertTrue(source.contains("ToolboxSettingsView"),
                      "detailPane must route to ToolboxSettingsView")
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
        throw NSError(domain: "SettingsWindowControllerTests", code: 1)
    }
}

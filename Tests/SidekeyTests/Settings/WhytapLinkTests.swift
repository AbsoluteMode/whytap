// Tests/SidekeyTests/Settings/WhytapLinkTests.swift
import AppKit
import XCTest
@testable import Sidekey

final class WhytapLinkTests: XCTestCase {

    private func request(_ string: String) -> WhytapLinkRequest? {
        guard let url = URL(string: string) else { return nil }
        return WhytapLink.request(for: url)
    }

    private func destination(_ string: String) -> WhytapLinkDestination? {
        switch request(string) {
        case .show(let destination): return destination
        case .propose(let change): XCTFail("\(string) proposed \(change)"); return nil
        case nil: return nil
        }
    }

    private static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Source of one function, up to the next sibling declaration.
    private func body(of signature: String, in file: String) throws -> Substring {
        let source = try String(contentsOf: Self.root.appendingPathComponent(file), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: signature), signature)
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    (private |@objc private )?(static )?func ", options: .regularExpression)?
            .lowerBound ?? rest.endIndex
        return rest[..<end]
    }

    // MARK: - Every tile and tab

    func test_every_tool_link_shows_the_place_its_tile_belongs_to() {
        for tool in HoverTool.allCases {
            let parsed = destination("whytap://tool/\(tool.rawValue)")
            XCTAssertEqual(parsed, WhytapLink.destination(for: tool), "\(tool)")

            switch HoverToolRegistry.info(for: tool).kind {
            case .inlinePanel:
                // Same panel as the tile click and its feature hotkey.
                guard case .openPanel(let panel) = HoverSlotRouter.effect(for: tool) else {
                    XCTFail("\(tool) is an inline panel without a panel effect")
                    continue
                }
                // Case asks for Touch ID on appear, so its link stops at Toolbox.
                let expected: WhytapLinkDestination = tool == .caseVault
                    ? .settings(.tab(.toolbox)) : .hoverPanel(panel)
                XCTAssertEqual(parsed, expected, "\(tool)")
            case .navigate(let target):
                XCTAssertEqual(parsed, .settings(target), "\(tool)")
            case .action:
                if case .hoverPanel = parsed { XCTFail("\(tool) action opened a hover panel") }
                XCTAssertNotEqual(parsed, .island, "\(tool) has no place")
            }
        }
    }

    func test_every_settings_link_opens_and_highlights_its_tab() {
        for tab in SettingsWindowTab.allCases {
            XCTAssertEqual(destination("whytap://settings/\(tab.rawValue)"), .settings(.tab(tab)), "\(tab)")
        }
    }

    func test_known_tool_destinations_do_not_run_actions() {
        XCTAssertEqual(destination("whytap://tool/meetingRecord"), .toolboxTool(.meetingRecord))
        XCTAssertEqual(destination("whytap://tool/screenshot"), .toolboxTool(.screenshot))
        XCTAssertEqual(destination("whytap://tool/dropMode"), .toolboxTool(.dropMode))
        XCTAssertEqual(destination("whytap://tool/quit"), .settings(.quitRow))
        XCTAssertEqual(destination("whytap://tool/settings"), .settings(.tab(.apiAndModels)))
        XCTAssertEqual(destination("whytap://tool/tasks"), .hoverPanel(.tasks))
        XCTAssertEqual(destination("whytap://tool/calendar"), .hoverPanel(.calendar))
        XCTAssertEqual(destination("whytap://tool/translate"), .translation(.text))
        XCTAssertEqual(destination("whytap://tool/subtitles"), .translation(.subtitles))
    }

    // MARK: - Show only (Invariant 7)

    /// Every destination kind is reviewed as show-only. A new case does not
    /// compile here until someone classifies it.
    private func isShowOnly(_ destination: WhytapLinkDestination) -> Bool {
        switch destination {
        case .hoverPanel(let panel):
            return isShowOnly(panel)
        case .toolboxTool(let tool):
            // Toolbox panes whose action is an explicit button. Case's pane
            // requests Touch ID on appear and is excluded.
            return [.dropMode, .meetingRecord, .screenshot].contains(tool)
        case .settings, .translation, .island:
            return true
        }
    }

    /// Each inline panel is reviewed for what it does when it appears.
    private func isShowOnly(_ panel: HoverInlinePanel) -> Bool {
        switch panel {
        case .history, .tasks, .calendar, .notifications, .vocabularyEditor, .fillerEditor,
             .inputLanguagePicker, .outputLanguagePicker, .monitor, .brightness:
            // Show content; changes need a click or typing.
            return true
        case .caseVault:
            // Requests Touch ID when it appears.
            return false
        }
    }

    func test_no_link_runs_an_action_or_asks_for_authentication() {
        let destinations = HoverTool.allCases.map(WhytapLink.destination(for:))
            + SettingsWindowTab.allCases.map(WhytapLink.destination(for:))
        for destination in destinations {
            XCTAssertTrue(isShowOnly(destination), "\(destination)")
        }
    }

    func test_link_handler_never_calls_an_action() throws {
        let file = "Sources/Sidekey/AppDelegate.swift"
        let show = try body(of: "private func show(_ destination: WhytapLinkDestination)", in: file)
        for forbidden in ["invoke(", "actions.", "toggle", "quit", "Quit", "paste", "Pasteboard", "copy",
                          "record", "Record", "unlock", "openScreenshot", "start(", "terminate", "apply("] {
            XCTAssertFalse(show.contains(forbidden), "The whytap:// handler must only show places: found \(forbidden)")
        }
        for entry in ["@objc private func handleGetURLEvent(", "private func handle(_ request: WhytapLinkRequest)"] {
            let source = try body(of: entry, in: file)
            XCTAssertFalse(source.contains("apply("), "\(entry) applies a change without confirmation")
        }
    }

    /// A proposed change reaches `HotkeyPreferences.apply` only after the
    /// user's Assign in Whytap's own dialog.
    func test_a_link_change_is_applied_only_after_confirmation() throws {
        let propose = try body(of: "private func propose(_ change: WhytapLinkChange)",
                               in: "Sources/Sidekey/AppDelegate.swift")
        let confirm = try XCTUnwrap(propose.range(of: "WhytapLinkConfirmation.confirm("))
        let apply = try XCTUnwrap(propose.range(of: ".apply("))
        XCTAssertLessThan(confirm.lowerBound, apply.lowerBound)
        XCTAssertEqual(propose.components(separatedBy: ".apply(").count, 2, "one apply call")

        XCTAssertGreaterThanOrEqual(WhytapLinkConfirmation.armingDelay, 1.0)
    }

    @MainActor
    func test_native_confirmation_defaults_to_cancel_without_showing_a_window() throws {
        _ = NSApplication.shared
        let combo = try XCTUnwrap(WhytapLink.linkCombo(from: "option+shift+s"))
        let alert = WhytapLinkConfirmation.makeDialog(.toolHotkey(.screenshot, combo), replacing: nil)
        XCTAssertEqual(alert.buttons.count, 2)
        let cancel = alert.buttons[0]
        let assign = alert.buttons[1]
        XCTAssertEqual(cancel.title, "Cancel")
        XCTAssertEqual(cancel.keyEquivalent, "\r", "A first Cancel title alone receives Escape, not Return")
        XCTAssertTrue(alert.window.defaultButtonCell === cancel.cell)
        XCTAssertEqual(assign.title, "Assign")
        XCTAssertEqual(assign.keyEquivalent, "")
        XCTAssertFalse(assign.isEnabled)
        XCTAssertFalse(alert.window.isVisible)
        alert.layout()
        XCTAssertTrue(alert.window.defaultButtonCell === cancel.cell)
        XCTAssertEqual(cancel.keyEquivalent, "\r")
        XCTAssertFalse(alert.window.isVisible, "Layout must remain offscreen; never runModal in this fixture")
    }

    func test_scheme_and_kind_are_case_insensitive_but_ids_are_not() {
        XCTAssertEqual(destination("WHYTAP://Settings/agentMode"), .settings(.tab(.agentMode)))
        XCTAssertEqual(destination("whytap://settings/AGENTMODE"), .island)
    }

    // MARK: - Links from a newer site

    func test_unknown_ids_and_kinds_only_show_the_island() {
        XCTAssertEqual(destination("whytap://tool/someFutureTile"), .island)
        XCTAssertEqual(destination("whytap://settings/someFutureTab"), .island)
        XCTAssertEqual(destination("whytap://feature/notes"), .island)
    }

    func test_query_and_fragment_are_ignored() {
        XCTAssertEqual(destination("whytap://settings/backup?from=ask#top"), .settings(.tab(.backup)))
    }

    // MARK: - Rejected

    func test_other_schemes_are_rejected() {
        XCTAssertNil(destination("https://tool/notes"))
        XCTAssertNil(destination("whytapx://tool/notes"))
        XCTAssertNil(destination("file:///tool/notes"))
        XCTAssertNil(destination("exodia://settings/backup"))
    }

    func test_missing_kind_or_id_is_rejected() {
        XCTAssertNil(destination("whytap://"))
        XCTAssertNil(destination("whytap:tool/notes"))
        XCTAssertNil(destination("whytap:///notes"))
        XCTAssertNil(destination("whytap://tool"))
        XCTAssertNil(destination("whytap://tool/"))
        XCTAssertNil(destination("whytap://settings"))
    }

    func test_extra_segments_and_traversal_are_rejected() {
        XCTAssertNil(destination("whytap://tool/notes/"))
        XCTAssertNil(destination("whytap://tool/notes/extra"))
        XCTAssertNil(destination("whytap://tool//notes"))
        XCTAssertNil(destination("whytap://tool/.."))
        XCTAssertNil(destination("whytap://tool/../settings/backup"))
        XCTAssertNil(destination("whytap://settings/%2E%2E"))
        XCTAssertNil(destination("whytap://settings/backup%2Fother"))
        XCTAssertNil(destination("whytap://tool/.notes"))
    }

    func test_ids_outside_the_raw_value_alphabet_are_rejected() {
        XCTAssertNil(destination("whytap://tool/meeting-record"))
        XCTAssertNil(destination("whytap://tool/notes%00"))
        XCTAssertNil(destination("whytap://tool/n%C3%B6tes"))
        XCTAssertNil(destination("whytap://tool/" + String(repeating: "a", count: 65)))
    }

    func test_credentials_and_ports_are_rejected() {
        XCTAssertNil(destination("whytap://user@tool/notes"))
        XCTAssertNil(destination("whytap://user:secret@tool/notes"))
        XCTAssertNil(destination("whytap://tool:80/notes"))
    }

    // MARK: - Toolbox focus and registration

    @MainActor
    func test_toolbox_focus_selects_toolbox_and_carries_the_tool() {
        let selection = SettingsWindowSelection()
        selection.focus(HoverTool.meetingRecord)
        XCTAssertEqual(selection.selectedTab, .toolbox)
        XCTAssertEqual(selection.focusedTool, .meetingRecord)
    }

    func test_info_plist_registers_the_whytap_scheme() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("Resources/Info.plist.template"),
                                encoding: .utf8)
        let pattern = "<key>CFBundleURLTypes</key>\\s*<array>\\s*<dict>[\\s\\S]*?"
            + "<key>CFBundleURLSchemes</key>\\s*<array>\\s*<string>whytap</string>"
        XCTAssertNotNil(source.range(of: pattern, options: .regularExpression))
    }
}

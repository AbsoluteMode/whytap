// Tests/SidekeyTests/Settings/WhytapLinkHotkeyTests.swift
import Carbon.HIToolbox
import XCTest
@testable import Sidekey

/// `whytap://hotkey/<HoverTool>?keys=…` proposes a tool hotkey; Whytap applies
/// it only after its own confirmation. These cover parsing, the safety limits
/// and the plan shown to the user.
final class WhytapLinkHotkeyTests: XCTestCase {

    private let option = UInt32(optionKey)
    private let shift = UInt32(shiftKey)
    private let control = UInt32(controlKey)
    private let command = UInt32(cmdKey)

    private func request(_ string: String) -> WhytapLinkRequest? {
        URL(string: string).flatMap(WhytapLink.request(for:))
    }

    private func combo(_ code: Int, _ modifiers: UInt32, _ title: String) -> HotkeyTapCombo {
        HotkeyTapCombo(keyCode: UInt32(code), modifiers: modifiers, keyTitle: title)
    }

    private let showHotkeys = WhytapLinkRequest.show(.settings(.tab(.hotkeys)))

    // MARK: - Parsing

    func test_link_proposes_the_tool_hotkey() {
        XCTAssertEqual(request("whytap://hotkey/screenshot?keys=option+shift+s"),
                       .propose(.toolHotkey(.screenshot, combo(kVK_ANSI_S, option | shift, "S"))))
    }

    func test_every_tool_but_quit_accepts_a_link_hotkey() {
        for tool in HoverTool.allCases {
            let parsed = request("whytap://hotkey/\(tool.rawValue)?keys=ctrl+option+k")
            if tool == .quit {
                XCTAssertEqual(parsed, showHotkeys, "a link must not give Quit a hotkey")
            } else {
                XCTAssertEqual(parsed, .propose(.toolHotkey(tool, combo(kVK_ANSI_K, control | option, "K"))),
                               "\(tool)")
            }
        }
    }

    func test_modifier_aliases_case_and_key_kinds() {
        XCTAssertEqual(request("whytap://hotkey/notes?keys=Ctrl+Alt+F5"),
                       .propose(.toolHotkey(.notes, combo(kVK_F5, control | option, "F5"))))
        XCTAssertEqual(request("whytap://hotkey/notes?keys=command+option+1"),
                       .propose(.toolHotkey(.notes, combo(kVK_ANSI_1, command | option, "1"))))
        XCTAssertEqual(request("whytap://hotkey/notes?keys=opt+%2F"),
                       .propose(.toolHotkey(.notes, combo(kVK_ANSI_Slash, option, "/"))))
        XCTAssertEqual(request("whytap://hotkey/notes?keys=control%20shift%20m"),
                       .propose(.toolHotkey(.notes, combo(kVK_ANSI_M, control | shift, "M"))))
    }

    func test_unsafe_or_malformed_keys_only_show_hotkeys() {
        for keys in ["cmd+c", "cmd+q", "shift+a", "cmd+shift+4", "s", "option", "option+space",
                     "option+tab", "option+return", "option+escape", "option+delete", "option+option+s",
                     "option+s+d", "hyper+s", "option+", "+s", "option+%E2%8C%98", "option+ss",
                     "ctrl+option+shift+cmd+f21"] {
            XCTAssertEqual(request("whytap://hotkey/notes?keys=\(keys)"), showHotkeys, keys)
        }
    }

    func test_query_must_be_exactly_one_keys_item() {
        XCTAssertEqual(request("whytap://hotkey/notes"), showHotkeys)
        XCTAssertEqual(request("whytap://hotkey/notes?key=option+n"), showHotkeys)
        XCTAssertEqual(request("whytap://hotkey/notes?keys=option+n&keys=option+m"), showHotkeys)
        XCTAssertEqual(request("whytap://hotkey/notes?keys=option+n&then=apply"), showHotkeys)
    }

    func test_unknown_tool_shows_hotkeys_and_path_rules_still_apply() {
        XCTAssertEqual(request("whytap://hotkey/someFutureTile?keys=option+n"), showHotkeys)
        XCTAssertNil(request("whytap://hotkey/notes/extra?keys=option+n"))
        XCTAssertNil(request("whytap://hotkey/..?keys=option+n"))
        XCTAssertNil(request("https://hotkey/notes?keys=option+n"))
    }

    // MARK: - Plan

    private let screenshotKeys = HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | shiftKey),
                                                keyTitle: "S")

    func test_free_keys_ask_for_confirmation() {
        let change = WhytapLinkChange.toolHotkey(.screenshot, screenshotKeys)
        XCTAssertEqual(change.plan(for: .defaults), .confirm(current: nil))
    }

    func test_replacing_an_existing_tool_hotkey_names_it() {
        var configuration = HotkeyConfiguration.defaults
        let old = HotkeyShortcut.combo(combo(kVK_ANSI_X, control | option, "X"))
        configuration.toolShortcuts[.screenshot] = old
        XCTAssertEqual(WhytapLinkChange.toolHotkey(.screenshot, screenshotKeys).plan(for: configuration),
                       .confirm(current: old))
    }

    func test_same_keys_are_unchanged() {
        var configuration = HotkeyConfiguration.defaults
        configuration.toolShortcuts[.screenshot] = .combo(screenshotKeys)
        XCTAssertEqual(WhytapLinkChange.toolHotkey(.screenshot, screenshotKeys).plan(for: configuration), .unchanged)
    }

    func test_keys_owned_by_other_actions_are_a_conflict() {
        let meetingRecord = WhytapLinkChange.toolHotkey(.notes, combo(kVK_ANSI_M, option, "M"))
        XCTAssertEqual(meetingRecord.plan(for: .defaults), .conflict(actionTitles: ["Meeting record"]))

        let help = WhytapLinkChange.toolHotkey(.notes, combo(kVK_ANSI_H, option, "H"))
        XCTAssertEqual(help.plan(for: .defaults), .conflict(actionTitles: ["Help"]))

        var configuration = HotkeyConfiguration.defaults
        configuration.toolShortcuts[.monitor] = .combo(screenshotKeys)
        XCTAssertEqual(WhytapLinkChange.toolHotkey(.screenshot, screenshotKeys).plan(for: configuration),
                       .conflict(actionTitles: ["Monitor"]))
    }

    func test_applying_changes_only_that_tool_hotkey() {
        var configuration = HotkeyConfiguration.defaults
        configuration.toolShortcuts[.monitor] = .combo(combo(kVK_ANSI_X, control | option, "X"))
        let result = WhytapLinkChange.toolHotkey(.screenshot, screenshotKeys).applied(to: configuration)
        var expected = configuration
        expected.toolShortcuts[.screenshot] = .combo(screenshotKeys)
        XCTAssertEqual(result, expected)
        XCTAssertTrue(result.conflicts.isEmpty)
    }

    // MARK: - Saved through the same path as Settings

    @MainActor
    func test_confirmed_change_saves_like_settings_and_then_reads_unchanged() throws {
        let suite = "WhytapLinkHotkeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HotkeyPreferences(defaults: defaults)
        let change = WhytapLinkChange.toolHotkey(.screenshot, screenshotKeys)

        XCTAssertEqual(change.plan(for: preferences.configuration), .confirm(current: nil))
        try preferences.apply(change.applied(to: preferences.configuration))

        XCTAssertEqual(preferences.toolShortcuts[.screenshot], .combo(screenshotKeys))
        XCTAssertEqual(HotkeyPreferences(defaults: defaults).toolShortcuts[.screenshot], .combo(screenshotKeys))
        XCTAssertEqual(change.plan(for: preferences.configuration), .unchanged)
        XCTAssertEqual(preferences.meetingRecordShortcut, HotkeyConfiguration.defaults.meetingRecordShortcut)
    }
}

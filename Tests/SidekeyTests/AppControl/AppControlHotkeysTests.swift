import Carbon.HIToolbox
import Combine
import XCTest
import WhytapCaseKit
@testable import Sidekey

/// Every Whytap hotkey through the application controls, as Claude Code,
/// Codex and the island's Agent reach them: `hotkeys_get` and `hotkey_set`
/// with `hotkey`. Temporary defaults only; no monitor is installed.
private extension AppControlResponse {
    var error: (code: String, message: String)? {
        guard !ok, let code = data.object?["code"]?.string else { return nil }
        return (code, data.object?["message"]?.string ?? "")
    }
}

@MainActor
final class AppControlHotkeysTests: XCTestCase {
    private var preferences: HotkeyPreferences!
    private var toolbox: AppControlToolbox!

    override func setUp() async throws {
        let suite = "app-control-hotkeys-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let preferences = HotkeyPreferences(defaults: defaults)
        let layout = HoverLayoutStore(defaults: defaults)
        self.preferences = preferences
        toolbox = AppControlToolbox(layout: { layout }, hotkeys: { preferences })
        let saved = AppControlToolbox.keyboardCharacter
        AppControlToolbox.keyboardCharacter = { _ in nil }
        addTeardownBlock { await MainActor.run { AppControlToolbox.keyboardCharacter = saved } }
    }

    private var grave: HotkeyShortcut {
        .combo(HotkeyTapCombo(keyCode: UInt32(kVK_ANSI_Grave), modifiers: 0, keyTitle: "`"))
    }
    private func combo(_ keys: String) -> HotkeyShortcut { .combo(WhytapLink.linkCombo(from: keys)!) }

    private func set(_ arguments: [String: AppControlValue]) -> AppControlResponse {
        toolbox.handle("hotkey_set", arguments)
    }

    private func rows() throws -> [String: [String: AppControlValue]] {
        let response = toolbox.handle("hotkeys_get", [:])
        XCTAssertTrue(response.ok)
        let list = try XCTUnwrap(response.data.object?["hotkeys"]?.array)
        return Dictionary(uniqueKeysWithValues: list.compactMap(\.object).map { ($0["id"]!.string!, $0) })
    }

    /// The owner's case: Drop left on Toggle with the ` key, put back on hold
    /// Space with one call. Space forces Hold, as the Settings recorder does.
    func test_dictation_back_to_hold_space_from_toggle_on_grave() throws {
        var start = preferences.configuration
        start.setDropShortcut(grave)
        start.dropVoiceGesture = .tap
        try preferences.apply(start)
        let drop = try XCTUnwrap(try rows()["dropVoice"])
        XCTAssertEqual(drop["keys"], .string("`"))
        XCTAssertEqual(drop["mode"], .string("toggle"))
        XCTAssertEqual(drop["modes"], .array([.string("hold"), .string("toggle")]))
        XCTAssertEqual(drop["changeable"], .bool(true))
        XCTAssertEqual(drop["default"]?.object?["keys"], .string("space"))

        let response = set(["hotkey": .string("dropVoice"), "keys": .string("space"), "expected": .string("`")])
        XCTAssertTrue(response.ok, "\(response)")
        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        XCTAssertEqual(response.data.object?["mode"], .string("hold"))
        XCTAssertEqual(response.data.object?["changed"], .bool(true))
        XCTAssertEqual(response.data.object?["previous"], .object(["keys": .string("`"), "mode": .string("toggle")]))
        XCTAssertEqual(try rows()["dropVoice"]?["modes"], .array([.string("hold")]))

        let again = set(["hotkey": .string("dropVoice"), "keys": .string("space"), "mode": .string("hold"),
                         "expected": .string("space")])
        XCTAssertEqual(again.data.object?["changed"], .bool(false))
    }

    /// The running app re-registers from the published preferences: the
    /// AppDelegate sinks receive the new Drop shortcut and gesture.
    func test_a_change_reaches_the_drop_monitor_observers_at_once() throws {
        var shortcuts: [HotkeyShortcut] = [], gestures: [HotkeyGesture] = []
        let a = AppDelegate.observeDropShortcut(preferences) { shortcuts.append($0) }
        let b = AppDelegate.observeDropGesture(preferences) { gestures.append($0) }
        defer { a.cancel(); b.cancel() }
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "keys": .string("control+option+d"), "mode": .string("toggle"),
                           "expected": .string("space")]).ok)
        XCTAssertEqual(shortcuts.last, combo("control+option+d"))
        XCTAssertEqual(gestures.last, .tap)

        var tools: [[HoverTool: HotkeyShortcut]] = []
        let c = AppDelegate.observeToolShortcuts(preferences) { tools.append($0) }
        defer { c.cancel() }
        XCTAssertTrue(set(["hotkey": .string("tool.screenshot"), "keys": .string("option+s"), "expected": .null]).ok)
        XCTAssertEqual(tools.last?[.screenshot], combo("option+s"))
    }

    func test_switch_hold_and_toggle_on_a_combo_keeps_the_keys() throws {
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "keys": .string("option+d"), "expected": .string("space")]).ok)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "mode": .string("toggle"), "expected": .string("option+d")]).ok)
        XCTAssertEqual(preferences.dropVoiceShortcut, combo("option+d"))
        XCTAssertEqual(preferences.dropVoiceGesture, .tap)
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "mode": .string("hold"), "expected": .string("option+d")]).ok)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)

        var gestures: [HotkeyGesture] = []
        let sink = preferences.$googleSearchVoiceGesture.dropFirst().sink { gestures.append($0) }
        defer { sink.cancel() }
        XCTAssertTrue(set(["hotkey": .string("googleVoice"), "keys": .string("control+option+g"), "mode": .string("toggle"),
                           "expected": .string("right_option")]).ok)
        XCTAssertEqual(gestures, [.tap])
    }

    func test_toggle_on_space_and_space_elsewhere_are_refused_and_change_nothing() throws {
        let before = preferences.configuration
        let toggle = set(["hotkey": .string("dropVoice"), "mode": .string("toggle"), "expected": .string("space")])
        XCTAssertEqual(toggle.error?.code, "invalid_mode")
        XCTAssertTrue(toggle.error?.message.contains("hold-only") == true)
        XCTAssertEqual(set(["hotkey": .string("meetingRecord"), "keys": .string("space"), "expected": .string("option+m")]).error?.code,
                       "hotkey_not_allowed")
        XCTAssertEqual(set(["hotkey": .string("agentClose"), "mode": .string("hold"), "expected": .string("option+q")]).error?.code,
                       "invalid_mode")
        XCTAssertEqual(preferences.configuration, before)
    }

    /// One physical key = one action: ⌥M is meeting recording. Nothing moves;
    /// the answer names the owner and free keys.
    func test_conflict_names_the_owner_and_the_nearest_free_keys() throws {
        let before = preferences.configuration
        let response = set(["hotkey": .string("dropVoice"), "keys": .string("option+m"), "expected": .string("space")])
        XCTAssertEqual(response.error?.code, "hotkey_conflict")
        let message = try XCTUnwrap(response.error?.message)
        XCTAssertTrue(message.contains("⌥M is already used by Meeting record"), message)
        XCTAssertTrue(message.contains("Nearest free keys: option+shift+m"), message)
        XCTAssertEqual(preferences.configuration, before)

        // Agent voice toggle on Right Command would be a tap, Agent text's.
        let split = set(["hotkey": .string("agentVoice"), "mode": .string("toggle"), "expected": .string("right_command")])
        XCTAssertEqual(split.error?.code, "hotkey_conflict")
        XCTAssertTrue(split.error?.message.contains("Agent text") == true, "\(split)")
        XCTAssertEqual(preferences.configuration, before)
    }

    func test_modifier_only_drop_and_reset_to_default() throws {
        let response = set(["hotkey": .string("dropVoice"), "keys": .string("Right Option"), "expected": .string("space")])
        // Google search holds Right Option: refused.
        XCTAssertEqual(response.error?.code, "hotkey_conflict")
        XCTAssertTrue(response.error?.message.contains("Google") == true, "\(response)")
        XCTAssertTrue(set(["hotkey": .string("googleText"), "keys": .string("option+g"), "expected": .string("right_option")]).ok)
        XCTAssertTrue(set(["hotkey": .string("googleVoice"), "keys": .string("control+option+g"),
                           "expected": .string("right_option")]).ok)
        let drop = set(["hotkey": .string("dropVoice"), "keys": .string("right_option"), "expected": .string("space")])
        XCTAssertTrue(drop.ok, "\(drop)")
        XCTAssertEqual(preferences.dropVoiceShortcut, .modifier(.rightOption))
        XCTAssertEqual(try rows()["dropVoice"]?["display"], .string("R⌥"))

        let reset = set(["hotkey": .string("dropVoice"), "reset": .bool(true), "expected": .string("right_option")])
        XCTAssertTrue(reset.ok, "\(reset)")
        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace)
        XCTAssertEqual(preferences.dropVoiceGesture, .hold)
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "reset": .bool(true), "keys": .string("f5"),
                            "expected": .string("space")]).error?.code, "invalid_arguments")
    }

    func test_clearing_only_tools_and_unknown_or_fixed_hotkeys() throws {
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "keys": .null, "expected": .string("space")]).error?.code, "not_clearable")
        XCTAssertTrue(set(["hotkey": .string("tool.translate"), "keys": .string("option+t"), "expected": .null]).ok)
        XCTAssertTrue(set(["hotkey": .string("tool.translate"), "keys": .null, "expected": .string("option+t")]).ok)
        XCTAssertNil(preferences.toolShortcuts[.translate])
        XCTAssertEqual(set(["hotkey": .string("help"), "keys": .string("option+j"), "expected": .string("option+h")]).error?.code,
                       "hotkey_not_allowed")
        XCTAssertEqual(set(["hotkey": .string("dictation"), "keys": .string("f5"), "expected": .null]).error?.code, "unknown_hotkey")
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "keys": .string("command+c"), "expected": .string("space")]).error?.code,
                       "invalid_hotkey")
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "keys": .string("d"), "expected": .string("space")]).error?.code,
                       "invalid_hotkey")
        XCTAssertEqual(set(["hotkey": .string("dropVoice"), "keys": .string("f5"), "extra": .bool(true),
                            "expected": .string("space")]).error?.code, "invalid_arguments")
        XCTAssertEqual(preferences.dropVoiceShortcut, .holdSpace)
    }

    func test_wrong_expected_value_changes_nothing() throws {
        let before = preferences.configuration
        let response = set(["hotkey": .string("dropVoice"), "keys": .string("f5"), "expected": .string("`")])
        XCTAssertEqual(response.error?.code, "conflict")
        XCTAssertEqual(preferences.configuration, before)
        // A bare F-key types nothing and is accepted with the right expected value.
        XCTAssertTrue(set(["hotkey": .string("dropVoice"), "keys": .string("F5"), "expected": .string("space")]).ok)
        XCTAssertEqual(try rows()["dropVoice"]?["keys"], .string("f5"))
    }

    /// The read covers every Settings → Hotkeys row, every tool and the
    /// fixed global keys.
    func test_read_lists_every_hotkey_with_modes_and_defaults() throws {
        let all = try rows()
        for id in AppControlHotkeys.Row.allCases.map(\.rawValue) + HoverTool.allCases.map({ "tool." + $0.rawValue }) + ["help", "answerEscape"] {
            XCTAssertNotNil(all[id], id)
        }
        XCTAssertEqual(all["agentText"]?["keys"], .string("right_command"))
        XCTAssertEqual(all["agentText"]?["mode"], .string("tap"))
        XCTAssertEqual(all["agentVoice"]?["mode"], .string("hold"))
        XCTAssertEqual(all["meetingRecord"]?["display"], .string("⌥M"))
        XCTAssertEqual(all["help"]?["changeable"], .bool(false))
        XCTAssertEqual(all["tool.quit"]?["changeable"], .bool(false))
        XCTAssertEqual(all["tool.screenshot"]?["clearable"], .bool(true))
        XCTAssertEqual(toolbox.handle("hotkeys_get", ["x": .bool(true)]).error?.code, "invalid_arguments")
    }
}
